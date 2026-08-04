// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// mWETH/mDAI are plain OZ ERC20s with no transfer hooks, so they can't
// naturally re-enter the pool; this malicious mDAI stand-in calls back into
// the pool from within transfer() to exercise nonReentrant during
// withdrawReserves() — the only new milestone-9 function that makes an
// external call. Mirrors the MaliciousReentrantDai pattern in
// BorrowRepay_Reentrancy.t.sol.
contract MaliciousReentrantDai is ERC20 {
    LendingPool public pool;
    bool public attackOnTransfer;

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

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attackOnTransfer) {
            // withdrawReserves() is mid-flight here; totalReserves has
            // already been decremented (CEI), but the nonReentrant lock is
            // global across the whole contract, so re-entering ANY
            // nonReentrant function — even a permissionless one like
            // borrow() — must still revert.
            pool.borrow(1);
        }
        return super.transfer(to, amount);
    }
}

contract AdminReentrancyTest is Test {
    LendingPool pool;
    MockWETH weth;
    MaliciousReentrantDai dai;
    MockPriceOracle oracle;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address treasury = address(0x7EA5);

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

        dai.mint(bob, 100_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(100_000e18);
        vm.stopPrank();

        vm.prank(alice);
        pool.depositCollateral(10e18);

        // Borrow (attack disabled) so there's outstanding debt to accrue
        // interest on, which is what funds totalReserves.
        vm.prank(alice);
        pool.borrow(8_000e18);

        // Warp forward and let interest accrue via any owner call, so
        // totalReserves > 0 before we exercise withdrawReserves().
        vm.warp(block.timestamp + 365 days);
        pool.setBaseRate(pool.baseRate());

        require(pool.totalReserves() > 0, "test setup: expected accrued reserves");
    }

    function test_RevertWhen_ReenteringDuringWithdrawReservesTransfer() public {
        dai.setAttackOnTransfer(true);

        uint256 amount = pool.totalReserves();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pool.withdrawReserves(treasury, amount);
    }

    function test_WithdrawReservesSucceedsAndUpdatesStateWhenNotAttacked() public {
        // Sanity/CEI check: with the attack disabled, withdrawReserves()
        // behaves normally — totalReserves is decremented and the funds
        // land at the recipient, confirming the state write that happens
        // before the external transfer is correct and not itself the issue.
        uint256 reservesBefore = pool.totalReserves();
        uint256 amount = reservesBefore / 2;

        pool.withdrawReserves(treasury, amount);

        assertEq(pool.totalReserves(), reservesBefore - amount);
        assertEq(dai.balanceOf(treasury), amount);
    }
}
