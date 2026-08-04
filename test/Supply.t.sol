// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

contract SupplyTest is Test {
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

        dai.mint(alice, 10_000e18);
        vm.prank(alice);
        dai.approve(address(pool), type(uint256).max);
    }

    function test_Supply() public {
        vm.prank(alice);
        pool.supply(1_000e18);

        assertEq(pool.suppliedBalance(alice), 1_000e18);
        assertEq(pool.totalDaiSupplied(), 1_000e18);
        assertEq(dai.balanceOf(address(pool)), 1_000e18);
        assertEq(dai.balanceOf(alice), 9_000e18);
    }

    function test_WithdrawSupply() public {
        vm.startPrank(alice);
        pool.supply(1_000e18);
        pool.withdrawSupply(400e18);
        vm.stopPrank();

        assertEq(pool.suppliedBalance(alice), 600e18);
        assertEq(pool.totalDaiSupplied(), 600e18);
        assertEq(dai.balanceOf(address(pool)), 600e18);
        assertEq(dai.balanceOf(alice), 9_400e18);
    }

    function test_RevertWhen_WithdrawMoreThanSupplied() public {
        vm.startPrank(alice);
        pool.supply(1_000e18);
        vm.expectRevert("insufficient supply balance");
        pool.withdrawSupply(1_001e18);
        vm.stopPrank();
    }

    function test_WithdrawAvailableWhenNothingBorrowed() public {
        // Sanity check for the always-available case: with totalDaiBorrowed == 0
        // (borrow() doesn't exist yet), a supplier can withdraw their full balance.
        vm.startPrank(alice);
        pool.supply(1_000e18);
        pool.withdrawSupply(1_000e18);
        vm.stopPrank();

        assertEq(pool.suppliedBalance(alice), 0);
        assertEq(pool.totalDaiSupplied(), 0);
    }
}
