// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// borrow() doesn't exist until milestone 6 — this harness exposes a raw
// setter for principalDebt so the health factor formula can be tested in
// isolation, per PLAN.md milestone 5.
contract LendingPoolHarness is LendingPool {
    constructor(address initialOwner, address collateralToken_, address daiToken_, address oracle_)
        LendingPool(initialOwner, collateralToken_, daiToken_, oracle_)
    {}

    function setDebtForTesting(address user, uint256 amount) external {
        principalDebt[user] = amount;
        userBorrowIndex[user] = borrowIndex;
    }
}

contract HealthFactorTest is Test {
    LendingPoolHarness pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPoolHarness(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        weth.mint(alice, 100e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);
    }

    function test_ZeroDebtIsInfiniteHealthFactor() public {
        vm.prank(alice);
        pool.depositCollateral(10e18);

        assertEq(pool.healthFactor(alice), type(uint256).max);
    }
    
    function test_HealthFactorAtExactThreshold() public {
        // 10 mWETH @ $2000 = $20,000 collateral; 80% threshold = $16,000.
        // Debt of $16,000 mDAI puts health factor at exactly 1e18.
        vm.prank(alice);
        pool.depositCollateral(10e18);
        pool.setDebtForTesting(alice, 16_000e18);

        assertEq(pool.healthFactor(alice), 1e18);
    }

    function test_HealthFactorBelowOneWithNonRoundCollateral() public {
        vm.prank(alice);
        pool.depositCollateral(9.93e18);
        pool.setDebtForTesting(alice, 16_000e18);

        assertEq(pool.healthFactor(alice), 0.993e18);
    }

    function test_HealthFactorAboveOne() public {
        // 10 mWETH @ $2000 = $20,000 collateral; 80% threshold = $16,000.
        // Debt of $8,000 -> health factor = 16,000 / 8,000 = 2.0
        vm.prank(alice);
        pool.depositCollateral(10e18);
        pool.setDebtForTesting(alice, 8_000e18);

        assertEq(pool.healthFactor(alice), 2e18);
    }

    function test_HealthFactorBelowOne() public {
        // 10 mWETH @ $2000 = $20,000 collateral; 80% threshold = $16,000.
        // Debt of $20,000 -> health factor = 16,000 / 20,000 = 0.8
        vm.prank(alice);
        pool.depositCollateral(10e18);
        pool.setDebtForTesting(alice, 20_000e18);

        assertEq(pool.healthFactor(alice), 0.8e18);
    }

    function test_HealthFactorMovesWithPrice() public {
        vm.prank(alice);
        pool.depositCollateral(10e18);
        pool.setDebtForTesting(alice, 8_000e18);

        assertEq(pool.healthFactor(alice), 2e18);

        // Crash the collateral price by half -> health factor halves too.
        oracle.setPrice(address(weth), 1000e18);
        assertEq(pool.healthFactor(alice), 1e18);

        // Double the original price -> health factor doubles from baseline.
        oracle.setPrice(address(weth), 4000e18);
        assertEq(pool.healthFactor(alice), 4e18);
    }

    function test_HealthFactorTruncatesOnIndivisibleRatio() public {
        // 1 mWETH @ $1 = $1 collateral; 80% threshold = $0.80.
        // Debt of 3 wei mDAI @ $1 -> exact ratio is 0.8/3 = 0.2666...,
        // which has no exact 1e18 fixed-point representation. Solidity
        // integer division truncates (rounds toward zero), so the result
        // is the floor of the true ratio, not the ratio itself.
        vm.prank(alice);
        pool.depositCollateral(1e18);
        oracle.setPrice(address(weth), 1e18);
        pool.setDebtForTesting(alice, 3);

        uint256 hf = pool.healthFactor(alice);

        // Exact floor of (1e18 * 8000 * 1e18) / (10000 * 3), computed
        // independently to confirm the contract truncates rather than
        // rounding, and that truncation rounds DOWN (the safe direction —
        // it never reports a position healthier than it actually is).
        assertEq(hf, 266666666666666666666666666666666666);
        assertLt(hf * 3, 1e18 * 8000 * 1e18 / 10000);
    }

    function test_RevertWhen_HealthFactorNumeratorOverflows() public {
        // Push collateralValueUSD high enough that the later
        // `collateralValueUSD * liquidationThreshold * 1e18` step in
        // healthFactor() exceeds type(uint256).max, even though the
        // collateralValueUSD computation itself does not overflow.
        // Solidity 0.8's checked arithmetic must revert (Panic 0x11),
        // not silently wrap.
        uint256 hugeCollateral = 1e59;
        weth.mint(alice, hugeCollateral);

        vm.startPrank(alice);
        pool.depositCollateral(hugeCollateral);
        vm.stopPrank();

        oracle.setPrice(address(weth), 1e18);
        pool.setDebtForTesting(alice, 1e18);

        vm.expectRevert(stdError.arithmeticError);
        pool.healthFactor(alice);
    }

    function test_RevertWhen_DaiPriceIsZero() public {
        // Debt is nonzero but the DAI price was never set (defaults to 0
        // in MockPriceOracle), so debtValueUSD's division would divide by
        // an oracle-driven 0. healthFactor() must revert explicitly here
        // rather than let debtValueUSD truncate to 0 and panic later, or
        // silently treat an unpriced asset as safe.
        vm.prank(alice);
        pool.depositCollateral(10e18);
        pool.setDebtForTesting(alice, 8_000e18);

        oracle.setPrice(address(dai), 0);

        vm.expectRevert("LendingPool: Invalid DAI price");
        pool.healthFactor(alice);
    }
}
