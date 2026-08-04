// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 6 added borrow()/repay() and wired a real health-factor gate
// into withdrawCollateral. These tests check the cross-user/cross-token
// state invariants that must hold after any sequence of
// deposit/withdraw/supply/withdrawSupply/borrow/repay calls from multiple
// independent users, rather than any single function's behavior in
// isolation (covered elsewhere).
contract BorrowRepayStateConsistencyTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);

    // Used across test_SumInvariant / test_LiquidityInvariant.
    address dave = address(0xDA5E); // supplier
    address alice = address(0xA11CE); // borrower
    address bob = address(0xB0B); // borrower
    address carol = address(0xCA501); // borrower

    // Used in test_WithdrawSupplyRevertsWhenLiquidityBorrowedOut.
    address eve = address(0xE5E); // supplier
    address frank = address(0xF5A); // borrower

    // Used in test_BorrowDoesNotTouchCollateralAccounting.
    address grace = address(0x6AACE); // depositor/borrower
    address henry = address(0x4E4E1); // supplier

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        // Suppliers.
        dai.mint(dave, 100_000e18);
        vm.prank(dave);
        dai.approve(address(pool), type(uint256).max);

        dai.mint(eve, 10_000e18);
        vm.prank(eve);
        dai.approve(address(pool), type(uint256).max);

        dai.mint(henry, 5_000e18);
        vm.prank(henry);
        dai.approve(address(pool), type(uint256).max);

        // Borrowers: collateral + DAI (for repay).
        address[4] memory borrowers = [alice, bob, carol, frank];
        for (uint256 i = 0; i < borrowers.length; i++) {
            weth.mint(borrowers[i], 100e18);
            dai.mint(borrowers[i], 100_000e18);
            vm.startPrank(borrowers[i]);
            weth.approve(address(pool), type(uint256).max);
            dai.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }

        weth.mint(grace, 100e18);
        dai.mint(grace, 100_000e18);
        vm.startPrank(grace);
        weth.approve(address(pool), type(uint256).max);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // --- Invariant 1: totalDaiBorrowed == sum(principalDebt[user]) ---------

    function _assertSumInvariant() internal view {
        uint256 sumDebt = pool.principalDebt(alice) + pool.principalDebt(bob) + pool.principalDebt(carol);
        assertEq(pool.totalDaiBorrowed(), sumDebt, "totalDaiBorrowed != sum(principalDebt)");
    }

    function test_SumInvariant_HoldsAcrossMultipleBorrowersAndPartialRepays() public {
        // Liquidity.
        vm.prank(dave);
        pool.supply(100_000e18);
        _assertSumInvariant();

        // Three independent borrowers, each with their own collateral.
        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000 @ $2000/weth
        pool.borrow(5_000e18);
        vm.stopPrank();
        _assertSumInvariant();

        vm.startPrank(bob);
        pool.depositCollateral(20e18); // $40,000
        pool.borrow(10_000e18);
        vm.stopPrank();
        _assertSumInvariant();

        vm.startPrank(carol);
        pool.depositCollateral(5e18); // $10,000
        pool.borrow(2_000e18);
        vm.stopPrank();
        _assertSumInvariant();

        // Partial repay from alice.
        vm.prank(alice);
        pool.repay(2_000e18);
        assertEq(pool.principalDebt(alice), 3_000e18);
        _assertSumInvariant();

        // Full repay from bob.
        vm.prank(bob);
        pool.repay(10_000e18);
        assertEq(pool.principalDebt(bob), 0);
        _assertSumInvariant();

        // carol never repays.
        assertEq(pool.principalDebt(carol), 2_000e18);
        _assertSumInvariant();

        // Final sanity: 3,000 (alice) + 0 (bob) + 2,000 (carol) = 5,000.
        assertEq(pool.totalDaiBorrowed(), 5_000e18);
    }

    // --- Invariant 2: pool's mDAI balance == totalDaiSupplied - totalDaiBorrowed ---

    function _assertLiquidityInvariant() internal view {
        assertEq(
            dai.balanceOf(address(pool)),
            pool.totalDaiSupplied() - pool.totalDaiBorrowed(),
            "pool DAI balance != totalDaiSupplied - totalDaiBorrowed"
        );
    }

    function test_LiquidityInvariant_HoldsThroughSupplyBorrowRepayWithdrawSupply() public {
        vm.prank(dave);
        pool.supply(100_000e18);
        _assertLiquidityInvariant(); // 100,000 - 0 = 100,000

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();
        _assertLiquidityInvariant(); // 100,000 - 5,000 = 95,000

        vm.startPrank(bob);
        pool.depositCollateral(20e18);
        pool.borrow(10_000e18);
        vm.stopPrank();
        _assertLiquidityInvariant(); // 100,000 - 15,000 = 85,000

        vm.startPrank(carol);
        pool.depositCollateral(5e18);
        pool.borrow(2_000e18);
        vm.stopPrank();
        _assertLiquidityInvariant(); // 100,000 - 17,000 = 83,000

        vm.prank(alice);
        pool.repay(2_000e18);
        _assertLiquidityInvariant(); // 100,000 - 15,000 = 85,000

        vm.prank(bob);
        pool.repay(10_000e18); // full repay
        _assertLiquidityInvariant(); // 100,000 - 5,000 = 95,000

        // Unborrowed liquidity is now 100,000 - 5,000 = 95,000; dave can
        // withdraw all of it.
        vm.prank(dave);
        pool.withdrawSupply(95_000e18);
        _assertLiquidityInvariant(); // 5,000 - 5,000 = 0

        assertEq(dai.balanceOf(address(pool)), 0);
        assertEq(pool.totalDaiSupplied(), 5_000e18);
        assertEq(pool.totalDaiBorrowed(), 5_000e18);
    }

    // --- Invariant 3: withdrawSupply liquidity gate is now live/testable ---

    function test_WithdrawSupplyRevertsWhenLiquidityBorrowedOut() public {
        vm.prank(eve);
        pool.supply(10_000e18);

        vm.startPrank(frank);
        pool.depositCollateral(10e18); // $20,000 collateral
        pool.borrow(9_000e18); // borrows most of the pool's liquidity
        vm.stopPrank();

        // Unborrowed liquidity = 10,000 - 9,000 = 1,000. Eve's supplied
        // balance (10,000) is more than enough on paper, but the pool
        // physically only has 1,000 mDAI of unborrowed liquidity.
        assertEq(pool.totalDaiSupplied() - pool.totalDaiBorrowed(), 1_000e18);

        vm.prank(eve);
        vm.expectRevert("insufficient liquidity");
        pool.withdrawSupply(2_000e18);

        // Withdrawing exactly the unborrowed amount succeeds.
        vm.prank(eve);
        pool.withdrawSupply(1_000e18);
        assertEq(dai.balanceOf(address(pool)), 0);
        _assertLiquidityInvariant();
    }

    // --- Invariant 4: borrow() must not touch collateral accounting -------

    function test_BorrowDoesNotTouchCollateralAccounting() public {
        vm.prank(henry);
        pool.supply(5_000e18);

        vm.prank(grace);
        pool.depositCollateral(10e18);

        assertEq(weth.balanceOf(address(pool)), 10e18);
        assertEq(pool.collateralBalance(grace), 10e18);

        vm.prank(grace);
        pool.borrow(1_000e18); // $20,000 collateral, well within LTV

        // Collateral token balance and per-user collateral accounting are
        // completely unaffected by borrow().
        assertEq(weth.balanceOf(address(pool)), 10e18);
        assertEq(pool.collateralBalance(grace), 10e18);

        // Repay in full, then withdraw the collateral: only
        // withdrawCollateral should move the collateral token / decrement
        // collateralBalance.
        vm.startPrank(grace);
        pool.repay(1_000e18);
        pool.withdrawCollateral(10e18);
        vm.stopPrank();

        assertEq(weth.balanceOf(address(pool)), 0);
        assertEq(pool.collateralBalance(grace), 0);
        assertEq(weth.balanceOf(grace), 100e18); // back to original mint amount
    }
}
