// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @notice Fresh deployment entry point for the L1/L2 exploration harness.
/// @dev The production contracts are reused unchanged. Receipt and fee
///      metadata is collected by the surrounding PowerShell wrapper from the
///      broadcast file and RPC receipts.
contract ExplorationDeploy is Script {
    uint256 private constant INITIAL_WETH_PRICE = 2000e18;
    uint256 private constant INITIAL_DAI_PRICE = 1e18;

    function run() external {
        vm.startBroadcast();

        address deployer = msg.sender;
        MockWETH weth = new MockWETH();
        MockDAI dai = new MockDAI();
        MockPriceOracle oracle = new MockPriceOracle(deployer);

        oracle.setPrice(address(weth), INITIAL_WETH_PRICE);
        oracle.setPrice(address(dai), INITIAL_DAI_PRICE);

        LendingPool pool = new LendingPool(deployer, address(weth), address(dai), address(oracle));

        vm.stopBroadcast();

        console.log("Exploration deployment chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("MockWETH:", address(weth));
        console.log("MockDAI:", address(dai));
        console.log("MockPriceOracle:", address(oracle));
        console.log("LendingPool:", address(pool));
    }
}
