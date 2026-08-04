// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 10: full integration pass against SPEC.md §11. Every individual
// §11 bullet already has isolated unit coverage spread across the other
// test/*.t.sol files (see the milestone 10 audit notes in PLAN.md's
// progress log) — what's missing before this milestone is a single test
// that walks a *whole* protocol lifecycle end to end, the way a real
// sequence of on-chain calls would actually play out: liquidity arrives,
// a position gets opened near its limit, real time passes and interest
// compounds on both sides of the pool, the market moves against the
// borrower, and a liquidator closes the position out. Every number below is
// chosen so the underlying fixed-point math lands on an exact or
// hand-derivable figure (no fudge-factor tolerances), and is either
// asserted directly or re-derived from the same formulas the contract uses
// (mirroring the style already used in Liquidation_SpecLogic.t.sol /
// InterestAccrual_SpecLogic.t.sol) so a wrong contract formula — not a wrong
// test expectation — is what would make this fail.
contract IntegrationTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);

    // --- Scenario 1 actors ---
    address dave = address(0xDA5E); // mDAI liquidity supplier
    address alice = address(0xA11CE); // mWETH collateral depositor / borrower
    address liquidator1 = address(0x11117A70); // closes out alice's position

    // --- Scenario 2 actors (fresh set, so the two scenarios can't leak
    //     state into each other even though they share this contract) ---
    address carol = address(0xCA501); // mDAI liquidity supplier
    address erin = address(0xE11EE); // mWETH collateral depositor / borrower
    address frank = address(0xF4A17C); // closes out erin's (bad-debt) position

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        // Fund + approve every actor used across both scenarios.
        address[4] memory daiSuppliers = [dave, liquidator1, carol, frank];
        for (uint256 i = 0; i < daiSuppliers.length; i++) {
            dai.mint(daiSuppliers[i], 10_000_000e18);
            vm.prank(daiSuppliers[i]);
            dai.approve(address(pool), type(uint256).max);
        }

        address[2] memory wethBorrowers = [alice, erin];
        for (uint256 i = 0; i < wethBorrowers.length; i++) {
            weth.mint(wethBorrowers[i], 1000e18);
            vm.prank(wethBorrowers[i]);
            weth.approve(address(pool), type(uint256).max);
            vm.prank(wethBorrowers[i]);
            dai.approve(address(pool), type(uint256).max);
        }
    }

    // =====================================================================
    // Scenario 1: healthy lifecycle, sufficient-collateral liquidation.
    //
    // dave supplies mDAI liquidity -> alice deposits mWETH collateral and
    // borrows right up to her 75% LTV limit -> a full year passes, so
    // interest compounds into both alice's debt and dave's supplied
    // balance (net of the 10% reserve cut) -> mWETH crashes hard enough
    // (interest alone wasn't enough) to push alice below the 80%
    // liquidation threshold, but not so hard that her collateral can't
    // cover the full 1.10x bonus -> liquidator1 repays her full,
    // interest-inflated debt and is paid the bonus in mWETH.
    // =====================================================================
    function test_FullLifecycle_SupplyBorrowInterestCrashLiquidate() public {
        // --- 1. dave supplies mDAI liquidity ---
        // Sized so that alice's LTV-max borrow below lands utilization
        // exactly on the 80% kink (150,000 / 187,500 = 0.8e18), which
        // gives an exact 4% APR borrow rate for clean interest math.
        vm.prank(dave);
        pool.supply(187_500e18);
        assertEq(pool.totalDaiSupplied(), 187_500e18);

        // --- 2. alice deposits mWETH collateral and borrows to her LTV limit ---
        vm.startPrank(alice);
        pool.depositCollateral(100e18); // 100e18 * $2000 = $200,000 collateral
        pool.borrow(150_000e18); // exactly 75% LTV: 200,000 * 0.75 = 150,000
        vm.stopPrank();

        assertEq(pool.getUtilization(), 0.8e18, "sanity: must land exactly on the kink");
        assertEq(pool.getBorrowRate(), 0.04e18, "sanity: rate at kink must be exactly 4% APR");
        assertGe(pool.healthFactor(alice), 1e18, "borrowing to the LTV limit must still be a safe position");

        // --- 3. a year passes; interest compounds on both sides of the pool ---
        vm.warp(block.timestamp + 365 days);

        // Trigger accrual + settle both principals with harmless no-op
        // calls (mirrors the idiom used in InterestAccrual_SpecLogic.t.sol)
        // so we can read live, index-scaled figures out of storage.
        vm.prank(dave);
        pool.supply(0);
        vm.prank(alice);
        pool.repay(0);

        // interestAccrued = 150,000e18 * 4% = 6,000e18 (exact: timeDelta is
        // exactly SECONDS_PER_YEAR and all inputs are round numbers).
        assertEq(pool.principalDebt(alice), 156_000e18, "alice's debt must have grown by exactly one year of 4% APR");
        assertEq(pool.totalDaiBorrowed(), 156_000e18);

        // Reserve factor = 10% of interest accrued -> 600e18 to reserves,
        // 5,400e18 (90%) flows to dave as sole supplier.
        assertEq(pool.totalReserves(), 600e18, "reserve cut must be exactly 10% of interest accrued");
        assertEq(pool.suppliedBalance(dave), 192_900e18, "dave's balance must capture the full 90% supplier cut");
        assertEq(pool.totalDaiSupplied(), 192_900e18);

        // Interest alone (no price move) has not yet made alice unsafe:
        // 200,000 * 0.8 = 160,000 > 156,000 debt.
        assertGe(pool.healthFactor(alice), 1e18, "interest alone must not yet breach the liquidation threshold");

        // --- 4. mWETH price crashes: alice becomes liquidatable, but her ---
        //        collateral still covers the full 1.10x bonus.
        oracle.setPrice(address(weth), 1800e18);
        // collateralValueUSD = 100e18 * 1800 = 180,000; 180,000*0.8=144,000 < 156,000 debt -> unsafe.
        assertLt(pool.healthFactor(alice), 1e18, "price crash must push alice below the liquidation threshold");

        uint256 debtBefore = pool.principalDebt(alice); // 156,000e18, settled above
        uint256 daiPrice = oracle.getPrice(address(dai));
        uint256 wethPrice = oracle.getPrice(address(weth));
        uint256 repaidDebtValueUSD = debtBefore * daiPrice / pool.WAD();
        uint256 seizeValueUSD = repaidDebtValueUSD * pool.liquidationBonus() / pool.BPS_DENOMINATOR();
        uint256 expectedSeize = seizeValueUSD * pool.WAD() / wethPrice;

        assertLt(expectedSeize, pool.collateralBalance(alice), "sanity: this must be the sufficient-collateral case");

        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator1);
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator1);

        // --- 5. liquidator1 closes the position out ---
        vm.prank(liquidator1);
        pool.liquidate(alice);

        // Liquidator paid exactly the full interest-inflated debt, and
        // received exactly repaidDebtValueUSD * 1.10 worth of mWETH.
        assertEq(dai.balanceOf(liquidator1), liquidatorDaiBefore - debtBefore, "liquidator must pay the full live debt");
        assertEq(
            weth.balanceOf(liquidator1),
            liquidatorWethBefore + expectedSeize,
            "liquidator must receive exactly the 10% bonus in mWETH"
        );

        // Borrower's debt is zeroed and her position is safe again (infinite HF).
        assertEq(pool.principalDebt(alice), 0, "borrower's debt must be fully zeroed");
        assertEq(pool.healthFactor(alice), type(uint256).max, "zero-debt position must read back as infinitely safe");
        assertEq(pool.collateralBalance(alice), 100e18 - expectedSeize);
        assertEq(pool.totalDaiBorrowed(), 0, "alice was the sole borrower, so the pool's total debt returns to zero");

        // Reserves and dave's growth from step 3 are untouched by liquidation itself.
        assertEq(pool.totalReserves(), 600e18);
        assertEq(pool.suppliedBalance(dave), 192_900e18);

        // --- 6. closing the loop: with debt fully repaid, all liquidity is ---
        //        available again and dave can withdraw his full grown balance.
        uint256 daveDaiBefore = dai.balanceOf(dave);
        vm.prank(dave);
        pool.withdrawSupply(192_900e18);
        assertEq(dai.balanceOf(dave), daveDaiBefore + 192_900e18);
        assertEq(pool.suppliedBalance(dave), 0);
    }

    // =====================================================================
    // Scenario 2: bad-debt-capped liquidation, in the same full-lifecycle
    // shape as scenario 1 (supply -> borrow to LTV limit -> time passes ->
    // interest compounds -> price crashes), but this time the crash is
    // severe enough that erin's collateral can't cover the full 1.10x
    // bonus. Seizure must cap at her actual balance, her debt must still be
    // fully zeroed, and the liquidator must still pay the full debt amount
    // (the resulting shortfall is accepted bad debt per SPEC.md §10, not
    // solved). Uses a disjoint set of actors/pool state from scenario 1.
    // =====================================================================
    function test_FullLifecycle_BadDebtCappedSeizure() public {
        // --- 1. carol supplies mDAI liquidity ---
        // Sized so erin's LTV-max borrow again lands exactly on the 80%
        // kink (15,000 / 18,750 = 0.8e18) for clean 4% APR interest math.
        vm.prank(carol);
        pool.supply(18_750e18);

        // --- 2. erin deposits mWETH collateral and borrows to her LTV limit ---
        vm.startPrank(erin);
        pool.depositCollateral(10e18); // 10e18 * $2000 = $20,000 collateral
        pool.borrow(15_000e18); // exactly 75% LTV
        vm.stopPrank();

        assertEq(pool.getBorrowRate(), 0.04e18, "sanity: rate at kink must be exactly 4% APR");

        // --- 3. a year passes; interest compounds ---
        vm.warp(block.timestamp + 365 days);

        vm.prank(carol);
        pool.supply(0);
        vm.prank(erin);
        pool.repay(0);

        // interestAccrued = 15,000e18 * 4% = 600e18 exactly.
        assertEq(pool.principalDebt(erin), 15_600e18);
        assertEq(pool.totalReserves(), 60e18, "10% reserve cut");
        assertEq(pool.suppliedBalance(carol), 19_290e18, "90% supplier cut");

        // --- 4. mWETH crashes hard: erin's collateral can no longer cover ---
        //        even the un-bonused debt, let alone the 1.10x bonus.
        oracle.setPrice(address(weth), 1500e18);
        // collateralValueUSD = 10e18 * 1500 = 15,000 < 15,600 debt -> unsafe.
        assertLt(pool.healthFactor(erin), 1e18);

        uint256 debtBefore = pool.principalDebt(erin); // 15,600e18
        uint256 collateralBefore = pool.collateralBalance(erin); // 10e18
        uint256 daiPrice = oracle.getPrice(address(dai));
        uint256 wethPrice = oracle.getPrice(address(weth));
        uint256 repaidDebtValueUSD = debtBefore * daiPrice / pool.WAD();
        uint256 seizeValueUSD = repaidDebtValueUSD * pool.liquidationBonus() / pool.BPS_DENOMINATOR();
        uint256 uncappedSeize = seizeValueUSD * pool.WAD() / wethPrice;
        assertGt(uncappedSeize, collateralBefore, "sanity: this must genuinely be the capped-seizure case");

        uint256 liquidatorDaiBefore = dai.balanceOf(frank);
        uint256 liquidatorWethBefore = weth.balanceOf(frank);

        // --- 5. frank closes the position out; seizure caps at erin's full balance ---
        vm.prank(frank);
        pool.liquidate(erin);

        // Liquidator still pays the FULL live debt, even though the
        // collateral they receive back is worth less than that (bad debt).
        assertEq(dai.balanceOf(frank), liquidatorDaiBefore - debtBefore, "liquidator must pay the full live debt");
        assertEq(
            weth.balanceOf(frank),
            liquidatorWethBefore + collateralBefore,
            "liquidator must receive exactly the borrower's full remaining collateral, capped at their balance"
        );

        assertEq(pool.principalDebt(erin), 0, "debt must be fully zeroed even though seizure was capped");
        assertEq(pool.collateralBalance(erin), 0, "collateral must be fully drained");
        assertEq(pool.totalDaiBorrowed(), 0, "erin was the sole borrower, so pool debt returns to zero");

        // Supplier growth and reserves from step 3 are unaffected by the
        // bad-debt outcome — carol's accrued interest is not clawed back.
        assertEq(pool.totalReserves(), 60e18);
        assertEq(pool.suppliedBalance(carol), 19_290e18);

        // Liquidity invariant still holds: with debt fully repaid (even
        // though under-collateralized), all supplied mDAI is available again.
        assertEq(pool.totalDaiSupplied() - pool.totalDaiBorrowed(), 19_290e18);
        uint256 carolDaiBefore = dai.balanceOf(carol);
        vm.prank(carol);
        pool.withdrawSupply(19_290e18);
        assertEq(dai.balanceOf(carol), carolDaiBefore + 19_290e18);
    }
}
