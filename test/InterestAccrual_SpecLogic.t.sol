// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 7 spec-correctness checks: interest rate model + accrual index
// math, against SPEC.md §5/§6 and PLAN.md's milestone 7 test list. Not
// covering generic vulnerability classes (reentrancy/overflow/rounding
// artifacts/oracle timing) — those are owned by other parallel test files
// for this milestone. Where integer division forces a non-exact result we
// use a tight tolerance and state why.
contract InterestAccrualSpecLogicTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    // 1 wei of WAD-scaled tolerance for checkpoints that should land exactly
    // on round numbers given our chosen round-number test inputs; genuine
    // spec mismatches will be orders of magnitude off this, not 1 wei.
    uint256 constant TOL = 1;

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
    // 1. Rate curve checkpoints (SPEC.md §5): 0% util -> 0% APR,
    //    80% util (kink) -> 4% APR, 100% util -> 79% APR.
    // ---------------------------------------------------------------

    function test_BorrowRateAtZeroUtilizationIsZero() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);
        // nobody borrows -> utilization == 0
        assertEq(pool.getUtilization(), 0);
        assertEq(pool.getBorrowRate(), 0);
    }

    function test_BorrowRateAtKinkUtilizationIsFourPercent() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(1000e18); // $2,000,000 collateral, plenty for 75% LTV
        pool.borrow(800_000e18); // exactly 80% of 1,000,000e18 supplied
        vm.stopPrank();

        assertEq(pool.getUtilization(), 0.8e18, "utilization must be exactly 80%");
        assertEq(pool.getBorrowRate(), 0.04e18, "rate at kink must be exactly 4% APR");
    }

    function test_BorrowRateAtFullUtilizationIsSeventyNinePercent() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(1_000_000e18); // 100% of supplied liquidity
        vm.stopPrank();

        assertEq(pool.getUtilization(), 1e18, "utilization must be exactly 100%");
        assertEq(pool.getBorrowRate(), 0.79e18, "rate at 100% util must be exactly 79% APR");
    }

    // ---------------------------------------------------------------
    // 2. Utilization formula: totalDaiBorrowed / totalDaiSupplied, WAD-scaled,
    //    0 if totalDaiSupplied == 0. Also confirms scale-then-divide ordering
    //    (multiplying by WAD before dividing, not after — which would floor
    //    to 0 for any utilization < 100%).
    // ---------------------------------------------------------------

    function test_GetUtilizationIsZeroWhenNothingSupplied() public {
        assertEq(pool.totalDaiSupplied(), 0);
        assertEq(pool.getUtilization(), 0);
    }

    function test_GetUtilizationMatchesFormulaAtNonRoundRatio() public {
        vm.prank(bob);
        pool.supply(3e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000, way over LTV needs for 1e18 debt
        pool.borrow(1e18);
        vm.stopPrank();

        // Correct (scale-first) formula: 1e18 * 1e18 / 3e18 = 333333333333333333.
        // A buggy (divide-first) formula would floor 1e18/3e18 to 0 before
        // scaling, giving utilization == 0 — this test would catch that.
        uint256 borrowed = 1e18;
        uint256 supplied = 3e18;
        uint256 expected = (borrowed * 1e18) / supplied;
        assertEq(pool.getUtilization(), expected);
        assertGt(pool.getUtilization(), 0);
    }

    // ---------------------------------------------------------------
    // 3. Supply rate formula: supplyRate = borrowRate * utilization * (1 - reserveFactor).
    // ---------------------------------------------------------------

    function test_GetSupplyRateMatchesSpecFormulaAtKink() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization -> borrowRate == 4%
        vm.stopPrank();

        uint256 borrowRate = pool.getBorrowRate();
        uint256 utilization = pool.getUtilization();
        uint256 reserveFactor = pool.reserveFactor();

        // Literal spec formula, computed independently of the contract's
        // internal scaling to catch an operand-order/double-scaling bug.
        uint256 expected = (borrowRate * utilization / 1e18) * (1e18 - reserveFactor) / 1e18;
        assertEq(pool.getSupplyRate(), expected);
        // Sanity-check the concrete number: 4% * 80% * 90% = 2.88%.
        assertEq(pool.getSupplyRate(), 0.0288e18);
    }

    // ---------------------------------------------------------------
    // 4. Per-second linear accrual: SECONDS_PER_YEAR == 365 days exactly,
    //    and a full year at fixed utilization grows the index by exactly
    //    (1 + borrowRate).
    // ---------------------------------------------------------------

    function test_SecondsPerYearIsExactly365Days() public view {
        assertEq(pool.SECONDS_PER_YEAR(), 365 days);
    }

    function test_OneYearAccrualAtKinkGrowsIndexByExactlyBorrowRate() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization -> borrowRate == 4% APR, fixed point
        vm.stopPrank();

        assertEq(pool.borrowIndex(), 1e18);

        vm.warp(block.timestamp + 365 days);
        // Trigger accrual without changing any balances.
        vm.prank(bob);
        pool.supply(0);

        // interestFactor = 1 + 0.04 * (365 days / 365 days) = 1.04 exactly.
        assertEq(pool.borrowIndex(), 1.04e18, "borrowIndex must grow by exactly the APR after 1 year");
    }

    // ---------------------------------------------------------------
    // 5. Index-scaling formula: currentDebt = principal * borrowIndex /
    //    userBorrowIndexAtLastUpdate (and same pattern for supply).
    //    Also doubles as the reserve-factor-split check (#6): of 32,000e18
    //    interest accrued, exactly 3,200e18 (10%) goes to reserves and
    //    28,800e18 (90%) flows to the supplier's balance.
    // ---------------------------------------------------------------

    function test_IndexScaledDebtAndSupplyAndReserveSplitAfterOneYear() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization, borrowRate == 4% APR
        vm.stopPrank();

        assertEq(pool.principalDebt(alice), 800_000e18);
        assertEq(pool.userBorrowIndex(alice), 1e18);
        assertEq(pool.suppliedBalance(bob), 1_000_000e18);
        assertEq(pool.userSupplyIndex(bob), 1e18);
        assertEq(pool.totalReserves(), 0);

        vm.warp(block.timestamp + 365 days);

        // Trigger global accrual + settle bob's supply principal.
        vm.prank(bob);
        pool.supply(0);
        // Trigger settlement of alice's debt principal (repay(0) is a no-op
        // repay amount but still runs _accrueInterest + _settleDebt first).
        vm.prank(alice);
        pool.repay(0);

        // interestAccrued = 800,000e18 * 0.04 = 32,000e18 (exact, no rounding
        // needed since timeDelta == SECONDS_PER_YEAR and inputs are round).
        // currentDebt = principal * borrowIndex(1.04e18) / userBorrowIndex(1e18)
        //             = 800,000e18 * 1.04 = 832,000e18.
        assertEq(pool.principalDebt(alice), 832_000e18, "debt must scale by index ratio, index-scaling formula");
        assertEq(pool.totalDaiBorrowed(), 832_000e18);

        // reserveFactor = 10% of interest accrued -> reserveCut = 3,200e18.
        assertEq(pool.totalReserves(), 3_200e18, "reserve cut must be exactly 10% of interest accrued");

        // supplyCut = 90% of interest accrued -> 28,800e18 flows to suppliers.
        // bob is the sole supplier so his balance captures 100% of supplyCut:
        // suppliedBalance = principal * supplyIndex / userSupplyIndex
        //                 = 1,000,000e18 * 1.0288e18 / 1e18 = 1,028,800e18.
        assertEq(
            pool.suppliedBalance(bob), 1_028_800e18, "supply balance must scale by index ratio, index-scaling formula"
        );
        assertEq(pool.totalDaiSupplied(), 1_028_800e18);

        // Cross-check: reserve + supplier growth must equal total interest
        // accrued (32,000e18), and the split ratio must be exactly 10/90,
        // not inverted or using some other constant.
        uint256 reserveGrowth = pool.totalReserves();
        uint256 supplierGrowth = pool.suppliedBalance(bob) - 1_000_000e18;
        assertEq(reserveGrowth + supplierGrowth, 32_000e18);
        assertEq(reserveGrowth * 9, supplierGrowth, "split must be exactly 10% reserves / 90% suppliers");
    }

    // ---------------------------------------------------------------
    // 7. _accrueInterest() must run at the top of every state-changing
    //    function (deposit/withdraw collateral, supply/withdrawSupply,
    //    borrow/repay) — confirmed here by observing the global index/
    //    timestamp actually advance as a side effect of calling each one.
    // ---------------------------------------------------------------

    function test_AccrueInterestTriggeredByEveryStateChangingFunction() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(1000e18);
        pool.borrow(800_000e18); // 80% utilization, nonzero borrow rate so index moves
        vm.stopPrank();

        // depositCollateral
        _warpAndAssertAccrual(1 days);
        vm.prank(alice);
        pool.depositCollateral(0);
        _assertAccrualHappened();

        // withdrawCollateral
        _warpAndAssertAccrual(1 days);
        vm.prank(alice);
        pool.withdrawCollateral(0);
        _assertAccrualHappened();

        // supply
        _warpAndAssertAccrual(1 days);
        vm.prank(bob);
        pool.supply(0);
        _assertAccrualHappened();

        // withdrawSupply
        _warpAndAssertAccrual(1 days);
        vm.prank(bob);
        pool.withdrawSupply(0);
        _assertAccrualHappened();

        // repay
        _warpAndAssertAccrual(1 days);
        vm.prank(alice);
        pool.repay(0);
        _assertAccrualHappened();

        // borrow (must use a nonzero amount, borrow() reverts on 0)
        _warpAndAssertAccrual(1 days);
        vm.prank(alice);
        pool.borrow(1e18);
        _assertAccrualHappened();
    }

    uint256 private _preTimestamp;
    uint256 private _preIndex;

    function _warpAndAssertAccrual(uint256 delta) internal {
        _preTimestamp = pool.lastAccrualTimestamp();
        _preIndex = pool.borrowIndex();
        vm.warp(block.timestamp + delta);
    }

    function _assertAccrualHappened() internal view {
        assertEq(pool.lastAccrualTimestamp(), block.timestamp, "_accrueInterest must have updated the timestamp");
        assertGt(pool.borrowIndex(), _preIndex, "_accrueInterest must have grown the borrow index");
    }
}
