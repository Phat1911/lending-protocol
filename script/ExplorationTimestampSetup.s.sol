// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @notice Creates a fresh debt position for the real-time accrual experiment.
///         It deliberately reuses the deployed production contracts unchanged.
contract ExplorationTimestampSetup is Script {
    uint256 private constant WETH_AMOUNT = 1e18;
    uint256 private constant SUPPLY_AMOUNT = 1_000e18;
    uint256 private constant BORROW_AMOUNT = 500e18;
    uint256 private constant REPAY_BUFFER = 510e18;

    function run(address poolAddress, address wethAddress, address daiAddress) external {
        LendingPool pool = LendingPool(poolAddress);
        MockWETH weth = MockWETH(wethAddress);
        MockDAI dai = MockDAI(daiAddress);
        address actor = msg.sender;

        vm.startBroadcast();

        // These unrestricted mints are testnet funding through the existing
        // mock-token interfaces, not a replacement for lending logic.
        weth.mint(actor, WETH_AMOUNT);
        dai.mint(actor, SUPPLY_AMOUNT + REPAY_BUFFER);

        IERC20(address(weth)).approve(address(pool), WETH_AMOUNT);
        IERC20(address(dai)).approve(address(pool), SUPPLY_AMOUNT);
        pool.supply(SUPPLY_AMOUNT);
        pool.depositCollateral(WETH_AMOUNT);
        pool.borrow(BORROW_AMOUNT);

        vm.stopBroadcast();

        console.log("Timestamp experiment actor:", actor);
        console.log("Debt after setup:", pool.principalDebt(actor));
        console.log("Last accrual timestamp:", pool.lastAccrualTimestamp());
    }
}
