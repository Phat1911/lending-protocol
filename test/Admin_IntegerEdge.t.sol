// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Integer/boundary-value probes for milestone 9's admin controls
// (pause/unpause, the risk-parameter setters, and withdrawReserves) in
// src/LendingPool.sol. Follows the conventions of
// test/InterestAccrual_IntegerEdge.t.sol and test/Liquidation_IntegerEdge.t.sol.
contract AdminIntegerEdgeTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE); // borrower
    address bob = address(0xB0B); // supplier (LP)

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        weth.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        dai.mint(bob, 10_000_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================================
    // 1. setOptimalUtilization: require(newOptimalUtilization > 0 && < WAD)
    // =========================================================================

    function test_RevertWhen_SetOptimalUtilizationToZero() public {
        vm.expectRevert("optimal utilization out of range");
        pool.setOptimalUtilization(0);
    }

    function test_RevertWhen_SetOptimalUtilizationToWad() public {
        vm.expectRevert("optimal utilization out of range");
        pool.setOptimalUtilization(1e18);
    }

    function test_SetOptimalUtilizationToWadMinusOneSucceeds() public {
        pool.setOptimalUtilization(1e18 - 1);
        assertEq(pool.optimalUtilization(), 1e18 - 1);
    }

    function test_SetOptimalUtilizationToOneWeiSucceeds() public {
        pool.setOptimalUtilization(1);
        assertEq(pool.optimalUtilization(), 1);
    }

    function test_GetBorrowRateDoesNotDivideByZeroWithOptimalUtilizationAtOneWei() public {
        // optimalUtilization == 1 wei: branch 1's denominator is 1 (fine),
        // branch 2's denominator (WAD - optimalUtilization) is WAD - 1
        // (also fine). Exercise both branches via real 0% and 100%
        // utilization.
        pool.setOptimalUtilization(1);

        vm.prank(bob);
        pool.supply(1_000_000e18);

        assertEq(pool.getUtilization(), 0);
        uint256 rateAtZero = pool.getBorrowRate(); // must not revert
        assertEq(rateAtZero, pool.baseRate());

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(1_000_000e18); // 100% utilization
        vm.stopPrank();

        assertEq(pool.getUtilization(), 1e18);
        uint256 rateAtFull = pool.getBorrowRate(); // must not revert
        // excessUtilization = 1e18 - 1, excessRange = 1e18 - 1 -> they
        // cancel, so rate == baseRate + slope1 + slope2 exactly.
        assertEq(rateAtFull, pool.baseRate() + pool.slope1() + pool.slope2());
    }

    function test_GetBorrowRateDoesNotDivideByZeroWithOptimalUtilizationAtWadMinusOne() public {
        // optimalUtilization == WAD - 1: branch 1's denominator is WAD - 1
        // (fine), branch 2's denominator (WAD - optimalUtilization) is 1
        // (also fine, not zero).
        pool.setOptimalUtilization(1e18 - 1);

        vm.prank(bob);
        pool.supply(1_000_000e18);

        assertEq(pool.getUtilization(), 0);
        uint256 rateAtZero = pool.getBorrowRate(); // must not revert
        assertEq(rateAtZero, pool.baseRate());

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(1_000_000e18); // 100% utilization
        vm.stopPrank();

        assertEq(pool.getUtilization(), 1e18);
        uint256 rateAtFull = pool.getBorrowRate(); // must not revert
        // excessUtilization = 1e18 - (1e18-1) = 1, excessRange = 1 -> they
        // cancel too, so rate == baseRate + slope1 + slope2 exactly.
        assertEq(rateAtFull, pool.baseRate() + pool.slope1() + pool.slope2());
    }

    // =========================================================================
    // 2. setLiquidationBonus: require(newLiquidationBonus >= BPS_DENOMINATOR)
    // =========================================================================

    function test_SetLiquidationBonusToExactlyBpsDenominatorSucceeds() public {
        pool.setLiquidationBonus(10000);
        assertEq(pool.liquidationBonus(), 10000);
    }

    function test_RevertWhen_SetLiquidationBonusOneBelowBpsDenominator() public {
        vm.expectRevert("bonus must be >= 100%");
        pool.setLiquidationBonus(9999);
    }

    function test_SetLiquidationBonusToMaxSaneCeilingSucceeds() public {
        pool.setLiquidationBonus(pool.MAX_LIQUIDATION_BONUS_BPS());
        assertEq(pool.liquidationBonus(), pool.MAX_LIQUIDATION_BONUS_BPS());
    }

    function test_RevertWhen_SetLiquidationBonusOneAboveMaxSaneCeiling() public {
        // FIX (was FINDING): setLiquidationBonus previously had no upper
        // bound, so an extreme value (e.g. type(uint256).max) didn't just
        // distort the seize amount -- it made liquidate() UNCALLABLE for any
        // borrower with nonzero debt, since
        // `debtValueDai * liquidationBonus` would overflow Solidity 0.8's
        // checked arithmetic before the collateral cap was even consulted.
        // A sane ceiling (MAX_LIQUIDATION_BONUS_BPS = 1,000%, far above any
        // realistic bonus) now rejects the value at set-time instead of
        // bricking liquidations later.
        uint256 tooHigh = pool.MAX_LIQUIDATION_BONUS_BPS() + 1;
        vm.expectRevert("bonus exceeds sane ceiling");
        pool.setLiquidationBonus(tooHigh);
    }

    // =========================================================================
    // 3. setReserveFactor: require(newReserveFactor <= WAD)
    // =========================================================================

    function test_SetReserveFactorToExactlyWadSucceeds() public {
        pool.setReserveFactor(1e18);
        assertEq(pool.reserveFactor(), 1e18);
    }

    function test_RevertWhen_SetReserveFactorOneAboveWad() public {
        vm.expectRevert("reserve factor exceeds 100%");
        pool.setReserveFactor(1e18 + 1);
    }

    function test_SetReserveFactorToZeroSucceeds() public {
        pool.setReserveFactor(0);
        assertEq(pool.reserveFactor(), 0);
    }

    // =========================================================================
    // 4. setLtv / setLiquidationThreshold cross-validation
    // =========================================================================

    function test_SetLiquidationThresholdEqualToLtvSucceeds() public {
        // Default ltv == 7500; threshold == ltv satisfies `>= ltv`.
        pool.setLiquidationThreshold(7500);
        assertEq(pool.liquidationThreshold(), 7500);
    }

    function test_RevertWhen_SetLiquidationThresholdBelowLtv() public {
        // Default ltv == 7500; one below it must revert regardless of the
        // BPS_DENOMINATOR check.
        vm.expectRevert("threshold must be >= ltv");
        pool.setLiquidationThreshold(7499);
    }

    function test_RevertWhen_SetLiquidationThresholdAboveBpsDenominator() public {
        vm.expectRevert("threshold exceeds 100%");
        pool.setLiquidationThreshold(10001);
    }

    function test_SetLtvEqualToLiquidationThresholdSucceeds() public {
        // Default liquidationThreshold == 8000; ltv == threshold satisfies
        // `<= liquidationThreshold`.
        pool.setLtv(8000);
        assertEq(pool.ltv(), 8000);
    }

    function test_RevertWhen_SetLtvAboveLiquidationThreshold() public {
        // Default liquidationThreshold == 8000.
        vm.expectRevert("ltv must be <= liquidation threshold");
        pool.setLtv(8001);
    }

    function test_SetLtvToZeroSucceeds() public {
        // No lower bound on ltv itself.
        pool.setLtv(0);
        assertEq(pool.ltv(), 0);
    }

    function test_SetLiquidationThresholdToZeroSucceedsOnceLtvIsAlsoZero() public {
        // threshold == 0 only clears `>= ltv` once ltv has been lowered to
        // 0 too (default ltv 7500 would otherwise reject it).
        pool.setLtv(0);
        pool.setLiquidationThreshold(0);
        assertEq(pool.liquidationThreshold(), 0);
    }

    // =========================================================================
    // 5. withdrawReserves
    // =========================================================================

    function _accrueRealReserves() internal returns (uint256 reservesGenerated) {
        // Generate genuine (token-backed) reserves: supply, borrow, let
        // interest accrue, then have the borrower fully repay so the real
        // mDAI backing the accrued interest actually lands in the pool
        // (accrual itself is pure bookkeeping -- no tokens move until
        // repay() pulls them in).
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(500_000e18); // 50% utilization, below the kink
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        dai.mint(alice, 10_000_000e18); // plenty to cover principal + interest
        vm.prank(alice);
        pool.repay(type(uint256).max); // capped at actual outstanding debt

        assertEq(pool.totalDaiBorrowed(), 0, "test setup expects full repayment");
        reservesGenerated = pool.totalReserves();
        assertGt(reservesGenerated, 0, "test setup expects nonzero accrued reserves");
    }

    function test_WithdrawReservesExactAmountSucceedsAndZeroesReserves() public {
        uint256 reserves = _accrueRealReserves();

        uint256 poolDaiBefore = dai.balanceOf(address(pool));
        uint256 ownerDaiBefore = dai.balanceOf(owner);

        pool.withdrawReserves(owner, reserves);

        assertEq(pool.totalReserves(), 0);
        assertEq(dai.balanceOf(address(pool)), poolDaiBefore - reserves);
        assertEq(dai.balanceOf(owner), ownerDaiBefore + reserves);
    }

    function test_RevertWhen_WithdrawReservesExceedsTotalReserves() public {
        uint256 reserves = _accrueRealReserves();

        vm.expectRevert("insufficient reserves");
        pool.withdrawReserves(owner, reserves + 1);

        assertEq(pool.totalReserves(), reserves, "failed withdrawal must not mutate state");
    }

    function test_WithdrawReservesZeroAmountWhenReservesZeroIsNoOp() public {
        assertEq(pool.totalReserves(), 0);
        pool.withdrawReserves(owner, 0); // must not revert
        assertEq(pool.totalReserves(), 0);
    }

    function test_RevertWhen_WithdrawReservesNonZeroAmountWhenReservesZero() public {
        assertEq(pool.totalReserves(), 0);
        vm.expectRevert("insufficient reserves");
        pool.withdrawReserves(owner, 1);
    }

    // =========================================================================
    // 6. setBaseRate / setSlope1 / setSlope2: bounded by MAX_RATE_CURVE_PARAM
    // =========================================================================

    function test_RevertWhen_SetBaseRateAboveMaxRateCurveParam() public {
        // FIX (was FINDING): setBaseRate previously had no upper-bound
        // check, and unlike setLiquidationBonus's footgun, that one was NOT
        // recoverable once triggered -- EVERY state-changing function
        // (including the owner's own setBaseRate/setSlope*/withdrawReserves)
        // calls _accrueInterest() first, which calls getBorrowRate()
        // whenever totalDaiBorrowed > 0. An extreme baseRate would overflow
        // that addition on the very next accrual (once time had elapsed),
        // permanently bricking the whole contract with no path to recovery.
        // MAX_RATE_CURVE_PARAM (10,000% APR, far beyond any realistic curve)
        // now rejects the value at set-time instead.
        vm.expectRevert("rate exceeds sane ceiling");
        pool.setBaseRate(type(uint256).max);
    }

    function test_SetBaseRateToMaxRateCurveParamSucceeds() public {
        pool.setBaseRate(pool.MAX_RATE_CURVE_PARAM());
        assertEq(pool.baseRate(), pool.MAX_RATE_CURVE_PARAM());
    }

    function test_RevertWhen_SetSlope1AboveMaxRateCurveParam() public {
        // Same structural risk as baseRate above, via the other
        // now-bounded setter: `(utilization * slope1) / optimalUtilization`
        // multiplies before dividing, so an extreme slope1 would overflow
        // as soon as utilization > 0. setSlope2 shares the identical shape
        // in the excess-utilization branch and carries the same bound.
        vm.expectRevert("rate exceeds sane ceiling");
        pool.setSlope1(type(uint256).max);
    }

    function test_RevertWhen_SetSlope2AboveMaxRateCurveParam() public {
        vm.expectRevert("rate exceeds sane ceiling");
        pool.setSlope2(type(uint256).max);
    }

    function test_MaxRateCurveParamsTogetherDoNotBrickAccrueInterest() public {
        // Confirms the fix actually holds end-to-end: even set to the
        // maximum allowed value on all three rate-curve params at once,
        // _accrueInterest() (called from any subsequent state-changing
        // function) still completes without overflowing.
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(500_000e18); // totalDaiBorrowed > 0, 50% utilization
        vm.stopPrank();

        pool.setBaseRate(pool.MAX_RATE_CURVE_PARAM());
        pool.setSlope1(pool.MAX_RATE_CURVE_PARAM());
        pool.setSlope2(pool.MAX_RATE_CURVE_PARAM());

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        pool.repay(0); // must not revert -- accrual completes, no overflow
    }
}
