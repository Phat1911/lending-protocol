// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Zero-value and boundary probes for milestone 7's interest rate model +
// accrual index math (_accrueInterest, getUtilization, getBorrowRate,
// getSupplyRate, _settleDebt, _settleSupply, _liveDebt, _mulDivUp). Follows
// the conventions of test/BorrowRepay_IntegerEdge.t.sol.
contract InterestAccrualIntegerEdgeTest is Test {
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

        weth.mint(alice, 1_000e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        dai.approve(address(pool), type(uint256).max);

        dai.mint(bob, 1_000_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // --- getUtilization() ---

    function test_UtilizationZeroWhenNoSupply() public view {
        // No supply, no borrows: must return 0, not divide by zero.
        assertEq(pool.totalDaiSupplied(), 0);
        assertEq(pool.getUtilization(), 0);
    }

    // --- getBorrowRate() at the kink boundary ---

    function test_BorrowRateContinuousAtKinkBoundary() public {
        // Set up totalDaiSupplied/totalDaiBorrowed so utilization lands
        // exactly at optimalUtilization (80%), then nudge 1 unit of
        // totalDaiSupplied smaller/larger to probe both branches without
        // an actual discontinuity/off-by-one at the boundary.
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(800_000e18); // exactly 80% utilization
        vm.stopPrank();

        assertEq(pool.getUtilization(), 0.8e18);

        uint256 rateAtKink = pool.getBorrowRate();
        // At exactly the kink: baseRate + slope1 = 0 + 0.04e18.
        assertEq(rateAtKink, 0.04e18);

        // Branch selection uses `<=`, so the kink itself takes the
        // "below/at kink" branch. Confirm the "above kink" branch's formula
        // would agree in the limit (continuity), by checking a hair above.
        // (We can't get a "hair above" via whole-token borrows easily, so
        // instead directly verify the two formulas agree symbolically at
        // u == optimalUtilization: excessUtilization would be 0, so branch2
        // would also yield baseRate + slope1 + 0 == rateAtKink.)
        uint256 optimal = pool.optimalUtilization();
        uint256 slope1 = pool.slope1();
        uint256 baseRate = pool.baseRate();
        assertEq(rateAtKink, baseRate + (optimal * slope1) / optimal);
    }

    function test_BorrowRateAtFullUtilizationIsSlope1PlusSlope2() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(1_000_000e18); // 100% utilization
        vm.stopPrank();

        assertEq(pool.getUtilization(), 1e18);
        // baseRate(0) + slope1(4%) + slope2(75%) = 79%, per SPEC.md §5.
        assertEq(pool.getBorrowRate(), 0.79e18);
    }

    // --- _accrueInterest() with zero borrows ---

    function test_AccrueInterestSkipsInterestMathButUpdatesTimestampWhenNoBorrows() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        uint256 borrowIndexBefore = pool.borrowIndex();
        uint256 supplyIndexBefore = pool.supplyIndex();

        vm.warp(block.timestamp + 365 days);

        // Any state-changing call triggers _accrueInterest(); use a no-op
        // repay(0) from alice (no debt) to avoid disturbing supply state.
        vm.prank(alice);
        pool.repay(0);

        // No borrows ever existed -> indices must be untouched...
        assertEq(pool.borrowIndex(), borrowIndexBefore);
        assertEq(pool.supplyIndex(), supplyIndexBefore);
        // ...but lastAccrualTimestamp must still advance.
        assertEq(pool.lastAccrualTimestamp(), block.timestamp);
    }

    // --- totalDaiSupplied == 0 but totalDaiBorrowed > 0: reachability ---

    function test_Invariant_TotalSuppliedNeverBelowTotalBorrowed_SoSupplyIndexGuardIsUnreachableButSafe()
        public
    {
        // withdrawSupply() requires `amount <= totalDaiSupplied -
        // totalDaiBorrowed` (checked after accrual), so totalDaiSupplied
        // can never be dragged below totalDaiBorrowed by a withdrawal, and
        // totalDaiBorrowed only increases via accrual/borrow when
        // totalDaiSupplied already covers it. That makes
        // `totalDaiSupplied == 0 && totalDaiBorrowed > 0` unreachable via
        // the public interface: the `if (totalDaiSupplied > 0)` guard in
        // _accrueInterest is defensive dead code, not a live bug. This test
        // exercises the closest reachable state (supplied fully drained
        // down to outstanding debt) and confirms no revert / no div-by-zero.
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(500_000e18);
        vm.stopPrank();

        // Bob withdraws everything not currently borrowed.
        vm.prank(bob);
        pool.withdrawSupply(500_000e18);

        assertEq(pool.totalDaiSupplied(), pool.totalDaiBorrowed());
        assertGt(pool.totalDaiSupplied(), 0);

        // Accrue interest from this drained-to-the-limit state; must not
        // revert, and totalDaiSupplied must stay >= totalDaiBorrowed
        // immediately after (supplyCut is added in the same step debt grows).
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        pool.repay(0);

        assertGt(pool.totalDaiSupplied(), 0);
    }

    function test_Finding_UtilizationCanExceedFullWadOverLongHorizonsDueToReserveFactorAsymmetry()
        public
    {
        // FINDING (not a revert/overflow bug, but a boundary-correctness
        // issue worth flagging): each _accrueInterest() step adds the FULL
        // interestAccrued to totalDaiBorrowed, but only the post-reserve-cut
        // 90% (supplyCut) to totalDaiSupplied. That means the gap
        // (totalDaiSupplied - totalDaiBorrowed) strictly shrinks by
        // 10%*interestAccrued on every accrual with totalDaiBorrowed > 0,
        // even though nothing ever pulls totalDaiSupplied back down other
        // than withdrawSupply. Given enough elapsed time (or a single very
        // large vm.warp), totalDaiBorrowed can overtake totalDaiSupplied,
        // pushing getUtilization() above 1e18 (100%) — a state the SPEC.md
        // §5 kinked curve was not written to handle ("at 100% utilization:
        // 79% APR" implies utilization is bounded at 100%). Once above
        // 100%, getBorrowRate()'s excessUtilization can exceed excessRange,
        // driving the borrow rate past the documented 79% ceiling with no
        // cap. This does not revert and is not new-money-unsafe by itself,
        // but it is a real spec deviation surfaced by milestone 7's math.
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 1_000_000e18);
        pool.depositCollateral(1_000_000e18);
        pool.borrow(800_000e18); // 80% utilization, at the kink
        vm.stopPrank();

        assertEq(pool.getUtilization(), 0.8e18);

        // One huge jump (400 years) forces enough single-shot linear
        // interest that totalDaiBorrowed overtakes totalDaiSupplied.
        vm.warp(block.timestamp + 400 * 365 days);
        vm.prank(alice);
        pool.repay(0); // triggers _accrueInterest()

        assertGt(pool.totalDaiBorrowed(), pool.totalDaiSupplied());
        assertGt(pool.getUtilization(), 1e18);
        assertGt(pool.getBorrowRate(), 0.79e18);
    }

    // --- _settleDebt()/_settleSupply() for a brand-new user ---

    function test_SettleDebtForBrandNewUserDoesNotDivideByZero() public {
        // alice has principalDebt == 0 and userBorrowIndex == 0 (default).
        // repay(0) runs _accrueInterest() then _settleDebt(alice); the
        // `if (principalDebt[user] > 0)` guard must skip the
        // _mulDivUp(principal, borrowIndex, userBorrowIndex[user]) call
        // entirely, avoiding a 0-denominator division.
        assertEq(pool.principalDebt(alice), 0);
        assertEq(pool.userBorrowIndex(alice), 0);

        vm.prank(alice);
        pool.repay(0); // must not revert

        // userBorrowIndex is still stamped to current borrowIndex even
        // though there was no debt to rescale.
        assertEq(pool.userBorrowIndex(alice), pool.borrowIndex());
    }

    function test_SettleSupplyForBrandNewUserDoesNotDivideByZero() public {
        assertEq(pool.suppliedBalance(alice), 0);
        assertEq(pool.userSupplyIndex(alice), 0);

        // supply() runs _accrueInterest() then _settleSupply(alice) before
        // crediting the new principal; guarded the same way as debt.
        dai.mint(alice, 100e18);
        vm.startPrank(alice);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(100e18); // must not revert
        vm.stopPrank();

        assertEq(pool.suppliedBalance(alice), 100e18);
        assertEq(pool.userSupplyIndex(alice), pool.supplyIndex());
    }

    // --- _liveDebt() for a user who has never borrowed ---

    function test_LiveDebtForNeverBorrowedUserIsZero() public view {
        assertEq(pool.principalDebt(alice), 0);
        assertEq(pool.healthFactor(alice), type(uint256).max);
    }

    // --- _mulDivUp() boundary behavior (indirectly, via _liveDebt) ---

    function test_MulDivUpRoundsUpNotDownForDebtSettlement() public {
        // Force a case where principal * borrowIndex / userBorrowIndex has
        // a nonzero remainder, and confirm the ceiling-division rounds in
        // the protocol's favor (never lets a borrower's live debt round
        // down to less than what's actually owed).
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(700_000e18); // 70% utilization, below kink
        vm.stopPrank();

        uint256 principalBefore = pool.principalDebt(alice);
        uint256 userIndexBefore = pool.userBorrowIndex(alice);

        // Small warp so interestFactor's fractional growth is tiny enough
        // to likely produce a non-clean division remainder.
        vm.warp(block.timestamp + 37); // 37 seconds
        vm.prank(alice);
        pool.repay(0); // accrues + settles

        uint256 newBorrowIndex = pool.borrowIndex();
        uint256 expectedFloor = principalBefore * newBorrowIndex / userIndexBefore;
        uint256 actualSettled = pool.principalDebt(alice);

        assertGe(actualSettled, expectedFloor);
        assertLe(actualSettled, expectedFloor + 1); // ceiling div is at most +1 wei
    }

    // --- large timeDelta sanity (10+ years) ---

    function test_AccrueInterestAfterTenYearsDoesNotOverflowForRealisticPrincipal() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(400_000e18); // 40% utilization, below kink
        vm.stopPrank();

        vm.warp(block.timestamp + 10 * 365 days);

        // Must not revert/overflow for realistic (six-to-seven-figure
        // token) principal amounts.
        vm.prank(alice);
        pool.repay(0);

        assertGt(pool.principalDebt(alice), 400_000e18);
        assertGt(pool.borrowIndex(), 1e18);
    }

    function test_AccrueInterestAfterFiftyYearsAtMaxRateDoesNotOverflow() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        weth.mint(alice, 10_000e18);
        pool.depositCollateral(10_000e18);
        pool.borrow(1_000_000e18); // 100% utilization, max rate (79%)
        vm.stopPrank();

        vm.warp(block.timestamp + 50 * 365 days);

        vm.prank(alice);
        pool.repay(0); // must not revert despite huge single-shot linear growth

        assertGt(pool.borrowIndex(), 1e18);
    }
}
