// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @notice Sets up the lifecycle position and deliberately stops before repay.
/// The Base Sepolia wrapper submits approval and repay as separate transactions
/// because batched Forge execution can produce ReentrancySentryOOG here.
contract ExplorationLifecycleSetup is Script {
    uint256 private constant WETH_AMOUNT = 1e18;
    uint256 private constant SUPPLY_AMOUNT = 1000e18;
    uint256 private constant BORROW_AMOUNT = 500e18;
    uint256 private constant REPAY_ALLOWANCE = 510e18;

    function run(address poolAddress, address wethAddress, address daiAddress) external {
        LendingPool pool = LendingPool(poolAddress);
        MockWETH weth = MockWETH(wethAddress);
        MockDAI dai = MockDAI(daiAddress);
        address actor = msg.sender;

        vm.startBroadcast();
        weth.mint(actor, WETH_AMOUNT);
        dai.mint(actor, SUPPLY_AMOUNT + REPAY_ALLOWANCE);
        IERC20(address(weth)).approve(address(pool), WETH_AMOUNT);
        IERC20(address(dai)).approve(address(pool), SUPPLY_AMOUNT);
        pool.supply(SUPPLY_AMOUNT);
        pool.depositCollateral(WETH_AMOUNT);
        pool.borrow(BORROW_AMOUNT);
        IERC20(address(dai)).approve(address(pool), REPAY_ALLOWANCE);
        vm.stopBroadcast();
    }
}
