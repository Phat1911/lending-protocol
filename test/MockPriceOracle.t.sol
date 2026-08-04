// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

contract MockPriceOracleTest is Test {
    MockPriceOracle oracle;

    address owner = address(this);
    address notOwner = address(0xBEEF);
    address token = address(0x1234);

    function setUp() public {
        oracle = new MockPriceOracle(owner);
    }

    function test_OwnerCanSetAndGetPrice() public {
        oracle.setPrice(token, 2000e18);
        assertEq(oracle.getPrice(token), 2000e18);
    }

    function test_RevertWhen_NonOwnerSetsPrice() public {
        vm.prank(notOwner);
        vm.expectRevert();
        oracle.setPrice(token, 2000e18);
    }
}
