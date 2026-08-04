// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 8's liquidate() reads oracle.getPrice() three times in one call:
// once indirectly via healthFactor(borrower) (the eligibility gate) and twice
// directly for the seize-amount payout math (daiPrice, collateralPrice).
// MockPriceOracle is an intentionally-unrealistic, owner-settable price feed
// with no staleness/manipulation resistance (SPEC.md §3/§10) -- that is a
// deliberate design choice, not a bug to fix here. What these tests check is
// narrower: given whatever price the owner has set, does liquidate() (a)
// read it live rather than a cached/stale value, (b) use one internally
// consistent price snapshot across the eligibility check and the payout
// calc within a single call (there's no reentrancy/callback vector on a
// plain view function, so this is really about the two separate
// oracle.getPrice() calls in liquidate() agreeing with the one inside
// healthFactor()), and (c) correctly reflect a brand new price the instant
// after oracle.setPrice() runs, with no memory of a prior "was liquidatable
// at some point" state.
contract LiquidationOraclePriceTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address lp = address(0x1717);
    address liquidator = address(0x11C4);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address charlie = address(0xC4A211E);
    address dave = address(0xDA5E);
    address erin = address(0xE81);
    address frank = address(0xF6A);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        // Liquidity so borrow() can transfer mDAI out.
        dai.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(1_000_000e18);
        vm.stopPrank();

        address[6] memory users = [alice, bob, charlie, dave, erin, frank];
        for (uint256 i = 0; i < users.length; i++) {
            weth.mint(users[i], 100e18);
            vm.prank(users[i]);
            weth.approve(address(pool), type(uint256).max);
        }

        // Liquidator needs mDAI on hand to repay borrowers' debt in exchange
        // for seized collateral.
        dai.mint(liquidator, 1_000_000e18);
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    // 1. A position that is healthy at the current mWETH price must reject
    // liquidation; the *same* position, after the owner crashes the price,
    // must accept it. Since MockPriceOracle.getPrice() is a plain storage
    // read with no caching, this also proves liquidate() isn't holding onto
    // a price snapshot from an earlier call.
    function test_RevertsBeforeCrash_SucceedsAfterCrash_LivePriceNotCached() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18); // $20,000 collateral @ $2000; HF ~= 1.1428e18, healthy.
        vm.stopPrank();

        assertGe(pool.healthFactor(alice), 1e18);
        vm.prank(liquidator);
        vm.expectRevert("position is healthy");
        pool.liquidate(alice);

        // Collateral craters $2000 -> $1600 (20% drop).
        oracle.setPrice(address(weth), 1600e18);

        // collateralValueUSD = $16,000; 80% threshold = $12,800 < $14,000
        // debt -> unsafe.
        assertLt(pool.healthFactor(alice), 1e18);

        vm.prank(liquidator);
        pool.liquidate(alice);

        assertEq(pool.principalDebt(alice), 0);
    }

    // 2. The seize amount liquidate() actually pays out after a collateral
    // crash must match a hand-computed value using the NEW (post-crash)
    // collateralPrice -- proving the payout math isn't accidentally using a
    // stale pre-crash price even though healthFactor() (the eligibility
    // check) and the seize calc are two separate oracle reads within the
    // same call.
    function test_SeizeAmountReflectsPostCrashCollateralPrice() public {
        vm.startPrank(bob);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18); // same setup as above: healthy at $2000/mWETH.
        vm.stopPrank();

        oracle.setPrice(address(weth), 1600e18);
        assertLt(pool.healthFactor(bob), 1e18);

        // Hand computation at the POST-crash price ($1600/mWETH, $1/mDAI):
        //   repaidDebtValueUSD = 14,000 * 1        = 14,000
        //   seizeValueUSD      = 14,000 * 1.10     = 15,400
        //   seizeAmount        = 15,400 / 1,600    = 9.625 mWETH
        // (not capped: 9.625e18 < bob's 10e18 collateral balance)
        uint256 expectedSeizeAmount = 9_625_000_000_000_000_000; // 9.625e18

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        uint256 bobCollateralBefore = pool.collateralBalance(bob);

        vm.prank(liquidator);
        pool.liquidate(bob);

        assertEq(weth.balanceOf(liquidator) - liquidatorWethBefore, expectedSeizeAmount);
        assertEq(bobCollateralBefore - pool.collateralBalance(bob), expectedSeizeAmount);
        assertEq(pool.collateralBalance(bob), 10e18 - expectedSeizeAmount);
    }

    // 3. A position dips underwater after a crash, but the owner moves the
    // price back up before anyone calls liquidate(). liquidate() must
    // re-evaluate health factor fresh at call time and revert -- there is
    // no persisted "this address was liquidatable at block N" flag lying
    // around from the unhealthy window.
    function test_PriceRecoveryBeforeLiquidation_RevertsAgain() public {
        vm.startPrank(charlie);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18); // healthy at $2000/mWETH.
        vm.stopPrank();

        oracle.setPrice(address(weth), 1600e18);
        assertLt(pool.healthFactor(charlie), 1e18); // now liquidatable...

        // ...but nobody calls liquidate() during the dip. Price recovers,
        // even past the original level, before any liquidation happens.
        oracle.setPrice(address(weth), 2500e18);
        assertGe(pool.healthFactor(charlie), 1e18);

        vm.prank(liquidator);
        vm.expectRevert("position is healthy");
        pool.liquidate(charlie);

        // Debt and collateral are untouched -- no partial/ghost liquidation
        // occurred during the brief unhealthy window.
        assertEq(pool.principalDebt(charlie), 14_000e18);
        assertEq(pool.collateralBalance(charlie), 10e18);
    }

    // 4a. A collateral-price crash alone (mDAI held at peg) must be able to
    // drive a position underwater and trigger a successful liquidation.
    function test_LiquidationTriggeredByCollateralPriceCrash() public {
        vm.startPrank(dave);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18);
        vm.stopPrank();

        oracle.setPrice(address(weth), 1600e18); // mDAI stays at $1.
        assertLt(pool.healthFactor(dave), 1e18);

        vm.prank(liquidator);
        pool.liquidate(dave);

        assertEq(pool.principalDebt(dave), 0);
    }

    // 4b. Conversely, holding mWETH's price fixed and depegging mDAI
    // *upward* (debt becomes worth more in USD terms) must independently be
    // able to drive the same kind of position underwater, since
    // healthFactor() depends on both prices.
    function test_LiquidationTriggeredByDaiPriceDepeg() public {
        vm.startPrank(erin);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18); // healthy: $20,000 collateral vs $14,000 debt @ $1 mDAI.
        vm.stopPrank();

        assertGe(pool.healthFactor(erin), 1e18);

        // mDAI depegs upward: $1.00 -> $1.20. mWETH price is untouched.
        oracle.setPrice(address(dai), 1.2e18);

        // debtValueUSD = 14,000 * 1.2 = $16,800; 80% threshold on $20,000
        // collateral = $16,000 < $16,800 -> unsafe.
        assertLt(pool.healthFactor(erin), 1e18);

        // Hand computation at ($1.20 mDAI, $2000 mWETH):
        //   repaidDebtValueUSD = 14,000 * 1.2      = 16,800
        //   seizeValueUSD      = 16,800 * 1.10     = 18,480
        //   seizeAmount        = 18,480 / 2,000    = 9.24 mWETH
        uint256 expectedSeizeAmount = 9_240_000_000_000_000_000; // 9.24e18

        vm.prank(liquidator);
        pool.liquidate(erin);

        assertEq(pool.principalDebt(erin), 0);
        assertEq(pool.collateralBalance(erin), 10e18 - expectedSeizeAmount);
    }

    // 5. If the oracle price lands exactly on the boundary where health
    // factor is precisely 1e18, liquidate() must still revert -- matching
    // the ">= 1e18 is safe" invariant used by withdrawCollateral()/borrow()
    // elsewhere. Liquidation is only for health factor strictly below 1e18.
    function test_ExactBoundaryHealthFactor_RevertsNotLiquidatable() public {
        vm.startPrank(frank);
        pool.depositCollateral(10e18);
        pool.borrow(12_000e18); // within 75% LTV at $2000/mWETH (HF ~= 1.333e18).
        vm.stopPrank();

        // Move mWETH to a price where collateralValueUSD * 80% == debt
        // exactly: 10 mWETH * $1500 = $15,000; 80% of that = $12,000 = debt.
        oracle.setPrice(address(weth), 1500e18);

        assertEq(pool.healthFactor(frank), 1e18);

        vm.prank(liquidator);
        vm.expectRevert("position is healthy");
        pool.liquidate(frank);

        assertEq(pool.principalDebt(frank), 12_000e18);
        assertEq(pool.collateralBalance(frank), 10e18);
    }

    // 6. liquidate() has its own daiPrice/collateralPrice > 0 guard (line
    // 145) separate from healthFactor()'s own daiValue > 0 check. Only the
    // collateralPrice == 0 side is independently reachable through
    // liquidate(): a daiPrice of 0 would instead make healthFactor()
    // (called first, to check eligibility) revert on its own
    // "LendingPool: Invalid DAI price" guard before ever reaching this line
    // -- that path is already covered by HealthFactor.t.sol and
    // BorrowRepay_OraclePrice.t.sol. Crashing collateralPrice to exactly 0
    // is the one way to make healthFactor() itself return a low-but-valid
    // number (0, since collateralValueUSD becomes 0) so liquidate() clears
    // the eligibility check and reaches its own price guard, which must
    // then revert cleanly instead of dividing by zero in the seize-amount
    // math a few lines later.
    function test_RevertWhen_CollateralPriceIsZeroDuringLiquidate() public {
        address grace = address(0x6AACE);
        weth.mint(grace, 100e18);
        vm.startPrank(grace);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(10e18);
        pool.borrow(12_000e18); // healthy at $2000/mWETH.
        vm.stopPrank();

        oracle.setPrice(address(weth), 0);

        // collateralValueUSD = 0, debt > 0 -> healthFactor() returns 0
        // (definitely unsafe), clearing liquidate()'s eligibility check.
        assertEq(pool.healthFactor(grace), 0);

        vm.prank(liquidator);
        vm.expectRevert("LendingPool: invalid price");
        pool.liquidate(grace);

        // Untouched: the revert happened before any state mutation.
        assertEq(pool.principalDebt(grace), 12_000e18);
        assertEq(pool.collateralBalance(grace), 10e18);
    }
}
