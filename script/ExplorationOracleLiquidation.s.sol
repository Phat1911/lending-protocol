// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @notice Testnet-only actions for milestone 15. Production contracts are
/// reused unchanged; these scripts only call their existing interfaces.
contract ExplorationOracleLiquidationSetup is Script {
    function run(address poolAddress, address wethAddress, address daiAddress, uint256 supplyAmount,
        uint256 collateralAmount, uint256 borrowAmount) external {
        LendingPool pool = LendingPool(poolAddress);
        MockWETH weth = MockWETH(wethAddress);
        MockDAI dai = MockDAI(daiAddress);
        address borrower = msg.sender;

        vm.startBroadcast();
        weth.mint(borrower, collateralAmount);
        dai.mint(borrower, supplyAmount);
        IERC20(address(weth)).approve(address(pool), collateralAmount);
        IERC20(address(dai)).approve(address(pool), supplyAmount);
        pool.supply(supplyAmount);
        pool.depositCollateral(collateralAmount);
        pool.borrow(borrowAmount);
        vm.stopBroadcast();
        console.log("Oracle experiment borrower:", borrower);
    }
}

contract ExplorationOraclePriceChange is Script {
    function run(address oracleAddress, address wethAddress, uint256 newWethPrice) external {
        vm.startBroadcast();
        MockPriceOracle(oracleAddress).setPrice(wethAddress, newWethPrice);
        vm.stopBroadcast();
        console.log("New mock WETH price:", newWethPrice);
    }
}

contract ExplorationOracleLiquidation is Script {
    function run(address poolAddress, address daiAddress, address borrower, uint256 fundingAmount) external {
        LendingPool pool = LendingPool(poolAddress);
        MockDAI dai = MockDAI(daiAddress);
        address liquidator = msg.sender;

        vm.startBroadcast();
        dai.mint(liquidator, fundingAmount);
        IERC20(address(dai)).approve(address(pool), fundingAmount);
        pool.liquidate(borrower);
        vm.stopBroadcast();
        console.log("Liquidator:", liquidator);
    }
}
