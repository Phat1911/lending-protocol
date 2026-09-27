// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @notice Triggers the existing pool accrual path without repaying debt.
///         LendingPool.repay(0) accrues interest and settles debt, then caps
///         the transfer amount to zero.
contract ExplorationTimestampTrigger is Script {
    function run(address poolAddress) external {
        LendingPool pool = LendingPool(poolAddress);

        vm.startBroadcast();
        pool.repay(0);
        vm.stopBroadcast();

        console.log("Debt after zero-repay accrual:", pool.principalDebt(msg.sender));
        console.log("Borrow index:", pool.borrowIndex());
        console.log("Last accrual timestamp:", pool.lastAccrualTimestamp());
    }
}
