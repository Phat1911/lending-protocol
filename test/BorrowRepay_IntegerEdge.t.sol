// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Zero-value and boundary/maximum-value probes for borrow()/repay(), per
// milestone 6 (PLAN.md). Focused on the division/multiplication sites in
// the LTV check and healthFactor(): borrow(0), repay(0), repay with zero
// debt, zero-collateral borrows, the exact 75% LTV boundary (+/- 1 wei),
// and a self-minted-collateral overflow scenario that is known/accepted
// out-of-scope behavior (see CLAUDE.md — MockWETH's public mint() is
// intentionally unrestricted for this learning project).
contract BorrowRepayIntegerEdgeTest is Test {
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

        // Alice: borrower, holds collateral.
        weth.mint(alice, 1_000e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        dai.approve(address(pool), type(uint256).max);

        // Bob: supplies mDAI liquidity so borrow() has something to pull from.
        dai.mint(bob, 1_000_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(1_000_000e18);
        vm.stopPrank();
    }

    function test_RevertWhen_BorrowZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        pool.borrow(0);
    }

    function test_RepayZeroWhenNoDebtIsNoOp() public {
        // No debt, repay(0): cappedAmount = min(0, 0) = 0. Should not
        // revert, should not move any tokens, and debt stays at 0.
        uint256 aliceDaiBefore = dai.balanceOf(alice);
        uint256 poolDaiBefore = dai.balanceOf(address(pool));

        vm.prank(alice);
        pool.repay(0);

        assertEq(pool.principalDebt(alice), 0);
        assertEq(dai.balanceOf(alice), aliceDaiBefore);
        assertEq(dai.balanceOf(address(pool)), poolDaiBefore);
    }

    function test_RepayWithZeroDebtDoesNotPullTokensEvenWithPositiveAmount() public {
        // Alice has zero debt but calls repay() with a large positive
        // amount. cappedAmount = min(amount, 0) = 0, so safeTransferFrom
        // must pull exactly 0 tokens — it must NOT revert (even though
        // alice holds no mDAI at all here) and must NOT attempt to pull
        // `amount`.
        assertEq(dai.balanceOf(alice), 0);
        assertEq(pool.principalDebt(alice), 0);

        vm.prank(alice);
        pool.repay(500e18);

        assertEq(pool.principalDebt(alice), 0);
        assertEq(dai.balanceOf(alice), 0);
        assertEq(dai.balanceOf(address(pool)), 1_000_000e18);
    }

    function test_RevertWhen_BorrowWithZeroCollateral() public {
        // Alice never deposited collateral: collateralValueUSD = 0, so the
        // LTV check `0 >= debtValueUSD * 10000` fails for any amount > 0.
        assertEq(pool.collateralBalance(alice), 0);

        vm.prank(alice);
        vm.expectRevert("exceeds LTV");
        pool.borrow(1e18);
    }

    function test_BorrowAtExactLTVBoundarySucceeds() public {
        // 10 mWETH @ $2000 = $20,000 collateral; 75% LTV -> max borrow is
        // exactly $15,000 of mDAI (price $1). At the boundary:
        // collateralValueUSD * ltv == debtValueUSD * BPS_DENOMINATOR
        // (20,000e18 * 7500 == 15,000e18 * 10000), so the `>=` check must
        // pass exactly.
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(15_000e18);
        vm.stopPrank();

        assertEq(pool.principalDebt(alice), 15_000e18);
        assertEq(dai.balanceOf(alice), 15_000e18);
    }

    function test_RevertWhen_BorrowOneWeiOverLTVBoundary() public {
        // Same setup as above, but borrowing 1 wei past the exact boundary
        // must revert on the LTV check, per PLAN.md's explicit milestone 6
        // test plan ("borrow up to LTV succeeds, one wei over reverts").
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        vm.expectRevert("exceeds LTV");
        pool.borrow(15_000e18 + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_HugeSelfMintedCollateralOverflowsHealthFactorDuringBorrow() public {
        // KNOWN/ACCEPTED OUT-OF-SCOPE BEHAVIOR (see CLAUDE.md + user
        // memory on milestone 8 liquidation overflow griefing): because
        // MockWETH.mint() is public and unrestricted, a user can self-mint
        // an absurd collateral balance that overflows the checked
        // arithmetic inside healthFactor()'s
        // `collateralValueUSD * liquidationThreshold * 1e18` step, even
        // though the LTV check earlier in borrow() does not itself
        // overflow. This test documents that borrow() reverts with a raw
        // Panic(0x11) (arithmetic overflow) in that scenario, rather than
        // silently wrapping or mispricing the position. This is NOT a bug
        // to fix here — no defensive overflow guard should be added.
        uint256 hugeCollateral = 1e59;
        weth.mint(alice, hugeCollateral);

        vm.startPrank(alice);
        pool.depositCollateral(hugeCollateral);

        // LTV check itself is fine here: collateralValueUSD * ltv
        // (1e59 * 7500 = 7.5e62) comfortably fits in uint256, and the
        // requested debt is tiny relative to the (absurd) collateral.
        vm.expectRevert(stdError.arithmeticError);
        pool.borrow(1e18);
        vm.stopPrank();

        // Confirm the whole call reverted, not just the healthFactor read:
        // no debt should have been recorded.
        assertEq(pool.principalDebt(alice), 0);
    }
}
