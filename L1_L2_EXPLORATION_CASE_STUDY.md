# What changes when the same lending protocol runs on an L1 and two L2s?

## The question

I wanted to understand Ethereum Layer 1 versus Layer 2 behavior at the point
where it matters to a smart-contract auditor: not by copying another diagram
of rollups, but by deploying the same contracts and watching real transactions
execute. I reused the existing lending protocol in this repository without
rewriting its core logic. The protocol has mock WETH collateral, mock DAI,
an owner-controlled price oracle, health-factor checks, interest accrual, and
liquidation.

The experiment covered Ethereum Sepolia as the L1 reference, Arbitrum Sepolia,
and Base Sepolia as L2 environments. The goal was not to rank networks or
produce a performance guarantee. It was to learn which observations are about
the LendingPool itself, which are provider or network observations, and which
questions require a production threat model rather than a small public-testnet
sample.

Repository: [github.com/Phat1911/lending-protocol](https://github.com/Phat1911/lending-protocol)

## Method

I deployed fresh copies of MockWETH, MockDAI, MockPriceOracle, and LendingPool
on each network. Every deployment record includes the chain ID, contract
addresses, transaction hashes, block information, gas, fees, and explorer
links. The public deployer address is recorded; private keys and RPC URLs stay
local.

I then exercised four kinds of behavior:

1. A supply → collateral deposit → borrow → repay lifecycle.
2. Real wall-clock waits followed by `repay(0)`, which triggers the existing
   `_accrueInterest()` path without transferring DAI.
3. An owner-controlled mock-oracle price change followed by liquidation.
4. Three close Sepolia transactions plus a deliberately delayed interaction,
   with both local submission order and canonical receipt order recorded.

The analysis script aggregates the raw records by network, scenario, and run.
It keeps `gasUsed`, `effectiveGasPriceWei`, and `totalFeeWei` separate. Where
submission and receipt timestamps exist, it calculates receipt latency. It does
not call a receipt finality, and it does not infer L1 settlement from an L2
receipt.

## Results at a glance

| Network | Scenario evidence | Fee/receipt observation |
|---|---|---|
| Sepolia (chain 11155111) | Deployment, timestamp accrual, liquidation, ordering/delay | Deployment used 5,718,162 gas and 6,114,059,507,888,110 wei. The Sepolia ordering sample had median receipt latency 25.551 s, range 5.784–26.467 s. |
| Arbitrum Sepolia (chain 421614) | Deployment plus three nine-transaction lifecycle runs | Lifecycle gas totals were 769,142, 562,115, and 562,113. Fees were 24,155,106,295,142; 17,671,918,002,115; and 17,634,477,252,113 wei. Provider-specific L2 fee components were not exposed. |
| Base Sepolia (chain 84532) | Deployment plus three nine-transaction lifecycle runs | Lifecycle gas totals were 568,273, 553,973, and 553,973. Fees were 3,409,638,000,000; 3,323,838,000,000; and 3,323,838,000,000 wei. Provider-specific L2 fee components were not exposed. |

These are observations from particular testnet runs, not a claim that Arbitrum
is always cheaper, Base is always faster, or an L2 block number is comparable
to an L1 block number. The L2 lifecycle recorders captured gas and effective
gas price but not a provider-specific decomposition into execution, calldata,
or batch-posting components. That missing field is visible in the report.

## What the protocol behavior taught me

The timestamp experiment was the clearest bridge between protocol logic and
network behavior. Three requested 60-second waits produced on-chain timestamp
deltas of 84, 84, and 96 seconds. The local process waiting did not change
storage. The later `repay(0)` transaction did: `borrowIndex` and principal
debt increased, and `lastAccrualTimestamp` advanced to the included block's
timestamp. This means “interest accrues with time” is incomplete wording for
this contract. Time passes externally, but the contract records its effect
only when an accrual-triggering state change executes.

That distinction matters for auditing and automation. An off-chain preview can
become stale while a transaction waits for inclusion. A keeper should treat
debt, health factor, and liquidation profitability as execution-time state,
not as facts guaranteed by the moment a transaction was prepared. This is not
a timestamp exploit finding; the experiment did not manipulate timestamps. It
is evidence that timestamp-sensitive accounting and delayed interaction belong
in the threat model.

The liquidation experiment showed the current-price path. With one WETH of
collateral, 500 DAI of debt, and a WETH price of `2000e18`, health factor was
`3.2e18`. The owner then changed the mock price to `500e18`; health factor
became `0.8e18`, and liquidation succeeded. Debt and collateral were cleared,
and the accounting state remained consistent. The price-change transaction was
`0x0aa935b384e876c976b430c3034f012844c5c2fd0dc278f1db05afe6d6901aaf`; the
liquidation transaction was
`0x30fc62d02c682de8d325ec07042bf94d928bec38a86f2f92f959b501e2a3455a`.

The important security qualification is that this was an owner-controlled
`MockPriceOracle`, and the same wallet acted as borrower, oracle owner, and
liquidator. It demonstrates protocol mechanics and a trust boundary. It does
not demonstrate that an arbitrary attacker can manipulate a production price
feed, nor does it test independent liquidator incentives, oracle freshness, or
feed disagreement.

## What the L2 runs taught me

The same lifecycle completed on Arbitrum Sepolia and Base Sepolia. Each L2
repeat recorded nine successful receipts and ended with zero principal debt and
a true pool accounting identity. Base exposed an especially useful operational
lesson: Forge-batched state-changing calls repeatedly hit
`ReentrancySentryOOG`, while submitting each action as a separate transaction
completed the lifecycle. That is not evidence that Base changes the Solidity
reentrancy logic. It is evidence that tooling, RPC behavior, gas estimation,
and transaction boundaries can affect how a test harness behaves on a target
network.

Block numbers also illustrate why cross-network comparisons need careful
language. The recorded Base lifecycle used block numbers around 47 million;
Arbitrum used around 313 million; Sepolia used around 11 million. Those values
are useful for ordering transactions within each chain, but they do not imply
that one Base block equals one Ethereum block or that the three chains share a
cadence. The report compares block and timestamp progression within each
network only.

On Sepolia, three close transactions landed in one block with canonical
transaction indices 104, 118, and 125, matching the observed submission order.
The delayed interaction landed later after an 84-second on-chain timestamp
delta. A first burst attempt also produced an `already known` RPC error because
the asynchronous sender reused a nonce. Reserving explicit pending nonces fixed
the runner. This was a useful operational observation, not a LendingPool
vulnerability: canonical receipts, not local console order, establish what
actually executed.

## Receipt, settlement, and finality are different claims

The main directly measured timing comparison here is receipt latency: local
submission until the RPC reported a transaction receipt. A receipt tells the
application that the transaction was included with a status according to that
RPC. It does not automatically mean that an L2 state update has been posted to
Ethereum L1, nor that the relevant history is irreversible under the network's
finality model.

I did not capture a network-specific settlement or finality signal. Therefore,
the honest conclusion is narrower: these runs compare observed receipt speed.
They do not prove settlement at receipt time, and they do not establish a
confirmation policy for production collateral, repayment, oracle, or
liquidation actions.

The same boundary applies to sequencers. The Arbitrum and Base runs show normal
successful operation. They did not reproduce a sequencer outage, censorship
event, or forced-inclusion path. A production audit should ask what happens to
repayments, liquidations, oracle updates, and timestamp-based accrual when the
sequencer is delayed or unavailable. This project records that as a threat
model question rather than pretending to have tested it.

## Limitations and reproduction

The Sepolia baseline lifecycle initially failed during repayment with an
`ReentrancySentryOOG` trace and was recovered manually with a larger gas limit.
The failed observation remains in the cross-network dataset. The L2 lifecycle
records contain no provider-specific fee decomposition. Lifecycle scripts also
lack submission timestamps, so their receipt latency is intentionally not
invented. The mock tokens have unrestricted testnet minting and do not model
real asset value.

To reproduce the analysis from the local raw evidence:

```powershell
powershell -ExecutionPolicy Bypass -File exploration/scripts/analyze-cross-network.ps1
```

Supporting artifacts:

- [GitHub repository](https://github.com/Phat1911/lending-protocol)
- [Cross-network analysis](deployments/exploration-cross-network-analysis.md)
- [Machine-readable analysis](deployments/exploration-cross-network-analysis.json)
- [Security interpretation](L1_L2_SECURITY_NOTE.md)
- [Exploration instructions](exploration/README.md)
- [Sepolia deployment metadata](deployments/exploration-sepolia.json)
- [Arbitrum Sepolia deployment metadata](deployments/exploration-arbitrum-sepolia.json)
- [Base Sepolia deployment metadata](deployments/exploration-base-sepolia.json)

The central lesson is not that one chain “wins.” It is that the same contract
logic sits inside different transaction, fee, ordering, and operational
environments. An auditor must preserve that boundary: measure what the receipt
and contract state prove, identify the assumptions around oracle and sequencer,
and leave finality and outage conclusions explicitly bounded.
