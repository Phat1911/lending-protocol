// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {InterestAccrualHarness} from "./InterestAccrual_StateConsistency.t.sol";

// Milestone 10 (full integration pass). The per-milestone StateConsistency
// files (BorrowRepay/InterestAccrual/Liquidation/Admin) already cover their
// own milestone's invariants in isolation — including, individually: the
// reserve-inclusive liquidity invariant, the totalDaiBorrowed-vs-sum-of-
// live-debts drift bound, and single liquidation events. What none of them
// do is combine everything in ONE sequence: multiple borrowers settling at
// different index snapshots, interleaved vm.warp accrual, a normal
// (uncapped) liquidation AND a bad-debt-capped liquidation, and partial
// reserve withdrawal in between further accrual — all in the same test, so
// invariants are checked at points where features actually interact rather
// than one at a time. Reuses InterestAccrualHarness purely for its side-
// effect-free accrueForTesting()/liveDebtForTesting()/liveSupplyForTesting()
// views.
contract IntegrationStateConsistencyTest is Test {
    InterestAccrualHarness pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);

    address dave = address(0xDA5E); // supplier, in from the start
    address henry = address(0x4E4E1); // supplier, joins mid-scenario
    address alice = address(0xA11CE); // borrower, later liquidated normally (uncapped)
    address bob = address(0xB0B); // borrower, later liquidated bad-debt (capped)
    address carol = address(0xCA501); // borrower, partially repays, survives to the end
    address liquidator = address(0x11101D);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new InterestAccrualHarness(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        dai.mint(dave, 300_000e18);
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

        dai.mint(liquidator, 500_000e18);
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    // ===================================================================
    // Shared invariant helpers
    // ===================================================================

    // Reserve-inclusive liquidity invariant (established in
    // InterestAccrual_StateConsistency.t.sol / confirmed to survive
    // liquidation in Liquidation_StateConsistency.t.sol): once accrual has
    // ever run, reserve cuts are bookkept in totalReserves but never
    // physically move until withdrawReserves() is called, so the pool's
    // real mDAI balance sits totalReserves *above*
    // (totalDaiSupplied - totalDaiBorrowed). This must hold as an EXACT
    // equality (no token ever moves for interest itself) at every
    // checkpoint below, including around partial reserve withdrawals and
    // both liquidation flavors.
    function _assertLiquidityInvariant() internal view {
        assertEq(
            dai.balanceOf(address(pool)),
            pool.totalDaiSupplied() - pool.totalDaiBorrowed() + pool.totalReserves(),
            "pool DAI balance != (totalDaiSupplied - totalDaiBorrowed) + totalReserves"
        );
    }

    // mWETH collateral never accrues interest (only depositCollateral /
    // withdrawCollateral / liquidate-seizure move it), so this must hold as
    // an EXACT equality at every checkpoint, unlike the mDAI-side
    // aggregate-vs-per-user invariants below (which have documented
    // ceil-rounding drift).
    function _assertCollateralInvariant() internal view {
        uint256 sumCollateral =
            pool.collateralBalance(alice) + pool.collateralBalance(bob) + pool.collateralBalance(carol);
        assertEq(weth.balanceOf(address(pool)), sumCollateral, "pool mWETH balance != sum(collateralBalance[user])");
    }

    // totalDaiBorrowed (aggregate, ceil-rounded every accrual step) vs. the
    // sum of each live borrower's individually-settled debt (ceil-rounded
    // only at that user's own last interaction). Per
    // InterestAccrual_StateConsistency.t.sol this is a genuinely open
    // question that resolves to: aggregate >= sum, by a small
    // protocol-favoring (never-undercounts) drift. Summing all three
    // borrowers unconditionally is safe even after one is liquidated/fully
    // repaid: liquidate()/repay() zero principalDebt exactly, so a
    // settled-out user's live debt contributes 0 to the sum either way.
    function _assertBorrowedAtLeastSumLiveDebt(uint256 maxDriftWei) internal view {
        uint256 sumLiveDebt =
            pool.liveDebtForTesting(alice) + pool.liveDebtForTesting(bob) + pool.liveDebtForTesting(carol);
        uint256 totalBorrowed = pool.totalDaiBorrowed();

        assertGe(totalBorrowed, sumLiveDebt, "totalDaiBorrowed fell below sum of live per-user debts (undercount!)");
        uint256 drift = totalBorrowed - sumLiveDebt;
        assertLt(drift, maxDriftWei, "totalDaiBorrowed/sum(liveDebt) drift exceeded expected rounding noise");
    }

    // Mirrors liquidate()'s exact seize-amount arithmetic so test
    // construction (uncapped vs. bad-debt-capped) can be verified at
    // runtime instead of hand-computed, same convention as
    // Liquidation_StateConsistency.t.sol.
    function _expectedSeizeAmount(uint256 debt, address borrower) internal view returns (uint256) {
        uint256 daiPrice = oracle.getPrice(address(dai));
        uint256 collateralPrice = oracle.getPrice(address(weth));

        uint256 repaidDebtValueUSD = debt * daiPrice / pool.WAD();
        uint256 seizeValueUSD = repaidDebtValueUSD * pool.liquidationBonus() / pool.BPS_DENOMINATOR();
        uint256 seizeAmount = seizeValueUSD * pool.WAD() / collateralPrice;

        uint256 borrowerCollateral = pool.collateralBalance(borrower);
        if (seizeAmount > borrowerCollateral) {
            seizeAmount = borrowerCollateral;
        }
        return seizeAmount;
    }

    // ===================================================================
    // The combined scenario.
    // ===================================================================

    function test_FullLifecycle_AllInvariantsHoldThroughInterleavedMultiUserScenario() public {
        // --- Phase 1: liquidity + independent borrowers at staggered times ---

        vm.prank(dave);
        pool.supply(200_000e18);
        _assertLiquidityInvariant();
        _assertCollateralInvariant();

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000 @ $2000/weth
        pool.borrow(8_000e18); // 40% LTV
        vm.stopPrank();
        _assertLiquidityInvariant();
        _assertCollateralInvariant();

        vm.warp(block.timestamp + 20 days);
        vm.startPrank(bob);
        pool.depositCollateral(25e18); // $50,000 @ $2000/weth
        pool.borrow(37_500e18); // exactly 75% LTV cap
        vm.stopPrank();
        _assertLiquidityInvariant();
        _assertCollateralInvariant();

        vm.warp(block.timestamp + 15 days);
        vm.startPrank(carol);
        pool.depositCollateral(3e18); // $6,000 @ $2000/weth
        pool.borrow(2_000e18); // ~33% LTV, well under threshold
        vm.stopPrank();
        _assertLiquidityInvariant();
        _assertCollateralInvariant();

        // Henry joins as a supplier LATE, at an already-grown supplyIndex
        // baseline different from dave's.
        vm.warp(block.timestamp + 10 days);
        vm.prank(henry);
        pool.supply(100_000e18);
        _assertLiquidityInvariant();
        _assertCollateralInvariant();

        // --- Phase 2: pure accrual (no principal changes) then a partial ---
        // repay, interleaved with the borrowed-vs-sum-live-debt check.

        vm.warp(block.timestamp + 30 days);
        pool.accrueForTesting(); // isolated accrual step
        _assertLiquidityInvariant();
        _assertCollateralInvariant();
        _assertBorrowedAtLeastSumLiveDebt(1000);

        vm.prank(carol);
        pool.repay(1_000e18); // partial repay, settles carol against current index
        _assertLiquidityInvariant();
        _assertCollateralInvariant();
        _assertBorrowedAtLeastSumLiveDebt(1000);

        // --- Phase 3: owner withdraws HALF the accrued reserves mid- -------
        // scenario, then MORE interest accrues on top of the reduced base
        // (confirms withdrawReserves doesn't reset the growth baseline and
        // the liquidity invariant survives a partial, non-terminal draw).

        uint256 reservesBeforeDraw = pool.totalReserves();
        assertGt(reservesBeforeDraw, 0, "test construction: expected reserves to have accrued by now");

        uint256 halfReserves = reservesBeforeDraw / 2;
        pool.withdrawReserves(owner, halfReserves);
        assertEq(pool.totalReserves(), reservesBeforeDraw - halfReserves, "partial reserve withdrawal miscounted");
        _assertLiquidityInvariant();
        _assertCollateralInvariant();

        vm.warp(block.timestamp + 40 days);
        pool.accrueForTesting();
        assertGt(
            pool.totalReserves(), reservesBeforeDraw - halfReserves, "reserves should keep growing from reduced base"
        );
        _assertLiquidityInvariant();
        _assertCollateralInvariant();
        _assertBorrowedAtLeastSumLiveDebt(1000);

        // --- Phase 4: crash price just enough to break bob (uncapped -------
        // liquidation) while alice/carol stay healthy. Bob originated at
        // EXACTLY the 75% LTV cap (only a 75/80 = 6.25% price-drop buffer
        // to the 80% liquidation threshold), so he is the FIRST position to
        // break as price falls — well before alice (40% initial LTV, a much
        // bigger buffer) or carol (~33% initial LTV, bigger still).

        oracle.setPrice(address(weth), 1800e18);
        assertLt(pool.healthFactor(bob), 1e18, "test construction: bob should be unhealthy at 1800");
        assertGe(pool.healthFactor(alice), 1e18, "test construction: alice should still be healthy at 1800");
        assertGe(pool.healthFactor(carol), 1e18, "test construction: carol should still be healthy at 1800");

        uint256 bobDebtBefore = pool.liveDebtForTesting(bob);
        uint256 bobCollateralBefore = pool.collateralBalance(bob);
        uint256 expectedBobSeize = _expectedSeizeAmount(bobDebtBefore, bob);
        assertLt(expectedBobSeize, bobCollateralBefore, "test construction: expected an UNCAPPED seizure for bob");

        vm.prank(liquidator);
        pool.liquidate(bob);

        assertEq(pool.principalDebt(bob), 0, "bob's debt must be fully zeroed");
        _assertLiquidityInvariant();
        _assertCollateralInvariant();
        _assertBorrowedAtLeastSumLiveDebt(1000);

        // --- Phase 5: crash price much further so alice (40% initial LTV, -
        // a far bigger cushion than bob had) now becomes bad-debt: the
        // seizure formula exceeds her actual collateral, so it's capped at
        // her full balance, while carol (even lower LTV, further repaid)
        // stays healthy throughout.

        oracle.setPrice(address(weth), 800e18);
        assertLt(pool.healthFactor(alice), 1e18, "test construction: alice should be unhealthy at 800");
        assertGe(pool.healthFactor(carol), 1e18, "test construction: carol should still be healthy at 800");

        uint256 aliceDebtBefore = pool.liveDebtForTesting(alice);
        uint256 aliceCollateralBefore = pool.collateralBalance(alice);
        uint256 expectedAliceSeize = _expectedSeizeAmount(aliceDebtBefore, alice);
        assertEq(
            expectedAliceSeize,
            aliceCollateralBefore,
            "test construction: expected a CAPPED (bad-debt) seizure for alice"
        );

        uint256 poolDaiBeforeAliceLiquidation = dai.balanceOf(address(pool));
        uint256 totalBorrowedBeforeAliceLiquidation = pool.totalDaiBorrowed();

        vm.prank(liquidator);
        pool.liquidate(alice);

        assertEq(pool.principalDebt(alice), 0, "bad debt must still fully zero alice's principalDebt");
        assertEq(pool.collateralBalance(alice), 0, "alice's collateral must be fully seized (capped case)");

        // Key bad-debt-shape check: because liquidate() always pulls the
        // FULL live debt in mDAI from the liquidator regardless of whether
        // seizure was capped (only the collateral leg is capped, not the
        // debt repayment leg), the mDAI liquidity invariant is completely
        // undisturbed by the fact that this was a bad-debt liquidation —
        // the loss lands entirely on the liquidator (who overpaid in mDAI
        // relative to the collateral value they received), never on the
        // pool's own mDAI accounting. Confirm both explicitly.
        assertEq(
            dai.balanceOf(address(pool)),
            poolDaiBeforeAliceLiquidation + aliceDebtBefore,
            "pool mDAI balance should grow by alice's FULL debt even though collateral seizure was capped"
        );
        assertEq(
            pool.totalDaiBorrowed(),
            totalBorrowedBeforeAliceLiquidation - aliceDebtBefore,
            "totalDaiBorrowed should drop by alice's full live debt even in the capped-seizure case"
        );

        _assertLiquidityInvariant();
        _assertCollateralInvariant();
        _assertBorrowedAtLeastSumLiveDebt(1000);

        // --- Phase 6: carol (sole surviving borrower) fully repays; -------
        // totalDaiBorrowed should return to (near-)zero with no dust left
        // over from either liquidation.

        vm.warp(block.timestamp + 5 days);
        uint256 carolLiveDebt = pool.liveDebtForTesting(carol);
        vm.prank(carol);
        pool.repay(carolLiveDebt + 100e18); // deliberate overpay, must be capped by repay()

        assertEq(pool.principalDebt(carol), 0, "carol's debt must be fully cleared");
        assertLt(pool.totalDaiBorrowed(), 1000, "totalDaiBorrowed should be ~0 with all borrowers settled");
        _assertLiquidityInvariant();
        _assertCollateralInvariant();

        // --- Phase 7: suppliers pull their live (settled) balances; the ---
        // sum of BOTH suppliers' live balances must never exceed
        // totalDaiSupplied (same bound established in
        // InterestAccrual_StateConsistency.t.sol), now proven across a
        // scenario that also included two liquidations and a mid-flight
        // partial reserve withdrawal.

        uint256 daveLive = pool.liveSupplyForTesting(dave);
        uint256 henryLive = pool.liveSupplyForTesting(henry);
        assertLe(
            daveLive + henryLive, pool.totalDaiSupplied(), "sum of suppliers' live balances exceeds totalDaiSupplied"
        );

        uint256 daveBalanceBefore = dai.balanceOf(dave);
        vm.prank(dave);
        pool.withdrawSupply(daveLive);
        assertEq(dai.balanceOf(dave), daveBalanceBefore + daveLive);
        _assertLiquidityInvariant();

        uint256 henryBalanceBefore = dai.balanceOf(henry);
        vm.prank(henry);
        pool.withdrawSupply(henryLive);
        assertEq(dai.balanceOf(henry), henryBalanceBefore + henryLive);
        _assertLiquidityInvariant();
        _assertCollateralInvariant();

        // --- Phase 8: owner drains whatever reserves remain; the ----------
        // liquidity invariant must still hold exactly (down to only
        // rounding dust in totalDaiSupplied, exactly as in
        // Admin_StateConsistency.t.sol's equivalent end state).

        uint256 remainingReserves = pool.totalReserves();
        if (remainingReserves > 0) {
            pool.withdrawReserves(owner, remainingReserves);
        }
        assertEq(pool.totalReserves(), 0);
        _assertLiquidityInvariant();

        // This scenario runs far more accrual steps over a much larger
        // principal (hundreds of thousands of mDAI, ~150 days, two
        // liquidations, a partial reserve draw) than the smaller
        // single-feature precedent in Admin_StateConsistency.t.sol, so the
        // accumulated floor-rounding drift on the supply side (see
        // InterestAccrual_StateConsistency.t.sol's note on supplyIndex
        // being floor-divided every accrual step, compounding
        // multiplicatively) is correspondingly larger in absolute terms —
        // observed ~5e5 wei here. Still utterly negligible: on a
        // ~3e23-wei-scale principal that's a relative error around 1e-18,
        // many orders of magnitude below anything a real scaling bug would
        // produce (which would be proportional to balance size).
        uint256 remainingSupplied = pool.totalDaiSupplied();
        assertLt(remainingSupplied, 1_000_000, "unexpectedly large amount of supplier funds left stranded");
        assertEq(pool.totalDaiBorrowed(), 0);
        assertEq(dai.balanceOf(address(pool)), remainingSupplied, "pool balance should equal only leftover dust");
    }
}
