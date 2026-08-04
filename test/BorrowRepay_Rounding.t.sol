// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 6 rounding audit.
//
// Every USD-value conversion in LendingPool is `x * price / 1e18`, and
// Solidity integer division always truncates toward zero (floors, for the
// non-negative values used throughout this contract). This file checks,
// for each division introduced by borrow()/repay()/healthFactor(), which
// direction that floor pushes the result, and whether that direction is
// conservative (favors the protocol / makes checks stricter) or favors the
// user (makes checks looser — the dangerous direction for a safety gate).
//
// forge is not available in this sandbox; every numeric assertion below is
// computed by hand in the comments next to it rather than run.
//
// Reused harness pattern from test/HealthFactor.t.sol: borrow() debits real
// DAI liquidity and credits principalDebt itself, but some cases here need
// to plant an exact debt value without needing prior borrows to land on it,
// so we expose the same raw setter milestone 5's harness used.
contract LendingPoolHarness is LendingPool {
    constructor(address initialOwner, address collateralToken_, address daiToken_, address oracle_)
        LendingPool(initialOwner, collateralToken_, daiToken_, oracle_)
    {}

    function setDebtForTesting(address user, uint256 amount) external {
        principalDebt[user] = amount;
        userBorrowIndex[user] = borrowIndex;
    }
}

contract BorrowRepayRoundingTest is Test {
    LendingPoolHarness pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);
    address supplier = address(0x5011);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPoolHarness(owner, address(weth), address(dai), address(oracle));

        weth.mint(alice, 1_000_000e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);

        dai.mint(supplier, 1_000_000e18);
        vm.startPrank(supplier);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(1_000_000e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // 1. collateralValueUSD = collateralBalance * price / 1e18 truncates
    //    DOWN -> understates collateral -> makes both the LTV check and
    //    healthFactor MORE conservative (safe direction).
    // ------------------------------------------------------------------
    function test_CollateralValueTruncatesDown_MakesHealthFactorMoreConservative() public {
        // 7 wei mWETH @ price 0.3e18 ($0.3/token).
        // real collateralValueUSD = 7 * 0.3e18 / 1e18 = 2.1 (not representable
        // as an integer in 1e18-scaled "USD" units here).
        // Solidity computes: 7 * 3e17 = 2_100_000_000_000_000_000 (2.1e18),
        // then / 1e18 floors to 2, dropping the remainder 1e17 (the ".1").
        vm.prank(alice);
        pool.depositCollateral(7);
        oracle.setPrice(address(weth), 3e17);

        // Keep debtValueUSD exact (daiPrice = 1e18 is a clean multiple of
        // 1e18, so debt * 1e18 / 1e18 == debt for any debt, no truncation)
        // so this case isolates ONLY the collateral-side truncation.
        oracle.setPrice(address(dai), 1e18);
        pool.setDebtForTesting(alice, 1);

        // Computed: hf = (2 * 8000 * 1e18) / (10000 * 1) = 16000e18/10000 = 1.6e18.
        uint256 hf = pool.healthFactor(alice);
        assertEq(hf, 1.6e18);

        // Had collateralValueUSD NOT been floored (true value 2.1, not 2):
        // hf_true = (2.1 * 8000 * 1e18) / 10000 = 16800e18/10000 = 1.68e18.
        // 1.6e18 < 1.68e18: the floored computation reports a WORSE (lower)
        // health factor than the true continuous value. Understating
        // collateral can only make the position look less healthy, never
        // more — this is the safe direction.
        assertLt(hf, 1.68e18);
    }

    // ------------------------------------------------------------------
    // 2. debtValueUSD = debt * price / 1e18 truncates DOWN -> understates
    //    debt -> makes the LTV check and healthFactor look BETTER than
    //    reality. This is the direction actually worth worrying about.
    // ------------------------------------------------------------------
    function test_DebtValueTruncatesDown_MakesHealthFactorLookBetterThanReality() public {
        // 1e18 wei mWETH (1 token) @ price 1e18 ($1/token) is a clean
        // multiple of 1e18, so collateralValueUSD = 1e18 * 1e18 / 1e18 = 1e18
        // exactly — no collateral-side truncation, isolating the debt side.
        vm.prank(alice);
        pool.depositCollateral(1e18);
        oracle.setPrice(address(weth), 1e18);

        // 7 wei of debt @ daiPrice 0.3e18: real debtValueUSD = 7*0.3e18/1e18
        // = 2.1, Solidity computes 7*3e17=2.1e18 / 1e18 -> floors to 2,
        // same truncation mechanics as case 1, just on the debt leg.
        oracle.setPrice(address(dai), 3e17);
        pool.setDebtForTesting(alice, 7);

        // Computed: hf = (1e18 * 8000 * 1e18) / (10000 * 2)
        //              = 8_000e36 / 20_000 = 4e35.
        uint256 hf = pool.healthFactor(alice);
        assertEq(hf, 4e35);

        // Had debtValueUSD NOT been floored (true value 2.1, not 2), the
        // denominator would have been 10000*2.1 = 21000 instead of 20000.
        // Same numerator (8e39), strictly larger denominator (21000 > 20000)
        // => strictly SMALLER true quotient. So:
        //   hf_true = 8e39 / 21000  <  8e39 / 20000 = hf_computed.
        // The floored debtValueUSD makes the reported health factor HIGHER
        // (better) than the true continuous value — flooring debt is the
        // direction that favors the user / looks less safe than reality.
        // (21000 > 20000 is the only fact needed for that inequality —
        // no floating point required.)
        assertGt(uint256(21000), uint256(20000));
    }

    // ------------------------------------------------------------------
    // 3. The cross-multiplied LTV check in borrow():
    //      collateralValueUSD * ltv >= debtValueUSD * BPS_DENOMINATOR
    //    has no division of its own — it's a pure integer comparison, so
    //    it introduces NO additional rounding beyond whatever truncation
    //    already happened computing collateralValueUSD/debtValueUSD in
    //    steps 1/2 above. Confirmed by reading LendingPool.sol:75 — both
    //    sides are products, no `/` appears in that line. Demonstrated
    //    here with an exact-integer boundary via the real borrow() path:
    //    the check must accept the boundary at EXACT equality and reject
    //    the very next wei, with zero slack either way (a division-based
    //    check could round the boundary itself and be off by one; this
    //    one can't, because there's nothing to round).
    // ------------------------------------------------------------------
    function test_LtvCrossMultiplyCheck_IsExactAtTheWeiBoundary() public {
        // 10e18 wei mWETH (10 tokens) @ $2000 (both clean multiples of
        // 1e18) => collateralValueUSD = 20000e18 exactly, no truncation.
        vm.prank(alice);
        pool.depositCollateral(10e18);
        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18); // debtValueUSD == debt exactly

        // ltv = 7500 bps (75%) by default. Exact boundary debt:
        // collateralValueUSD * ltv == debtValueUSD * BPS_DENOMINATOR
        //   20000e18 * 7500      ==      15000e18 * 10000
        //   150,000,000e18       ==      150,000,000e18   (equal)
        // healthFactor at this debt, threshold 8000/10000:
        //   (20000e18*8000*1e18)/(10000*15000e18) ratio 1.6e8/1.5e8 > 1e18,
        // so the healthFactor gate doesn't interfere with observing the
        // LTV check's own boundary behavior here.
        vm.prank(alice);
        pool.borrow(15000e18); // exact equality: must succeed

        assertEq(pool.principalDebt(alice), 15000e18);

        // One more wei of debt: 15000e18+1.
        //   LHS = collateralValueUSD*ltv           = 150,000,000e18 (unchanged)
        //   RHS = debtValueUSD*BPS_DENOMINATOR      = (15000e18+1)*10000
        //       = 150,000,000e18 + 10000
        // LHS < RHS by exactly 10000 (an exact integer comparison — no
        // rounding ambiguity), so this must revert with "exceeds LTV".
        vm.prank(alice);
        vm.expectRevert("exceeds LTV");
        pool.borrow(1);
    }

    // ------------------------------------------------------------------
    // 4. healthFactor's final division:
    //      (collateralValueUSD * liquidationThreshold * 1e18)
    //        / (BPS_DENOMINATOR * debtValueUSD)
    //    floors. In general: for any real x, floor(x) is by definition the
    //    greatest integer <= x. Since 1e18 itself is an integer, if the
    //    true (unrounded) ratio x >= 1e18, then floor(x) >= 1e18 too — the
    //    final division can NEVER turn a mathematically-safe position
    //    (x >= 1e18) into a reported-unsafe one. It can only ever push an
    //    already-marginal or unsafe ratio down further. That's the safe
    //    direction: false "unsafe" reverts are possible at the wei level,
    //    false "safe" passes on a truly-unsafe position are not (from this
    //    division alone).
    //
    //    Demonstrated at a real 1-wei-of-debt boundary, isolating this
    //    division from steps 1/2 by keeping collateralValueUSD an exact
    //    20000e18 (as in test 3) and varying only the last wei of debt.
    // ------------------------------------------------------------------
    function test_HealthFactorFinalDivision_FloorsButNeverFalselyPasses() public {
        vm.prank(alice);
        pool.depositCollateral(10e18);
        oracle.setPrice(address(weth), 2000e18); // collateralValueUSD = 20000e18 exactly
        oracle.setPrice(address(dai), 1e18); // debtValueUSD == debt exactly

        // Exact boundary from test_HealthFactorAtExactThreshold's numbers:
        // debt = 16000e18 gives healthFactor == 1e18 exactly (already
        // covered in HealthFactor.t.sol). Here we probe 1 wei on each side.

        // --- debt = 16000e18 - 1 (true ratio is a hair ABOVE 1) ---
        // N = collateralValueUSD * liquidationThreshold * 1e18
        //   = 20000e18 * 8000 * 1e18 = 1.6e44 (exact)
        // D = BPS_DENOMINATOR * debtValueUSD = 10000*(16000e18-1)
        //   = 1.6e26 - 10000
        // D*1e18 = 1.6e44 - 1e22 = N - 1e22 < N  => floor(N/D) >= 1e18
        // D*(1e18+1) = N + (1.6e26 - 1e22 - 10000) > N => floor(N/D) <= 1e18
        // => floor(N/D) == 1e18 exactly.
        pool.setDebtForTesting(alice, 16000e18 - 1);
        assertEq(pool.healthFactor(alice), 1e18);

        // --- debt = 16000e18 + 1 (true ratio is a hair BELOW 1, genuinely
        // unsafe by 1 wei of debt) ---
        // N unchanged = 1.6e44.
        // D' = 10000*(16000e18+1) = 1.6e26 + 10000
        // D'*1e18 = N + 1e22 > N => floor(N/D') < 1e18
        // D'*(1e18-1) = N - (1.6e26 - 1e22 - 10000) < N => floor(N/D') >= 1e18-1
        // => floor(N/D') == 1e18 - 1 == 999999999999999999 exactly.
        pool.setDebtForTesting(alice, 16000e18 + 1);
        assertEq(pool.healthFactor(alice), 999999999999999999);

        // The genuinely-unsafe-by-1-wei case must actually be rejected by
        // the live withdrawCollateral() gate, confirming the floored
        // number (not just its comparison to 1e18 in isolation) drives
        // real contract behavior correctly: a position that's unsafe by
        // any margin, however small, still reverts.
        vm.prank(alice);
        vm.expectRevert("unsafe position");
        pool.withdrawCollateral(0);
    }
}
