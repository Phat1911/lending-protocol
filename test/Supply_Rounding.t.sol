// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Rounding audit: dust-sized FIRST deposits and supply-index initialization.
//
// Prompted by external review feedback on this project: lending audits often
// find Highs in "rounding in index updates when the first deposit is
// dust-sized". Design intent under test (per SPEC.md §6, not up for
// redesign here):
//   - `userSupplyIndex` defaults to 0 for a fresh user. `_settleSupply`
//     guards the balance == 0 first interaction, so the first touch of a
//     user's accounting can never divide by zero, and the user index is
//     anchored at the CURRENT supplyIndex before the first wei is booked:
//     a dust first deposit is credited exactly - neither inflated nor
//     truncated.
//   - Balances are underlying-denominated (not shares). Interest settles
//     through a single floor division (`* supplyIndex / userSupplyIndex`),
//     so sub-wei interest may round AWAY from a dust supplier - the safe
//     direction - but a dust supplier's settled balance never drops below
//     their deposited principal and is always fully withdrawable.
//   - There is no share-minting, so the classic ERC4626-style
//     first-depositor inflation attack has no surface here: unsolicited
//     token donations to the pool change no user balance, no index, and
//     no total. That absence is asserted, not assumed.
//   - Pool solvency invariant under dust-first flows:
//       dai.balanceOf(pool) >= totalDaiSupplied - totalDaiBorrowed + totalReserves
//     and the per-user rounding direction guarantees
//       sum(settled user supplies) <= totalDaiSupplied.
contract SupplyRoundingTest is Test {
    LendingPool pool;
    MockWETH weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE); // dust-first depositor
    address bob = address(0xB0B); // whale supplier + borrower
    address mallory = address(0xBAAD); // donor / would-be inflater

    function setUp() public {
        weth = new MockWETH();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        // Alice only ever needs dust.
        dai.mint(alice, 1_000e18);
        vm.prank(alice);
        dai.approve(address(pool), type(uint256).max);

        // Bob: large supplier + borrower (well beyond any interest he owes).
        dai.mint(bob, 1_000_000e18);
        weth.mint(bob, 1_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        dai.mint(mallory, 2_000_000e18);
        vm.prank(mallory);
        dai.approve(address(pool), type(uint256).max);
    }

    /// @dev Triggers `_settleSupply` for `user` through the public path.
    function _settle(address user) internal {
        vm.prank(user);
        pool.supply(0);
    }

    // ------------------------------------------------------------------
    // 1. Index initialization: the first deposit is dust (1 wei)
    // ------------------------------------------------------------------

    function test_FirstSupplyOfOneWei_IsCreditedExactly() public {
        vm.prank(alice);
        pool.supply(1);

        assertEq(pool.suppliedBalance(alice), 1, "dust principal must be booked exactly");
        assertEq(pool.totalDaiSupplied(), 1);
        assertEq(pool.userSupplyIndex(alice), pool.supplyIndex(), "index must anchor at current supplyIndex");
        assertEq(pool.supplyIndex(), 1e18, "fresh pool index is WAD");
        assertEq(dai.balanceOf(address(pool)), 1);

        // Full round-trip: the dust supplier can get their wei back.
        vm.prank(alice);
        pool.withdrawSupply(1);

        assertEq(pool.suppliedBalance(alice), 0);
        assertEq(pool.totalDaiSupplied(), 0);
        assertEq(dai.balanceOf(alice), 1_000e18);
    }

    function test_FirstInteraction_SupplyZero_AnchorsWithoutBalance() public {
        // A zero-amount first touch must not panic (0 / 0 division) and
        // must not corrupt the anchor for the real deposit that follows.
        vm.prank(alice);
        pool.supply(0);

        assertEq(pool.suppliedBalance(alice), 0);
        assertEq(pool.userSupplyIndex(alice), 1e18, "anchor set even with zero balance");

        // Generate real accrual, then make Alice's first real deposit.
        vm.startPrank(bob);
        pool.supply(1_000e18);
        pool.depositCollateral(10e18);
        pool.borrow(100e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        pool.supply(1_000e18);

        assertEq(
            pool.suppliedBalance(alice),
            1_000e18,
            "first real deposit must be credited exactly despite earlier zero-anchor"
        );
        assertEq(pool.userSupplyIndex(alice), pool.supplyIndex(), "re-anchored at deposit-time index");
    }

    // ------------------------------------------------------------------
    // 2. Dust principal under real interest: rounding direction
    // ------------------------------------------------------------------

    function test_DustFirstDeposit_InterestRoundsAgainstSupplierNotToZeroOrOverpay() public {
        // Alice is the FIRST depositor, with exactly 1 wei.
        vm.prank(alice);
        pool.supply(1);

        vm.startPrank(bob);
        pool.supply(1_000e18);
        pool.depositCollateral(10e18);
        pool.borrow(100e18); // generates interest for suppliers
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // Settle everyone through the public path.
        vm.prank(bob);
        pool.repay(type(uint256).max);
        _settle(alice);
        _settle(bob);

        uint256 aliceBalance = pool.suppliedBalance(alice);
        uint256 bobBalance = pool.suppliedBalance(bob);

        // Sub-wei interest rounds AWAY from the dust supplier: her balance
        // stays exactly at principal - never below (no destruction) ...
        assertEq(aliceBalance, 1, "sub-wei interest must floor to principal, not below");
        // ... while the whale (whose interest is many whole wei) does grow.
        assertGt(bobBalance, 1_000e18, "whole-wei interest must reach the whale");

        // Rounding direction guarantee: settled claims never exceed the total.
        assertLe(
            aliceBalance + bobBalance,
            pool.totalDaiSupplied(),
            "sum of settled supplies must not exceed totalDaiSupplied"
        );

        // Solvency invariant.
        assertGe(
            dai.balanceOf(address(pool)),
            pool.totalDaiSupplied() - pool.totalDaiBorrowed() + pool.totalReserves(),
            "pool must remain solvent after dust-first accrual"
        );

        // And the dust supplier can still exit fully.
        vm.prank(alice);
        pool.withdrawSupply(aliceBalance);
        assertEq(pool.suppliedBalance(alice), 0);
    }

    function test_DonationCannotInflateOrDestroyDustBalance() public {
        vm.prank(alice);
        pool.supply(1);

        // Mallory donates a huge amount straight to the pool, hoping to
        // distort index accounting (the ERC4626 first-depositor pattern).
        vm.prank(mallory);
        dai.transfer(address(pool), 1_000_000e18);

        uint256 supplyIndexBefore = pool.supplyIndex();

        _settle(alice);

        assertEq(pool.suppliedBalance(alice), 1, "donation must not touch user balances");
        assertEq(pool.supplyIndex(), supplyIndexBefore, "donation must not touch the index");
        assertEq(supplyIndexBefore, 1e18);
        assertEq(pool.totalDaiSupplied(), 1, "donation must not enter supply totals");
        assertEq(pool.totalReserves(), 0, "donation must not become reserves");

        // Alice still exits with exactly her principal.
        vm.prank(alice);
        pool.withdrawSupply(1);
        assertEq(pool.suppliedBalance(alice), 0);
        assertEq(dai.balanceOf(alice), 1_000e18);
    }

    function test_FirstDepositorDonatesBeforeOthers_NothingInflates() public {
        // The classic ERC4626 inflation setup, verbatim: the FIRST depositor
        // supplies dust, then donates a large amount straight to the pool
        // BEFORE anyone else deposits. In a share-price-derived design this
        // deflates the next depositor's shares; here every accounting surface
        // must stay untouched - and the donation ends up stranded.
        vm.startPrank(mallory);
        pool.supply(1);
        dai.transfer(address(pool), 1_000_000e18);
        vm.stopPrank();

        // Victim deposits into the "inflated" pool.
        vm.prank(alice);
        pool.supply(1_000e18);

        assertEq(pool.supplyIndex(), 1e18, "donation must not move the index");
        assertEq(pool.totalDaiSupplied(), 1_000e18 + 1, "donation must not enter totals");
        assertEq(pool.totalReserves(), 0, "donation must not become reserves");
        assertEq(pool.suppliedBalance(alice), 1_000e18, "victim credited exactly - no deflation");
        assertEq(pool.userSupplyIndex(alice), 1e18, "victim anchored at the untampered index");

        // Attacker exits with exactly their principal - nothing more.
        vm.prank(mallory);
        pool.withdrawSupply(1);
        assertEq(pool.suppliedBalance(mallory), 0);
        assertEq(dai.balanceOf(mallory), 1_000_000e18, "attacker recovers only the dust; the donation is gone");

        // Victim exits whole as well.
        vm.prank(alice);
        pool.withdrawSupply(1_000e18);
        assertEq(pool.suppliedBalance(alice), 0);
        assertEq(pool.totalDaiSupplied(), 0);

        // The donation is stranded: it backs no claim (totalDaiSupplied == 0)
        // and cannot be extracted even by the owner via withdrawReserves,
        // which is capped at interest-grown totalReserves.
        assertEq(dai.balanceOf(address(pool)), 1_000_000e18, "donation remains, unclaimable by anyone");
    }

    // ------------------------------------------------------------------
    // 3. Bounded fuzz: dust-first flows preserve the invariants
    // ------------------------------------------------------------------

    function testFuzz_DustFirstDeposit_InvariantsHold(uint96 dustAmount, uint96 whaleAmount, uint32 timeWarp) public {
        dustAmount = uint96(bound(dustAmount, 1, 1_000_000)); // dust: 1 wei .. 1e6 wei
        whaleAmount = uint96(bound(whaleAmount, 1e21, 1e24)); // whale: 1k .. 1M DAI
        timeWarp = uint32(bound(timeWarp, 1, 5 * 365 days)); // up to 5 years

        // Bob's setUp endowment must cover supplying `whaleAmount` AND
        // repaying `whaleAmount / 2` plus five years of interest afterwards.
        dai.mint(bob, uint256(whaleAmount));

        // Alice is the first depositor, with dust.
        vm.prank(alice);
        pool.supply(dustAmount);

        // Whale supplies, posts collateral, borrows half the pool at ~50%
        // utilization (below the kink).
        uint256 borrowAmount = uint256(whaleAmount) / 2;
        vm.startPrank(bob);
        pool.supply(whaleAmount);
        pool.depositCollateral(1_000e18); // 1000 WETH: LTV headroom >> borrow
        pool.borrow(borrowAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + timeWarp);

        // Whale repays everything (settles debt side, final accrual).
        vm.prank(bob);
        pool.repay(type(uint256).max);

        // Settle both suppliers through the public path.
        _settle(alice);
        _settle(bob);

        uint256 aliceBalance = pool.suppliedBalance(alice);
        uint256 bobBalance = pool.suppliedBalance(bob);
        uint256 upperBound = (uint256(dustAmount) * pool.supplyIndex()) / 1e18 + 1;

        // Dust principal is never destroyed ...
        assertGe(aliceBalance, dustAmount, "dust supplier never below principal");
        // ... never inflated beyond exact index math + 1 wei of tolerance ...
        assertLe(aliceBalance, upperBound, "dust supplier never overpaid");
        // ... claims never exceed the tracked total ...
        assertLe(
            aliceBalance + bobBalance,
            pool.totalDaiSupplied(),
            "sum of settled supplies must not exceed totalDaiSupplied"
        );
        // ... and the pool stays solvent.
        assertGe(
            dai.balanceOf(address(pool)),
            pool.totalDaiSupplied() - pool.totalDaiBorrowed() + pool.totalReserves(),
            "solvency invariant"
        );

        // The dust supplier can always exit with their full settled balance.
        vm.prank(alice);
        pool.withdrawSupply(aliceBalance);
        assertEq(pool.suppliedBalance(alice), 0);
    }
}
