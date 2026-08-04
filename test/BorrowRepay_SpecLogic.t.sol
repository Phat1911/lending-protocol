// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 6 spec-correctness checks: borrow/repay/withdraw gating against
// PLAN.md's milestone 6 test list and SPEC.md §4/§8. Not covering generic
// vulnerability classes (reentrancy/overflow/rounding/oracle timing) — those
// are owned by other parallel test files for this milestone.
contract BorrowRepaySpecLogicTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        weth.mint(alice, 100e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        dai.approve(address(pool), type(uint256).max);

        dai.mint(bob, 1_000_000e18);
        vm.prank(bob);
        dai.approve(address(pool), type(uint256).max);
    }

    // 1. Borrow up to exactly 75% LTV succeeds; one wei of debt over reverts.
    function test_BorrowUpToExactLTVSucceeds_OneWeiOverReverts() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);

        // 10 mWETH @ $2000 = $20,000 collateral; 75% LTV = $15,000 max debt.
        // dai price is 1e18 so debtValueUSD == debt amount exactly (no
        // truncation), making this an exact integer boundary.
        pool.borrow(15_000e18);
        assertEq(pool.principalDebt(alice), 15_000e18);
        assertEq(dai.balanceOf(alice), 15_000e18);

        // One more wei of debt pushes debtValueUSD*10000 past
        // collateralValueUSD*ltv by exactly 10000 (see require in borrow()).
        vm.expectRevert("exceeds LTV");
        pool.borrow(1);
        vm.stopPrank();
    }

    // 2. repay reduces principalDebt correctly; overpay is capped, not reverted.
    function test_RepayReducesDebtAndCapsOverpayment() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);

        pool.repay(2_000e18);
        assertEq(pool.principalDebt(alice), 3_000e18);

        // Alice holds exactly 3,000e18 mDAI left (5,000 borrowed - 2,000
        // repaid). Overpaying with type(uint256).max must succeed, cap the
        // actual pull at the remaining 3,000e18 debt, and zero the debt —
        // not revert with leftover debt.
        assertEq(dai.balanceOf(alice), 3_000e18);
        pool.repay(type(uint256).max);
        vm.stopPrank();

        assertEq(pool.principalDebt(alice), 0);
        assertEq(pool.totalDaiBorrowed(), 0);
        assertEq(dai.balanceOf(alice), 0);
    }

    // 3. withdrawCollateral: blocked past the health-factor boundary, allowed at/above it.
    function test_WithdrawCollateralAllowedAtHealthFactorBoundary() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(12_000e18);

        // debtValueUSD = 12,000e18; liquidationThreshold = 80%, so the
        // minimum collateralValueUSD to keep HF >= 1e18 is
        // 12,000e18 * 10000 / 8000 = 15,000e18 -> 7.5 mWETH @ $2000.
        // Withdrawing 2.5e18 leaves exactly 7.5e18, HF == 1e18 exactly.
        pool.withdrawCollateral(2.5e18);
        vm.stopPrank();

        assertEq(pool.collateralBalance(alice), 7.5e18);
        assertEq(pool.healthFactor(alice), 1e18);
    }

    function test_RevertWhen_WithdrawCollateralBreachesHealthFactor() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(12_000e18);

        // One wei past the 7.5e18 boundary computed above drops HF just
        // below 1e18 (each wei of collateral is worth 2000 wei of USD value
        // at this price, so removing 1 extra wei removes 2000 wei of value).
        vm.expectRevert("unsafe position");
        pool.withdrawCollateral(2.5e18 + 1);
        vm.stopPrank();
    }

    // 4. withdrawSupply is blocked when liquidity is currently borrowed out.
    function test_RevertWhen_WithdrawSupplyExceedsUnborrowedLiquidity() public {
        vm.prank(bob);
        pool.supply(10_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(5_000e18);
        vm.stopPrank();

        // Unborrowed liquidity = 10,000e18 - 5,000e18 = 5,000e18.
        vm.startPrank(bob);
        vm.expectRevert("insufficient liquidity");
        pool.withdrawSupply(5_000e18 + 1);

        // Exactly the available amount must still succeed.
        pool.withdrawSupply(5_000e18);
        vm.stopPrank();

        assertEq(pool.suppliedBalance(bob), 5_000e18);
    }

    // 5. borrow's LTV check must use `ltv` (75%), not `liquidationThreshold` (80%).
    function test_RevertWhen_BorrowUsesLTVNotLiquidationThreshold() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);

        // 10 mWETH @ $2000 = $20,000 collateral.
        // Valid at 80% (liquidationThreshold): max debt $16,000.
        // Invalid at 75% (ltv, the correct borrow-time limit): max debt $15,000.
        // 15,500 sits strictly between the two -> must revert if `ltv` is
        // used correctly, would wrongly succeed if `liquidationThreshold`
        // were used instead.
        vm.expectRevert("exceeds LTV");
        pool.borrow(15_500e18);
        vm.stopPrank();
    }

    // 6. Regression: zero-debt borrower's healthFactor is still the infinite sentinel.
    function test_ZeroDebtHealthFactorStillMaxAfterMilestone6() public {
        vm.prank(alice);
        pool.depositCollateral(10e18);

        assertEq(pool.healthFactor(alice), type(uint256).max);
    }

    // 7. borrow() must independently enforce pool-level liquidity, distinct
    // from the borrower's own LTV limit. Alice's collateral gives her ample
    // LTV headroom ($150,000 max debt), but the pool has only ever had
    // 1,000e18 mDAI supplied -- borrowing past that must revert on the pool
    // liquidity check, not silently succeed or get misattributed to LTV.
    function test_RevertWhen_BorrowExceedsPoolLiquidityDespiteAmpleLTVHeadroom() public {
        vm.prank(bob);
        pool.supply(1_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(100e18); // $200,000 collateral; 75% LTV = $150,000 max debt.

        vm.expectRevert("insufficient pool liquidity");
        pool.borrow(1_000e18 + 1);

        // Exactly the pool's total supplied liquidity is still borrowable.
        pool.borrow(1_000e18);
        vm.stopPrank();

        assertEq(pool.principalDebt(alice), 1_000e18);
        assertEq(pool.totalDaiBorrowed(), 1_000e18);
    }
}
