# L1/L2 security interpretation note

This is a bounded interpretation of the testnet observations in
[`exploration-cross-network-analysis.md`](deployments/exploration-cross-network-analysis.md).
It is not a production audit and does not claim that testnet behavior is a
network guarantee.

## Scope and evidence boundary

The same existing lending contracts were observed on Ethereum Sepolia,
Arbitrum Sepolia, and Base Sepolia. The experiments exercised timestamp-based
interest accrual, price-driven liquidation, rapid transactions, delayed
interactions, and ordinary supply/borrow/repay lifecycles.

The protocol has no AMM swap deadline in the deployed lending path. Therefore,
this note does not invent a deadline finding. The relevant timing boundary is
the time between an off-chain observation, transaction submission, and block
inclusion.

## Four-part interpretation

### 1. Timestamp-based interest accrual

**Observation.** On Sepolia, three requested 60-second waits produced on-chain
timestamp deltas of 84, 84, and 96 seconds. The `repay(0)` trigger transactions
were `0x77bbfcd2f36d65f66b9849d08834c50815162493b2c4bc4fc8b6ad2415ec6e3c`,
`0x36b5ac740d2947bf35754349df8d1cb6587d9cfd2b3eb4cd4f7716207af06cda`, and
`0x0ff4e9ca0bbc79ca5455b9aafddf63a9541a024aafb65d201c6c90f5eecd3da6`.
Each trigger increased `borrowIndex` and principal debt. Waiting in the local
process alone did not mutate storage.

**Assumption.** The deployed contract intentionally accrues interest when a
state-changing entry point calls `_accrueInterest()`, using the included
block's `block.timestamp`. The timestamp is a block input, not a continuously
updated contract variable.

**Risk question.** Can a timestamp boundary, long inclusion delay, or an
unexpectedly delayed keeper interaction make debt, health-factor, or
liquidation behavior differ from an off-chain preview? Could a deployment
assume timestamp precision that the target chain does not provide?

**Bounded conclusion.** This experiment demonstrates delayed state update and
timestamp-sensitive debt growth. It does not demonstrate timestamp
manipulation, a timestamp exploit, or a universal L1/L2 timestamp rule. An
auditor should test timestamp tolerance and stale-preview handling at the
protocol's actual risk boundaries.

### 2. Delayed repayment and liquidation

**Observation.** After a Sepolia burst, the delayed `repay(0)` landed in block
`11790759`; the observed timestamp moved from `1790480988` to `1790481072`, an
84-second delta, and debt/index values increased only when the transaction was
included. The ordering experiment's burst transactions were all in block
`11790752`, at transaction indices 104, 118, and 125.

**Assumption.** A user, keeper, or liquidator may submit a transaction based on
state that changes before inclusion. The current contract checks health factor
and reads the oracle during execution, rather than trusting a caller-supplied
health factor.

**Risk question.** Does an automation system re-read debt, oracle price, and
health factor after a delay? Can a delayed liquidation become unprofitable,
revert, or compete with repayment? Are off-chain warnings treated as
authoritative when the contract will use newer state at inclusion?

**Bounded conclusion.** The recorded delay is evidence that elapsed time can
change the execution result and interest amount. It is not evidence of a
liquidation bug or of a guaranteed keeper latency. The safe design principle is
to treat previews as provisional and re-check execution-time state.

### 3. Oracle freshness and trust

**Observation.** In the Sepolia liquidation experiment, the WETH price changed
from `2000e18` to `500e18`; health factor changed from `3.2e18` to `0.8e18`,
then liquidation succeeded. The price-change transaction was
`0x0aa935b384e876c976b430c3034f012844c5c2fd0dc278f1db05afe6d6901aaf` and the
liquidation transaction was
`0x30fc62d02c682de8d325ec07042bf94d928bec38a86f2f92f959b501e2a3455a`.

**Assumption.** `MockPriceOracle` is owner-controlled, and the experiment used
the same wallet for borrower, oracle owner, and liquidator. Mock token minting
also has no real market-value constraint.

**Risk question.** In production, is the oracle permissionless or controlled?
How are freshness, decimals, stale answers, sequencer status, and feed
disagreement handled? Can a price update make a position liquidatable without
giving users enough practical time to react?

**Bounded conclusion.** The run validates the existing current-price
health-factor and liquidation mechanics under the mock oracle's trust model.
It is not evidence that a production oracle can be manipulated by an arbitrary
attacker, and it does not model independent liquidator incentives.

### 4. Transaction ordering and nonce behavior

**Observation.** The three burst transactions were canonically ordered by
receipt block and transaction index in the same order they were submitted.
Receipt latencies were 26.242, 26.467, and 24.860 seconds; the delayed call
was 5.784 seconds. An initial attempt exposed an RPC/nonce issue: a duplicate
submission returned `already known`; reserving explicit pending nonces fixed the
runner.

**Assumption.** Local submission order is not authoritative. Contract state is
determined by canonical inclusion order and transaction execution, not by the
order in which a script printed requests.

**Risk question.** Does a keeper or liquidation bot handle replacement,
duplicate, dropped, and reordered transactions? Does it recompute calldata
when a transaction is replaced or delayed?

**Bounded conclusion.** The evidence supports using receipt block number and
transaction index for observed ordering. It does not prove that all future
bursts preserve local submission order, and the `already known` result is an
operational RPC/nonce observation rather than a LendingPool vulnerability.

### 5. Sequencer delay and censorship on L2

**Observation.** Arbitrum Sepolia and Base Sepolia lifecycle transactions
received successful receipts, and the Base runner needed separate submissions
after Forge-batched calls repeatedly hit `ReentrancySentryOOG`. No run
reproduced a sequencer outage, censorship event, or forced transaction delay.

**Assumption.** An L2 normally relies on a sequencer to order and include user
transactions before later publication/settlement processes. A successful
receipt shows inclusion on the observed L2; it does not by itself establish
L1 settlement or finality.

**Risk question.** What happens to repayments, liquidations, oracle updates,
and interest accrual if the sequencer is delayed, censors a transaction, or
temporarily stops accepting transactions? Is there a documented escape hatch
or alternate submission path for time-sensitive operations?

**Bounded conclusion.** These public testnet runs measure normal operation
only. They do not reproduce a sequencer outage, so this project makes no claim
about outage resistance, censorship resistance, or forced-inclusion behavior.
Those are L2 operational threat-model questions, not findings in the existing
LendingPool code.

### 6. Receipt versus settlement/finality

**Observation.** The reports record receipt status, block number, timestamp,
gas, fee, and (for one Sepolia experiment) receipt latency. They do not record
a network-specific settlement or finality proof.

**Assumption.** A receipt means the RPC reported an included transaction with a
status; it is not interchangeable with irreversible settlement across every
network or provider.

**Risk question.** When may an application safely treat a repayment,
liquidation, oracle update, or collateral movement as irreversible? What
confirmation policy and L1-origin/finality signal does the production
deployment require?

**Bounded conclusion.** The project compares receipt speed only. It does not
claim that any measured receipt was final, settled on L1, or immune to a
reorg. A production integration needs a network-specific confirmation policy.

## Protocol findings versus operational questions

No new production-code vulnerability is claimed by these experiments. The
protocol-specific observations are:

- timestamp-based interest is applied on the next accrual-triggering call;
- liquidation uses the current mock-oracle price at execution;
- canonical receipts, not local submission order, establish observed order;
- the existing accounting identity held after the successful lifecycle runs.

The following remain operational or deployment questions rather than findings
against this LendingPool implementation: sequencer outage/censorship,
network-specific finality, production oracle quality, and keeper behavior under
delayed or replaced transactions.

## Reproduction and limitations

Regenerate the cross-network data summary with:

```powershell
powershell -ExecutionPolicy Bypass -File exploration/scripts/analyze-cross-network.ps1
```

The detailed transaction hashes and explorer links are in
[`exploration-cross-network-analysis.json`](deployments/exploration-cross-network-analysis.json).
The Arbitrum/Base lifecycle recorders did not expose provider-specific L2 fee
components. The Sepolia baseline lifecycle is partly preserved in Markdown,
and receipt latency is unavailable for lifecycle records without submission
timestamps. These limitations are intentionally retained rather than filled
with estimates.
