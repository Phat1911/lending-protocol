// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

// Milestone 7 rounding audit: interest rate model + accrual index math.
//
// Design intent under test (per CLAUDE.md / SPEC.md §5-6, not up for
// redesign here):
//   - Every division that determines what a user OWES rounds UP
//     (_mulDivUp, used for debt settlement) - the protocol never lets a
//     borrower slip out slightly underpaying due to truncation.
//   - Every division that determines what a user is OWED rounds DOWN
//     (plain `/` in _settleSupply) - suppliers never over-withdraw.
//   - The reserve/supply interest split never loses a wei: reserveCut is
//     one truncating division, supplyCut is the remainder
//     (interestAccrued - reserveCut), not a second independent division.
//
// _mulDivUp, _settleDebt, _liveDebt, _settleSupply and _accrueInterest are
// all internal, so (following test/HealthFactor.t.sol and
// test/BorrowRepay_Rounding.t.sol's precedent) this harness exposes them
// directly plus raw setters to plant exact index/balance states without
// needing to reverse-engineer them from realistic borrow/supply flows.
contract LendingPoolHarness is LendingPool {
    constructor(address initialOwner, address collateralToken_, address daiToken_, address oracle_)
        LendingPool(initialOwner, collateralToken_, daiToken_, oracle_)
    {}

    function exposed_mulDivUp(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256) {
        return _mulDivUp(x, y, denominator);
    }

    function setPrincipalDebtForTesting(address user, uint256 amount) external {
        principalDebt[user] = amount;
    }

    function setUserBorrowIndexForTesting(address user, uint256 index) external {
        userBorrowIndex[user] = index;
    }

    function setBorrowIndexForTesting(uint256 index) external {
        borrowIndex = index;
    }

    function exposed_settleDebt(address user) external {
        _settleDebt(user);
    }

    function exposed_liveDebt(address user) external view returns (uint256) {
        return _liveDebt(user);
    }

    function setSuppliedBalanceForTesting(address user, uint256 amount) external {
        suppliedBalance[user] = amount;
    }

    function setUserSupplyIndexForTesting(address user, uint256 index) external {
        userSupplyIndex[user] = index;
    }

    function setSupplyIndexForTesting(uint256 index) external {
        supplyIndex = index;
    }

    function exposed_settleSupply(address user) external {
        _settleSupply(user);
    }

    function setBaseRateForTesting(uint256 rate) external {
        baseRate = rate;
    }

    function setTotalDaiBorrowedForTesting(uint256 amount) external {
        totalDaiBorrowed = amount;
    }

    function exposed_accrueInterest() external {
        _accrueInterest();
    }
}

contract InterestAccrualRoundingTest is Test {
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
    }

    // ------------------------------------------------------------------
    // 1a. _mulDivUp itself: (x*y + denominator - 1) / denominator.
    //     Confirm it ceils on a remainder and is a no-op (matches plain
    //     floor division) when the division is already exact.
    // ------------------------------------------------------------------
    function test_MulDivUp_CeilsOnRemainder() public view {
        // 7 * 3 / 2 = 21 / 2 = 10.5 true value.
        // Floor (naive division) = 10. Ceiling must be 11.
        uint256 result = pool.exposed_mulDivUp(7, 3, 2);
        assertEq(result, 11);
        assertEq(uint256(21) / 2, 10); // sanity: naive floor would be 10, one wei short
        assertGt(result, uint256(21) / 2);
    }

    function test_MulDivUp_ExactDivision_MatchesFloor() public view {
        // 10 * 3 / 2 = 30 / 2 = 15 exactly, no remainder to round away.
        uint256 result = pool.exposed_mulDivUp(10, 3, 2);
        assertEq(result, 15);
        assertEq(result, uint256(30) / 2);
    }

    // Fuzzed general ceiling-division property: result*denom >= x*y always
    // (never under-reports), and result is minimal, i.e. one less would no
    // longer cover x*y (never over-reports by more than needed to round up).
    // Inputs bounded to uint96 so x*y (<=192 bits) can't overflow uint256
    // and obscure the property being tested.
    function testFuzz_MulDivUp_IsMinimalCeiling(uint96 x, uint96 y, uint96 denominator) public view {
        vm.assume(denominator > 0);
        uint256 xy = uint256(x) * uint256(y);
        uint256 result = pool.exposed_mulDivUp(x, y, denominator);

        assertGe(result * denominator, xy); // covers the true product
        if (result > 0) {
            assertLt((result - 1) * denominator, xy); // one less would undershoot
        } else {
            assertEq(xy, 0); // result is only 0 when x*y is 0
        }
    }

    // ------------------------------------------------------------------
    // 1b. _settleDebt / _liveDebt use _mulDivUp -> debt rounds UP. Planted
    //     with a non-exact ratio so the direction is unambiguous.
    // ------------------------------------------------------------------
    function test_SettleDebt_RoundsUp_NeverUnderchargesBorrower() public {
        // principal=100, userBorrowIndex=3, borrowIndex=7.
        // True scaled debt = 100*7/3 = 233.33...
        pool.setPrincipalDebtForTesting(alice, 100);
        pool.setUserBorrowIndexForTesting(alice, 3);
        pool.setBorrowIndexForTesting(7);

        pool.exposed_settleDebt(alice);

        uint256 settled = pool.principalDebt(alice);
        uint256 naiveFloor = (uint256(100) * 7) / 3; // = 233, what a truncating division would give
        assertEq(naiveFloor, 233);
        assertEq(settled, 234); // ceil(700/3) = 234
        assertGt(settled, naiveFloor); // strictly more debt than floor - protocol's favor
    }

    function test_LiveDebt_ViewMatchesWhatSettleDebtWouldWrite() public {
        pool.setPrincipalDebtForTesting(alice, 100);
        pool.setUserBorrowIndexForTesting(alice, 3);
        pool.setBorrowIndexForTesting(7);

        // The view must report the same rounded-up figure _settleDebt will
        // actually persist - otherwise a user could read one number and be
        // charged a different one.
        uint256 live = pool.exposed_liveDebt(alice);
        assertEq(live, 234);

        pool.exposed_settleDebt(alice);
        assertEq(pool.principalDebt(alice), live);
    }

    // ------------------------------------------------------------------
    // 2. _settleSupply uses plain truncating division -> rounds DOWN, the
    //    opposite direction from debt, using the identical planted ratio
    //    (100 * 7 / 3) to make the contrast explicit: debt settles to 234,
    //    supply settles to 233, for the exact same numbers.
    // ------------------------------------------------------------------
    function test_SettleSupply_RoundsDown_NeverOvercreditsSupplier() public {
        pool.setSuppliedBalanceForTesting(alice, 100);
        pool.setUserSupplyIndexForTesting(alice, 3);
        pool.setSupplyIndexForTesting(7);

        pool.exposed_settleSupply(alice);

        uint256 settled = pool.suppliedBalance(alice);
        assertEq(settled, 233); // floor(700/3) = 233, not the debt-side 234
        assertLt(settled, 234); // strictly less than the ceiling counterpart
    }

    // ------------------------------------------------------------------
    // 3. reserveCut/supplyCut split inside _accrueInterest: reserveCut is
    //    one truncating division, supplyCut is the remainder
    //    (interestAccrued - reserveCut), so reserveCut + supplyCut ==
    //    interestAccrued holds by construction, with no dust vanishing.
    //
    //    Drive this through the REAL _accrueInterest code path (not a
    //    reimplementation): set totalDaiSupplied = 0 so getUtilization()
    //    returns 0 and getBorrowRate() collapses to exactly `baseRate`
    //    (the slope terms drop out), then pick baseRate=7 and warp exactly
    //    SECONDS_PER_YEAR so:
    //      interestFactor = WAD + 7 * 365 days / 365 days = WAD + 7
    //      newBorrowIndex = borrowIndex(=WAD) * (WAD+7) / WAD = WAD + 7
    //      interestAccrued = ceil(totalDaiBorrowed(=1e18) * 7 / WAD) = 7
    //    exactly, with the default reserveFactor = 0.10e18 (10%).
    // ------------------------------------------------------------------
    function test_AccrueInterest_ReserveAndSupplyCutSumExactlyToInterestAccrued() public {
        pool.setBaseRateForTesting(7);
        pool.setBorrowIndexForTesting(1e18); // == WAD, the default anyway
        pool.setTotalDaiBorrowedForTesting(1e18);
        // totalDaiSupplied intentionally left at 0 (default) so utilization
        // is 0 and getBorrowRate() == baseRate exactly - isolates the split
        // math from the rate-curve math, which is out of scope here.

        vm.warp(block.timestamp + 365 days);

        uint256 borrowedBefore = pool.totalDaiBorrowed();
        uint256 reservesBefore = pool.totalReserves();
        uint256 suppliedBefore = pool.totalDaiSupplied();

        pool.exposed_accrueInterest();

        uint256 interestAccrued = pool.totalDaiBorrowed() - borrowedBefore;
        uint256 reserveCut = pool.totalReserves() - reservesBefore;
        uint256 supplyCut = pool.totalDaiSupplied() - suppliedBefore;

        assertEq(interestAccrued, 7); // confirms the hand-derived setup above
        assertEq(reserveCut, 0); // floor(7 * 0.10e18 / 1e18) = floor(0.7) = 0
        assertEq(supplyCut, 7); // remainder: 7 - 0

        // The invariant the split is designed to guarantee, by construction:
        assertEq(reserveCut + supplyCut, interestAccrued);
    }

    // ------------------------------------------------------------------
    // Same interestAccrued=7 case, but showing what a NAIVE implementation
    // (two independent truncating divisions: reserveCut = accrued*rf/WAD
    // and supplyCut = accrued*(WAD-rf)/WAD) would have produced instead -
    // it silently loses 1 wei that the actual remainder-based split does
    // not.
    // ------------------------------------------------------------------
    function test_AccrueInterest_NaiveDoubleDivisionWouldLoseAWei() public {
        pool.setBaseRateForTesting(7);
        pool.setBorrowIndexForTesting(1e18);
        pool.setTotalDaiBorrowedForTesting(1e18);

        vm.warp(block.timestamp + 365 days);

        uint256 borrowedBefore = pool.totalDaiBorrowed();
        uint256 reservesBefore = pool.totalReserves();
        uint256 suppliedBefore = pool.totalDaiSupplied();

        pool.exposed_accrueInterest();

        uint256 interestAccrued = pool.totalDaiBorrowed() - borrowedBefore;
        uint256 actualReserveCut = pool.totalReserves() - reservesBefore;
        uint256 actualSupplyCut = pool.totalDaiSupplied() - suppliedBefore;

        uint256 reserveFactor = pool.reserveFactor();
        uint256 WAD = pool.WAD();

        // What the contract actually did (remainder-based split):
        assertEq(actualReserveCut + actualSupplyCut, interestAccrued);

        // What a naive "two independent divisions" implementation would
        // have computed instead, using the exact same inputs:
        uint256 naiveSupplyCut = (interestAccrued * (WAD - reserveFactor)) / WAD;
        assertEq(actualReserveCut, 0);
        assertEq(naiveSupplyCut, 6); // floor(7 * 0.9e18 / 1e18) = floor(6.3) = 6

        // The naive split drops a wei of value that belongs to nobody:
        assertLt(actualReserveCut + naiveSupplyCut, interestAccrued);
        assertEq(interestAccrued - (actualReserveCut + naiveSupplyCut), 1);

        // ...while the actual implementation's supplyCut (the remainder)
        // recovers exactly that wei instead of losing it.
        assertEq(actualSupplyCut, naiveSupplyCut + 1);
    }
}
