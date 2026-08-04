// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 7 made totalDaiBorrowed/totalDaiSupplied "live" aggregates that
// grow every _accrueInterest() call in lockstep with borrowIndex/
// supplyIndex, while per-user principalDebt/suppliedBalance are settled
// lazily (only on that user's own next interaction). These tests check the
// state-consistency invariants that must hold across that split — same
// category/convention as test/BorrowRepay_StateConsistency.t.sol, updated
// for index-scaled accounting.
contract InterestAccrualHarness is LendingPool {
    constructor(address initialOwner, address collateralToken_, address daiToken_, address oracle_)
        LendingPool(initialOwner, collateralToken_, daiToken_, oracle_)
    {}

    // Lets a test force an accrual step with no other side effects, so
    // ΔtotalDaiBorrowed / ΔtotalReserves across the call can be attributed
    // purely to interest.
    function accrueForTesting() external {
        _accrueInterest();
    }

    function liveDebtForTesting(address user) external view returns (uint256) {
        return _liveDebt(user);
    }

    // Mirrors _settleSupply's math as a view, so a user's true live supply
    // balance can be read without mutating state (principalDebt has
    // _liveDebt for this already; suppliedBalance has no equivalent on the
    // base contract).
    function liveSupplyForTesting(address user) public view returns (uint256) {
        uint256 principal = suppliedBalance[user];
        if (principal == 0) return 0;
        return principal * supplyIndex / userSupplyIndex[user];
    }
}

contract InterestAccrualStateConsistencyTest is Test {
    InterestAccrualHarness pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);

    address dave = address(0xDA5E); // supplier
    address henry = address(0x4E4E1); // supplier, joins mid-scenario
    address alice = address(0xA11CE); // borrower
    address bob = address(0xB0B); // borrower
    address carol = address(0xCA501); // borrower

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

        dai.mint(henry, 200_000e18);
        vm.prank(henry);
        dai.approve(address(pool), type(uint256).max);

        address[3] memory borrowers = [alice, bob, carol];
        for (uint256 i = 0; i < borrowers.length; i++) {
            weth.mint(borrowers[i], 100e18);
            dai.mint(borrowers[i], 200_000e18);
            vm.startPrank(borrowers[i]);
            weth.approve(address(pool), type(uint256).max);
            dai.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    // --- Invariant 5: indices are monotonically non-decreasing -------------

    function test_IndicesMonotonicNonDecreasing_AcrossFullScenario() public {
        uint256 lastBorrowIndex = pool.borrowIndex();
        uint256 lastSupplyIndex = pool.supplyIndex();

        vm.prank(dave);
        pool.supply(100_000e18);
        _assertIndicesNonDecreasing(lastBorrowIndex, lastSupplyIndex);
        (lastBorrowIndex, lastSupplyIndex) = (pool.borrowIndex(), pool.supplyIndex());

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();
        _assertIndicesNonDecreasing(lastBorrowIndex, lastSupplyIndex);
        (lastBorrowIndex, lastSupplyIndex) = (pool.borrowIndex(), pool.supplyIndex());

        vm.warp(block.timestamp + 30 days);
        vm.startPrank(bob);
        pool.depositCollateral(20e18);
        pool.borrow(10_000e18);
        vm.stopPrank();
        _assertIndicesNonDecreasing(lastBorrowIndex, lastSupplyIndex);
        (lastBorrowIndex, lastSupplyIndex) = (pool.borrowIndex(), pool.supplyIndex());

        vm.warp(block.timestamp + 5 days);
        vm.prank(alice);
        pool.repay(1_000e18);
        _assertIndicesNonDecreasing(lastBorrowIndex, lastSupplyIndex);
        (lastBorrowIndex, lastSupplyIndex) = (pool.borrowIndex(), pool.supplyIndex());

        vm.warp(block.timestamp + 60 days);
        vm.prank(bob);
        pool.repay(20_000e18); // overpay, capped at bob's actual debt
        _assertIndicesNonDecreasing(lastBorrowIndex, lastSupplyIndex);
        (lastBorrowIndex, lastSupplyIndex) = (pool.borrowIndex(), pool.supplyIndex());

        // totalDaiBorrowed may now be small/zero for stretches — confirm
        // index still never regresses even when accrual is a no-op.
        vm.warp(block.timestamp + 10 days);
        vm.prank(dave);
        pool.withdrawSupply(1_000e18);
        _assertIndicesNonDecreasing(lastBorrowIndex, lastSupplyIndex);
    }

    function _assertIndicesNonDecreasing(uint256 prevBorrowIndex, uint256 prevSupplyIndex) internal view {
        assertGe(pool.borrowIndex(), prevBorrowIndex, "borrowIndex decreased");
        assertGe(pool.supplyIndex(), prevSupplyIndex, "supplyIndex decreased");
    }

    // --- Invariant (construction check): totalDaiBorrowed growth ratio -----
    // matches borrowIndex growth ratio, up to the ceil-rounding described
    // in CLAUDE.md's task brief: interestAccrued = ceil(total_old *
    // Δindex / index_old), so total_new is in
    // [total_old*index_new/index_old, total_old*index_new/index_old + 1).
    // Cross-multiplied (no division/rounding in the check itself):
    //   total_new * index_old >= total_old * index_new                (>=)
    //   total_new * index_old <  total_old * index_new + index_old    (< +1 ulp)

    function test_BorrowedTotalGrowthRatioMatchesIndexGrowthRatio_SingleStep() public {
        vm.prank(dave);
        pool.supply(100_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();

        uint256 totalOld = pool.totalDaiBorrowed();
        uint256 indexOld = pool.borrowIndex();

        vm.warp(block.timestamp + 17 days);
        pool.accrueForTesting();

        uint256 totalNew = pool.totalDaiBorrowed();
        uint256 indexNew = pool.borrowIndex();

        assertGt(indexNew, indexOld, "expected interest to accrue");
        assertGe(totalNew * indexOld, totalOld * indexNew, "totalDaiBorrowed grew less than index ratio");
        assertLt(
            totalNew * indexOld,
            totalOld * indexNew + indexOld,
            "totalDaiBorrowed overshot index ratio by more than 1 ulp"
        );
    }

    // --- Same construction check, supply side. Here supplyIndex itself is
    // floor-divided while totalDaiSupplied is bumped by an exact supplyCut,
    // so the inequality direction flips: the aggregate grows at least as
    // fast as the index ratio implies (index growth is the one that's
    // rounded down here, not the total).

    function test_SuppliedTotalGrowthRatioMatchesIndexGrowthRatio_SingleStep() public {
        vm.prank(dave);
        pool.supply(100_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();

        uint256 totalOld = pool.totalDaiSupplied();
        uint256 indexOld = pool.supplyIndex();

        vm.warp(block.timestamp + 17 days);
        pool.accrueForTesting();

        uint256 totalNew = pool.totalDaiSupplied();
        uint256 indexNew = pool.supplyIndex();

        assertGt(indexNew, indexOld, "expected supply interest to accrue");
        // supplyIndex_new/supplyIndex_old <= totalDaiSupplied_new/totalDaiSupplied_old
        assertLe(indexNew * totalOld, indexOld * totalNew, "supplyIndex outran totalDaiSupplied growth");
    }

    // --- Invariant 1: totalDaiBorrowed >= sum of each borrower's live debt -

    function test_AggregateBorrowedAtLeastSumOfLiveDebts_MultiUserOverTime() public {
        vm.prank(dave);
        pool.supply(150_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000
        pool.borrow(5_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        vm.startPrank(bob);
        pool.depositCollateral(20e18); // $40,000
        pool.borrow(10_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        vm.startPrank(carol);
        pool.depositCollateral(5e18); // $10,000
        pool.borrow(2_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days);
        vm.prank(alice);
        pool.repay(2_000e18); // alice partially settles here

        vm.warp(block.timestamp + 20 days);
        vm.prank(bob);
        pool.repay(50_000e18); // overpay, capped at bob's full live debt

        // Many small accrual-only steps in between, to accumulate the
        // per-step ceil-rounding the aggregate total picks up that
        // individual users (who settle only once, at query/interaction
        // time) don't.
        for (uint256 i = 0; i < 30; i++) {
            vm.warp(block.timestamp + 1 days);
            pool.accrueForTesting();
        }

        uint256 sumLiveDebt =
            pool.liveDebtForTesting(alice) + pool.liveDebtForTesting(bob) + pool.liveDebtForTesting(carol);
        uint256 totalBorrowed = pool.totalDaiBorrowed();

        assertGe(totalBorrowed, sumLiveDebt, "totalDaiBorrowed fell below sum of live per-user debts");

        uint256 drift = totalBorrowed - sumLiveDebt;

        // Observed drift across ~35 accrual events on ~1e22-scale balances
        // is a handful of wei (ceil rounds up by < 1 wei per accrual call).
        // 1000 wei is a generous tolerance that would still catch a real
        // scaling bug (which would produce drift proportional to balance
        // size, i.e. many orders of magnitude larger).
        assertLt(drift, 1000, "drift far larger than expected rounding noise");
    }

    // --- Invariant 2: totalDaiSupplied >= sum of each supplier's live -----
    // balance.

    function test_AggregateSuppliedAtLeastSumOfLiveSupplyBalances_MultiUserOverTime() public {
        vm.prank(dave);
        pool.supply(100_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 15 days);

        vm.startPrank(bob);
        pool.depositCollateral(20e18);
        pool.borrow(10_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 15 days);

        // Henry joins later, at a different (already-grown) supplyIndex
        // baseline than dave.
        vm.prank(henry);
        pool.supply(50_000e18);

        vm.warp(block.timestamp + 10 days);

        for (uint256 i = 0; i < 30; i++) {
            vm.warp(block.timestamp + 1 days);
            pool.accrueForTesting();
        }

        // Dave partially withdraws, settling his principal against the
        // current index; henry never touches his position again.
        vm.prank(dave);
        pool.withdrawSupply(1_000e18);

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1 days);
            pool.accrueForTesting();
        }

        uint256 sumLiveSupply = pool.liveSupplyForTesting(dave) + pool.liveSupplyForTesting(henry);
        uint256 totalSupplied = pool.totalDaiSupplied();

        assertGe(totalSupplied, sumLiveSupply, "totalDaiSupplied fell below sum of live per-user supply balances");

        uint256 drift = totalSupplied - sumLiveSupply;

        // Unlike the debt side (single ceil-rounding per accrual call on
        // the aggregate), supplyIndex itself is floor-divided on every
        // accrual step (`supplyIndex = supplyIndex * (S+supplyCut) / S`),
        // so the per-step rounding error compounds multiplicatively across
        // ~40 accrual events here rather than just adding linearly. That's
        // still utterly negligible relative to balance size (observed
        // ~3e6 wei of drift against a ~1.5e23-wei balance, i.e. a relative
        // error around 1e-17) — bound it relative to scale rather than
        // with a fixed wei cap, which would be too tight for this
        // rounding mode and too loose for the debt side's.
        assertLt(drift, totalSupplied / 1e12, "drift far larger than expected rounding noise");
    }

    // --- Invariant 3: totalReserves only grows, proportional to interest --
    // accrued at the configured reserveFactor (10%).

    function test_TotalReservesGrowsProportionallyToInterestAtReserveFactor() public {
        vm.prank(dave);
        pool.supply(100_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();

        uint256 lastReserves = pool.totalReserves();
        assertEq(lastReserves, 0);

        for (uint256 i = 0; i < 10; i++) {
            uint256 totalBorrowedBefore = pool.totalDaiBorrowed();

            vm.warp(block.timestamp + 7 days);
            pool.accrueForTesting(); // isolated accrual step: only interest changes totalDaiBorrowed here

            uint256 totalBorrowedAfter = pool.totalDaiBorrowed();
            uint256 interestAccrued = totalBorrowedAfter - totalBorrowedBefore;
            uint256 expectedReserveCut = interestAccrued * pool.reserveFactor() / 1e18;

            uint256 reservesNow = pool.totalReserves();
            assertGe(reservesNow, lastReserves, "totalReserves decreased");
            assertEq(reservesNow - lastReserves, expectedReserveCut, "reserve cut != interestAccrued * 10%");

            lastReserves = reservesNow;
        }

        assertGt(pool.totalReserves(), 0, "reserves never grew despite accrued interest");
    }

    // --- Invariant 4: pool's live mDAI balance == totalDaiSupplied - -------
    // totalDaiBorrowed, still holds once both totals are index-scaled and
    // growing every accrual (not just on principal-changing calls).

    function test_LiquidityInvariantHoldsWithLiveIndexScaledTotals() public {
        vm.prank(dave);
        pool.supply(100_000e18);
        _assertLiquidityInvariant();

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();
        _assertLiquidityInvariant();

        vm.warp(block.timestamp + 40 days);
        vm.startPrank(bob);
        pool.depositCollateral(20e18);
        pool.borrow(10_000e18);
        vm.stopPrank();
        _assertLiquidityInvariant();

        // Interest accrues silently via warps with no calls in between —
        // confirm the invariant still holds the instant the next call
        // triggers accrual (no token transfer happens for interest itself,
        // only internal bookkeeping, so this must remain an exact equality,
        // not just an approximate one).
        vm.warp(block.timestamp + 60 days);
        pool.accrueForTesting();
        _assertLiquidityInvariant();

        vm.prank(alice);
        pool.repay(3_000e18);
        _assertLiquidityInvariant();

        // Unborrowed liquidity gate must be computed against the LIVE
        // (index-scaled) totals, not stale principal sums. Note this can't
        // naively be "totalDaiSupplied - totalDaiBorrowed" requested in
        // full: even as dave's sole supplier here, Invariant 2's floor-
        // rounding drift (see
        // test_AggregateSuppliedAtLeastSumOfLiveSupplyBalances) means
        // dave's own settled suppliedBalance can trail totalDaiSupplied by
        // a few wei after ~100 accrual events, so requesting the full
        // aggregate-implied amount reverts on the *personal* balance check
        // (`suppliedBalance[msg.sender] >= amount`), not the liquidity
        // check — confirming the aggregate is the more generous of the two
        // bounds, exactly as CLAUDE.md's invariant requires.
        uint256 available = pool.totalDaiSupplied() - pool.totalDaiBorrowed();
        uint256 daveLiveBalance = pool.liveSupplyForTesting(dave);
        uint256 withdrawAmount = available < daveLiveBalance ? available : daveLiveBalance;

        vm.prank(dave);
        pool.withdrawSupply(withdrawAmount);
        _assertLiquidityInvariant();
    }

    // The naive form of this invariant from milestone 6
    // (BorrowRepay_StateConsistency.t.sol) was
    // `dai.balanceOf(pool) == totalDaiSupplied - totalDaiBorrowed`, which
    // held when there was no reserve split. Milestone 7 breaks that: every
    // accrual siphons a reserveCut out of "unborrowed liquidity" terms
    // (totalDaiSupplied grows by supplyCut = interestAccrued - reserveCut,
    // while totalDaiBorrowed grows by the full interestAccrued), but the
    // reserveCut is only bookkept in totalReserves — no token ever leaves
    // the contract for it (no reserve-withdrawal function exists yet, per
    // PLAN.md milestone 9). So the contract's real token balance sits
    // totalReserves *above* `totalDaiSupplied - totalDaiBorrowed`. The
    // corrected, milestone-7-accurate invariant folds totalReserves back
    // in; this held with exact equality (no tolerance needed) in every
    // step of this test.
    function _assertLiquidityInvariant() internal view {
        assertEq(
            dai.balanceOf(address(pool)),
            pool.totalDaiSupplied() - pool.totalDaiBorrowed() + pool.totalReserves(),
            "pool DAI balance != (totalDaiSupplied - totalDaiBorrowed) + totalReserves"
        );
    }
}
