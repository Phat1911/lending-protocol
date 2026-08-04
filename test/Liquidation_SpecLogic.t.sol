// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 8 spec-correctness checks: `liquidate()` against SPEC.md §7
// ("Liquidation") and §10's bad-debt bullet, plus CLAUDE.md's "Liquidation
// correctness" rule. Not covering generic vulnerability classes
// (reentrancy/rounding/oracle timing/integer edge cases/state consistency)
// — those are owned by other parallel test files for this milestone. This
// file is purely about whether the business logic matches what SPEC.md §7
// actually says, especially the easy-to-misimplement bad-debt case: full
// debt is always repaid by the liquidator, even when seizure is capped
// below the full 1.10x bonus value.
contract LiquidationSpecLogicTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE); // borrower
    address bob = address(0xB0B); // mDAI liquidity supplier
    address liquidator = address(0x11117A70); // liquidates alice, distinct account so its
        // dai/weth balances aren't entangled with bob's supplier position

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

        dai.mint(bob, 10_000_000e18);
        vm.prank(bob);
        dai.approve(address(pool), type(uint256).max);

        dai.mint(liquidator, 10_000_000e18);
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    // ---------------------------------------------------------------
    // 1. SPEC §7: "Liquidation is disallowed if the position is currently
    //    healthy (health factor >= 1e18) — liquidating a safe position must
    //    revert." Confirm the revert reason is specifically the health
    //    check, not some unrelated failure (e.g. missing approval/debt).
    // ---------------------------------------------------------------

    function test_RevertWhen_LiquidatingHealthyPositionReverts() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000 @ $2000/mWETH
        pool.borrow(5_000e18); // well under both LTV and liquidation threshold
        vm.stopPrank();

        assertGe(pool.healthFactor(alice), 1e18, "sanity: position must actually be safe for this test to be meaningful");

        vm.prank(liquidator);
        vm.expectRevert("position is healthy");
        pool.liquidate(alice);
    }

    // ---------------------------------------------------------------
    // 2. SPEC §7: unhealthy position, sufficient collateral. Liquidator
    //    receives exactly `repaidDebtValueUSD * 1.10` worth of mWETH; debt
    //    is fully zeroed. Expected seizure is hand-computed straight from
    //    the spec formula (replicated with the contract's own
    //    mul-then-div operation order, so integer truncation matches
    //    exactly rather than needing a fudge-factor tolerance).
    // ---------------------------------------------------------------

    function test_LiquidateSufficientCollateral_ReceivesExactBonusSeizure() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000 @ $2000/mWETH
        pool.borrow(15_000e18); // exactly 75% LTV -> HF = 1.0667e18 (safe)
        vm.stopPrank();

        assertGe(pool.healthFactor(alice), 1e18);

        // Crash mWETH price: collateralValueUSD = 10e18 * 1800e18/1e18 = 18,000e18.
        // debtValueUSD stays 15,000e18 (dai price untouched at 1e18).
        // HF check: 18,000 * 0.8 = 14,400 < 15,000 -> unhealthy.
        // Bonus-value check: 18,000 >= 15,000 * 1.10 = 16,500 -> collateral
        // is sufficient for the full 1.10x seizure (cap does NOT engage).
        oracle.setPrice(address(weth), 1800e18);
        assertLt(pool.healthFactor(alice), 1e18);

        uint256 debtBefore = pool.principalDebt(alice); // 15,000e18, no time has passed -> no interest yet
        assertEq(debtBefore, 15_000e18);

        uint256 daiPrice = oracle.getPrice(address(dai));
        uint256 wethPrice = oracle.getPrice(address(weth));
        uint256 repaidDebtValueUSD = debtBefore * daiPrice / 1e18; // 15,000e18
        uint256 seizeValueUSD = repaidDebtValueUSD * pool.liquidationBonus() / 10_000; // 16,500e18
        uint256 expectedSeize = seizeValueUSD * 1e18 / wethPrice; // ~9.1667e18 mWETH

        assertLt(expectedSeize, pool.collateralBalance(alice), "sanity: this case must NOT hit the collateral cap");

        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice);

        assertEq(pool.principalDebt(alice), 0, "debt must be fully zeroed after liquidation");
        assertEq(
            dai.balanceOf(liquidator), liquidatorDaiBefore - debtBefore, "liquidator must pay exactly the full debt"
        );
        assertEq(
            weth.balanceOf(liquidator),
            liquidatorWethBefore + expectedSeize,
            "liquidator must receive exactly repaidDebtValueUSD * 1.10 worth of mWETH, per SPEC S7"
        );
        assertEq(pool.collateralBalance(alice), 10e18 - expectedSeize);
    }

    // ---------------------------------------------------------------
    // 3. SPEC §7 "Insufficient collateral case" + §10 bad-debt bullet +
    //    CLAUDE.md "Liquidation correctness" rule. THIS IS THE CRITICAL
    //    TEST: when collateral can't cover the full 1.10x bonus, seizure
    //    is capped at the borrower's actual balance, debt is still zeroed,
    //    but the liquidator must still pay the FULL original debt amount
    //    -- not a reduced/prorated amount scaled down to what they
    //    actually received back. A liquidator here ends up underwater
    //    (pays more USD value than they receive) -- that is the spec-
    //    mandated bad-debt behavior, not a bug.
    // ---------------------------------------------------------------

    function test_LiquidateInsufficientCollateral_SeizureCappedButLiquidatorStillPaysFullDebt() public {
        vm.prank(bob);
        pool.supply(1_000_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(15_000e18);
        vm.stopPrank();

        // Crash price hard: collateralValueUSD = 10e18 * 1500e18/1e18 = 15,000e18.
        // Bonus-value needed = 15,000e18 * 1.10 = 16,500e18 worth of mWETH,
        // but collateral is only worth 15,000e18 -> insufficient, seizure
        // must be capped at the borrower's full remaining balance (10e18).
        oracle.setPrice(address(weth), 1500e18);
        assertLt(pool.healthFactor(alice), 1e18);

        uint256 debtBefore = pool.principalDebt(alice); // full 15,000e18, no interest accrued yet
        uint256 collateralBefore = pool.collateralBalance(alice); // 10e18
        assertEq(debtBefore, 15_000e18);
        assertEq(collateralBefore, 10e18);

        // Confirm the *uncapped* formula would in fact demand more mWETH
        // than the borrower has, so this test genuinely exercises the cap
        // branch (not accidentally landing back in the sufficient case).
        uint256 daiPrice = oracle.getPrice(address(dai));
        uint256 wethPrice = oracle.getPrice(address(weth));
        uint256 repaidDebtValueUSD = debtBefore * daiPrice / 1e18;
        uint256 seizeValueUSD = repaidDebtValueUSD * pool.liquidationBonus() / 10_000;
        uint256 uncappedSeize = seizeValueUSD * 1e18 / wethPrice;
        assertGt(
            uncappedSeize,
            collateralBefore,
            "sanity: uncapped seizure must exceed the borrower's collateral for this to be a genuine cap test"
        );

        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        uint256 poolDaiBefore = dai.balanceOf(address(pool));

        vm.prank(liquidator);
        pool.liquidate(alice);

        // (a) liquidator receives ALL of the borrower's remaining
        //     collateral -- not more, not less than the actual balance.
        assertEq(
            weth.balanceOf(liquidator),
            liquidatorWethBefore + collateralBefore,
            "liquidator must receive exactly the borrower's full remaining collateral, capped at their balance"
        );
        assertEq(pool.collateralBalance(alice), 0, "borrower's collateral must be fully drained, not left partial");

        // (b) debt is still zeroed even though seizure was capped / bad
        //     debt is left unrecovered (SPEC S10: accepted, not solved).
        assertEq(
            pool.principalDebt(alice),
            0,
            "debt must still be zeroed even though collateral was insufficient to fully cover it"
        );

        // (c) THE CRITICAL SPEC-FIDELITY CHECK: the liquidator pays the
        //     FULL original debt amount, not a reduced/prorated amount.
        //     A natural (but spec-violating) alternate implementation
        //     would scale the repay amount down to keep the liquidator
        //     whole -- that must NOT be what happens here.
        assertEq(
            dai.balanceOf(liquidator),
            liquidatorDaiBefore - debtBefore,
            "liquidator must pay the FULL pre-liquidation debt even in the capped-seizure case, not a reduced/prorated amount"
        );
        assertEq(
            dai.balanceOf(address(pool)),
            poolDaiBefore + debtBefore,
            "pool must have received the full original debt as repayment, confirming no proration occurred"
        );
    }

    // ---------------------------------------------------------------
    // 4. SPEC §8 interface sketch: `function liquidate(address borrower)
    //    external;` -- full liquidation only, no partial-repay amount
    //    parameter exists at all. There's no runtime scenario for "a
    //    parameter that doesn't exist"; this asserts the ABI selector
    //    matches liquidate(address) exactly (not e.g. an overload taking
    //    a partial-repay uint256), which is the closest thing to a
    //    concrete, checkable assertion of that spec requirement.
    // ---------------------------------------------------------------

    function test_LiquidateSignatureTakesOnlyBorrowerAddress_NoPartialAmountParam() public view {
        assertEq(
            pool.liquidate.selector,
            bytes4(keccak256("liquidate(address)")),
            "liquidate() must be full-liquidation-only per SPEC S7/S8 -- no partial-repay amount parameter"
        );
    }

    // ---------------------------------------------------------------
    // 5. SPEC §6 + §7: the debt figure used for both the health check and
    //    the repay amount must be the live, index-scaled debt (principal
    //    + accrued interest) -- not stale pre-accrual principal. Drive a
    //    position unhealthy purely through interest growth (no price
    //    move at all) to prove this, and confirm the liquidator is
    //    charged the inflated figure.
    // ---------------------------------------------------------------

    function test_LiquidateTriggeredByInterestAloneUsesInflatedDebtFigure() public {
        // 100% utilization -> borrowRate = 79% APR (the max rate), so an
        // unhealthy position is reachable via interest growth alone
        // within a modest time warp.
        vm.prank(bob);
        pool.supply(15_000e18);

        vm.startPrank(alice);
        pool.depositCollateral(10e18); // $20,000 @ $2000/mWETH
        pool.borrow(15_000e18); // exactly 75% LTV, exactly 100% utilization
        vm.stopPrank();

        assertEq(pool.getUtilization(), 1e18, "sanity: must be exactly 100% utilization");
        assertEq(pool.getBorrowRate(), 0.79e18, "sanity: must be at the max 79% APR rate");
        assertGe(
            pool.healthFactor(alice), 1e18, "must start safe -- any unhealthiness below must come purely from interest"
        );

        // HF < 1e18 requires debtValueUSD > collateralValueUSD * 0.8 =
        // 16,000e18. At 79% APR linear accrual, 60 days of growth is
        // ~+12.99% (79% * 60/365), comfortably pushing debt from
        // 15,000e18 past the 16,000e18 threshold with margin to spare.
        vm.warp(block.timestamp + 60 days);

        // Trigger accrual + settle alice's principal (without changing
        // the amount owed) so we can read off the true inflated debt
        // figure before liquidating. repay(0) is a documented no-op
        // repay amount that still runs _accrueInterest + _settleDebt
        // first (see InterestAccrual_SpecLogic.t.sol).
        vm.prank(alice);
        pool.repay(0);

        uint256 inflatedDebt = pool.principalDebt(alice);
        assertGt(inflatedDebt, 15_000e18, "sanity: interest must actually have inflated the stored debt");
        assertLt(pool.healthFactor(alice), 1e18, "position must now be unhealthy purely from interest growth");

        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice);

        // The liquidator must be charged the current, interest-inflated
        // debt figure read above -- not the original 15,000e18 principal
        // -- confirming liquidate()'s `debt = principalDebt[borrower]`
        // read (taken right after _settleDebt) reflects live, index-
        // scaled debt rather than stale pre-accrual principal.
        assertEq(
            liquidatorDaiBefore - dai.balanceOf(liquidator),
            inflatedDebt,
            "liquidator must be charged the interest-inflated debt, not the original pre-interest principal"
        );
        assertEq(pool.principalDebt(alice), 0, "debt must be fully zeroed after liquidation");
    }
}
