// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// liquidate() doesn't let a test cheaply construct arbitrary debt/collateral
// ratios via the real borrow() flow (borrow() enforces the 75% LTV cap and
// pool-liquidity limits, so many degenerate liquidate() scenarios below the
// 80% liquidation threshold, or at absurd scale, are unreachable/expensive
// through borrow() alone). This harness exposes a raw principalDebt setter,
// same rationale/pattern as test/HealthFactor.t.sol's LendingPoolHarness.
contract LendingPoolLiquidationHarness is LendingPool {
    constructor(address initialOwner, address collateralToken_, address daiToken_, address oracle_)
        LendingPool(initialOwner, collateralToken_, daiToken_, oracle_)
    {}

    function setDebtForTesting(address user, uint256 amount) external {
        principalDebt[user] = amount;
        userBorrowIndex[user] = borrowIndex;
    }
}

// Zero-value and boundary/extreme-value probes for milestone 8's liquidate(),
// per PLAN.md. Follows the conventions of test/BorrowRepay_IntegerEdge.t.sol
// and test/InterestAccrual_IntegerEdge.t.sol.
contract LiquidationIntegerEdgeTest is Test {
    LendingPoolLiquidationHarness pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE); // borrower
    address bob = address(0xB0B); // supplier (LP)
    address liquidator = address(0xC0C0FEE);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPoolLiquidationHarness(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        weth.mint(alice, 1_000e18);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // Bob supplies pool liquidity so the real borrow() flow (used by the
        // healthy/exact-boundary tests) has something to lend against.
        dai.mint(bob, 1_000_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(1_000_000e18);
        vm.stopPrank();

        // Liquidator needs mDAI on hand to repay borrowers' debt.
        dai.mint(liquidator, 1_000_000e18);
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    // --- 1. Zero-debt borrower ---

    function test_RevertWhen_LiquidatingZeroDebtBorrower() public {
        // alice has never borrowed: principalDebt == 0, so healthFactor()
        // returns type(uint256).max (defined as "always safe"). liquidate()
        // checks `healthFactor(borrower) < 1e18` BEFORE it checks
        // `debt > 0`, so a zero-debt borrower is rejected by the health
        // check first.
        //
        // FINDING: this makes `require(debt > 0, "no debt to liquidate")`
        // dead code. healthFactor() returns type(uint256).max exactly when
        // (and only when) live debt is 0, and liquidate() always calls
        // _settleDebt(borrower) (which makes principalDebt == _liveDebt)
        // before reading either value. So debt == 0 <=> healthFactor == max
        // always holds at that point in the function — there is no reachable
        // state where healthFactor < 1e18 AND debt == 0. The revert reason a
        // caller actually sees for a zero-debt borrower is "position is
        // healthy", never "no debt to liquidate". This is not a
        // divide-by-zero or memory-safety issue, just an unreachable check.
        assertEq(pool.principalDebt(alice), 0);
        assertEq(pool.healthFactor(alice), type(uint256).max);

        vm.prank(liquidator);
        vm.expectRevert("position is healthy");
        pool.liquidate(alice);

        assertEq(pool.principalDebt(alice), 0);
    }

    // --- 2. Health factor exactly at the 1e18 safe boundary ---

    function test_RevertWhen_HealthFactorExactlyAtOneWad() public {
        // 10 mWETH deposited, borrow exactly to the 75% LTV cap at the
        // default $2000 price (matches test/BorrowRepay_IntegerEdge.t.sol's
        // boundary test), then move the collateral price so that
        // collateralValueUSD * liquidationThreshold == debtValueUSD * BPS
        // exactly: with debt = 15,000 mDAI @ $1, that requires
        // collateralValueUSD == 15,000 * (10000/8000) == $18,750, i.e. a
        // WETH price of $1,875 for the 10 mWETH deposited.
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(15_000e18);
        vm.stopPrank();

        oracle.setPrice(address(weth), 1_875e18);

        assertEq(pool.healthFactor(alice), 1e18, "boundary setup must land exactly at 1e18");

        // liquidate() requires STRICTLY less than 1e18, so exactly-1e18 must
        // still revert as healthy.
        vm.prank(liquidator);
        vm.expectRevert("position is healthy");
        pool.liquidate(alice);

        // Nothing should have moved (revert unwinds the whole call).
        assertEq(pool.principalDebt(alice), 15_000e18);
        assertEq(pool.collateralBalance(alice), 10e18);
    }

    // --- 3. Healthy borrower with nonzero debt ---

    function test_RevertWhen_LiquidatingHealthyBorrowerWithDebt() public {
        // Same setup, default $2000 WETH price: 75% LTV borrow leaves the
        // position comfortably above the 80% liquidation threshold
        // (healthFactor ~ 1.0667e18).
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(15_000e18);
        vm.stopPrank();

        assertGt(pool.healthFactor(alice), 1e18);
        assertGt(pool.principalDebt(alice), 0);

        vm.prank(liquidator);
        vm.expectRevert("position is healthy");
        pool.liquidate(alice);
    }

    // --- 4. 1-wei debt: seize-amount rounding must not create free collateral ---

    function test_LiquidateWithOneWeiDebtRoundsSeizeAmountDownNotUp() public {
        // No real collateral deposited, debt forced to 1 wei of mDAI via the
        // harness: collateralValueUSD == 0 makes the position maximally
        // unhealthy (healthFactor == 0) for any nonzero debt.
        pool.setDebtForTesting(alice, 1);
        assertEq(pool.healthFactor(alice), 0);

        // Expected math (mirrors liquidate()'s exact integer steps, using
        // the default oracle prices: DAI $1, WETH $2000):
        //   repaidDebtValueUSD = 1 * 1e18 / 1e18            = 1
        //   seizeValueUSD      = 1 * 11000 / 10000          = 1   (truncated)
        //   seizeAmount        = 1 * 1e18 / 2000e18         = 0   (truncated)
        // i.e. rounding truncates seizeAmount to 0 wei of collateral. This
        // is NOT a "free collateral" exploit for the liquidator — they still
        // pay the full 1 wei of real mDAI debt and receive nothing back. If
        // anything, dust-sized debts make liquidation economically
        // pointless (no bonus captured), never profitable at the borrower's
        // expense.
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);
        uint256 poolDaiBefore = dai.balanceOf(address(pool));

        vm.prank(liquidator);
        pool.liquidate(alice); // must not revert

        assertEq(pool.principalDebt(alice), 0);
        assertEq(pool.collateralBalance(alice), 0);
        assertEq(weth.balanceOf(liquidator), liquidatorWethBefore, "liquidator must receive zero collateral");
        assertEq(dai.balanceOf(liquidator), liquidatorDaiBefore - 1, "liquidator still pays the 1 wei debt");
        assertEq(dai.balanceOf(address(pool)), poolDaiBefore + 1);
    }

    // --- 5. Very large debt/collateral/price values: overflow-chain sanity ---

    function test_LiquidateWithLargeRealisticValuesDoesNotOverflow() public {
        // "Practical extreme" scale: ~1 billion mDAI of debt, and an
        // intentionally extreme (unrealistic) shared asset price of 1e24 to
        // stress the debt*price multiplication chain.
        uint256 debt = 1_000_000_000e18; // 1e27
        uint256 sharedPrice = 1e24;

        oracle.setPrice(address(dai), sharedPrice);
        oracle.setPrice(address(weth), sharedPrice);

        // Collateral chosen so the position is unhealthy (< 1.25x debt
        // value, since threshold/BPS == 0.8) but large enough that the
        // computed seize amount does NOT get capped by borrowerCollateral —
        // isolating the "does the math chain overflow" question from the
        // capping behavior covered separately in section 6 below.
        uint256 collateralAmount = 1_150_000_000e18; // 1.15e27
        weth.mint(alice, collateralAmount);
        vm.prank(alice);
        pool.depositCollateral(collateralAmount);

        pool.setDebtForTesting(alice, debt);

        uint256 hf = pool.healthFactor(alice);
        assertLt(hf, 1e18, "collateral must be sized to leave the position unhealthy");

        // Replicate liquidate()'s exact math using the pool's own public
        // constants/getters, to avoid hand-transcribing ~30-digit literals.
        uint256 wad = pool.WAD();
        uint256 bps = pool.BPS_DENOMINATOR();
        uint256 bonus = pool.liquidationBonus();

        uint256 repaidDebtValueUSD = debt * sharedPrice / wad;
        uint256 seizeValueUSD = repaidDebtValueUSD * bonus / bps;
        uint256 expectedSeizeAmount = seizeValueUSD * wad / sharedPrice;

        assertLe(expectedSeizeAmount, collateralAmount, "test is only meaningful if capping does NOT engage here");

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        dai.mint(liquidator, debt); // liquidator needs enough mDAI to repay
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);

        vm.prank(liquidator);
        pool.liquidate(alice); // must not revert / overflow

        assertEq(pool.principalDebt(alice), 0);
        assertEq(pool.collateralBalance(alice), collateralAmount - expectedSeizeAmount);
        assertEq(weth.balanceOf(liquidator), liquidatorWethBefore + expectedSeizeAmount);
    }

    function test_Finding_ExtremeSelfMintedDebtAndPriceOverflowHealthFactorBeforeLiquidationMathRuns() public {
        // KNOWN/ACCEPTED OUT-OF-SCOPE BEHAVIOR (same category already
        // documented in test/HealthFactor.t.sol's
        // test_RevertWhen_HealthFactorNumeratorOverflows and
        // test/BorrowRepay_IntegerEdge.t.sol's huge-self-minted-collateral
        // test): if a self-minted debt and an oracle price are both pushed
        // to ~1e40, `debt * daiValue` inside healthFactor()'s debtValueUSD
        // computation exceeds type(uint256).max (~1.1579e77) and Solidity
        // 0.8's checked arithmetic panics. This happens inside the very
        // first healthFactor(borrower) call in liquidate(), before any of
        // liquidate()'s own seize-amount math or token transfers run. It is
        // not a new overflow surface introduced by liquidate() — it's the
        // pre-existing healthFactor() overflow ceiling, just reachable from
        // this entry point too. No defensive guard should be added per
        // CLAUDE.md's oracle/scope constraints.
        uint256 extremeDebt = 1e40;
        uint256 extremePrice = 1e40; // debt * price = 1e80 > type(uint256).max

        pool.setDebtForTesting(alice, extremeDebt);
        oracle.setPrice(address(dai), extremePrice);

        vm.prank(liquidator);
        vm.expectRevert(stdError.arithmeticError);
        pool.liquidate(alice);
    }

    // --- 6. Insufficient-collateral (bad debt) capping boundary ---

    function test_LiquidateSeizesExactAmountWhenCollateralExactlyCoversIt() public {
        // debt = 100 mDAI @ $1, WETH @ $2000 (default oracle prices):
        //   repaidDebtValueUSD = 100e18 * 1e18 / 1e18        = 100e18
        //   seizeValueUSD      = 100e18 * 11000 / 10000      = 110e18
        //   seizeAmount        = 110e18 * 1e18 / 2000e18     = 55_000_000_000_000_000 (5.5e16)
        uint256 debt = 100e18;
        uint256 expectedSeizeAmount = 55_000_000_000_000_000;

        // Sanity-check the hand-derived literal against the pool's own
        // constants before relying on it.
        {
            uint256 wad = pool.WAD();
            uint256 bps = pool.BPS_DENOMINATOR();
            uint256 bonus = pool.liquidationBonus();
            uint256 daiPrice = oracle.getPrice(address(dai));
            uint256 wethPrice = oracle.getPrice(address(weth));
            uint256 repaidDebtValueUSD = debt * daiPrice / wad;
            uint256 seizeValueUSD = repaidDebtValueUSD * bonus / bps;
            assertEq(seizeValueUSD * wad / wethPrice, expectedSeizeAmount);
        }

        weth.mint(alice, expectedSeizeAmount);
        vm.prank(alice);
        pool.depositCollateral(expectedSeizeAmount);
        pool.setDebtForTesting(alice, debt);

        assertLt(pool.healthFactor(alice), 1e18);
        assertEq(pool.collateralBalance(alice), expectedSeizeAmount);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice);

        // No capping: borrowerCollateral == seizeAmount exactly, so the
        // borrower is left with 0 (not a revert, not underflow) and the
        // liquidator gets the full, uncapped bonus amount.
        assertEq(pool.collateralBalance(alice), 0);
        assertEq(weth.balanceOf(liquidator), liquidatorWethBefore + expectedSeizeAmount);
    }

    function test_LiquidateCapsSeizeAmountWhenCollateralOneWeiShort() public {
        // Identical to the exact-match case above, except the borrower's
        // collateral is 1 wei short of the computed seize amount. Capping
        // must kick in: the liquidator receives 1 wei less than the
        // "entitled" bonus amount, the borrower's collateral is fully wiped
        // (not left at some nonzero dust or underflowed), and the call does
        // not revert. This is the accepted "bad debt" outcome per
        // CLAUDE.md/SPEC.md — not solved/socialized, just capped.
        uint256 debt = 100e18;
        uint256 uncappedSeizeAmount = 55_000_000_000_000_000;
        uint256 shortCollateral = uncappedSeizeAmount - 1;

        weth.mint(alice, shortCollateral);
        vm.prank(alice);
        pool.depositCollateral(shortCollateral);
        pool.setDebtForTesting(alice, debt);

        assertLt(pool.healthFactor(alice), 1e18);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice);

        assertEq(pool.collateralBalance(alice), 0, "capped seizure must still fully drain the borrower, not underflow");
        assertEq(
            weth.balanceOf(liquidator),
            liquidatorWethBefore + shortCollateral,
            "liquidator receives the capped (1 wei short) amount, not the full bonus"
        );
        assertEq(pool.principalDebt(alice), 0, "debt is still fully cleared even though collateral fell short");
    }
}
