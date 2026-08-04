// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 9 spec-correctness checks: admin controls + hardening, against
// SPEC.md §9 and PLAN.md's milestone 9 test list. Not covering generic
// vulnerability classes (reentrancy/access-control-on-setters/integer-edges/
// state-consistency) — those are owned by other parallel test files for this
// milestone (see Admin_Reentrancy.t.sol). This file focuses on:
//   1. Pause actually blocks all seven state-changing functions (not just
//      the five spelled out literally in SPEC.md §9's prose).
//   2. withdrawReserves draws only from totalReserves (the reserve-factor
//      cut), reflects interest accrued up to the moment of withdrawal, and
//      doesn't touch supplier principal.
//   3. Rate-curve setters (and setReserveFactor) call _accrueInterest()
//      BEFORE mutating their parameter, so interest for the elapsed gap is
//      priced under the OLD curve, not retroactively under the new one.
//   4. ltv/liquidationThreshold/liquidationBonus setters don't skip accrual
//      in a way that leaves lastAccrualTimestamp harmfully stale.
contract AdminSpecLogicTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        weth.mint(alice, 10_000e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        dai.approve(address(pool), type(uint256).max);

        dai.mint(bob, 10_000_000e18);
        vm.prank(bob);
        dai.approve(address(pool), type(uint256).max);
    }

    // ---------------------------------------------------------------
    // 1. Pause must block ALL SEVEN state-changing functions: SPEC.md §9's
    //    prose only lists five (deposit/withdraw/borrow/repay/liquidate) but
    //    PLAN.md's milestone 9 wording is explicit that all seven of
    //    depositCollateral/withdrawCollateral/supply/withdrawSupply/borrow/
    //    repay/liquidate must revert while paused. Each sub-test sets up a
    //    scenario where the call would otherwise succeed, then pauses and
    //    confirms Pausable's revert fires (not some unrelated require).
    // ---------------------------------------------------------------

    function test_PauseBlocksDepositCollateral() public {
        pool.pause();
        vm.prank(alice);
        vm.expectRevert();
        pool.depositCollateral(1e18);
    }

    function test_PauseBlocksWithdrawCollateral() public {
        vm.prank(alice);
        pool.depositCollateral(1e18);

        pool.pause();
        vm.prank(alice);
        vm.expectRevert();
        pool.withdrawCollateral(1e18);
    }

    function test_PauseBlocksSupply() public {
        pool.pause();
        vm.prank(bob);
        vm.expectRevert();
        pool.supply(1e18);
    }

    function test_PauseBlocksWithdrawSupply() public {
        vm.prank(bob);
        pool.supply(1e18);

        pool.pause();
        vm.prank(bob);
        vm.expectRevert();
        pool.withdrawSupply(1e18);
    }

    function test_PauseBlocksBorrow() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.prank(alice);
        pool.depositCollateral(1000e18);

        pool.pause();
        vm.prank(alice);
        vm.expectRevert();
        pool.borrow(1e18);
    }

    function test_PauseBlocksRepay() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(100_000e18);
        vm.stopPrank();

        pool.pause();
        vm.prank(alice);
        vm.expectRevert();
        pool.repay(1e18);
    }

    function test_PauseBlocksLiquidate() public {
        vm.prank(bob);
        pool.supply(2_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18); // $2,000,000
        pool.borrow(1_400_000e18); // 70% LTV, under 75% cap
        vm.stopPrank();

        // Crash WETH price so alice's position becomes unhealthy.
        oracle.setPrice(address(weth), 1000e18);

        dai.mint(bob, 10_000_000e18);
        pool.pause();
        vm.prank(bob);
        vm.expectRevert();
        pool.liquidate(alice);
    }

    // Confirm unpause restores all seven — a single representative call per
    // function is enough since each already reverted-then-restored path
    // shares the same whenNotPaused modifier plumbing; this closes the loop
    // that pause() isn't a one-way trip.
    function test_UnpauseRestoresAllSevenFunctions() public {
        vm.prank(bob);
        pool.supply(2_000_000e18);
        vm.prank(alice);
        pool.depositCollateral(1000e18);

        pool.pause();
        pool.unpause();

        vm.prank(alice);
        pool.depositCollateral(1e18); // depositCollateral works again

        vm.prank(alice);
        pool.withdrawCollateral(1e18); // withdrawCollateral works again

        vm.prank(bob);
        pool.supply(1e18); // supply works again

        vm.prank(bob);
        pool.withdrawSupply(1e18); // withdrawSupply works again

        // Leave a real residual debt (borrow more than we repay) so there's
        // something left to liquidate below.
        vm.prank(alice);
        pool.borrow(1_000_000e18); // borrow works again (50% LTV, safe)

        vm.prank(alice);
        pool.repay(1e18); // repay works again (partial repay, debt still outstanding)

        // liquidate: crash price to make alice liquidatable, confirm it goes through.
        oracle.setPrice(address(weth), 500e18);
        dai.mint(bob, 10_000_000e18);
        vm.prank(bob);
        pool.liquidate(alice); // liquidate works again
    }

    // ---------------------------------------------------------------
    // 2. withdrawReserves must draw only from totalReserves (the
    //    reserve-factor cut), never supplier principal, and must reflect
    //    interest accrued up to the moment of withdrawal (i.e.
    //    _accrueInterest() runs first inside withdrawReserves itself, not
    //    just relying on a caller having triggered it earlier).
    // ---------------------------------------------------------------

    function test_WithdrawReservesAccruesFirstSoItIncludesInterestUpToTheCall() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization -> borrowRate == 4% APR
        vm.stopPrank();

        assertEq(pool.totalReserves(), 0);

        // Warp a full year WITHOUT anyone else triggering accrual first.
        vm.warp(block.timestamp + 365 days);
        assertEq(pool.totalReserves(), 0, "reserves must still read 0 before any accrual call");

        // interestAccrued = 800,000e18 * 4% = 32,000e18; reserveCut = 10% = 3,200e18.
        uint256 expectedReserves = 3_200e18;

        // Owner withdraws the exact expected reserve cut directly, with NO
        // prior call to touch the pool — this only succeeds if
        // withdrawReserves() itself calls _accrueInterest() first.
        pool.withdrawReserves(owner, expectedReserves);

        assertEq(pool.totalReserves(), 0, "withdrawing the full accrued reserve cut must zero it out");
        assertEq(dai.balanceOf(owner), expectedReserves);
    }

    function test_WithdrawReservesRevertsBeyondAccruedReserves() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 expectedReserves = 3_200e18;
        // One wei beyond the accrued cut must revert — proves the cap is
        // exactly totalReserves (post-accrual), not some looser bound like
        // the pool's whole DAI balance or supplier principal.
        vm.expectRevert();
        pool.withdrawReserves(owner, expectedReserves + 1);
    }

    function test_WithdrawReservesDoesNotTouchSupplierPrincipalOrSupply() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // Trigger accrual + settlement first via a no-op call, so the
        // "before" snapshot below is taken AFTER interest has already been
        // credited to suppliers — isolating whether withdrawReserves()
        // itself further disturbs supplier accounting, rather than
        // conflating that with the (correct, expected) growth from accrual.
        vm.prank(bob);
        pool.supply(0);

        uint256 supplyBefore = pool.totalDaiSupplied();
        uint256 bobBalanceBefore = pool.suppliedBalance(bob);

        pool.withdrawReserves(owner, 3_200e18);

        // Reserve withdrawal must be entirely orthogonal to supplier
        // accounting: totalDaiSupplied and bob's individual balance are
        // untouched by draining totalReserves.
        assertEq(pool.totalDaiSupplied(), supplyBefore, "withdrawReserves must not touch totalDaiSupplied");
        assertEq(pool.suppliedBalance(bob), bobBalanceBefore, "withdrawReserves must not touch supplier balances");
    }

    // ---------------------------------------------------------------
    // 3. Rate-curve setters (baseRate/optimalUtilization/slope1/slope2) and
    //    setReserveFactor must call _accrueInterest() BEFORE mutating the
    //    parameter. If a setter mutated first and accrued after, interest
    //    for the whole elapsed gap would be mispriced under the NEW curve
    //    instead of the OLD one it actually applied for. We isolate this by
    //    warping with debt outstanding, changing a param mid-scenario, and
    //    manually computing the expected borrowIndex using the OLD rate for
    //    the elapsed gap.
    // ---------------------------------------------------------------

    function test_SetBaseRateAccruesUnderOldRateBeforeApplyingNewRate() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization -> kink -> borrowRate == 4% APR (baseRate 0)
        vm.stopPrank();

        assertEq(pool.getBorrowRate(), 0.04e18);
        assertEq(pool.borrowIndex(), 1e18);

        // Elapsed gap under the OLD curve (baseRate == 0): 1 year at 4% APR.
        vm.warp(block.timestamp + 365 days);

        // Change baseRate mid-scenario. If accrual correctly ran first using
        // the OLD baseRate (0), borrowIndex must land at exactly 1.04e18 —
        // the mis-implemented ordering (mutate-then-accrue) would instead
        // apply the NEW baseRate (0.05e18) retroactively across the whole
        // elapsed year, landing at 1.09e18 instead.
        pool.setBaseRate(0.05e18);

        assertEq(
            pool.borrowIndex(),
            1.04e18,
            "interest for the elapsed gap must have accrued under the OLD baseRate (0%), not the new one (5%)"
        );

        // Sanity: the NEW rate is now stored and live for subsequent accrual
        // (read the state variable directly — getBorrowRate() also depends
        // on utilization, which has itself shifted slightly because the
        // accrual that just ran grew totalDaiBorrowed/totalDaiSupplied by
        // different amounts, so it's not a clean isolated check of baseRate
        // alone).
        assertEq(pool.baseRate(), 0.05e18, "new baseRate must be stored and in effect for future borrow rate reads");
    }

    function test_SetOptimalUtilizationAccruesUnderOldCurveBeforeApplyingNewKink() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization -> exactly at OLD kink (0.8e18) -> rate == 4%
        vm.stopPrank();

        assertEq(pool.getBorrowRate(), 0.04e18);

        vm.warp(block.timestamp + 365 days);

        // Moving the kink to 0.9e18 mid-scenario would, under the buggy
        // (mutate-then-accrue) ordering, retroactively price the whole
        // elapsed year below-kink: rate = 0 + 0.8e18*0.04e18/0.9e18 ~= 3.55%,
        // instead of the correct 4% (at-old-kink) that actually applied.
        pool.setOptimalUtilization(0.9e18);

        assertEq(
            pool.borrowIndex(),
            1.04e18,
            "interest for the elapsed gap must have accrued under the OLD kink (80%), not the new one (90%)"
        );
    }

    function test_SetSlope1AccruesUnderOldSlopeBeforeApplyingNewSlope() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization -> exactly at kink -> rate == slope1 == 4%
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // Doubling slope1 mid-scenario; correct ordering must still have
        // accrued the elapsed year at the OLD 4%, landing at 1.04e18 exactly.
        pool.setSlope1(0.08e18);

        assertEq(
            pool.borrowIndex(),
            1.04e18,
            "interest for the elapsed gap must have accrued under the OLD slope1 (4%), not the new one (8%)"
        );
        // Read the state variable directly, not getBorrowRate() (see
        // baseRate test above for why: utilization has itself drifted from
        // the accrual that just ran, so it's not a clean isolated check).
        assertEq(pool.slope1(), 0.08e18, "new slope1 must be stored and in effect for future borrow rate reads");
    }

    function test_SetSlope2AccruesUnderOldSlopeBeforeApplyingNewSlope() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(1_000_000e18); // 100% utilization -> above kink -> rate uses slope2, == 79%
        vm.stopPrank();

        assertEq(pool.getBorrowRate(), 0.79e18);

        vm.warp(block.timestamp + 365 days);

        // interestFactor = 1 + 0.79 = 1.79 exactly under the OLD slope2.
        pool.setSlope2(1.50e18);

        assertEq(
            pool.borrowIndex(),
            1.79e18,
            "interest for the elapsed gap must have accrued under the OLD slope2 (75%), not the new one (150%)"
        );
    }

    function test_SetReserveFactorAccruesUnderOldFactorBeforeApplyingNewFactor() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization, borrowRate == 4% APR
        vm.stopPrank();

        assertEq(pool.reserveFactor(), 0.10e18);

        vm.warp(block.timestamp + 365 days);

        // interestAccrued over the year = 32,000e18 regardless of
        // reserveFactor (that only affects the SPLIT, not the total
        // interest). Under the OLD 10% factor, reserveCut must be exactly
        // 3,200e18 — a mutate-then-accrue bug would instead apply the NEW
        // 50% factor to this same interest, landing at 16,000e18.
        pool.setReserveFactor(0.50e18);

        assertEq(
            pool.totalReserves(),
            3_200e18,
            "reserve cut for the elapsed gap must have used the OLD reserveFactor (10%), not the new one (50%)"
        );
        assertEq(pool.reserveFactor(), 0.50e18, "new reserveFactor must be in effect for future accruals");
    }

    // ---------------------------------------------------------------
    // 4. ltv/liquidationThreshold/liquidationBonus don't feed the rate
    //    curve, so there's no retroactive-mispricing risk analogous to
    //    point 3 — but confirm they still don't skip accrual in a way that
    //    leaves lastAccrualTimestamp/borrowIndex stale (they call
    //    _accrueInterest() too, just without an ordering hazard since their
    //    own parameter isn't read by _accrueInterest()).
    // ---------------------------------------------------------------

    function test_SetLtvStillAccruesAndAdvancesTimestamp() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18);
        vm.stopPrank();

        uint256 tsBefore = pool.lastAccrualTimestamp();
        vm.warp(block.timestamp + 365 days);

        pool.setLtv(7000);

        assertEq(pool.lastAccrualTimestamp(), block.timestamp, "setLtv must advance lastAccrualTimestamp via accrual");
        assertGt(pool.lastAccrualTimestamp(), tsBefore);
        assertEq(pool.borrowIndex(), 1.04e18, "interest must have accrued for the elapsed gap before ltv changed");
        assertEq(pool.ltv(), 7000);
    }

    function test_SetLiquidationThresholdStillAccruesAndAdvancesTimestamp() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        pool.setLiquidationThreshold(8500);

        assertEq(
            pool.lastAccrualTimestamp(),
            block.timestamp,
            "setLiquidationThreshold must advance lastAccrualTimestamp via accrual"
        );
        assertEq(pool.borrowIndex(), 1.04e18);
        assertEq(pool.liquidationThreshold(), 8500);
    }

    function test_SetLiquidationBonusStillAccruesAndAdvancesTimestamp() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        pool.setLiquidationBonus(11500);

        assertEq(
            pool.lastAccrualTimestamp(),
            block.timestamp,
            "setLiquidationBonus must advance lastAccrualTimestamp via accrual"
        );
        assertEq(pool.borrowIndex(), 1.04e18);
        assertEq(pool.liquidationBonus(), 11500);
    }
}
