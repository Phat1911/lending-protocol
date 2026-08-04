// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

contract CollateralTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        weth.mint(alice, 100e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);
    }

    function test_DepositCollateral() public {
        vm.prank(alice);
        pool.depositCollateral(10e18);

        assertEq(pool.collateralBalance(alice), 10e18);
        assertEq(weth.balanceOf(address(pool)), 10e18);
        assertEq(weth.balanceOf(alice), 90e18);
    }
    function test_WithdrawCollateral() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.withdrawCollateral(4e18);
        vm.stopPrank();

        assertEq(pool.collateralBalance(alice), 6e18);
        assertEq(weth.balanceOf(address(pool)), 6e18);
        assertEq(weth.balanceOf(alice), 94e18);
    }

    function test_RevertWhen_WithdrawMoreThanDeposited() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        vm.expectRevert("insufficient collateral");
        pool.withdrawCollateral(11e18);
        vm.stopPrank();
    }
}
