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
// the pool from within transfer()/transferFrom() to exercise nonReentrant.
contract MaliciousReentrantDai is ERC20 {
    LendingPool public pool;
    bool public attackOnTransfer;
    bool public attackOnTransferFrom;

    constructor() ERC20("Malicious DAI", "mDAI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPool(address pool_) external {
        pool = LendingPool(pool_);
    }

    function setAttackOnTransfer(bool on) external {
        attackOnTransfer = on;
    }

    function setAttackOnTransferFrom(bool on) external {
        attackOnTransferFrom = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attackOnTransfer) {
            // borrow() is mid-flight here; state is already updated but the
            // nonReentrant lock must still be held, so this must revert.
            pool.borrow(1);
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (attackOnTransferFrom) {
            // repay() pulls funds via transferFrom; reentering here must
            // also revert since the guard covers the whole call.
            pool.repay(1);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract BorrowRepayReentrancyTest is Test {
    LendingPool pool;
    MockWETH weth;
    MaliciousReentrantDai dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        dai = new MaliciousReentrantDai();
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(weth), address(dai), address(oracle));
        dai.setPool(address(pool));

        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(dai), 1e18);

        weth.mint(alice, 100e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);

        // Fund the pool via supply() (not a direct mint) so totalDaiSupplied
        // tracks the liquidity that's actually available to borrow(), per the
        // pool-wide liquidity check added after the milestone-7 attack review.
        dai.mint(bob, 100_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(100_000e18);
        vm.stopPrank();

        vm.prank(alice);
        pool.depositCollateral(10e18);
    }

    function test_RevertWhen_ReenteringBorrowDuringBorrowTransfer() public {
        dai.setAttackOnTransfer(true);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pool.borrow(8_000e18);
    }

    function test_RevertWhen_ReenteringRepayDuringRepayTransferFrom() public {
        // Borrow first (attack disabled) so alice has outstanding debt to repay.
        vm.prank(alice);
        pool.borrow(8_000e18);

        dai.mint(alice, 1_000e18);
        vm.prank(alice);
        dai.approve(address(pool), type(uint256).max);

        dai.setAttackOnTransferFrom(true);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pool.repay(1_000e18);
    }
}
