// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 6: borrow()/repay() and the healthFactor()-gated withdrawCollateral()
// all read live oracle prices at call time (no cache). These tests move the
// oracle price *between* transactions (vm.prank/oracle.setPrice are separate
// top-level calls, never mid-transaction) and check that every call keeps
// reading the *current* price rather than a stale one.
contract BorrowRepayOraclePriceTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address lp = address(0x1717);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address charlie = address(0xC4A211E);
    address dave = address(0xDA5E);
    address erin = address(0xE81);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        // Liquidity so borrow() can actually transfer mDAI out.
        dai.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(1_000_000e18);
        vm.stopPrank();

        address[5] memory users = [alice, bob, charlie, dave, erin];
        for (uint256 i = 0; i < users.length; i++) {
            weth.mint(users[i], 100e18);
            vm.prank(users[i]);
            weth.approve(address(pool), type(uint256).max);
            vm.prank(users[i]);
            dai.approve(address(pool), type(uint256).max);
        }
    }

    // 1. A borrow that was valid becomes impossible once the collateral price
    // crashes -- a later borrow call must be checked against the *current*
    // price, not the price at the time of the first borrow.
    function test_BorrowBecomesImpossibleAfterCollateralCrash() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18); // $20,000 collateral, well within 75% LTV.
        vm.stopPrank();

        // Collateral craters from $2000 -> $500.
        oracle.setPrice(address(weth), 500e18);

        // At the new price, 10 mWETH is worth $5,000; existing debt of
        // $14,000 already blows through 75% LTV, so any further borrow
        // must revert against the *live* price.
        vm.prank(alice);
        vm.expectRevert("exceeds LTV");
        pool.borrow(100e18);
    }

    // 2. A borrower whose health factor drops below 1e18 after a price crash
    // must be blocked from withdrawing collateral, even a tiny amount --
    // proving the gate re-reads price live rather than using a stale value
    // from borrow time.
    function test_WithdrawBlockedAfterCollateralCrashDropsHealthFactor() public {
        vm.startPrank(bob);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18); // HF = 16,000/14,000 ~= 1.1428e18 at $2000/mWETH.
        vm.stopPrank();

        oracle.setPrice(address(weth), 500e18);
        // collateralValueUSD = 5,000; threshold value = 4,000 < 14,000 debt
        // -> health factor now well below 1e18.
        assertLt(pool.healthFactor(bob), 1e18);

        vm.prank(bob);
        vm.expectRevert("unsafe position");
        pool.withdrawCollateral(1e15); // even a tiny withdrawal is blocked.
    }

    // 3. Conversely, a price *rise* after borrow should improve health factor
    // enough that a withdrawal which would have failed at the old price now
    // succeeds -- proving the gate is live, not just conservative/broken.
    function test_WithdrawSucceedsAfterCollateralPriceRise() public {
        vm.startPrank(charlie);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18);
        vm.stopPrank();

        // At $2000/mWETH: withdrawing 3 mWETH leaves 7 mWETH ($14,000),
        // 80% threshold = $11,200 < $14,000 debt -> unsafe, must revert.
        vm.prank(charlie);
        vm.expectRevert("unsafe position");
        pool.withdrawCollateral(3e18);

        // Collateral price doubles: $2000 -> $4000.
        oracle.setPrice(address(weth), 4000e18);

        // Same withdrawal, now against the live (higher) price: 7 mWETH is
        // worth $28,000, 80% threshold = $22,400 >= $14,000 debt -> safe.
        vm.prank(charlie);
        pool.withdrawCollateral(3e18);

        assertEq(pool.collateralBalance(charlie), 7e18);
        assertGe(pool.healthFactor(charlie), 1e18);
    }

    // 4. repay() operates on principalDebt (an mDAI-denominated quantity),
    // never touching the oracle. A crashed mDAI price must not change how
    // much debt a fixed mDAI repayment amount clears.
    function test_RepayDebtReductionIsPriceIndependent() public {
        vm.startPrank(dave);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();

        assertEq(pool.principalDebt(dave), 5_000e18);

        // Crash the mDAI price to a tiny value. repay() never calls
        // oracle.getPrice(), so this must have zero effect on the debt math.
        oracle.setPrice(address(dai), 1);

        uint256 poolDaiBefore = dai.balanceOf(address(pool));
        uint256 daveDaiBefore = dai.balanceOf(dave);

        vm.prank(dave);
        pool.repay(2_000e18);

        // Same principalDebt reduction (exactly the mDAI amount repaid) that
        // would occur at any other price.
        assertEq(pool.principalDebt(dave), 3_000e18);
        assertEq(pool.totalDaiBorrowed(), 3_000e18);
        assertEq(dai.balanceOf(address(pool)), poolDaiBefore + 2_000e18);
        assertEq(dai.balanceOf(dave), daveDaiBefore - 2_000e18);
    }

    // 5. Zero-price edge case: once mDAI's price is set to 0, both borrow()
    // and withdrawCollateral() route through healthFactor() (once the user
    // has nonzero debt) and must revert on its explicit
    // "LendingPool: Invalid DAI price" guard rather than dividing by zero or
    // silently treating the position as safe.
    function test_RevertWhen_DaiPriceIsZero_BorrowAndWithdraw() public {
        vm.startPrank(erin);
        pool.depositCollateral(10e18);
        pool.borrow(1_000e18); // valid at the normal $1 mDAI price.
        vm.stopPrank();

        oracle.setPrice(address(dai), 0);

        // borrow(): principalDebt is already nonzero from the first borrow,
        // so the healthFactor() call inside borrow() hits the zero-price
        // guard.
        vm.prank(erin);
        vm.expectRevert("LendingPool: Invalid DAI price");
        pool.borrow(1e18);

        // withdrawCollateral(): same guard, same reason -- debt is nonzero
        // so healthFactor() must revert rather than let debtValueUSD
        // truncate to 0 and treat the position as trivially safe.
        vm.prank(erin);
        vm.expectRevert("LendingPool: Invalid DAI price");
        pool.withdrawCollateral(1e18);
    }
}
