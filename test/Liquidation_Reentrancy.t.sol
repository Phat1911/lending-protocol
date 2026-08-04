// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockDAI} from "../src/mocks/MockDAI.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// mWETH/mDAI are plain OZ ERC20s with no transfer hooks, so they can't
// naturally re-enter the pool; this malicious mDAI stand-in calls back into
// the pool from within transferFrom() to exercise nonReentrant during the
// debt-pull leg of liquidate() (daiToken.safeTransferFrom(msg.sender, ...)).
contract MaliciousReentrantDaiLiq is ERC20 {
    LendingPool public pool;
    bool public attackOnTransferFrom;
    address public victim;

    constructor() ERC20("Malicious DAI", "mDAI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPool(address pool_) external {
        pool = LendingPool(pool_);
    }

    function setVictim(address victim_) external {
        victim = victim_;
    }

    function setAttackOnTransferFrom(bool on) external {
        attackOnTransferFrom = on;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (attackOnTransferFrom) {
            // liquidate() is mid-flight here: principalDebt/collateralBalance
            // have already been zeroed/decremented for `victim`, but the
            // collateral seizure transfer hasn't fired yet. If the
            // nonReentrant lock didn't cover this call, an attacker could
            // re-run liquidate() (or borrow/repay) against already-mutated
            // state. Must revert.
            pool.liquidate(victim);
        }
        return super.transferFrom(from, to, amount);
    }
}

// Analogous malicious mWETH stand-in: calls back into the pool from within
// transfer() to exercise nonReentrant during the collateral-push leg of
// liquidate() (collateralToken.safeTransfer(msg.sender, seizeAmount)).
contract MaliciousReentrantWethLiq is ERC20 {
    LendingPool public pool;
    bool public attackOnTransfer;
    address public victim;

    constructor() ERC20("Malicious WETH", "mWETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPool(address pool_) external {
        pool = LendingPool(pool_);
    }

    function setVictim(address victim_) external {
        victim = victim_;
    }

    function setAttackOnTransfer(bool on) external {
        attackOnTransfer = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attackOnTransfer) {
            // By this point liquidate() has already pulled the liquidator's
            // debt repayment and zeroed the borrower's debt/collateral in
            // storage; only the outbound seizure transfer is left. If
            // reentrancy weren't blocked here, this is the point at which a
            // second liquidate() (or any other state-changing call) could
            // run against a pool that already "settled" this borrower.
            pool.liquidate(victim);
        }
        return super.transfer(to, amount);
    }
}

/// @notice Sets up a genuinely liquidatable position (collateral deposited,
/// debt borrowed near the LTV cap, then the collateral price crashed so
/// health factor < 1e18) before attempting reentrancy, so that a revert can
/// only be attributed to ReentrancyGuard and not to an earlier unrelated
/// require (e.g. "position is healthy" or "no debt to liquidate").
contract LiquidateReentrancy_MaliciousDaiTest is Test {
    LendingPool pool;
    MockWETH weth;
    MaliciousReentrantDaiLiq dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE); // borrower who gets liquidated
    address bob = address(0xB0B); // honest supplier
    address mallory = address(0xBAD); // attacker acting as liquidator

    function setUp() public {
        weth = new MockWETH();
        dai = new MaliciousReentrantDaiLiq();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));
        dai.setPool(address(pool));
        dai.setVictim(alice);

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        // Fund the pool via supply() so totalDaiSupplied tracks liquidity
        // actually available to borrow().
        dai.mint(bob, 100_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(100_000e18);
        vm.stopPrank();

        // Alice deposits collateral and borrows near the 75% LTV cap
        // (attack flag off — this must succeed cleanly).
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18); // 10e18 * 2000e18 = $20,000 collateral; 70% LTV
        vm.stopPrank();

        // Crash the collateral price so health factor drops below 1e18:
        // collateralValueUSD 10,000 * 80% threshold = 8,000 < 14,000 debt.
        oracle.setPrice(address(weth), 1000e18);
        assertLt(pool.healthFactor(alice), 1e18, "position should be unhealthy before attack");

        // Mallory funds herself to repay Alice's full debt and act as
        // liquidator.
        dai.mint(mallory, 20_000e18);
        vm.prank(mallory);
        dai.approve(address(pool), type(uint256).max);
    }

    function test_RevertWhen_ReenteringLiquidateDuringDebtTransferFrom() public {
        dai.setAttackOnTransferFrom(true);

        vm.prank(mallory);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pool.liquidate(alice);
    }
}

contract LiquidateReentrancy_MaliciousWethTest is Test {
    LendingPool pool;
    MaliciousReentrantWethLiq weth;
    MockDAI dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE); // borrower who gets liquidated
    address bob = address(0xB0B); // honest supplier
    address mallory = address(0xBAD); // attacker acting as liquidator

    function setUp() public {
        weth = new MaliciousReentrantWethLiq();
        dai = new MockDAI();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));
        weth.setPool(address(pool));
        weth.setVictim(alice);

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        dai.mint(bob, 100_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(100_000e18);
        vm.stopPrank();

        // Alice deposits collateral and borrows near the 75% LTV cap
        // (attack flag off — this must succeed cleanly).
        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18);
        vm.stopPrank();

        // Crash the collateral price so health factor drops below 1e18.
        oracle.setPrice(address(weth), 1000e18);
        assertLt(pool.healthFactor(alice), 1e18, "position should be unhealthy before attack");

        // Mallory funds herself to repay Alice's full debt and act as
        // liquidator; the seized collateral push (mWETH) is where this
        // test's attack fires.
        dai.mint(mallory, 20_000e18);
        vm.prank(mallory);
        dai.approve(address(pool), type(uint256).max);
    }

    function test_RevertWhen_ReenteringLiquidateDuringCollateralTransfer() public {
        weth.setAttackOnTransfer(true);

        vm.prank(mallory);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pool.liquidate(alice);
    }
}
