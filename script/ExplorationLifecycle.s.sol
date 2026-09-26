// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @notice Executes one complete lifecycle against the already deployed
///         exploration contracts. The production contracts are not modified.
contract ExplorationLifecycle is Script {
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

        // The mock tokens are intentionally used only to fund the testnet
        // lifecycle. No production lending logic is recreated here.
        weth.mint(actor, WETH_AMOUNT);
        // Fund both sides of the lifecycle: the 1,000 mDAI supplier deposit
        // and a separate 510 mDAI balance to cover the borrower's repayment.
        dai.mint(actor, SUPPLY_AMOUNT + REPAY_ALLOWANCE);

        IERC20(address(weth)).approve(address(pool), WETH_AMOUNT);
        IERC20(address(dai)).approve(address(pool), SUPPLY_AMOUNT);
        pool.supply(SUPPLY_AMOUNT);
        pool.depositCollateral(WETH_AMOUNT);
        pool.borrow(BORROW_AMOUNT);

        // Allow enough mDAI for interest, if the testnet advances timestamps
        // between borrow and repay. repay() caps the amount at live debt.
        IERC20(address(dai)).approve(address(pool), REPAY_ALLOWANCE);
        pool.repay(REPAY_ALLOWANCE);

        vm.stopBroadcast();

        console.log("Lifecycle actor:", actor);
        console.log("LendingPool:", address(pool));
        console.log("Final principal debt:", pool.principalDebt(actor));
        console.log("Final total borrowed:", pool.totalDaiBorrowed());
    }
}
