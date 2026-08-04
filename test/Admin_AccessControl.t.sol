// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Milestone 9 access-control/pause checks per PLAN.md's milestone 9 test
// list: non-owner reverts on every setter and on pause/unpause; pause blocks
// all seven state-changing functions; unpause restores them; parameter
// changes take effect on subsequent calls; admin functions themselves are
// not gated by whenNotPaused (owner must be able to act during an incident).
contract AdminAccessControlTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA501);
    address nonOwner = address(0xBEEF);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        weth.mint(alice, 100e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        dai.approve(address(pool), type(uint256).max);

        dai.mint(bob, 1_000_000e18);
        vm.prank(bob);
        dai.approve(address(pool), type(uint256).max);
    }

    function _expectOwnableRevert(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    // Sets up a live position (supply + collateral + borrow) so that every
    // one of the seven state-changing functions has its non-pause
    // preconditions satisfied, isolating "blocked by pause" as the only
    // possible revert reason.
    function _seedActivePositions() internal {
        vm.prank(bob);
        pool.supply(100_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // 1. Access control: non-owner reverts, owner succeeds + state changes,
    //    for every onlyOwner admin function.
    // ---------------------------------------------------------------

    function test_RevertWhen_NonOwnerCallsPause() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.pause();
    }

    function test_OwnerCanPause() public {
        pool.pause();
        assertTrue(pool.paused());
    }

    function test_RevertWhen_NonOwnerCallsUnpause() public {
        pool.pause();

        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.unpause();
    }

    function test_OwnerCanUnpause() public {
        pool.pause();
        assertTrue(pool.paused());

        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_RevertWhen_NonOwnerCallsSetLtv() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.setLtv(7000);
    }

    function test_OwnerCanSetLtv() public {
        pool.setLtv(7000);
        assertEq(pool.ltv(), 7000);
    }

    function test_RevertWhen_NonOwnerCallsSetLiquidationThreshold() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.setLiquidationThreshold(8500);
    }

    function test_OwnerCanSetLiquidationThreshold() public {
        pool.setLiquidationThreshold(8500);
        assertEq(pool.liquidationThreshold(), 8500);
    }

    function test_RevertWhen_NonOwnerCallsSetLiquidationBonus() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.setLiquidationBonus(12000);
    }

    function test_OwnerCanSetLiquidationBonus() public {
        pool.setLiquidationBonus(12000);
        assertEq(pool.liquidationBonus(), 12000);
    }

    function test_RevertWhen_NonOwnerCallsSetReserveFactor() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.setReserveFactor(0.2e18);
    }

    function test_OwnerCanSetReserveFactor() public {
        pool.setReserveFactor(0.2e18);
        assertEq(pool.reserveFactor(), 0.2e18);
    }

    function test_RevertWhen_NonOwnerCallsSetBaseRate() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.setBaseRate(0.01e18);
    }

    function test_OwnerCanSetBaseRate() public {
        pool.setBaseRate(0.01e18);
        assertEq(pool.baseRate(), 0.01e18);
    }

    function test_RevertWhen_NonOwnerCallsSetOptimalUtilization() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.setOptimalUtilization(0.7e18);
    }

    function test_OwnerCanSetOptimalUtilization() public {
        pool.setOptimalUtilization(0.7e18);
        assertEq(pool.optimalUtilization(), 0.7e18);
    }

    function test_RevertWhen_NonOwnerCallsSetSlope1() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.setSlope1(0.05e18);
    }

    function test_OwnerCanSetSlope1() public {
        pool.setSlope1(0.05e18);
        assertEq(pool.slope1(), 0.05e18);
    }

    function test_RevertWhen_NonOwnerCallsSetSlope2() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.setSlope2(0.8e18);
    }

    function test_OwnerCanSetSlope2() public {
        pool.setSlope2(0.8e18);
        assertEq(pool.slope2(), 0.8e18);
    }

    function test_RevertWhen_NonOwnerCallsWithdrawReserves() public {
        _expectOwnableRevert(nonOwner);
        vm.prank(nonOwner);
        pool.withdrawReserves(nonOwner, 0);
    }

    function test_OwnerCanWithdrawReserves() public {
        // Generate real reserves: supply, borrow, warp a year, and trigger
        // accrual via a zero-amount supply call (no side effect on balances
        // beyond the index bookkeeping).
        _seedActivePositions();
        vm.warp(block.timestamp + 365 days);
        vm.prank(bob);
        pool.supply(0);

        uint256 reserves = pool.totalReserves();
        assertGt(reserves, 0);

        uint256 balBefore = dai.balanceOf(carol);
        pool.withdrawReserves(carol, reserves);

        assertEq(pool.totalReserves(), 0);
        assertEq(dai.balanceOf(carol), balBefore + reserves);
    }

    // ---------------------------------------------------------------
    // 2. Pause blocks all seven state-changing functions; unpause restores
    //    them.
    // ---------------------------------------------------------------

    function test_RevertWhen_DepositCollateralWhilePaused() public {
        _seedActivePositions();
        pool.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        pool.depositCollateral(1e18);
    }

    function test_RevertWhen_WithdrawCollateralWhilePaused() public {
        _seedActivePositions();
        pool.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        pool.withdrawCollateral(1e18);
    }

    function test_RevertWhen_SupplyWhilePaused() public {
        _seedActivePositions();
        pool.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        pool.supply(1e18);
    }

    function test_RevertWhen_WithdrawSupplyWhilePaused() public {
        _seedActivePositions();
        pool.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        pool.withdrawSupply(1e18);
    }

    function test_RevertWhen_BorrowWhilePaused() public {
        _seedActivePositions();
        pool.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        pool.borrow(1e18);
    }

    function test_RevertWhen_RepayWhilePaused() public {
        _seedActivePositions();
        pool.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        pool.repay(1e18);
    }

    function test_RevertWhen_LiquidateWhilePaused() public {
        _seedActivePositions();
        pool.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(carol);
        pool.liquidate(alice);
    }

    function test_UnpauseRestoresDepositCollateralAndSupply() public {
        _seedActivePositions();
        pool.pause();
        pool.unpause();

        uint256 aliceCollateralBefore = pool.collateralBalance(alice);
        vm.prank(alice);
        pool.depositCollateral(1e18);
        assertEq(pool.collateralBalance(alice), aliceCollateralBefore + 1e18);

        uint256 bobSuppliedBefore = pool.suppliedBalance(bob);
        vm.prank(bob);
        pool.supply(1e18);
        assertEq(pool.suppliedBalance(bob), bobSuppliedBefore + 1e18);
    }

    // ---------------------------------------------------------------
    // 3. Admin functions themselves are not gated by whenNotPaused: the
    //    owner must be able to adjust risk params or unpause during an
    //    incident.
    // ---------------------------------------------------------------

    function test_AdminSettersAndUnpauseWorkWhilePaused() public {
        _seedActivePositions();
        pool.pause();
        assertTrue(pool.paused());

        // None of these carry whenNotPaused, so all must succeed despite
        // the pool being paused.
        pool.setLtv(7000);
        pool.setLiquidationThreshold(8500);
        pool.setLiquidationBonus(12000);
        pool.setReserveFactor(0.2e18);
        pool.setBaseRate(0.01e18);
        pool.setOptimalUtilization(0.7e18);
        pool.setSlope1(0.05e18);
        pool.setSlope2(0.8e18);

        assertEq(pool.ltv(), 7000);
        assertEq(pool.liquidationThreshold(), 8500);
        assertEq(pool.liquidationBonus(), 12000);
        assertEq(pool.reserveFactor(), 0.2e18);
        assertEq(pool.baseRate(), 0.01e18);
        assertEq(pool.optimalUtilization(), 0.7e18);
        assertEq(pool.slope1(), 0.05e18);
        assertEq(pool.slope2(), 0.8e18);

        // Pool is still paused throughout — the setters didn't need it
        // unpaused to succeed.
        assertTrue(pool.paused());

        // unpause() itself is owner-only, not whenNotPaused-gated (it would
        // make no sense otherwise), and must work while paused.
        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_WithdrawReservesWorksWhilePaused() public {
        _seedActivePositions();
        vm.warp(block.timestamp + 365 days);
        vm.prank(bob);
        pool.supply(0);

        pool.pause();
        uint256 reserves = pool.totalReserves();
        assertGt(reserves, 0);

        pool.withdrawReserves(carol, reserves);
        assertEq(pool.totalReserves(), 0);
        assertEq(dai.balanceOf(carol), reserves);
    }

    // ---------------------------------------------------------------
    // 4. Parameter changes take effect on subsequent calls (not just the
    //    getter — the actual gating logic).
    // ---------------------------------------------------------------

    function test_SetLtvTakesEffectOnSubsequentBorrow() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);

        // 10 mWETH @ $2000 = $20,000 collateral. At default 75% LTV,
        // 15,500e18 debt would exceed the limit (see
        // BorrowRepay_SpecLogic.t.sol) — but if we lower LTV further first,
        // an amount that would have passed at 75% must now fail.
        vm.stopPrank();

        // Lower LTV to 50%: max borrowable debt becomes $10,000.
        pool.setLtv(5000);

        vm.startPrank(alice);
        vm.expectRevert("exceeds LTV");
        pool.borrow(10_001e18);

        // Exactly at the new (lower) limit still succeeds.
        pool.borrow(10_000e18);
        vm.stopPrank();

        assertEq(pool.principalDebt(alice), 10_000e18);
    }
}
