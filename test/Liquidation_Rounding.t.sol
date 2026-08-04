// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 8 rounding audit: liquidate().
//
// liquidate() introduces three new plain (floor) divisions, in order:
//   repaidDebtValueUSD = debt * daiPrice / WAD
//   seizeValueUSD      = repaidDebtValueUSD * liquidationBonus / BPS_DENOMINATOR
//   seizeAmount        = seizeValueUSD * WAD / collateralPrice
// Each one truncates DOWN. Composed, the liquidator's seized collateral can
// only ever be <= the exact (infinite-precision) 1.10x-of-repaid-debt value,
// never >. That is the safe direction for this invariant: a liquidator must
// never be able to extract MORE collateral than they are entitled to, and
// (separately) must never pay LESS mDAI than the borrower's live debt.
//
// `debt` itself is not re-derived here: it comes from _settleDebt(), which
// uses _mulDivUp (ceiling division) so principalDebt never understates the
// borrower's true fractional obligation. That's pre-existing/audited
// elsewhere (see InterestAccrual_Rounding.t.sol) - not re-tested here.
//
// One subtlety worth flagging explicitly (see test 3 below, "no bug"
// analysis): `debt` feeds INTO repaidDebtValueUSD, and `debt` is itself
// rounded UP. In isolation that might look like it could inflate the
// liquidator's payout basis and cancel out the floors that follow. It does
// not, because the liquidator's bonus is defined relative to the actual
// integer amount of mDAI they transfer (`debt`, transferred via
// safeTransferFrom(msg.sender, address(this), debt)) - not against some
// separate continuous "true" debt number that's never materialized
// on-chain. Since every division from that same integer `debt` onward
// floors, the seized collateral can never exceed 1.10x of the USD value of
// what the liquidator actually paid. Test 3 demonstrates this holds even
// when `debt` required real ceiling rounding during settlement.
contract LendingPoolHarness is LendingPool {
    constructor(address initialOwner, address collateralToken_, address daiToken_, address oracle_)
        LendingPool(initialOwner, collateralToken_, daiToken_, oracle_)
    {}

    // Plants principalDebt directly with userBorrowIndex == borrowIndex, so
    // _settleDebt() inside liquidate() is a no-op (debt is planted exactly,
    // isolating the liquidate()-specific divisions from settlement rounding).
    function setDebtForTesting(address user, uint256 amount) external {
        principalDebt[user] = amount;
        userBorrowIndex[user] = borrowIndex;
    }

    // Granular setters (mismatched principal/userBorrowIndex/borrowIndex) so
    // _settleDebt() performs REAL ceiling rounding during liquidate(),
    // per test/InterestAccrual_Rounding.t.sol's harness pattern.
    function setPrincipalDebtForTesting(address user, uint256 amount) external {
        principalDebt[user] = amount;
    }

    function setUserBorrowIndexForTesting(address user, uint256 index) external {
        userBorrowIndex[user] = index;
    }

    function setBorrowIndexForTesting(uint256 index) external {
        borrowIndex = index;
    }

    // Pure re-statement of liquidate()'s three value-conversion lines
    // (LendingPool.sol:131-133), exposed so the safe-rounding-direction
    // property can be fuzzed across a wide input space independent of the
    // rest of the contract's state machinery (deposits, health factor
    // gating, etc). Not a substitute for the end-to-end tests below, which
    // exercise the real liquidate() call path - this is supplementary.
    function exposed_computeSeizeAmount(uint256 debt, uint256 daiPrice, uint256 collateralPrice, uint256 bonus)
        external
        pure
        returns (uint256 seizeAmount)
    {
        uint256 repaidDebtValueUSD = debt * daiPrice / WAD;
        uint256 seizeValueUSD = repaidDebtValueUSD * bonus / BPS_DENOMINATOR;
        seizeAmount = seizeValueUSD * WAD / collateralPrice;
    }
}

contract LiquidationRoundingTest is Test {
    LendingPoolHarness pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);
    address liquidator = address(0x11101D);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPoolHarness(owner, address(weth), address(dai), address(oracle));

        weth.mint(alice, 1_000_000e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);

        dai.mint(liquidator, 1_000_000e18);
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // 1. All three liquidate()-specific divisions truncate DOWN, and the
    //    seized collateral never exceeds the exact (unrounded) 1.10x value
    //    of the repaid debt - i.e. rounding favors the borrower/protocol,
    //    never the liquidator.
    //
    //    debt = 13, daiPrice = 0.7e18, liquidationBonus = 11000 (default,
    //    110%), collateralPrice = 0.4e18 - every step below has a
    //    non-terminating fractional true value, forcing real truncation:
    //
    //      repaidDebtValueUSD = floor(13 * 0.7e18 / 1e18) = floor(9.1)  = 9
    //      seizeValueUSD      = floor(9 * 11000 / 10000)  = floor(9.9)  = 9
    //      seizeAmount        = floor(9 * 1e18 / 0.4e18)  = floor(22.5) = 22
    //
    //    True (unrounded) ideal seize = 13*0.7*1.10/0.4 = 25.025 tokens.
    //    Contract actually seizes only 22 - strictly less, in the
    //    liquidator's disfavor, never the reverse.
    // ------------------------------------------------------------------
    function test_Liquidate_SeizeAmountRoundsDown_NeverFavorsLiquidator() public {
        vm.prank(alice);
        pool.depositCollateral(28); // borrowerCollateral, chosen > seizeAmount(22) so it isn't capped

        oracle.setPrice(address(weth), 4e17);
        oracle.setPrice(address(dai), 7e17);

        pool.setDebtForTesting(alice, 13);

        // Confirm the position is actually unsafe before relying on
        // liquidate() to check it itself:
        //   collateralValueUSD = floor(28 * 0.4e18 / 1e18) = floor(11.2) = 11
        //   debtValueUSD       = floor(13 * 0.7e18 / 1e18) = floor(9.1)  = 9
        //   hf = (11 * 8000 * 1e18) / (10000 * 9) = 977777777777777777 < 1e18
        assertEq(pool.healthFactor(alice), 977777777777777777);

        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice);

        uint256 daiPaid = liquidatorDaiBefore - dai.balanceOf(liquidator);
        uint256 wethSeized = weth.balanceOf(liquidator) - liquidatorWethBefore;

        // Exact hand-computed values.
        assertEq(daiPaid, 13);
        assertEq(wethSeized, 22);
        assertEq(pool.collateralBalance(alice), 28 - 22);
        assertEq(pool.principalDebt(alice), 0);

        // Not capped by borrowerCollateral - this is the pure floor-division
        // result, not the min() safety net kicking in.
        assertLt(wethSeized, 28);

        // The general safe-direction property, as a cross-multiplied
        // integer inequality (avoids any real/fractional arithmetic):
        // wethSeized <= debt * daiPrice * liquidationBonus / (BPS_DENOMINATOR * collateralPrice)
        //   <=>  wethSeized * BPS_DENOMINATOR * collateralPrice <= debt * daiPrice * liquidationBonus
        uint256 lhs = wethSeized * pool.BPS_DENOMINATOR() * uint256(4e17);
        uint256 rhs = uint256(13) * uint256(7e17) * pool.liquidationBonus();
        assertLe(lhs, rhs);
        // Strict, since we deliberately forced truncation at every step:
        // lhs = 22 * 10000 * 0.4e18 = 8.8e22, rhs = 13 * 0.7e18 * 11000 = 1.001e23.
        assertEq(lhs, 8.8e22);
        assertEq(rhs, 1.001e23);
        assertLt(lhs, rhs);
    }

    // ------------------------------------------------------------------
    // 2. The exact mDAI amount pulled from the liquidator equals the
    //    borrower's full LIVE debt (post-_settleDebt, i.e. the ceiling-
    //    rounded figure) - no dust left in principalDebt, and no
    //    over-collection either.
    //
    //    principal=100, userBorrowIndex=3, borrowIndex=7 (same planted
    //    ratio as InterestAccrual_Rounding.t.sol, for a directly comparable
    //    number): true scaled debt = 100*7/3 = 233.33..., which
    //    _mulDivUp ceils to 234. A naive floor would settle to 233 and
    //    would undercharge the liquidator by 1 wei of mDAI, silently
    //    leaving 1 wei of unrecovered principalDebt behind. This asserts
    //    liquidate() pulls the full 234, not 233, and leaves zero dust.
    //
    //    Borrower has zero collateral deposited, so the position is
    //    unsafe (hf=0) regardless of price, and seizeAmount gets capped to
    //    0 by the borrowerCollateral min() - this isolates the mDAI-pull
    //    side from the collateral-seize side entirely (bad debt accepted
    //    per spec, not the concern of this test).
    // ------------------------------------------------------------------
    function test_Liquidate_PullsExactLiveDebt_NoDustNoOvercollection() public {
        oracle.setPrice(address(weth), 1e18);
        oracle.setPrice(address(dai), 1e18);

        pool.setPrincipalDebtForTesting(alice, 100);
        pool.setUserBorrowIndexForTesting(alice, 3);
        pool.setBorrowIndexForTesting(7);

        uint256 naiveFloor = (uint256(100) * 7) / 3;
        assertEq(naiveFloor, 233); // what a truncating settlement would have produced

        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice);

        uint256 daiPaid = liquidatorDaiBefore - dai.balanceOf(liquidator);

        assertEq(daiPaid, 234); // ceil(700/3) = 234, not the naive floor 233
        assertGt(daiPaid, naiveFloor);
        assertEq(pool.principalDebt(alice), 0); // no dust left behind
    }

    // ------------------------------------------------------------------
    // 3. "No bug" demonstration: even when `debt` itself required REAL
    //    ceiling rounding during _settleDebt() (not just planted exactly),
    //    chaining that rounded-up debt into the three liquidate()-specific
    //    floor divisions still never lets the liquidator extract more
    //    collateral than 1.10x of what they actually paid.
    //
    //    principal=50, userBorrowIndex=6, borrowIndex=13:
    //      true scaled debt = 50*13/6 = 108.333..., ceil -> settled debt = 109
    //    daiPrice=0.9e18, collateralPrice=0.4e18, liquidationBonus=11000:
    //      repaidDebtValueUSD = floor(109 * 0.9e18 / 1e18) = floor(98.1)  = 98
    //      seizeValueUSD      = floor(98 * 11000 / 10000)  = floor(107.8) = 107
    //      seizeAmount        = floor(107 * 1e18 / 0.4e18) = floor(267.5) = 267
    //    borrowerCollateral=300 (> 267, not capped).
    //
    //    If the +1 wei from ceiling the debt (109 vs the true 108.33...)
    //    were somehow "free" extra bonus basis for the liquidator, the
    //    cross-multiplied inequality below would fail. It does not fail -
    //    the floors compound in the borrower/protocol's favor even here,
    //    confirming this interaction is not a bug: the liquidator's bonus
    //    is anchored to the exact integer `debt` they transfer, and every
    //    downstream division only ever floors that basis down further.
    // ------------------------------------------------------------------
    function test_Liquidate_RoundedUpDebtStillNeverOverpaysLiquidator() public {
        vm.prank(alice);
        pool.depositCollateral(300);

        oracle.setPrice(address(weth), 4e17);
        oracle.setPrice(address(dai), 9e17);

        pool.setPrincipalDebtForTesting(alice, 50);
        pool.setUserBorrowIndexForTesting(alice, 6);
        pool.setBorrowIndexForTesting(13);

        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice);

        uint256 daiPaid = liquidatorDaiBefore - dai.balanceOf(liquidator);
        uint256 wethSeized = weth.balanceOf(liquidator) - liquidatorWethBefore;

        assertEq(daiPaid, 109); // ceil(50*13/6) = ceil(108.33...) = 109
        assertEq(wethSeized, 267);
        assertEq(pool.collateralBalance(alice), 300 - 267);
        assertEq(pool.principalDebt(alice), 0);
        assertLt(wethSeized, 300); // confirms uncapped: pure floor-division result

        // wethSeized * BPS_DENOMINATOR * collateralPrice <= daiPaid * daiPrice * liquidationBonus
        uint256 lhs = wethSeized * pool.BPS_DENOMINATOR() * uint256(4e17);
        uint256 rhs = daiPaid * uint256(9e17) * pool.liquidationBonus();
        assertEq(lhs, 1.068e24);
        assertEq(rhs, 1.0791e24);
        assertLe(lhs, rhs); // holds even though daiPaid itself was rounded UP by settlement
    }

    // ------------------------------------------------------------------
    // 4. General property, fuzzed independent of contract state: for any
    //    debt/daiPrice/collateralPrice/bonus, the composed floor divisions
    //    in liquidate() can never produce a seizeAmount whose USD value
    //    (at collateralPrice) exceeds `bonus` percent of the repaid debt's
    //    USD value (at daiPrice). Expressed as a cross-multiplied integer
    //    inequality so no fractional arithmetic is needed in the test
    //    itself.
    //
    //    Bounded to uint64/uint32 inputs so debt*daiPrice*bonus (the widest
    //    product computed) stays far below type(uint256).max and no
    //    overflow obscures the property being checked.
    // ------------------------------------------------------------------
    function testFuzz_ComputeSeizeAmount_NeverExceedsExactBonusValue(
        uint64 debt,
        uint64 daiPrice,
        uint64 collateralPrice,
        uint32 bonus
    ) public view {
        vm.assume(collateralPrice > 0);
        vm.assume(bonus > 0);

        uint256 seizeAmount = pool.exposed_computeSeizeAmount(debt, daiPrice, collateralPrice, bonus);

        assertLe(
            seizeAmount * pool.BPS_DENOMINATOR() * uint256(collateralPrice), uint256(debt) * uint256(daiPrice) * uint256(bonus)
        );
    }
}
