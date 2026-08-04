// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";

contract Deploy is Script {
    uint256 constant INITIAL_WETH_PRICE = 2000e18;
    uint256 constant INITIAL_DAI_PRICE = 1e18;

    function run() external {
        vm.startBroadcast();

        MockWETH weth = new MockWETH();
        MockDAI dai = new MockDAI();
        MockPriceOracle oracle = new MockPriceOracle(msg.sender);

        oracle.setPrice(address(weth), INITIAL_WETH_PRICE);
        oracle.setPrice(address(dai), INITIAL_DAI_PRICE);

        LendingPool pool = new LendingPool(msg.sender, address(weth), address(dai), address(oracle));

        vm.stopBroadcast();

        console.log("MockWETH:", address(weth));
        console.log("MockDAI:", address(dai));
        console.log("MockPriceOracle:", address(oracle));
        console.log("LendingPool:", address(pool));
    }
}
