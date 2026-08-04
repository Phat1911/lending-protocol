// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";

contract LendingPool is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken; // mWETH
    IERC20 public immutable daiToken; // mDAI
    MockPriceOracle public immutable oracle;

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // Sanity ceilings for owner-settable params, well above any realistic
    // value, that keep _accrueInterest()/liquidate()'s arithmetic from
    // overflowing (which would otherwise brick every state-changing call,
    // since they all accrue interest first, including the setters
    // themselves).
    uint256 public constant MAX_RATE_CURVE_PARAM = 100 * WAD; // 10,000% APR
    uint256 public constant MAX_LIQUIDATION_BONUS_BPS = 100_000; // 1,000%

    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public suppliedBalance;
    mapping(address => uint256) public principalDebt;
    uint256 public totalDaiSupplied;
    uint256 public totalDaiBorrowed;
    uint256 public liquidationThreshold = 8000; // 80%, bps
    uint256 public ltv = 7500; // 75%, bps
    uint256 public liquidationBonus = 11000; // 110%, bps (10% bonus over repaid debt value)

    // interest rate curve (WAD-scaled), per SPEC.md §5
    uint256 public baseRate = 0;
    uint256 public optimalUtilization = 0.8e18; // 80% kink
    uint256 public slope1 = 0.04e18; // 4%
    uint256 public slope2 = 0.75e18; // 75%
    uint256 public reserveFactor = 0.10e18; // 10%

    // accrual indices, per SPEC.md §6
    uint256 public borrowIndex = WAD;
    uint256 public supplyIndex = WAD;
    uint256 public lastAccrualTimestamp;
    uint256 public totalReserves;

    mapping(address => uint256) public userBorrowIndex;
    mapping(address => uint256) public userSupplyIndex;

    constructor(address initialOwner, address collateralToken_, address daiToken_, address oracle_)
        Ownable(initialOwner)
    {
        collateralToken = IERC20(collateralToken_);
        daiToken = IERC20(daiToken_);
        oracle = MockPriceOracle(oracle_);
        lastAccrualTimestamp = block.timestamp;
    }

    // ==================== Collateral (mWETH) ====================

    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();
        collateralBalance[msg.sender] += amount;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();
        require(collateralBalance[msg.sender] >= amount, "insufficient collateral");
        collateralBalance[msg.sender] -= amount;
        require(healthFactor(msg.sender) >= 1e18, "unsafe position");
        collateralToken.safeTransfer(msg.sender, amount);
    }

    // ==================== Supply (mDAI) ====================

    function supply(uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();
        _settleSupply(msg.sender);
        suppliedBalance[msg.sender] += amount;
        totalDaiSupplied += amount;
        daiToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawSupply(uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();
        _settleSupply(msg.sender);
        require(suppliedBalance[msg.sender] >= amount, "insufficient supply balance");
        uint256 availableLiquidity = totalDaiBorrowed >= totalDaiSupplied ? 0 : totalDaiSupplied - totalDaiBorrowed;
        require(amount <= availableLiquidity, "insufficient liquidity");
        suppliedBalance[msg.sender] -= amount;
        totalDaiSupplied -= amount;
        daiToken.safeTransfer(msg.sender, amount);
    }

    // ==================== Borrow / Repay (mDAI) ====================

    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();
        require(amount > 0, "zero amount");
        _settleDebt(msg.sender);

        principalDebt[msg.sender] += amount;
        totalDaiBorrowed += amount;
        require(totalDaiBorrowed <= totalDaiSupplied, "insufficient pool liquidity");

        uint256 collateralValueUSD = collateralBalance[msg.sender] * oracle.getPrice(address(collateralToken)) / 1e18;
        uint256 debtValueUSD = principalDebt[msg.sender] * oracle.getPrice(address(daiToken)) / 1e18;

        require(collateralValueUSD * ltv >= debtValueUSD * BPS_DENOMINATOR, "exceeds LTV");
        require(healthFactor(msg.sender) >= 1e18, "unsafe position");

        daiToken.safeTransfer(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();
        _settleDebt(msg.sender);
        uint256 debt = principalDebt[msg.sender];
        uint256 cappedAmount = amount > debt ? debt : amount;

        principalDebt[msg.sender] -= cappedAmount;
        totalDaiBorrowed -= cappedAmount;

        daiToken.safeTransferFrom(msg.sender, address(this), cappedAmount);
    }

    // ==================== Liquidation ====================

    function liquidate(address borrower) external nonReentrant whenNotPaused {
        _accrueInterest();
        _settleDebt(borrower);

        require(healthFactor(borrower) < 1e18, "position is healthy");

        uint256 debt = principalDebt[borrower];
        uint256 daiPrice = oracle.getPrice(address(daiToken));
        uint256 collateralPrice = oracle.getPrice(address(collateralToken));

        require(daiPrice > 0 && collateralPrice > 0, "LendingPool: invalid price");

        uint256 debtValueDai = debt * daiPrice / WAD;
        uint256 seizeDaiValue = debtValueDai * liquidationBonus / BPS_DENOMINATOR;
        uint256 seizeAmount = seizeDaiValue * WAD / collateralPrice;

        if (seizeAmount > collateralBalance[borrower]) {
            seizeAmount = collateralBalance[borrower];
        }

        principalDebt[borrower] = 0;
        totalDaiBorrowed = totalDaiBorrowed > debt ? totalDaiBorrowed - debt : 0;
        collateralBalance[borrower] -= seizeAmount;

        daiToken.safeTransferFrom(msg.sender, address(this), debt);
        collateralToken.safeTransfer(msg.sender, seizeAmount);
    }

    // ==================== Admin / Risk Parameters ====================

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setLtv(uint256 newLtv) external onlyOwner {
        _accrueInterest();
        require(newLtv <= liquidationThreshold, "ltv must be <= liquidation threshold");
        ltv = newLtv;
    }

    function setLiquidationThreshold(uint256 newLiquidationThreshold) external onlyOwner {
        _accrueInterest();
        require(newLiquidationThreshold <= BPS_DENOMINATOR, "threshold exceeds 100%");
        require(newLiquidationThreshold >= ltv, "threshold must be >= ltv");
        liquidationThreshold = newLiquidationThreshold;
    }

    function setLiquidationBonus(uint256 newLiquidationBonus) external onlyOwner {
        _accrueInterest();
        require(newLiquidationBonus >= BPS_DENOMINATOR, "bonus must be >= 100%");
        require(newLiquidationBonus <= MAX_LIQUIDATION_BONUS_BPS, "bonus exceeds sane ceiling");
        liquidationBonus = newLiquidationBonus;
    }

    function setReserveFactor(uint256 newReserveFactor) external onlyOwner {
        _accrueInterest();
        require(newReserveFactor <= WAD, "reserve factor exceeds 100%");
        reserveFactor = newReserveFactor;
    }

    function setBaseRate(uint256 newBaseRate) external onlyOwner {
        _accrueInterest();
        require(newBaseRate <= MAX_RATE_CURVE_PARAM, "rate exceeds sane ceiling");
        baseRate = newBaseRate;
    }

    function setOptimalUtilization(uint256 newOptimalUtilization) external onlyOwner {
        _accrueInterest();
        require(newOptimalUtilization > 0 && newOptimalUtilization < WAD, "optimal utilization out of range");
        optimalUtilization = newOptimalUtilization;
    }

    function setSlope1(uint256 newSlope1) external onlyOwner {
        _accrueInterest();
        require(newSlope1 <= MAX_RATE_CURVE_PARAM, "rate exceeds sane ceiling");
        slope1 = newSlope1;
    }

    function setSlope2(uint256 newSlope2) external onlyOwner {
        _accrueInterest();
        require(newSlope2 <= MAX_RATE_CURVE_PARAM, "rate exceeds sane ceiling");
        slope2 = newSlope2;
    }

    function withdrawReserves(address to, uint256 amount) external onlyOwner nonReentrant {
        _accrueInterest();
        require(amount <= totalReserves, "insufficient reserves");
        totalReserves -= amount;
        daiToken.safeTransfer(to, amount);
    }

    // ==================== Views ====================

    function healthFactor(address user) public view returns (uint256) {
        uint256 debt = _liveDebt(user);
        if (debt == 0) {
            return type(uint256).max;
        }

        uint256 daiValue = oracle.getPrice(address(daiToken));

        require(daiValue > 0, "LendingPool: Invalid DAI price");

        uint256 collateralValueUSD = collateralBalance[user] * oracle.getPrice(address(collateralToken)) / 1e18;
        uint256 debtValueUSD = debt * daiValue / 1e18;

        return (collateralValueUSD * liquidationThreshold * 1e18) / (BPS_DENOMINATOR * debtValueUSD);
    }

    function getUtilization() public view returns (uint256) {
        if (totalDaiSupplied == 0) {
            return 0;
        }
        return totalDaiBorrowed * WAD / totalDaiSupplied;
    }

    function getBorrowRate() public view returns (uint256) {
        uint256 utilization = getUtilization();
        if (utilization <= optimalUtilization) {
            return baseRate + (utilization * slope1) / optimalUtilization;
        }
        uint256 excessUtilization = utilization - optimalUtilization;
        uint256 excessRange = WAD - optimalUtilization;
        return baseRate + slope1 + (excessUtilization * slope2) / excessRange;
    }

    function getSupplyRate() public view returns (uint256) {
        uint256 borrowRate = getBorrowRate();
        uint256 utilization = getUtilization();
        return (borrowRate * utilization * (WAD - reserveFactor)) / WAD / WAD;
    }

    // ==================== Internal / Accrual Helpers ====================

    function _accrueInterest() internal {
        uint256 timeDelta = block.timestamp - lastAccrualTimestamp;
        if (timeDelta == 0) {
            return;
        }

        if (totalDaiBorrowed > 0) {
            uint256 borrowRateNow = getBorrowRate();
            uint256 interestFactor = WAD + (borrowRateNow * timeDelta) / SECONDS_PER_YEAR;
            uint256 newBorrowIndex = borrowIndex * interestFactor / WAD;

            uint256 interestAccrued = _mulDivUp(totalDaiBorrowed, newBorrowIndex - borrowIndex, borrowIndex);
            borrowIndex = newBorrowIndex;
            totalDaiBorrowed += interestAccrued;

            uint256 reserveCut = interestAccrued * reserveFactor / WAD;
            uint256 supplyCut = interestAccrued - reserveCut;
            totalReserves += reserveCut;

            if (totalDaiSupplied > 0) {
                supplyIndex = supplyIndex * (totalDaiSupplied + supplyCut) / totalDaiSupplied;
            }
            totalDaiSupplied += supplyCut;
        }

        lastAccrualTimestamp = block.timestamp;
    }

    function _settleDebt(address user) internal {
        if (principalDebt[user] > 0) {
            principalDebt[user] = _mulDivUp(principalDebt[user], borrowIndex, userBorrowIndex[user]);
        }
        userBorrowIndex[user] = borrowIndex;
    }

    function _settleSupply(address user) internal {
        if (suppliedBalance[user] > 0) {
            suppliedBalance[user] = suppliedBalance[user] * supplyIndex / userSupplyIndex[user];
        }
        userSupplyIndex[user] = supplyIndex;
    }

    function _liveDebt(address user) internal view returns (uint256) {
        uint256 principal = principalDebt[user];
        if (principal == 0) {
            return 0;
        }
        return _mulDivUp(principal, borrowIndex, userBorrowIndex[user]);
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y + denominator - 1) / denominator;
    }
}
