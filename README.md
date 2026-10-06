# Lending Protocol

A minimal Aave/Compound-style lending protocol (deposit, borrow,
interest accrual, liquidation), built with [Foundry](https://book.getfoundry.sh/)
to understand core DeFi lending mechanics in depth. Scope was
deliberately kept small — single collateral/borrow pair, no
multi-asset support, no bad-debt backstop — see [Known limitations](#known-limitations)
for the full list and reasoning.

Built using an AI-assisted, checkpoint-driven workflow — see
[CLAUDE.md](CLAUDE.md) and [`.claude/commands/`](.claude/commands/)
for the process, [SPEC.md](SPEC.md) for the full functional spec, and
[PLAN.md](PLAN.md) for the milestone-by-milestone build history.

Two fixed assets: `mWETH` (collateral-only) and `mDAI` (borrow/supply, interest-bearing). Suppliers earn interest on `mDAI`, borrowers post `mWETH` collateral to borrow `mDAI` up to a loan-to-value limit, and undercollateralized positions can be liquidated at a bonus.

> **Also deployed — unchanged — to Arbitrum Sepolia and Base Sepolia (L2s)** for a cross-network case study measuring gas, fees, receipt latency, and timestamp-based accrual: see [L1/L2 Exploration](#l1l2-exploration).

## Architecture

```
LendingPool (Ownable, Pausable, ReentrancyGuard)
  ├── holds: collateralToken (mWETH), daiToken (mDAI) — immutable, wired at deploy time
  ├── reads: MockPriceOracle — owner-settable price feed, per-token
  └── tracks:
        collateralBalance[user]        — mWETH deposited, never lent out
        suppliedBalance[user] + supplyIndex   — mDAI supplied, index-scaled for interest
        principalDebt[user]  + borrowIndex    — mDAI borrowed, index-scaled for interest
        totalDaiSupplied / totalDaiBorrowed / totalReserves — pool-level accounting
```

- **`LendingPool.sol`** — the single core contract. All state-changing entry points (`depositCollateral`, `withdrawCollateral`, `supply`, `withdrawSupply`, `borrow`, `repay`, `liquidate`) share the same shape: accrue interest first, mutate internal state, then move tokens last.
- **`MockPriceOracle.sol`** — a bare owner-settable `mapping(token => price)`. Deliberately has no staleness checks, no aggregation, no manipulation resistance (see Known Limitations).
- **`src/mocks/`** — `MockWETH`/`MockDAI`, plain 18-decimal ERC20s with unrestricted public `mint()` for test/dev setup.

No asset registry: the two tokens are wired in at deploy time and nothing else is supported.

## Key Design Decisions

**LTV (75%) vs. liquidation threshold (80%) are separate parameters.** A borrower maxed out at 75% LTV still has an 80% liquidation threshold, so a small price dip doesn't immediately trigger liquidation — see SPEC.md §4. The gap between the two is the borrower's safety buffer.

**Health factor is always computed live, never cached.** `healthFactor = collateralValueUSD * liquidationThreshold / debtValueUSD`, read fresh from the oracle and current balances on every call (SPEC.md §4). This avoids any window where a stale cached value could be exploited (e.g. borrowing against a health factor that no longer reflects the current price).

**Interest accrues via a global index, not per-user loops.** Instead of updating every borrower's debt on every block (unbounded gas cost as the user count grows), a single global `borrowIndex`/`supplyIndex` compounds over elapsed time, and each user's real balance is their stored principal scaled by how much the index has grown since their last interaction (SPEC.md §6). This is the standard Aave/Compound pattern and the reason `_accrueInterest()` must run first in every state-changing function — everything downstream depends on the index being current.

**Kinked interest rate curve.** Base 0%, kink at 80% utilization, 4% slope below the kink, 75% slope above it (SPEC.md §5). Below the kink, moderate rate growth lets the pool remain usable; above it, the rate spikes sharply to discourage further borrowing and pull utilization back down, protecting supplier withdrawals.

**Reserve factor (10%) taken from interest, not principal.** Of the interest borrowers actually pay, 10% is diverted to protocol reserves (owner-withdrawable) and 90% flows to suppliers — this happens automatically as part of the index math, with no separate supply-rate configuration (SPEC.md §5).

**Liquidation is all-or-nothing, no partial/close-factor.** A liquidator repays 100% of a borrower's debt and receives `repaidDebtValueUSD * 1.10` in collateral, capped at whatever the borrower actually has (SPEC.md §7). This is a deliberate simplification — partial liquidation adds complexity (close factor tuning, multiple liquidation rounds) that isn't the point of this learning project. If collateral can't cover the full bonus, the liquidator still pays the full debt but receives less than 1.10x — the shortfall is accepted as unrecovered bad debt, not socialized across suppliers (SPEC.md §10).

**Oracle is intentionally unrealistic.** No staleness window, no multi-source aggregation, no manipulation resistance — the owner just sets a price directly. This is a deliberate stand-in for Chainlink so tests can simulate price crashes on demand; it is explicitly not meant to be hardened (SPEC.md §3, §10).

## Security Considerations

The test suite (227 tests across 32 files) is organized by vulnerability category as well as by feature, so each concern gets deliberate, isolated coverage rather than being incidentally caught by functional tests:

- **Reentrancy** — every function making an external token transfer (`deposit`/`withdraw`/`supply`/`borrow`/`repay`/`liquidate`/`withdrawReserves`) is checked for checks-effects-interactions ordering (internal state mutated before any transfer) and guarded with OpenZeppelin `ReentrancyGuard`. Tested with malicious ERC20 mocks that attempt to re-enter mid-transfer.
- **Access control** — every risk-parameter setter, reserve withdrawal, and pause/unpause is `onlyOwner`; tested for both authorized success and unauthorized reverts on every single setter.
- **Integer edge cases** — zero collateral, zero debt, zero balances, and large/self-minted values are tested at every division site (health factor, utilization, interest index math) to catch div-by-zero and overflow.
- **Rounding direction** — every multiply/divide is checked for which side it favors. Debt settlement rounds up (borrower's disadvantage), supply settlement rounds down (supplier's disadvantage), liquidation seizure rounds down (never overpays the liquidator) — all protocol-solvency-favoring by design, verified with dedicated rounding-direction tests including fuzz tests.
- **Oracle/price manipulation** — tested for price changes mid-scenario (crash right before liquidation, price recovery before a pending liquidation, zero-price reverts) to confirm nothing caches a stale price.
- **State consistency** — cross-feature invariants (e.g. `totalDaiBorrowed` vs. the sum of individually-settled per-user debts, pool token balance vs. `totalDaiSupplied - totalDaiBorrowed + totalReserves`, collateral token balance vs. sum of per-user collateral) are asserted after individual functions and across full interleaved multi-user, multi-feature lifecycles (accrual + liquidation + reserve withdrawal together), not just in isolation.
- **Full integration scenarios** — end-to-end narrative tests (supplier + borrower + interest accrual + price crash + liquidator, including the bad-debt-capped case) exercise the whole system together rather than one function at a time.
- **Independent review pass** — a from-scratch review against SPEC.md and the CLAUDE.md security rules checklist (CEI ordering, reentrancy guards, access control, pausability, accrual ordering, both health-factor invariants, the liquidity invariant, liquidation correctness, repay-overpayment cap, oracle trust boundary) was run separately from the implementation work. It surfaced one real issue — `withdrawSupply`'s liquidity check could underflow-panic instead of returning a clean revert reason once a pool had run at sustained high utilization long enough for reserves to outpace the supply/borrow gap — which has since been fixed.

Coverage on `LendingPool.sol`: 100% lines, 99.5% statements, 94.4% branches, 100% functions. The remaining uncovered branches are a pool-level liquidity revert path in `borrow()` (real, minor gap — not yet tested independently of the LTV check) and a `healthFactor` revert path in `borrow()` that is provably unreachable as long as LTV ≤ liquidation threshold holds (defensive redundancy, not a gap).

## Known Limitations

These are deliberate simplifications for a learning project, not oversights (SPEC.md §10):

- **Bad debt is not socialized.** If liquidation can't fully cover a borrower's debt, the shortfall is simply left unrecovered — no insurance fund, no socialized loss mechanism.
- **Oracle has no production hardening.** No staleness checks, no decentralization, no manipulation resistance. Not safe for real funds.
- **Exactly two fixed assets**, no asset listing mechanism, no per-asset risk parameters beyond what's described above.
- **Liquidation is all-or-nothing** — no partial liquidation / close factor.
- **No flash loans.**
- **Single-owner governance** — no DAO, no timelock, no multisig.
- **Linear interest approximation**, not exact continuous compounding.
- **Not deployed to mainnet** — public testnets only (Ethereum Sepolia, Arbitrum Sepolia, Base Sepolia); no mainnet deployment has been made or is intended.

## Deployments

All four Ethereum Sepolia contracts below are verified on Etherscan (source-exact match). The same, unchanged contracts were later deployed to Arbitrum Sepolia and Base Sepolia for the cross-network exploration — see [L1/L2 Exploration](#l1l2-exploration) below.

### Ethereum Sepolia (chain id 11155111)

- **LendingPool:** [`0xCAe679dBcDF79D370DFD3D4843294EF54c6E86bA`](https://sepolia.etherscan.io/address/0xCAe679dBcDF79D370DFD3D4843294EF54c6E86bA#code)
- **MockPriceOracle:** [`0x21EaAC185835E2140De97e46Ac10613Dd4f6415A`](https://sepolia.etherscan.io/address/0x21EaAC185835E2140De97e46Ac10613Dd4f6415A#code)
- **mWETH:** [`0x071A1C32c8e0AA04db784066CC4a8e118104E968`](https://sepolia.etherscan.io/address/0x071A1C32c8e0AA04db784066CC4a8e118104E968#code)
- **mDAI:** [`0x4D6aF44f46e929926a569a474aA95C06056e7C1e`](https://sepolia.etherscan.io/address/0x4D6aF44f46e929926a569a474aA95C06056e7C1e#code)

Original deployment metadata: [deployments/sepolia.json](deployments/sepolia.json).

### Arbitrum Sepolia (chain id 421614) & Base Sepolia (chain id 84532)

Fresh deployments of the same unchanged contracts for the L1/L2 exploration. Addresses, transaction hashes, and explorer links are recorded in the exploration metadata:

- [deployments/exploration-sepolia.json](deployments/exploration-sepolia.json)
- [deployments/exploration-arbitrum-sepolia.json](deployments/exploration-arbitrum-sepolia.json)
- [deployments/exploration-base-sepolia.json](deployments/exploration-base-sepolia.json)

## L1/L2 Exploration

The same, **unchanged** contracts were deployed and exercised on **Ethereum Sepolia (L1), Arbitrum Sepolia, and Base Sepolia (L2s)** — measuring deployment and full-lifecycle gas, fees, receipt latency, and block/timestamp progression, plus delayed-interaction interest accrual and oracle-price-driven liquidation. Every number in the write-ups traces back to a recorded transaction hash.

Three artifacts, ordered spec → evidence → interpretation:

1. **[L1_L2_EXPLORATION_SPEC.md](L1_L2_EXPLORATION_SPEC.md)** — the exploration specification: goals and non-goals, measurement protocol, timing vocabulary (receipt vs. settlement vs. finality), trust model, and acceptance criteria.
2. **[L1_L2_EXPLORATION_CASE_STUDY.md](L1_L2_EXPLORATION_CASE_STUDY.md)** — the blog-style case study: method, results-at-a-glance table, what the protocol behavior taught (timestamp-based accrual, liquidation under a crashing oracle, ordering/nonce behavior), what the L2 runs taught, and explicit limitations.
3. **[L1_L2_SECURITY_NOTE.md](L1_L2_SECURITY_NOTE.md)** — the bounded security interpretation: four-part evidence pattern (observation → assumption → risk question → conclusion) covering oracle freshness, delayed repayment, transaction ordering, sequencer delay/censorship as a threat-model question, and receipt-vs-settlement-vs-finality.

Reproduce the cross-network summary from the raw evidence:

```powershell
powershell -ExecutionPolicy Bypass -File exploration/scripts/analyze-cross-network.ps1
```

## Development

```shell
forge build                              # compile
forge test                               # run full suite
forge test -vvvv                         # run with verbose traces (debugging)
forge coverage --report summary          # coverage report
forge fmt                                # format Solidity
forge script script/Deploy.s.sol --rpc-url <url> --private-key <key>  # deploy
```
