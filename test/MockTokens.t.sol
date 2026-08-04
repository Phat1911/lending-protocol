// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";

contract MockTokensTest is Test {
    MockWETH weth;
    MockDAI dai;

    address alice = address(0xA11CE);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
    }

    function test_MintWeth() public {
        weth.mint(alice, 10e18);
        assertEq(weth.balanceOf(alice), 10e18);
    }

    function test_MintDai() public {
        dai.mint(alice, 5000e18);
        assertEq(dai.balanceOf(alice), 5000e18);
    }
}
