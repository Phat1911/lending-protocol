// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {InterestAccrualHarness} from "./InterestAccrual_StateConsistency.t.sol";

// Milestone 9 added onlyOwner admin setters (ltv / liquidationThreshold /
// liquidationBonus / reserveFactor / rate-curve params) plus
// withdrawReserves and pause/unpause. These tests check the state-variable
// invariants that must hold across those new functions (same
// category/convention as test/InterestAccrual_StateConsistency.t.sol and
// test/BorrowRepay_StateConsistency.t.sol) rather than the access-
// control/pause-gating behavior itself (non-owner reverts, pause blocks
// calls, etc. — that belongs in a plain Admin.t.sol per PLAN.md's
// milestone 9 checklist and is out of scope here).
//
// Reuses InterestAccrualHarness (defined in
// InterestAccrual_StateConsistency.t.sol) purely for its side-effect-free
// accrueForTesting()/liveDebtForTesting()/liveSupplyForTesting() helpers —
// it adds no behavior of its own beyond LendingPool.
contract AdminStateConsistencyTest is Test {
    InterestAccrualHarness pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address dave = address(0xDA5E); // supplier
    address alice = address(0xA11CE); // borrower

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new InterestAccrualHarness(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        dai.mint(dave, 200_000e18);
        vm.prank(dave);
        dai.approve(address(pool), type(uint256).max);

        weth.mint(alice, 100e18);
        dai.mint(alice, 200_000e18);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // ===================================================================
    // Invariant 1: ltv <= liquidationThreshold, always, across any
    // ordering of setLtv/setLiquidationThreshold calls.
    // ===================================================================

    // Defaults: ltv = 7500 bps, liquidationThreshold = 8000 bps. Walks
    // through several orderings that SHOULD succeed (each individually
    // valid against the *current* value of the other param), asserting
    // the invariant after every call.
    function test_LtvThresholdInvariant_ValidOrderingsSucceed() public {
        assertLe(pool.ltv(), pool.liquidationThreshold());

        // Lower threshold down to meet the current ltv exactly (7500).
        pool.setLiquidationThreshold(7500);
        assertEq(pool.liquidationThreshold(), 7500);
        assertLe(pool.ltv(), pool.liquidationThreshold());

        // Threshold is now 7500, same as ltv. To go lower we must first
        // lower ltv (setLiquidationThreshold would otherwise reject it).
        pool.setLtv(7000);
        assertEq(pool.ltv(), 7000);
        assertLe(pool.ltv(), pool.liquidationThreshold());

        pool.setLiquidationThreshold(7000);
        assertEq(pool.liquidationThreshold(), 7000);
        assertLe(pool.ltv(), pool.liquidationThreshold());

        // Raise threshold first, then raise ltv to meet it — the other
        // valid ordering for moving both params upward.
        pool.setLiquidationThreshold(9000);
        assertLe(pool.ltv(), pool.liquidationThreshold());

        pool.setLtv(8000);
        assertEq(pool.ltv(), 8000);
        assertEq(pool.liquidationThreshold(), 9000);
        assertLe(pool.ltv(), pool.liquidationThreshold());
    }

    // Orderings that SHOULD be rejected: lowering threshold below the
    // current ltv, or raising ltv above the current threshold. Confirms
    // both the revert and that state is left completely unchanged.
    function test_LtvThresholdInvariant_InvalidOrderingsRevertAndLeaveStateUnchanged() public {
        assertEq(pool.ltv(), 7500);
        assertEq(pool.liquidationThreshold(), 8000);

        // Threshold below current ltv (7500) must revert.
        vm.expectRevert("threshold must be >= ltv");
        pool.setLiquidationThreshold(7000);
        assertEq(pool.liquidationThreshold(), 8000, "threshold changed despite revert");

        // Ltv above current threshold (8000) must revert.
        vm.expectRevert("ltv must be <= liquidation threshold");
        pool.setLtv(8500);
        assertEq(pool.ltv(), 7500, "ltv changed despite revert");

        // Invariant still holds after the rejected attempts.
        assertLe(pool.ltv(), pool.liquidationThreshold());

        // Sanity: the same target values succeed once applied in the
        // correct order (ltv down first, so threshold-lowering becomes
        // valid).
        pool.setLtv(7000);
        pool.setLiquidationThreshold(7000);
        assertEq(pool.ltv(), 7000);
        assertEq(pool.liquidationThreshold(), 7000);
    }

    function test_LiquidationThresholdCannotExceed100PercentAndMustStayAboveLtv() public {
        vm.expectRevert("threshold exceeds 100%");
        pool.setLiquidationThreshold(10001);

        // Exactly 100% is allowed (still >= current ltv of 7500).
        pool.setLiquidationThreshold(10000);
        assertEq(pool.liquidationThreshold(), 10000);
        assertLe(pool.ltv(), pool.liquidationThreshold());
    }

    // ===================================================================
    // Invariant 2: withdrawReserves can never draw out more mDAI than
    // totalReserves tracks, and — because totalDaiSupplied never falls
    // below totalDaiBorrowed (withdrawSupply's liquidity gate enforces
    // that) — this means it can never reach into supplier
    // principal/interest either.
    // ===================================================================

    function test_WithdrawReserves_RevertsWhenExceedingTrackedReserves() public {
        vm.prank(dave);
        pool.supply(100_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 180 days);
        pool.accrueForTesting(); // realize interest into totalReserves, no other side effects

        uint256 reserves = pool.totalReserves();
        assertGt(reserves, 0, "expected reserves to have accrued over 180 days");

        vm.expectRevert("insufficient reserves");
        pool.withdrawReserves(owner, reserves + 1);
        assertEq(pool.totalReserves(), reserves, "reserves changed despite reverted over-withdrawal");

        // Exactly the tracked amount succeeds.
        uint256 poolBalanceBefore = dai.balanceOf(address(pool));
        pool.withdrawReserves(owner, reserves);
        assertEq(pool.totalReserves(), 0);
        assertEq(dai.balanceOf(address(pool)), poolBalanceBefore - reserves);
    }

    // Full scenario from the milestone brief: supply + borrow + warp to
    // accrue real interest into totalReserves, withdraw reserves, then
    // confirm withdrawSupply still returns the full supplied+interest
    // amount — i.e. withdrawReserves did not siphon supplier funds under
    // the "reserves" label.
    function test_WithdrawReserves_ThenSupplierStillWithdrawsFullSuppliedPlusInterest() public {
        vm.prank(dave);
        pool.supply(100_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000 @ $2000/weth
        pool.borrow(5_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        pool.accrueForTesting();

        uint256 reserves = pool.totalReserves();
        assertGt(reserves, 0, "expected reserves to have accrued over a year");

        uint256 poolBalanceBeforeWithdraw = dai.balanceOf(address(pool));
        pool.withdrawReserves(owner, reserves);
        assertEq(pool.totalReserves(), 0, "reserves not fully drained");

        // Liquidity invariant (see InterestAccrual_StateConsistency.t.sol)
        // must still hold exactly, now with totalReserves == 0.
        assertEq(
            dai.balanceOf(address(pool)),
            pool.totalDaiSupplied() - pool.totalDaiBorrowed(),
            "pool balance != totalDaiSupplied - totalDaiBorrowed after reserves drained"
        );
        assertEq(dai.balanceOf(address(pool)), poolBalanceBeforeWithdraw - reserves);

        // Alice repays her full live debt (overpay, capped by repay()).
        vm.prank(alice);
        pool.repay(20_000e18);
        assertEq(pool.principalDebt(alice), 0);
        assertEq(pool.totalDaiBorrowed(), 0);

        // Dave withdraws his full live (settled) supply balance — this
        // includes his share of a year's interest, net of the 10% reserve
        // cut already pulled out above. Compute the exact live balance
        // (rather than assuming it equals totalDaiSupplied() to the wei —
        // see InterestAccrual_StateConsistency.t.sol's note on floor-
        // rounding drift between the aggregate and the per-user settled
        // amount) so the withdrawal request matches what _settleSupply
        // will actually produce.
        uint256 daveLiveSupply = pool.liveSupplyForTesting(dave);
        assertGt(daveLiveSupply, 100_000e18, "expected dave's live supply to include accrued interest");

        uint256 daveBalanceBefore = dai.balanceOf(dave);
        vm.prank(dave);
        pool.withdrawSupply(daveLiveSupply);

        assertEq(dai.balanceOf(dave), daveBalanceBefore + daveLiveSupply, "dave did not receive his full live supply");
        assertEq(pool.suppliedBalance(dave), 0, "dave's settled supply balance should be fully drained");

        // Whatever's left in totalDaiSupplied/pool balance now is at most
        // the tiny aggregate-vs-per-user rounding drift documented above
        // (dave was the sole supplier), not real supplier funds withheld.
        uint256 remainingSupplied = pool.totalDaiSupplied();
        assertLt(remainingSupplied, 1000, "unexpectedly large amount of supplier funds left stranded");
        assertEq(pool.totalDaiBorrowed(), 0);
        assertEq(
            dai.balanceOf(address(pool)),
            remainingSupplied,
            "pool balance should equal only the leftover rounding dust: no reserves, no debt"
        );
    }

    // ===================================================================
    // Invariant 3: parameter changes (setReserveFactor / setBaseRate)
    // take effect only from the point of the call forward. Because every
    // setter runs _accrueInterest() as its first line (per CLAUDE.md's
    // accrual-ordering rule), interest already accrued up to that instant
    // must be computed under the OLD parameter value, and only interest
    // accruing AFTER the call should reflect the new one. Verified via
    // "twin pools": two identically-seeded pools receive the exact same
    // actions/warps, then diverge — one takes a pure no-op accrual step,
    // the other takes the same step via the setter. If the setter's own
    // _accrueInterest() call used the NEW parameter (a retroactive-
    // corruption bug), the twins' post-call state would diverge right
    // there; it must not.
    // ===================================================================

    function test_SetReserveFactor_AccrualBoundaryClean_DoesNotRetroactivelyAffectAlreadyAccruedInterest() public {
        (InterestAccrualHarness poolA,) = _deployFundedTwinPool();
        (InterestAccrualHarness poolB,) = _deployFundedTwinPool();

        vm.warp(block.timestamp + 30 days);

        poolA.accrueForTesting(); // no-op control: accrues under the OLD (10%) reserveFactor
        poolB.setReserveFactor(0.20e18); // accrues first (old 10%), THEN changes to 20%

        // Every piece of state touched by accrual must match exactly —
        // the parameter change must not have leaked into this step.
        assertEq(poolA.totalDaiBorrowed(), poolB.totalDaiBorrowed(), "totalDaiBorrowed diverged at the boundary");
        assertEq(poolA.borrowIndex(), poolB.borrowIndex(), "borrowIndex diverged at the boundary");
        assertEq(poolA.totalReserves(), poolB.totalReserves(), "totalReserves diverged at the boundary");
        assertEq(poolA.totalDaiSupplied(), poolB.totalDaiSupplied(), "totalDaiSupplied diverged at the boundary");
        assertEq(poolA.supplyIndex(), poolB.supplyIndex(), "supplyIndex diverged at the boundary");
        assertEq(
            poolA.liveDebtForTesting(twinAlice()),
            poolB.liveDebtForTesting(twinAlice()),
            "borrower's live debt diverged at the boundary"
        );
        assertEq(
            poolA.liveSupplyForTesting(twinDave()),
            poolB.liveSupplyForTesting(twinDave()),
            "supplier's live supply diverged at the boundary"
        );
        assertEq(poolB.reserveFactor(), 0.20e18, "reserveFactor did not actually update");

        // Now prove the new value DOES take effect going forward: same
        // further warp, same accrual call on both — poolB (20%) must
        // divert roughly twice as much of this step's interest into
        // reserves as poolA (still 10%), since totalDaiBorrowed/utilization
        // (and hence the interest accrued) match going in.
        uint256 reservesABefore = poolA.totalReserves();
        uint256 reservesBBefore = poolB.totalReserves();
        assertEq(reservesABefore, reservesBBefore);

        vm.warp(block.timestamp + 30 days);
        poolA.accrueForTesting();
        poolB.accrueForTesting();

        assertEq(
            poolA.totalDaiBorrowed(),
            poolB.totalDaiBorrowed(),
            "reserveFactor should not affect total interest accrued to borrowers"
        );

        uint256 deltaA = poolA.totalReserves() - reservesABefore;
        uint256 deltaB = poolB.totalReserves() - reservesBBefore;
        assertGt(deltaA, 0, "expected poolA to still accrue some reserves this step");
        assertGt(deltaB, deltaA, "poolB's 20% reserveFactor should divert more into reserves than poolA's 10%");

        // deltaB should be ~2x deltaA (20% vs 10% of ~equal interest);
        // allow generous rounding slack (this file's own scale of drift is
        // at most a handful of wei per accrual, per
        // InterestAccrual_StateConsistency.t.sol's precedent).
        assertApproxEqAbs(deltaB, deltaA * 2, 10, "reserve split ratio did not match new/old reserveFactor ratio");
    }

    function test_SetBaseRate_AccrualBoundaryClean_DoesNotRetroactivelyAffectAlreadyAccruedInterest() public {
        (InterestAccrualHarness poolA,) = _deployFundedTwinPool();
        (InterestAccrualHarness poolB,) = _deployFundedTwinPool();

        assertEq(poolA.baseRate(), 0);

        vm.warp(block.timestamp + 30 days);

        poolA.accrueForTesting(); // no-op control: accrues under the OLD (0%) baseRate
        poolB.setBaseRate(0.05e18); // accrues first (old 0%), THEN changes baseRate to 5%

        assertEq(poolA.totalDaiBorrowed(), poolB.totalDaiBorrowed(), "totalDaiBorrowed diverged at the boundary");
        assertEq(poolA.borrowIndex(), poolB.borrowIndex(), "borrowIndex diverged at the boundary");
        assertEq(poolA.totalReserves(), poolB.totalReserves(), "totalReserves diverged at the boundary");
        assertEq(poolA.totalDaiSupplied(), poolB.totalDaiSupplied(), "totalDaiSupplied diverged at the boundary");
        assertEq(
            poolA.liveDebtForTesting(twinAlice()),
            poolB.liveDebtForTesting(twinAlice()),
            "borrower's live debt diverged at the boundary"
        );
        assertEq(poolB.baseRate(), 0.05e18, "baseRate did not actually update");

        // Prove the new baseRate DOES take effect going forward: with an
        // extra 5% base spread now on poolB, its next accrual step must
        // grow totalDaiBorrowed strictly more than poolA's (still 0% base).
        uint256 borrowedABefore = poolA.totalDaiBorrowed();
        uint256 borrowedBBefore = poolB.totalDaiBorrowed();
        assertEq(borrowedABefore, borrowedBBefore);

        vm.warp(block.timestamp + 30 days);
        poolA.accrueForTesting();
        poolB.accrueForTesting();

        uint256 interestA = poolA.totalDaiBorrowed() - borrowedABefore;
        uint256 interestB = poolB.totalDaiBorrowed() - borrowedBBefore;
        assertGt(interestB, interestA, "poolB's higher baseRate should accrue more interest than poolA's");
    }

    // --- twin-pool test scaffolding -----------------------------------

    // Fixed addresses reused across every twin-pool deployment: each pool
    // (and its own token/oracle instances) is fully independent, so reuse
    // is safe and keeps the pair symmetric.
    function twinDave() internal pure returns (address) {
        return address(0xD11);
    }

    function twinAlice() internal pure returns (address) {
        return address(0xA1100);
    }

    // Deploys a fresh token/oracle/pool stack and brings it to an
    // identical starting scenario: dave supplies 100,000 mDAI; alice
    // deposits 10 mWETH collateral and borrows 5,000 mDAI. Used to build
    // "twin" pools for the parameter-change boundary tests above.
    function _deployFundedTwinPool() internal returns (InterestAccrualHarness p, MockDAI d) {
        MockWETH w = new MockWETH();
        d = new MockDAI();
        MockPriceOracle o = new MockPriceOracle(owner);
        p = new InterestAccrualHarness(owner, address(w), address(d), address(o));

        o.setPrice(address(w), 2000e18);
        o.setPrice(address(d), 1e18);

        d.mint(twinDave(), 200_000e18);
        vm.prank(twinDave());
        d.approve(address(p), type(uint256).max);

        w.mint(twinAlice(), 100e18);
        d.mint(twinAlice(), 200_000e18);
        vm.startPrank(twinAlice());
        w.approve(address(p), type(uint256).max);
        d.approve(address(p), type(uint256).max);
        vm.stopPrank();

        vm.prank(twinDave());
        p.supply(100_000e18);

        vm.startPrank(twinAlice());
        p.depositCollateral(10e18);
        p.borrow(5_000e18);
        vm.stopPrank();
    }
}
