// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 8 added liquidate(): full-debt-repay only, seizure = repaid debt
// value * 1.10 in collateral, capped at the borrower's actual collateral
// balance (bad debt accepted, not solved). These tests check the
// cross-variable state-consistency invariants that must hold after
// liquidate() runs, in the same convention as
// test/BorrowRepay_StateConsistency.t.sol and
// test/InterestAccrual_StateConsistency.t.sol: perform the action, then
// assert internal accounting matches actual token balances and cross-user
// sums, rather than re-testing liquidate()'s gating logic in isolation.
contract LiquidationHarness is LendingPool {
    constructor(address initialOwner, address collateralToken_, address daiToken_, address oracle_)
        LendingPool(initialOwner, collateralToken_, daiToken_, oracle_)
    {}

    // Lets a test force an accrual step with no other side effects, so the
    // "one clean accrual, then liquidate in the same block" scenarios below
    // can isolate liquidate()'s own effect on totalDaiSupplied/totalReserves
    // from _accrueInterest()'s (which liquidate() also calls, but which is
    // orthogonal per CLAUDE.md's task brief).
    function accrueForTesting() external {
        _accrueInterest();
    }

    // True live (index-scaled) per-user debt, without mutating state.
    function liveDebtForTesting(address user) external view returns (uint256) {
        return _liveDebt(user);
    }

    // Mirrors _settleSupply's math as a view, so a supplier's true live
    // withdrawable balance can be read without mutating state.
    function liveSupplyForTesting(address user) public view returns (uint256) {
        uint256 principal = suppliedBalance[user];
        if (principal == 0) return 0;
        return principal * supplyIndex / userSupplyIndex[user];
    }
}

contract LiquidationStateConsistencyTest is Test {
    LiquidationHarness pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);

    address dave = address(0xDA5E); // supplier
    address henry = address(0x4E4E1); // supplier
    address alice = address(0xA11CE); // borrower, gets liquidated
    address bob = address(0xB0B); // borrower, survives
    address liquidator = address(0x11101D);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LiquidationHarness(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        dai.mint(dave, 1_000_000e18);
        vm.prank(dave);
        dai.approve(address(pool), type(uint256).max);

        dai.mint(henry, 1_000_000e18);
        vm.prank(henry);
        dai.approve(address(pool), type(uint256).max);

        address[2] memory borrowers = [alice, bob];
        for (uint256 i = 0; i < borrowers.length; i++) {
            weth.mint(borrowers[i], 100e18);
            dai.mint(borrowers[i], 1_000_000e18);
            vm.startPrank(borrowers[i]);
            weth.approve(address(pool), type(uint256).max);
            dai.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }

        dai.mint(liquidator, 1_000_000e18);
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    // Mirrors liquidate()'s exact seize-amount arithmetic (same operation
    // order) so expected values in assertions can't silently diverge from
    // the contract due to rounding-order differences.
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

    function _assertLiquidityInvariant() internal view {
        // Same corrected (reserve-inclusive) form as
        // InterestAccrual_StateConsistency.t.sol: the pool's real mDAI
        // balance sits totalReserves above (totalDaiSupplied -
        // totalDaiBorrowed) once accrual has ever run, since reserve cuts
        // are bookkept but never physically withdrawn.
        assertEq(
            dai.balanceOf(address(pool)),
            pool.totalDaiSupplied() - pool.totalDaiBorrowed() + pool.totalReserves(),
            "pool DAI balance != (totalDaiSupplied - totalDaiBorrowed) + totalReserves"
        );
    }

    // --- Invariants 1-3: debt zeroed, token balances, per-user collateral --
    // move by exactly the formula-derived amounts (no cap triggered here).

    function test_FullLiquidation_ZeroesDebtAndMatchesTokenBalanceDeltas() public {
        vm.prank(dave);
        pool.supply(500_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000 @ $2000/weth
        pool.borrow(8_000e18); // 40% LTV, well within the 75% cap
        vm.stopPrank();

        // Crash collateral price so alice's health factor drops below 1e18
        // (liquidationThreshold 80% vs a 40%-LTV position needs collateral
        // value to roughly halve).
        oracle.setPrice(address(weth), 900e18);
        assertLt(pool.healthFactor(alice), 1e18, "test construction: alice should be unhealthy");

        uint256 debtBefore = pool.principalDebt(alice); // no warp occurred, so this is exact, unaccrued
        uint256 collateralBefore = pool.collateralBalance(alice);
        uint256 expectedSeize = _expectedSeizeAmount(debtBefore, alice);
        assertLt(expectedSeize, collateralBefore, "test construction: expected an uncapped seizure here");

        uint256 poolDaiBefore = dai.balanceOf(address(pool));
        uint256 poolWethBefore = weth.balanceOf(address(pool));
        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        uint256 totalDaiBorrowedBefore = pool.totalDaiBorrowed();

        vm.prank(liquidator);
        pool.liquidate(alice);

        // Invariant 1: full-debt-repay only, no partial debt left.
        assertEq(pool.principalDebt(alice), 0, "principalDebt must be exactly zero after liquidation");

        // Invariant 2: real ERC20 balances move by exactly debt / seizeAmount.
        assertEq(dai.balanceOf(address(pool)), poolDaiBefore + debtBefore, "pool mDAI balance != +debt");
        assertEq(weth.balanceOf(address(pool)), poolWethBefore - expectedSeize, "pool mWETH balance != -seizeAmount");
        assertEq(dai.balanceOf(liquidator), liquidatorDaiBefore - debtBefore, "liquidator mDAI balance != -debt");
        assertEq(
            weth.balanceOf(liquidator), liquidatorWethBefore + expectedSeize, "liquidator mWETH balance != +seizeAmount"
        );

        // Invariant 3: per-user collateral accounting matches the real
        // seizure exactly, not just the token balance.
        assertEq(
            pool.collateralBalance(alice), collateralBefore - expectedSeize, "collateralBalance != -seizeAmount"
        );

        // Invariant 4 (single-borrower case): totalDaiBorrowed drops by
        // exactly debt, landing at zero with no dust/underflow.
        assertEq(pool.totalDaiBorrowed(), totalDaiBorrowedBefore - debtBefore);
        assertEq(pool.totalDaiBorrowed(), 0);
    }

    // --- Invariant 3 (bad debt): seizure caps at the borrower's actual ------
    // collateral balance when the formula value would exceed it; debt is
    // still fully cleared (bad debt accepted, not solved, per CLAUDE.md).

    function test_BadDebt_SeizeCappedAtBorrowerCollateral_DebtStillFullyCleared() public {
        vm.prank(dave);
        pool.supply(500_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(25e18); // $50,000 @ $2000/weth
        pool.borrow(37_500e18); // exactly the 75% LTV cap
        vm.stopPrank();

        // Crash the price hard enough that repaid-value*1.10 exceeds
        // alice's actual collateral value (bad debt scenario).
        oracle.setPrice(address(weth), 1000e18);
        assertLt(pool.healthFactor(alice), 1e18, "test construction: alice should be unhealthy");

        uint256 debtBefore = pool.principalDebt(alice); // no warp, exact
        uint256 collateralBefore = pool.collateralBalance(alice);
        uint256 expectedSeize = _expectedSeizeAmount(debtBefore, alice);
        assertEq(expectedSeize, collateralBefore, "test construction: expected the cap to bind here");

        uint256 poolWethBefore = weth.balanceOf(address(pool));
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice);

        // Debt fully cleared despite insufficient collateral.
        assertEq(pool.principalDebt(alice), 0, "bad debt must still zero principalDebt");
        assertEq(pool.totalDaiBorrowed(), 0, "totalDaiBorrowed must still clear fully (sole borrower)");

        // Seizure capped at the borrower's whole collateral balance, not the
        // (larger) formula value.
        assertEq(pool.collateralBalance(alice), 0);
        assertEq(weth.balanceOf(address(pool)), poolWethBefore - collateralBefore);
        assertEq(weth.balanceOf(liquidator), liquidatorWethBefore + collateralBefore);
    }

    // --- Invariant 4: totalDaiBorrowed never underflows/wraps across ------
    // multiple borrowers with accrued interest, and still correctly tracks
    // the surviving borrower's live debt after the other is liquidated.

    function test_TotalDaiBorrowed_MultipleBorrowersWithAccruedInterest_NoUnderflow() public {
        vm.prank(dave);
        pool.supply(500_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000, 40% LTV
        pool.borrow(8_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        pool.depositCollateral(50e18); // $100,000, 20% LTV
        pool.borrow(20_000e18);
        vm.stopPrank();

        // Let interest accrue once, in a single clean step.
        vm.warp(block.timestamp + 180 days);
        pool.accrueForTesting();

        // Crash the price enough to break alice's (higher-LTV) position
        // while bob's (lower-LTV) position stays healthy.
        oracle.setPrice(address(weth), 900e18);
        assertLt(pool.healthFactor(alice), 1e18, "test construction: alice should be unhealthy");
        assertGe(pool.healthFactor(bob), 1e18, "test construction: bob should stay healthy");

        vm.prank(liquidator);
        pool.liquidate(alice);

        uint256 totalBorrowedAfter = pool.totalDaiBorrowed();
        uint256 bobLiveDebtAfter = pool.liveDebtForTesting(bob);

        // No underflow/wrap: must stay a small, sane value, not close to
        // type(uint256).max.
        assertLt(totalBorrowedAfter, 1_000_000e18, "totalDaiBorrowed underflowed/wrapped");
        assertEq(pool.principalDebt(alice), 0);

        // Should now track bob's live debt (the only remaining borrower)
        // within a tiny rounding tolerance, per the wei-level drift
        // CLAUDE.md documents between per-user ceil-rounded settlement and
        // the aggregate's own accrual path.
        assertApproxEqAbs(
            totalBorrowedAfter,
            bobLiveDebtAfter,
            100,
            "totalDaiBorrowed should track the surviving borrower's live debt"
        );
    }

    // --- Invariant 5: totalDaiSupplied / totalReserves are unaffected by ---
    // liquidate() itself (only _accrueInterest() changes them, and that ran
    // to completion, as a no-op, before liquidate()'s own effects since no
    // time passes between the forced accrual and the liquidate() call).

    function test_TotalDaiSuppliedAndTotalReserves_UnaffectedByLiquidateItself() public {
        vm.prank(dave);
        pool.supply(200_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(8_000e18);
        vm.stopPrank();

        // Accrue interest once (bumps totalDaiSupplied/totalReserves), then
        // crash price and liquidate in the same block, so liquidate()'s own
        // internal _accrueInterest() call is a guaranteed no-op
        // (timeDelta == 0) and cannot contaminate this invariant.
        vm.warp(block.timestamp + 90 days);
        pool.accrueForTesting();

        oracle.setPrice(address(weth), 900e18);
        assertLt(pool.healthFactor(alice), 1e18, "test construction: alice should be unhealthy");

        uint256 suppliedBefore = pool.totalDaiSupplied();
        uint256 reservesBefore = pool.totalReserves();
        assertGt(reservesBefore, 0, "test construction: expected some interest/reserves to have accrued");

        vm.prank(liquidator);
        pool.liquidate(alice);

        assertEq(pool.totalDaiSupplied(), suppliedBefore, "liquidate() must not change totalDaiSupplied");
        assertEq(pool.totalReserves(), reservesBefore, "liquidate() must not change totalReserves");
    }

    // --- Invariant 6: liquidity invariant holds after liquidation changes --
    // totalDaiBorrowed, and the sum of suppliers' live withdrawable balances
    // never exceeds totalDaiSupplied; a liquidation that clears a borrower's
    // debt correctly frees up more withdrawable liquidity.

    function test_LiquidityInvariant_And_SupplierSumBound_HoldAfterLiquidation() public {
        vm.prank(dave);
        pool.supply(30_000e18);
        vm.prank(henry);
        pool.supply(20_000e18); // total supplied: 50,000

        vm.startPrank(alice);
        pool.depositCollateral(25e18); // $50,000 @ $2000/weth
        pool.borrow(37_500e18); // exactly the 75% LTV cap
        vm.stopPrank();

        _assertLiquidityInvariant();

        uint256 availableBefore = pool.totalDaiSupplied() - pool.totalDaiBorrowed();
        assertEq(availableBefore, 12_500e18);

        // Not enough free liquidity yet for henry to pull his full stake.
        vm.prank(henry);
        vm.expectRevert("insufficient liquidity");
        pool.withdrawSupply(20_000e18);

        // One clean accrual step, then a price crash that breaks alice's
        // position without pushing seizure past her collateral (chosen so
        // this test isolates the liquidity invariant, not the bad-debt cap
        // covered by test_BadDebt_SeizeCappedAtBorrowerCollateral...).
        vm.warp(block.timestamp + 30 days);
        pool.accrueForTesting();
        oracle.setPrice(address(weth), 1700e18);
        assertLt(pool.healthFactor(alice), 1e18, "test construction: alice should be unhealthy");

        uint256 aliceLiveDebtBefore = pool.liveDebtForTesting(alice);
        uint256 expectedSeize = _expectedSeizeAmount(aliceLiveDebtBefore, alice);
        assertLt(expectedSeize, pool.collateralBalance(alice), "test construction: expected an uncapped seizure here");

        // Sole borrower, single accrual step since her last settle: total
        // should equal her live debt exactly (no rounding drift possible
        // yet with only one borrower and one accrual event).
        assertEq(pool.totalDaiBorrowed(), aliceLiveDebtBefore);

        vm.prank(liquidator);
        pool.liquidate(alice);

        // Liquidity invariant still holds exactly after the liquidation.
        _assertLiquidityInvariant();

        // Sole borrower fully liquidated: totalDaiBorrowed back to exactly
        // zero, no dust/underflow.
        assertEq(pool.totalDaiBorrowed(), 0);

        // All of totalDaiSupplied is now free/withdrawable liquidity.
        uint256 availableAfter = pool.totalDaiSupplied() - pool.totalDaiBorrowed();
        assertEq(availableAfter, pool.totalDaiSupplied());

        // Henry's previously-blocked withdrawal now succeeds, since the
        // liquidation freed up the liquidity his withdrawal needed.
        vm.prank(henry);
        pool.withdrawSupply(20_000e18);
        _assertLiquidityInvariant();

        // Sum of all suppliers' live withdrawable balances never exceeds
        // totalDaiSupplied.
        uint256 sumLiveSupply = pool.liveSupplyForTesting(dave) + pool.liveSupplyForTesting(henry);
        assertLe(sumLiveSupply, pool.totalDaiSupplied(), "sum of suppliers' live balances exceeds totalDaiSupplied");
    }
}
