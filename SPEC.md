# Minimal Lending Protocol — Spec

**Purpose:** learn Solidity by building a small Aave/Compound-style lending
protocol. This is explicitly a learning project, not production code — scope
is kept deliberately small so the core mechanics (collateral, interest,
liquidation) are easy to reason about end to end.

**Tooling:** [Foundry](https://book.getfoundry.sh/) (tests written in
Solidity).

---

## 1. Assets

Two fixed mock ERC20 tokens, both 18 decimals:

| Token   | Symbol  | Role                                  |
|---------|---------|----------------------------------------|
| Mock WETH | `mWETH` | Collateral only — deposited, never lent out, earns no interest |
| Mock DAI  | `mDAI`  | Borrow/supply asset — deposited by suppliers, borrowed by borrowers, interest-bearing |

No other assets are supported. There is no asset registry/listing mechanism —
the two tokens are wired in at deploy time.

Both mock tokens are simple ERC20s with a public `mint(address, uint256)` for
test/dev setup (no access control needed on mint since this is not
production).

---

## 2. Roles / Actions

- **Collateral supplier**: deposits `mWETH`, withdraws `mWETH` (if it wouldn't
  make them unsafe), does not earn interest.
- **DAI supplier**: deposits `mDAI` to be lent out, earns interest from
  borrowers (minus reserve factor), withdraws `mDAI` (if enough is not
  currently borrowed out).
- **Borrower**: must have deposited `mWETH` collateral; borrows `mDAI` up to
  their LTV limit; repays `mDAI` + accrued interest; can be liquidated if
  unsafe.
- **Liquidator**: any address; repays a borrower's outstanding `mDAI` debt in
  full and receives that borrower's `mWETH` collateral at a bonus, if the
  borrower's health factor is below 1.
- **Owner** (deployer, via OpenZeppelin `Ownable`): sets risk parameters,
  can pause/unpause the protocol.

A single address may simultaneously be a collateral supplier, a DAI supplier,
and a borrower.

---

## 3. Price Oracle

- A separate `MockPriceOracle` contract stores a price per token:
  `mapping(address token => uint256 price)`, expressed with 18 decimals
  (e.g. `2000e18` = $2000).
- `owner` can call `setPrice(address token, uint256 price)` at any time —
  this is how tests simulate price moves (e.g. crashing `mWETH` price to
  trigger liquidations).
- No staleness checks, no aggregation, no decentralization — this is a
  deliberately unrealistic stand-in for Chainlink, scoped out to keep focus
  on lending mechanics.

---

## 4. Collateral, LTV, and Health Factor

- **LTV = 75%** (7500 in basis points, where 1 bp = 0.01%). Max borrowable
  DAI value at time of borrowing = `collateralValueUSD * 75%`.
- **Liquidation threshold = 80%** (8000 bps). This is the ratio at which a
  position becomes liquidatable — separate from and higher than LTV, giving
  borrowers who max out their LTV a small buffer before a price dip makes
  them liquidatable.
- **Health factor**:

  ```
  healthFactor = (collateralValueUSD * liquidationThreshold) / debtValueUSD
  ```

  (scaled by 1e18 fixed point; healthFactor >= 1e18 means safe.)

  - If the borrower has zero debt, health factor is defined as infinite
    (always safe).
- All borrow-limit and liquidation checks are computed live from current
  oracle prices — there is no stored/cached health factor.

---

## 5. Interest Rate Model

- **Utilization** (of the `mDAI` pool only — `mWETH` is never lent out):

  ```
  utilization = totalDaiBorrowed / totalDaiSupplied
  ```

  (0 if `totalDaiSupplied == 0`.)

- **Kinked rate curve** (Aave-style defaults), giving the **borrow APR**:

  | Parameter            | Value |
  |----------------------|-------|
  | Base rate            | 0%    |
  | Optimal utilization (kink) | 80% |
  | Slope 1 (below kink) | 4%    |
  | Slope 2 (above kink) | 75%   |

  ```
  if utilization <= optimalUtilization:
      borrowRate = baseRate + (utilization / optimalUtilization) * slope1
  else:
      excessUtilization = utilization - optimalUtilization
      excessRange = 1 - optimalUtilization
      borrowRate = baseRate + slope1 + (excessUtilization / excessRange) * slope2
  ```

  At 0% utilization: 0% APR. At 80% utilization: 4% APR. At 100%
  utilization: 79% APR.

- **Reserve factor = 10%**: of the interest actually paid by borrowers, 10%
  accrues to protocol reserves (tracked internally, withdrawable by owner —
  see §8), and 90% flows to `mDAI` suppliers proportional to their share of
  the pool. There is no supply-side APR formula to configure separately — it
  falls out of `borrowRate * utilization * (1 - reserveFactor)`.

- **Supply APR** (derived, not separately configured):

  ```
  supplyRate = borrowRate * utilization * (1 - reserveFactor)
  ```

---

## 6. Interest Accrual

**Why:** updating every borrower's debt on every block is unbounded gas
cost — a single global index tracks cumulative growth instead.

- A single global **borrow index** (starts at `1e18`) tracks cumulative
  interest growth for `mDAI` debt. A parallel **supply index** tracks
  cumulative growth for `mDAI` supplied (net of reserve factor).
- Both indices are updated (compounded) by elapsed time whenever any
  state-changing function is called (deposit, withdraw, borrow, repay,
  liquidate) — via an internal `_accrueInterest()` step run at the top of
  each of those functions.
- Compounding is **per-second**, using `block.timestamp` delta since last
  accrual, applied against the current borrow rate computed from
  utilization at that moment:

  ```
  timeDelta = block.timestamp - lastAccrualTimestamp
  interestFactor = 1 + borrowRate * timeDelta / SECONDS_PER_YEAR
  borrowIndex *= interestFactor
  ```

  (This is a linear approximation per accrual step, not continuous
  compounding — acceptable simplification for a learning project; true
  continuous/APY compounding is a possible stretch goal, not required.)
- Each borrower's stored `principalDebt` (set at time of borrow/last
  interaction) is scaled to current terms as:
  `currentDebt = principalDebt * borrowIndex / userBorrowIndexAtLastUpdate`.
  Same pattern for supplier principal against the supply index.
- `SECONDS_PER_YEAR` is a constant (`365 days`) for APR-to-per-second
  conversion — no leap-year handling needed.

---

## 7. Liquidation

**Why:** liquidation is what keeps the protocol solvent when a position's
collateral no longer safely covers its debt.

- **Trigger**: `healthFactor(borrower) < 1e18`.
- **Scope**: full liquidation only — a liquidator repays 100% of the
  borrower's outstanding `mDAI` debt in one call (no partial/close-factor
  liquidation).
- **Liquidation bonus = 10%**: liquidator receives collateral worth
  `repaidDebtValueUSD * 1.10` (converted to `mWETH` at current oracle
  price), seized from the borrower's deposited collateral.
- **Insufficient collateral case**: if the borrower's collateral is worth
  less than `repaidDebtValueUSD * 1.10`, the liquidator instead receives
  *all* of the borrower's remaining `mWETH` collateral (i.e. seizure is
  capped at the borrower's actual balance). This can leave the protocol
  with unrecovered bad debt — see §9 (explicitly out of scope to solve).
- After liquidation, the borrower's debt is zeroed and their collateral is
  reduced by the seized amount.
- Liquidation is disallowed if the position is currently healthy (health
  factor >= 1e18) — liquidating a safe position must revert.

---

## 8. Core Functions (Interface Sketch)

```solidity
// Collateral (mWETH)
function depositCollateral(uint256 amount) external;
function withdrawCollateral(uint256 amount) external; // must keep health factor >= 1

// Supply (mDAI)
function supply(uint256 amount) external;
function withdrawSupply(uint256 amount) external; // must not exceed available (unborrowed) liquidity

// Borrow (mDAI)
function borrow(uint256 amount) external;  // must keep health factor >= 1 after borrow
function repay(uint256 amount) external;   // amount may exceed debt; excess is capped/refused

// Liquidation
function liquidate(address borrower) external; // repays full debt, seizes collateral + bonus

// Views
function healthFactor(address user) external view returns (uint256);
function getUtilization() external view returns (uint256);
function getBorrowRate() external view returns (uint256);
function getSupplyRate() external view returns (uint256);
```

Standard safety practices applied throughout (not separately configurable):
- Checks-effects-interactions ordering; `nonReentrant` (OpenZeppelin
  `ReentrancyGuard`) on all state-changing external functions.
- `SafeERC20` for all token transfers.
- All state-changing functions call `_accrueInterest()` first.

---

## 9. Admin / Safety Controls

- **Owner** (OpenZeppelin `Ownable`), set at deploy time, can:
  - Update LTV, liquidation threshold, liquidation bonus, reserve factor,
    and rate-curve parameters (base rate, kink, slope1, slope2).
  - Withdraw accumulated protocol reserves (from the reserve factor cut).
  - Pause/unpause the protocol (OpenZeppelin `Pausable`) — while paused,
    deposit/withdraw/borrow/repay/liquidate all revert.
- No timelock, no multisig, no role separation beyond a single owner — not
  realistic for production, acceptable for a learning project.

---

## 10. Explicitly Out of Scope

These are known simplifications/limitations, called out deliberately so they
aren't mistaken for oversights:

- **Bad debt**: if liquidation can't fully cover a borrower's debt (collateral
  price crashed too fast), the shortfall is simply left as unrecovered bad
  debt. No insurance fund, no socialized loss mechanism.
- **Oracle security**: mock oracle, manually set — no decentralization, no
  staleness/freshness checks, no manipulation resistance. Not safe for real
  funds.
- **Multi-asset support**: exactly two fixed tokens; no asset listing,
  no per-asset risk parameters beyond the two described above.
- **Partial liquidation / close factor**: liquidation is all-or-nothing.
- **Flash loans**: not implemented.
- **Governance**: single owner key, no DAO/timelock.
- **Continuous compounding precision**: interest uses linear per-accrual-step
  approximation, not exact continuous compounding.

---

## 11. Testing Plan (Foundry)

Suggested test coverage, to be built alongside the contracts:

- Deposit/withdraw collateral, including withdrawal blocked when it would
  breach health factor.
- Supply/withdraw DAI, including withdrawal blocked when liquidity is
  borrowed out.
- Borrow up to and beyond LTV limit (latter reverts).
- Interest accrual over simulated time (`vm.warp`) at various utilization
  levels, verifying the kinked curve shape (rate at 0%, 80%, 100%
  utilization).
- Health factor calculation across price changes (`MockPriceOracle.setPrice`).
- Liquidation: healthy position liquidation reverts; unhealthy position
  liquidation succeeds with correct bonus payout; liquidation when
  collateral is insufficient to cover bonus (capped seizure).
- Reserve factor split verified via supplier balance growth vs. protocol
  reserve growth.
- Pause blocks all state-changing actions; unpause restores them.
- Owner-only access control on parameter setters.
