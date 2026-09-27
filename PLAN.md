# Implementation Plan: Minimal Lending Protocol

## Context

The repo started with only `SPEC.md` and `CLAUDE.md` — no code. This is a
learning project: the goal isn't to reach a working contract fastest, but to
sequence the work so that **boilerplate/plumbing is separated from the
genuinely hard mechanics** (health factor, interest accrual, rate curve,
liquidation math), so each hard part can be understood in isolation rather
than absorbed as one big blob alongside CRUD-style bookkeeping.

Each milestone is small enough for a single focused session, and is
compilable/testable on its own before moving to the next. The first
milestone is deliberately trivial — its only purpose is to get comfortable
with the `forge build` / `forge test` loop before any real logic appears.

## Progress

- [x] 1. Scaffold + trivial mock tokens — *supporting/boilerplate*
- [x] 2. MockPriceOracle + deploy script — *supporting/boilerplate*
- [x] 3. LendingPool skeleton — collateral deposit/withdraw only — *supporting/boilerplate*
- [x] 4. mDAI supply/withdraw bookkeeping (no interest yet) — *supporting/boilerplate*
- [x] 5. Health factor as an isolated pure view — **core logic**
- [x] 6. Borrow / repay wired to the health-factor gate — **core logic**
- [x] 7. Interest rate model + accrual index math — **core logic** (hardest)
- [x] 8. Liquidation, including the bad-debt-capped seizure case — **core logic**
- [x] 9. Admin controls + hardening pass — *supporting/boilerplate*
- [x] 10. Full integration pass against SPEC.md §11 — *supporting/boilerplate*

## Milestones

### 1. Scaffold + trivial mock tokens
**Label:** supporting/boilerplate

- Run `forge init`, install `openzeppelin-contracts` and confirm `forge-std`
  is present; set up `foundry.toml` (remappings, solc version).
- Create `src/mocks/MockWETH.sol` and `src/mocks/MockDAI.sol`: plain 18-decimal
  ERC20s (OZ `ERC20`) with a public, unrestricted `mint(address, uint256)`.
  *(Context: these mirror real WETH — "Wrapped ETH", an ERC20-wrapped version
  of ETH, used here as the volatile collateral asset — and real DAI, a
  USD-pegged stablecoin, used here as the stable borrow/supply asset. The
  mocks don't track real prices; they just play those two roles.)*
- Write `test/MockTokens.t.sol`: mint some tokens to a test address, assert
  `balanceOf` — nothing more.
- **Why first:** zero protocol logic, pure scaffolding — establishes the
  write/build/test loop.
- **Done when:** `forge test` passes on the mint/balance test.

### 2. MockPriceOracle + deploy script
**Label:** supporting/boilerplate

- Create `src/MockPriceOracle.sol`: `mapping(address => uint256) prices`,
  `onlyOwner setPrice(address token, uint256 price)`, `getPrice(address)` view.
  Use OZ `Ownable`.
- Create `script/Deploy.s.sol`: deploys MockWETH, MockDAI, MockPriceOracle,
  sets initial prices (e.g. mWETH = 2000e18, mDAI = 1e18).
- Write `test/MockPriceOracle.t.sol`: owner can set/get price; non-owner
  `setPrice` reverts.
- **Why here:** the oracle is a dependency of the health factor (milestone 5)
  and is trivial enough to knock out before real protocol logic starts.
- **Done when:** deploy script runs via `forge script`, oracle tests pass.

### 3. LendingPool skeleton — collateral deposit/withdraw only
**Label:** supporting/boilerplate

- Create `src/LendingPool.sol`, wired to mWETH/mDAI/oracle addresses (owner,
  Ownable + Pausable + ReentrancyGuard from the start, per CLAUDE.md).
- Implement `depositCollateral` / `withdrawCollateral` with **no health-factor
  gate yet** (or a placeholder that always allows withdrawal) — just track
  per-user `collateralBalance[user]` and move tokens via `SafeERC20`.
  `nonReentrant` + `whenNotPaused` on both, even though `_accrueInterest()`
  is a no-op stub at this point.
- Write `test/Collateral.t.sol`: deposit increases the user's tracked
  `collateralBalance[user]` *and* the LendingPool contract's actual mWETH
  token balance (confirms the real transfer happened, not just the internal
  mapping); withdraw decreases both; withdrawing more than deposited reverts.
  (This mapping is unrelated to mDAI supply accounting — mWETH collateral and
  mDAI supply are separate pools that never touch each other, per §1.)
- **Why here:** establishes the CEI pattern, SafeERC20 usage, and per-user
  balance bookkeeping pattern that supply/borrow will reuse — without yet
  needing the health factor.
- **Done when:** collateral deposit/withdraw tests pass.

### 4. mDAI supply/withdraw bookkeeping (no interest yet)
**Label:** supporting/boilerplate

- Add `supply` / `withdrawSupply` to `LendingPool.sol`: track
  `suppliedBalance[user]` and `totalDaiSupplied`, move mDAI via SafeERC20.
- Enforce the liquidity invariant: `withdrawSupply` reverts if amount exceeds
  currently-unborrowed liquidity (`totalDaiSupplied - totalDaiBorrowed`,
  with `totalDaiBorrowed` at 0 for now since borrow doesn't exist yet).
- Write `test/Supply.t.sol`: supply/withdraw balance tracking; withdraw
  blocked once (in a later milestone) liquidity is borrowed out — stub this
  assertion for now or defer it to milestone 6.
- **Why here:** same bookkeeping shape as collateral, done before the harder
  borrow-side logic needs it as a dependency.
- **Done when:** supply/withdraw tests pass, including the always-available
  case.

### 5. Health factor as an isolated pure view
**Label:** core logic — understand deeply

- Implement `healthFactor(address user) public view returns (uint256)` per
  §4: `(collateralValueUSD * liquidationThreshold) / debtValueUSD`, scaled
  1e18, using live oracle prices and current collateral/debt balances.
  Zero debt → return `type(uint256).max` (infinite/safe sentinel).
- At this point `debtValueUSD` will just read a `principalDebt` field with no
  index-scaling yet (borrow doesn't exist until milestone 6) — implement the
  formula shape correctly so wiring in real debt later is a non-event.
- Write `test/HealthFactor.t.sol` directly against the view function: set
  known collateral amount + a manually-set debt (via an internal test
  setter/harness, or just test the formula with 0 debt first), sweep oracle
  price via `setPrice` and assert the health factor moves as expected.
- **Why isolated:** this is the first genuinely hard formula (fixed-point
  math, USD value conversion, the 1e18 infinite-debt edge case) — testing it
  standalone, before it's a gate blocking borrow/withdraw, makes it easy to
  reason about in isolation.
- **Done when:** health factor tests pass across a range of collateral/debt/
  price combinations, including the zero-debt case.

### 6. Borrow / repay wired to the health-factor gate
**Label:** core logic — understand deeply

- Implement `borrow(uint256 amount)`: checks LTV (75%) at time of borrow
  against live collateral value, increases `principalDebt[user]` and
  `totalDaiBorrowed`, transfers mDAI out. Must keep health factor `>= 1e18`
  after the borrow (reverts otherwise).
- Implement `repay(uint256 amount)`: caps `amount` at outstanding debt (no
  overpayment left as negative debt), decreases `principalDebt[user]` and
  `totalDaiBorrowed`, transfers mDAI in.
- Wire `withdrawCollateral`'s real health-factor gate (replacing the
  milestone-3 placeholder): must keep health factor `>= 1e18` after
  withdrawal.
- Also now enforce `withdrawSupply`'s liquidity invariant for real (borrowed
  liquidity is nonzero).
- Write `test/BorrowRepay.t.sol`: borrow up to LTV succeeds, one wei over
  reverts; repay reduces debt correctly; overpaying repay is capped, not
  reverted with leftover debt; withdrawCollateral blocked when it would
  breach health factor; withdrawSupply blocked when liquidity is borrowed out.
- **Why here, why isolated:** this is where health factor becomes a live gate
  on three different code paths (borrow, withdrawCollateral, and indirectly
  withdrawSupply's liquidity check) — worth its own focused session before
  interest accrual complicates the debt numbers.
- **Done when:** all borrow/repay/gated-withdrawal tests pass.

### 7. Interest rate model + accrual index math
**Label:** core logic — understand deeply (likely the hardest milestone)

- Implement `getUtilization()`, `getBorrowRate()` (kinked curve: base 0%,
  kink 80%, slope1 4%, slope2 75%, per §5), `getSupplyRate()` (derived).
- Implement `_accrueInterest()`: global `borrowIndex`/`supplyIndex` (both
  start `1e18`), per-second linear compounding since `lastAccrualTimestamp`
  using the current borrow rate, per §6. Call it first in every
  state-changing function (deposit/withdraw/supply/borrow/repay — liquidate
  comes next milestone).
- Switch `principalDebt`/`suppliedBalance` bookkeeping to be index-scaled:
  store principal + the index value at last user interaction, compute live
  balance as `principal * currentIndex / userIndexAtLastUpdate` (both for
  debt and for supply, net of reserve factor for supply).
- Reserve factor (10%) split: track protocol reserves separately from
  supplier-accruing interest.
- Write `test/InterestAccrual.t.sol`: assert borrow rate at 0%/80%/100%
  utilization matches the spec's worked examples (0%, 4%, 79% APR); use
  `vm.warp` to simulate elapsed time and verify debt/supply balances grow
  correctly; verify reserve factor split (supplier growth vs. reserve
  growth) matches 90/10.
- **Why isolated and why last among the "gating" logic:** this is the
  hardest math in the spec (kinked curve, index-based compounding, reserve
  split) and it changes how debt/supply balances are read everywhere else —
  doing it only after borrow/repay/health-factor already work with flat
  balances means this milestone is purely about the interest math, not
  simultaneously debugging borrow logic.
- **Done when:** rate-curve and accrual tests pass, including the 0/80/100%
  utilization checkpoints and the reserve-split assertion.

### 8. Liquidation, including the bad-debt-capped seizure case
**Label:** core logic — understand deeply

- Implement `liquidate(address borrower)`: reverts if `healthFactor(borrower)
  >= 1e18`; otherwise liquidator repays 100% of the borrower's current
  (index-scaled) debt, receives `repaidDebtValueUSD * 1.10` worth of mWETH
  at current oracle price; borrower's debt zeroed, collateral reduced by
  seized amount.
- Implement the insufficient-collateral edge case: if borrower's collateral
  value < `repaidDebtValueUSD * 1.10`, cap seizure at the borrower's actual
  mWETH balance (bad debt accepted, not socialized — no extra mechanism).
- Write `test/Liquidation.t.sol`: liquidating a healthy position reverts;
  liquidating an unhealthy position succeeds with correct 10% bonus payout
  and correct debt zeroing; liquidating when collateral can't cover the full
  bonus results in capped seizure (all remaining collateral, debt still
  zeroed, bad debt implicitly left).
- **Why here:** depends on both the health factor (milestone 5) and
  index-scaled debt (milestone 7) being correct, so it has to come after
  both; the capped-seizure edge case is subtle enough to deserve its own
  focused test pass.
- **Done when:** all three liquidation scenarios (revert-when-healthy,
  normal bonus payout, capped seizure) pass.

### 9. Admin controls + hardening pass
**Label:** supporting/boilerplate

- Add `onlyOwner` setters for LTV, liquidation threshold, liquidation bonus,
  reserve factor, and rate-curve params (base/kink/slope1/slope2).
- Add owner-only reserve withdrawal (draws from tracked protocol reserves).
- Wire `Pausable`: `whenNotPaused` on deposit/withdraw/supply/withdrawSupply/
  borrow/repay/liquidate; owner `pause()`/`unpause()`.
- Sweep pass: confirm every state-changing external function has
  `nonReentrant`, calls `_accrueInterest()` first, and respects
  `whenNotPaused`, per CLAUDE.md's rules section.
- Write `test/Admin.t.sol`: non-owner reverts on every setter and on pause/
  unpause; pause blocks all seven state-changing functions; unpause restores
  them; parameter changes take effect on subsequent calls.
- **Why here:** these are cross-cutting concerns best applied once all the
  functions they wrap already exist and are individually correct.
- **Done when:** admin/access-control/pause tests pass.

### 10. Full integration pass against SPEC.md §11
**Label:** supporting/boilerplate

- Write `test/Integration.t.sol` (or extend existing files) covering any
  gaps against the §11 checklist not already exercised end-to-end: a full
  multi-user scenario (supplier + borrower + price crash + liquidator) in
  one test; confirm all §11 bullets have at least one corresponding test.
- Do a final read-through of `LendingPool.sol` against CLAUDE.md's Rules
  section as a checklist (CEI ordering, reentrancy guards, access control,
  pausability, accrual ordering, both health-factor invariants, liquidity
  invariant, liquidation correctness, repay overpayment cap, oracle trust
  boundary) — fix anything missed.
- **Why last:** validates the whole system together and catches any
  cross-milestone integration gaps (e.g. a rule from CLAUDE.md that was
  correct in isolation per-milestone but drifted when combined).
- **Done when:** full test suite passes and every §11 bullet and every
  CLAUDE.md rule has a corresponding passing test.

## Verification

After each milestone: `forge build` then `forge test -vv` (or `-vvvv` when
debugging a specific failing case) scoped to that milestone's new test file.
After milestone 10, run the full suite (`forge test`) and confirm coverage
against SPEC.md §11 line by line.

---

# L1/L2 Exploration Milestones

This section implements `L1_L2_EXPLORATION_SPEC.md`. The original milestones
above describe the lending protocol itself and remain unchanged. These new
milestones start with the smallest useful exploration increment: a local,
non-secret measurement skeleton that can be validated before spending testnet
funds.

## 11. Exploration scaffold, configuration, and measurement schema
**Label:** supporting/boilerplate — quick review

- Add the exploration area described in the L1/L2 specification, with a
  network registry for Sepolia, Arbitrum Sepolia, and Base Sepolia.
- Add environment-variable validation for RPC URLs and the dedicated testnet
  private key; fail clearly when required values are missing.
- Define the machine-readable transaction/deployment record schema: network,
  chain ID, scenario, run, hash, block, on-chain timestamp, wall-clock
  timestamps, status, gas, fee fields, explorer URL, and error notes.
- Add a dry-run or local validation path that checks configuration and writes a
  sample record without broadcasting a transaction.
- Do not add any deadline probe or modify production contracts.

**Done when:** the scaffold validates locally, refuses missing secrets, emits a
schema-valid sample record, and no private key or RPC credential is written to
the repository.

## 12. Fresh deployment harness on Sepolia
**Label:** supporting/boilerplate — quick review

- Reuse the existing four contracts and deployment constructor arguments.
- Add a harness command that deploys fresh copies to Sepolia and records each
  address, deployment transaction hash, receipt data, block number, block
  timestamp, gas, fee, and explorer URL.
- Record the deployer/owner address publicly, but never record the private key.
- Make the output suitable for later reuse by interaction scripts.

**Done when:** all four contracts deploy successfully on Sepolia, the recorded
metadata can be used to reconnect to them, and the existing local build/tests
still pass.

## 13. Sepolia baseline lifecycle and invariant checks
**Label:** core logic — deep checkpoint

- Run the existing protocol through supply, collateral deposit, borrow, and repay using the deployed contracts.
- Record every state-changing transaction with the standard schema.
- Read balances, debt, indexes, reserves, health factor, and pool token balances before and after the lifecycle.
- Confirm that the harness is observing the existing contract behavior rather
  than recreating it in off-chain calculations.

**Invariant/security property:** the lifecycle must preserve the protocol’s
  accounting identity—pool DAI balance must match tracked supplied liquidity
  minus borrowed liquidity plus tracked reserves, subject to the contract’s
  documented token-flow semantics. Repayment must not increase a user’s debt,
  and no successful transaction may silently change owner/oracle authority.

**Done when:** one complete Sepolia lifecycle is reproducible from recorded
  addresses and all post-transaction accounting assertions pass.

## 14. Real-time timestamp and interest-accrual experiment
**Label:** core logic — deep checkpoint

- Establish a borrower position on Sepolia.
- Record `block.timestamp`, `block.number`, `lastAccrualTimestamp`,
  `borrowIndex`, and live debt.
- Wait using real wall-clock time; do not use `vm.warp` in the live script.
- Trigger accrual through `repay()` or another existing state-changing entry
  point, then record the same values again.
- Run the ordinary interaction three times where practical and report elapsed wall-clock time versus on-chain timestamp delta.

**Invariant/security property:** interest must be applied once to the elapsed
  timestamp interval when the next accrual-triggering call occurs. The
  `borrowIndex` and `lastAccrualTimestamp` must not decrease, and a read-only
  observation must not mutate state. The write-up must distinguish delayed
  state update from continuous off-chain time passage.

**Done when:** the measured result demonstrates whether and how the deployed
  contract’s debt/index changes after real elapsed time, with transaction
  hashes and before/after state evidence.

**Observed completion (Sepolia, 2026-09-27):** three sequential 60-second
wall-clock waits produced on-chain timestamp deltas of 84, 84, and 96 seconds.
All three successful `repay(0)` triggers increased both `borrowIndex` and
principal debt. The corresponding trigger hashes are
`0x77bbfcd2f36d65f66b9849d08834c50815162493b2c4bc4fc8b6ad2415ec6e3c`,
`0x36b5ac740d2947bf35754349df8d1cb6587d9cfd2b3eb4cd4f7716207af06cda`, and
`0x0ff4e9ca0bbc79ca5455b9aafddf63a9541a024aafb65d201c6c90f5eecd3da6`.
Full machine-readable evidence is stored locally in
`deployments/exploration-sepolia-timestamp-results.json`.

## 15. Oracle-price and liquidation experiment
**Label:** core logic — deep checkpoint

- Set up a funded supplier, borrower, collateral position, and liquidator
  using the existing mock tokens and owner-controlled mock oracle.
- Record the healthy position and oracle prices.
- Change the oracle price, record the transaction, then observe health factor
  and liquidation behavior.
- Execute a successful liquidation where possible and record debt, collateral,
  bonus, reserves, and token balances before and after.
- Label the owner-controlled oracle as a trust assumption in every result.

**Invariant/security property:** a healthy position must not be liquidated; an
  unhealthy position may be liquidated according to the existing contract’s
  current-price and debt/accounting rules; liquidation must not seize more
  collateral than the borrower owns or leave accounting inconsistent. The
  experiment must not imply that the mock oracle models a production feed.

**Done when:** the price-change and liquidation path is evidenced by on-chain
  transactions and the result is categorized as protocol behavior plus trust
  boundary, not as an unqualified oracle-manipulation finding.

**Implementation status:** the role-separated Sepolia harness is implemented
in `ExplorationOracleLiquidation.s.sol` and
`run-sepolia-oracle-liquidation.ps1`. Milestone 15 remains open until its
on-chain run produces the evidence described above.

**Observed completion (Sepolia, 2026-09-27):** a fresh deployment used the
same wallet as borrower, oracle owner, and liquidator. At WETH price `2000e18`,
the position had `1e18` collateral, `500e18` debt, and health factor `3.2e18`.
The owner then changed the mock WETH price to `500e18` in transaction
`0x0aa935b384e876c976b430c3034f012844c5c2fd0dc278f1db05afe6d6901aaf`;
the observed health factor became `0.8e18`. Liquidation succeeded in
transaction `0x30fc62d02c682de8d325ec07042bf94d928bec38a86f2f92f959b501e2a3455a`,
leaving zero debt, zero collateral, zero total borrowed, and a protocol
reserve balance of `4280821917800` wei. The liquidation used `165158` gas.
The price change used `29591` gas. Full evidence is in the local ignored file
`deployments/exploration-sepolia-oracle-liquidation-results.json`.

This demonstrates the existing current-price liquidation behavior and the
mock oracle's trust boundary; it is not evidence that a production oracle can
be manipulated in the same way. Because all three roles were the same wallet,
the run demonstrates mechanics rather than independent-liquidator incentives.

## 16. Rapid-transaction and delayed-interaction observations
**Label:** core logic — deep checkpoint

- Submit several compatible transactions close together on Sepolia and record
  their block numbers, timestamps, receipts, and ordering.
- Run one deliberately delayed interaction after the borrower has accrued debt.
- Compare transaction submission order with inclusion order and compare wall
  clock delay with on-chain timestamp delta.
- Document any RPC retries, pending periods, replacement transactions, or
  failed calls rather than hiding them.

**Invariant/security property:** transaction ordering must be reported from
  canonical receipts, not assumed from local submission order. Delayed
  interaction must not cause the analysis to double-count elapsed time or call
  a receipt equivalent to finality. Any conclusion about timestamp safety must
  remain bounded by the observed testnet evidence.

**Done when:** the data shows how close submissions and delayed calls appeared
  in actual blocks and the write-up clearly separates receipt speed from
  settlement/finality.

## 17. Replicate the deployment and scenario harness on Arbitrum Sepolia
**Label:** supporting/boilerplate — quick review

- Deploy fresh copies of the same four contracts to Arbitrum Sepolia.
- Reuse the same scenario inputs and recorder used on Sepolia.
- Confirm chain ID, addresses, owner, oracle, token wiring, and explorer links.
- Run at least one complete scenario and three ordinary repeats where
  practical; record blocked or unavailable operations explicitly.

**Done when:** Arbitrum Sepolia has traceable deployment metadata and enough
  records to compare the same contract calls with Sepolia.

## 18. Replicate the deployment and scenario harness on Base Sepolia
**Label:** supporting/boilerplate — quick review

- Deploy fresh copies of the same four contracts to Base Sepolia.
- Reuse the same scenario inputs, recorder, and assertions.
- Confirm chain ID, addresses, owner, oracle, token wiring, and explorer links.
- Run at least one complete scenario and three ordinary repeats where
  practical; record blocked or unavailable operations explicitly.

**Done when:** Base Sepolia has traceable deployment metadata and enough
  records to compare the same contract calls with both Sepolia and Arbitrum
  Sepolia.

## 19. Cross-network fee, timing, and block-behavior analysis
**Label:** core logic — deep checkpoint

- Aggregate raw records by network, scenario, and run.
- Report `gasUsed`, `effectiveGasPrice`, total fee, and exposed L2 fee
  components separately.
- Report receipt latency using median and observed range for three-run groups.
- Compare block-number and timestamp progression without assuming that an L2
  block number has the same meaning or cadence as an L1 block number.
- Add settlement/finality observations only when a reliable network-specific source exists; otherwise document the limitation.

**Invariant/security property:** every summary row must be traceable to a
  transaction hash and must not conflate gas used with total fee, receipt with
  finality, or one network’s block-number semantics with another’s. Missing or
  failed observations must remain visible in the dataset.

**Done when:** a reviewer can reproduce each headline number from raw records,
  and the comparison makes no unsupported universal claim from the sample.

## 20. Security interpretation and sequencer threat-model note
**Label:** core logic — deep checkpoint

- Apply the specification’s four-part pattern to each result: observation, assumption, risk question, and bounded conclusion.
- Analyze timestamp-based accrual, delayed repayment/liquidation, oracle freshness/trust, transaction ordering, sequencer delay/censorship, and the receipt-versus-finality distinction.
- Explicitly state that a public testnet run does not reproduce a sequencer
  outage unless a safe reproducible method was actually used.
- Separate findings about this LendingPool from general L2 operational risks.

**Invariant/security property:** the final security claims must preserve the
  trust model and evidence boundary: owner-controlled mock-oracle behavior is
  a stated assumption, not silently treated as permissionless oracle failure;
  observed latency is not presented as a protocol guarantee; and no conclusion
  claims more than the recorded transactions establish.

**Done when:** each major security statement has supporting transaction/data
  references or is explicitly labeled as a threat-model question or limitation.

## 21. Portfolio artifact and final verification
**Label:** supporting/boilerplate — quick review

- Write the 1,200–1,800 word recruiter-facing case study.
- Include the experiment question, networks, method, compact results table,
  timestamp/block observations, gas/fee comparison, latency statistics,
  receipt-versus-settlement/finality distinction, security observations,
  trust assumptions, limitations, and reproduction links.
- Add or update exploration README instructions for a fresh user.
- Confirm no secrets are tracked, raw data is present, and existing Foundry tests still pass.
- Record unavailable networks, failed runs, skipped repeats, and measurement limitations honestly.

**Done when:** the repository and write-up satisfy every acceptance criterion in
  `L1_L2_EXPLORATION_SPEC.md` and a recruiter can understand the result without
  mistaking it for a production audit or a universal L1/L2 performance claim.
