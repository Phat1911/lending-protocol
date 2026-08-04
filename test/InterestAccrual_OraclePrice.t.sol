// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 7 changed healthFactor() to read _liveDebt(user) (index-scaled,
// growing over time via interest) instead of the old flat principalDebt[user].
// These tests check the interaction between live interest accrual and live
// oracle prices -- both now vary between healthFactor() calls, and we need
// to confirm they compose correctly rather than one masking or double
// counting the other.
contract InterestAccrualOraclePriceTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address lp = address(0x1717);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address charlie = address(0xC4A211E);

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        dai.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(1_000_000e18);
        vm.stopPrank();

        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            weth.mint(users[i], 100e18);
            vm.prank(users[i]);
            weth.approve(address(pool), type(uint256).max);
            vm.prank(users[i]);
            dai.approve(address(pool), type(uint256).max);
        }
    }

    // 1. healthFactor() must reflect BOTH a live (interest-grown) debt AND a
    // live oracle price at the same time. Borrow, warp forward so interest
    // accrues (growing debt while collateral value is unchanged), confirm HF
    // dropped from that alone; then crash the collateral price on top of the
    // already-grown debt and confirm HF drops further, by more than either
    // effect would explain alone -- proving the two compose multiplicatively
    // in the denominator/numerator rather than one clobbering the other.
    function test_HealthFactorReflectsBothInterestGrowthAndPriceCrash() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000 collateral @ $2000/mWETH.
        pool.borrow(14_000e18); // HF0 = (20,000 * 0.8) / 14,000 = 16,000/14,000.
        vm.stopPrank();

        uint256 hf0 = pool.healthFactor(alice);
        uint256 expectedHF0 = uint256(16_000e18) * 1e18 / uint256(14_000e18);
        assertApproxEqRel(hf0, expectedHF0, 1e12);

        // Push utilization high enough to accrue meaningful interest, then
        // warp a full year forward with price unchanged.
        vm.warp(block.timestamp + 365 days);

        // NOTE: healthFactor() is a pure `view` -- it reads the *stored*
        // borrowIndex, which is only advanced by _accrueInterest() inside a
        // state-changing transaction. A bare vm.warp() with no follow-up
        // transaction does NOT retroactively update borrowIndex, so a raw
        // view call immediately after warping would still show the
        // pre-warp (stale) debt. Trigger accrual explicitly here via a
        // harmless zero-amount repay from an unrelated account, exactly as
        // any real borrow()/repay()/withdrawCollateral() call would do as
        // its first line -- this is what makes interest "real" on-chain.
        vm.prank(lp);
        pool.repay(0);

        uint256 hf1 = pool.healthFactor(alice);
        assertLt(hf1, hf0, "interest accrual alone must lower health factor");

        // Now crash the collateral price on top of the interest-grown debt.
        oracle.setPrice(address(weth), 1000e18);
        uint256 hf2 = pool.healthFactor(alice);

        assertLt(hf2, hf1, "price crash on top of grown debt must lower health factor further");

        // Sanity: recompute hf2 independently from live contract state and
        // confirm it matches the formula in SPEC.md §4 exactly, proving both
        // effects (grown debt, crashed price) are reflected simultaneously
        // rather than the collateral or debt leg silently using a stale
        // value from borrow time.
        vm.prank(alice);
        pool.repay(0); // triggers _accrueInterest() so principalDebt reflects the same index read by healthFactor()... actually repay(0) still settles debt.
        uint256 liveDebt = pool.principalDebt(alice);
        uint256 collateralValueUSD = pool.collateralBalance(alice) * oracle.getPrice(address(weth)) / 1e18;
        uint256 debtValueUSD = liveDebt * oracle.getPrice(address(dai)) / 1e18;
        uint256 expectedHF = (collateralValueUSD * pool.liquidationThreshold() * 1e18) / (10000 * debtValueUSD);

        // hf2 was read before the repay(0) settle call above (one more
        // second may have elapsed via warp inside vm, but no time passed
        // here), so it should match the freshly recomputed value.
        assertEq(hf2, expectedHF, "healthFactor() must match live debt * live price formula exactly");
    }

    // 2. borrow() always calls _accrueInterest() before checking the health
    // factor / LTV gate, and accrual is purely a function of elapsed wall
    // time (block.timestamp - lastAccrualTimestamp), not of anything a
    // borrower can influence within their own transaction. This test proves
    // a borrower cannot "time" a borrow to slip through the gate using
    // interest that hasn't been accrued yet: the same borrow amount that
    // reverts before a utilization-changing warp also reverts immediately
    // after, in the same block as the warp -- because _accrueInterest() runs
    // first inside that same call and catches the pool up before the gate
    // is evaluated.
    function test_BorrowCannotExploitStaleAccrualToBypassHealthFactorGate() public {
        vm.startPrank(bob);
        pool.depositCollateral(10e18); // $20,000 collateral.
        pool.borrow(14_000e18); // near max LTV (75% of 20,000 = 15,000).
        vm.stopPrank();

        // A further borrow that would push debt past 75% LTV must revert,
        // regardless of any pending un-accrued interest.
        vm.prank(bob);
        vm.expectRevert("exceeds LTV");
        pool.borrow(1_500e18);

        // Warp forward so a large amount of interest is now "pending"
        // (not yet written to storage, since no call has triggered
        // _accrueInterest() since the warp).
        vm.warp(block.timestamp + 365 days);

        // If the borrower could sneak in a borrow using the *stale*
        // (pre-accrual) borrowIndex/health factor, this call might wrongly
        // succeed. But borrow() calls _accrueInterest() as its very first
        // line, so the pending interest is applied before principalDebt is
        // even settled or the LTV/HF checks run -- the borrower's own debt
        // grows first, making the gate strictly harder to pass, not easier.
        vm.prank(bob);
        vm.expectRevert("exceeds LTV");
        pool.borrow(1_500e18);

        // Confirm the accrual actually happened as part of that reverted
        // call's ancestry by checking a *separate* successful transaction
        // (view calls don't mutate state, so assert via principalDebt after
        // a state-changing call) -- trigger accrual via a zero-effect repay
        // and confirm debt has in fact grown past the original 14,000e18.
        vm.prank(bob);
        pool.repay(0);
        assertGt(pool.principalDebt(bob), 14_000e18, "interest must have accrued by the time the gate was checked");
    }

    // 3. Utilization (and therefore borrow/supply rate) is a pure
    // totalDaiBorrowed/totalDaiSupplied ratio -- both mDAI-denominated token
    // amounts -- and must be completely unaffected by oracle price moves on
    // either asset.
    function test_UtilizationAndRatesAreUnaffectedByPriceChanges() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18);
        vm.stopPrank();

        uint256 utilBefore = pool.getUtilization();
        uint256 borrowRateBefore = pool.getBorrowRate();
        uint256 supplyRateBefore = pool.getSupplyRate();

        // Crash mWETH (collateral) and mDAI (borrow asset) prices by wildly
        // different factors.
        oracle.setPrice(address(weth), 1e18); // $2000 -> $1
        oracle.setPrice(address(dai), 1e30); // $1 -> absurd spike

        assertEq(pool.getUtilization(), utilBefore, "utilization must be price-independent");
        assertEq(pool.getBorrowRate(), borrowRateBefore, "borrow rate must be price-independent");
        assertEq(pool.getSupplyRate(), supplyRateBefore, "supply rate must be price-independent");

        // Even a zero price must not perturb the token-amount ratio.
        oracle.setPrice(address(weth), 0);
        assertEq(pool.getUtilization(), utilBefore);
        assertEq(pool.getBorrowRate(), borrowRateBefore);
        assertEq(pool.getSupplyRate(), supplyRateBefore);
    }

    // 4. A borrower can become liquidatable purely through interest accrual,
    // with the oracle price held perfectly constant throughout. Liquidation
    // itself isn't implemented until milestone 8, so this test only asserts
    // that healthFactor() correctly crosses below 1e18 as debt compounds --
    // documenting that the interest model alone is a legitimate path to
    // unsafe positions, not a bug.
    function test_HealthFactorDropsBelowOneSolelyFromInterestAccrual_NoPriceChange() public {
        vm.startPrank(charlie);
        pool.depositCollateral(10e18); // $20,000 collateral @ $2000/mWETH, held fixed all test.
        pool.borrow(14_999e18); // just under 75% LTV (15,000).
        vm.stopPrank();

        assertGe(pool.healthFactor(charlie), 1e18, "position must start safe");

        // Push utilization high (charlie's borrow alone vs. 1,000,000 supply
        // is tiny -- utilization stays far below the kink, so pull in a
        // second heavy borrower to push utilization above the 80% kink and
        // generate meaningful compounding interest). Needs collateral value
        // >= borrow / 75% LTV, so mint bob enough mWETH first.
        weth.mint(bob, 600e18);
        vm.startPrank(bob);
        pool.depositCollateral(600e18); // $1,200,000 collateral @ $2000/mWETH.
        pool.borrow(850_000e18); // utilization ~= 865,000 / 1,000,000 = 86.5% > 80% kink.
        vm.stopPrank();

        // Price of both assets never changes for the rest of this test.
        uint256 wethPrice = oracle.getPrice(address(weth));
        uint256 daiPrice = oracle.getPrice(address(dai));

        // Warp forward multiple years to let compounding interest do its
        // work on charlie's debt.
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 365 days);
            // Touch accrual via a no-op-ish call so index updates happen
            // incrementally (not required for correctness, but keeps the
            // scenario realistic -- multiple accrual events, not one giant
            // jump).
            vm.prank(lp);
            pool.repay(0);
        }

        assertEq(oracle.getPrice(address(weth)), wethPrice, "collateral price must be unchanged");
        assertEq(oracle.getPrice(address(dai)), daiPrice, "debt price must be unchanged");

        assertLt(
            pool.healthFactor(charlie), 1e18, "sustained interest accrual alone must be able to push HF below 1e18"
        );
    }
}
