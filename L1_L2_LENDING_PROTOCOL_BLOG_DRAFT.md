# Auditing the same lending protocol across Ethereum L1 and L2

Most L1-versus-L2 explanations begin with architecture diagrams. I wanted a
more useful starting point for smart-contract auditing: deploy the same
protocol, send real transactions, and record what actually changes.

This project reused an existing lending protocol and deployed it to Ethereum
Sepolia, Arbitrum Sepolia, and Base Sepolia. The contracts were not rewritten
for the experiment. I exercised the existing supply, collateral, borrowing,
repayment, interest-accrual, oracle, and liquidation paths, then compared the
observed behavior and the security questions that remain unanswered.

The complete project is available on
[GitHub](https://github.com/Phat1911/lending-protocol).

## What I wanted to learn

The practical question was: what does an auditor need to notice when identical
Solidity logic runs on an L1 and on different L2s?

I focused on five areas:

- deployment and transaction costs;
- `block.timestamp` and `block.number` behavior;
- receipt speed and transaction ordering;
- delayed repayment and liquidation;
- the boundary between observed protocol behavior and L2 operational risk.

This distinction matters because a contract does not run in isolation. Its
behavior is affected by when a transaction is included, which oracle value is
current at execution time, what a keeper saw before submission, and what a
receipt actually proves.

## The experiment

Each network received fresh copies of four existing contracts: MockWETH,
MockDAI, MockPriceOracle, and LendingPool. The deployment metadata records
chain IDs, addresses, transaction hashes, blocks, gas, fees, and explorer
links. Private keys and authenticated RPC URLs remained local.

I ran a basic lending lifecycle: fund the mock tokens, approve them, supply
DAI, deposit WETH collateral, borrow DAI, and repay. I also created a real
borrower position on Sepolia, waited in wall-clock time, and called `repay(0)`.
That call is useful here because the existing contract accrues interest before
settlement while transferring zero DAI.

For liquidation, the owner-controlled mock oracle price was changed and the
position was liquidated using the current contract path. Finally, I submitted
three close transactions and one deliberately delayed interaction, recording
both local submission order and canonical receipt order.

The supporting analyzer is deliberately conservative. It keeps gas used,
effective gas price, and total fee as different measurements. It calculates
receipt latency only when submission and receipt timestamps exist. It does not
pretend that a receipt is settlement or finality.

## Results from the three networks

The public testnet sample is not large enough to rank networks universally,
but it provides concrete engineering observations.

| Network | What completed | Selected observation |
|---|---|---|
| Ethereum Sepolia | Deployment, accrual, liquidation, ordering, and delay experiments | Deployment used 5,718,162 gas. The ordering sample had a 25.551-second median receipt latency, with an observed range of 5.784–26.467 seconds. |
| Arbitrum Sepolia | Deployment and three nine-transaction lifecycle runs | Lifecycle gas totals were 769,142, 562,115, and 562,113. Each run cleared principal debt and preserved the accounting identity. |
| Base Sepolia | Deployment and three nine-transaction lifecycle runs | Lifecycle gas totals were 568,273, 553,973, and 553,973. Each run cleared principal debt and preserved the accounting identity. |

The L2 recorders did not expose a provider-specific decomposition of execution,
calldata, and batch-posting fees. That field is reported as missing rather than
estimated. The observed fees are therefore useful for this particular run, but
not a complete economic model of L2 transaction cost.

Block numbers also need careful interpretation. The experiments observed Base
blocks around 47 million, Arbitrum blocks around 313 million, and Sepolia
blocks around 11 million. Those numbers establish ordering within each chain;
they do not mean that an L2 block is equivalent to an Ethereum block or that
all three chains advance at the same cadence.

## The most important protocol observation: time passes before storage changes

The timestamp experiment produced the clearest auditing lesson. Three waits
requested for 60 seconds resulted in on-chain timestamp deltas of 84, 84, and
96 seconds. During the local wait, the contract state did not change. The next
state-changing transaction applied the elapsed interval: `borrowIndex`,
principal debt, and `lastAccrualTimestamp` advanced.

So “interest accrues continuously” would be an imprecise description of this
implementation. Time passes continuously outside the EVM, but the contract
records its effect when `_accrueInterest()` runs during a state change.

That creates a practical audit question. An off-chain interface may preview a
health factor or debt amount, but the transaction may be included later under a
different timestamp and a different debt index. Keepers and liquidators should
treat previews as provisional and re-check execution-time state. This project
did not manipulate timestamps and did not find a timestamp exploit. It showed
why timestamp-sensitive accounting belongs in the threat model.

## Oracle trust is part of the result

The liquidation experiment began with one WETH of collateral, 500 DAI of debt,
and a WETH price of `2000e18`. The health factor was `3.2e18`. After the mock
oracle price was changed to `500e18`, the health factor became `0.8e18` and
liquidation succeeded. Debt and collateral were cleared, and the accounting
state remained consistent.

That is useful evidence about the LendingPool's current-price liquidation path.
It is not evidence that a production oracle can be manipulated by an arbitrary
attacker. The oracle is owner-controlled, mock tokens can be minted freely, and
the same wallet acted as borrower, oracle owner, and liquidator. A production
review would additionally ask about oracle freshness, decimals, stale values,
feed disagreement, sequencer status, and independent liquidator incentives.

The experiment therefore treats the oracle as a trust boundary, not as a
permissionless manipulation finding.

## What the L2 runs changed about my audit thinking

The same lifecycle completed on both L2s, but the test harness did not behave
identically everywhere. On Base Sepolia, Forge-batched state-changing calls
repeatedly produced `ReentrancySentryOOG`. Submitting each action as a separate
transaction completed the lifecycle.

This does not show that Base changes the Solidity reentrancy guard. It shows
that deployment and testing are operational systems: RPC behavior, gas
estimation, transaction boundaries, and tooling can affect whether an
experiment reaches the contract path being studied. A failed harness run must
be diagnosed before being labeled a protocol failure.

The Sepolia ordering experiment produced another useful operational result.
Three close transactions landed in the same block at canonical transaction
indices 104, 118, and 125. A first attempt also returned `already known` because
an asynchronous sender reused a nonce. Reserving explicit pending nonces fixed
the runner. Local submission order is evidence of what a script attempted;
receipt block number and transaction index are evidence of canonical execution
order.

## Receipt speed is not finality

The measured timing in this project is receipt latency: local submission until
the RPC reported an included transaction receipt. That is valuable for studying
user and keeper experience, but it is a narrower claim than settlement or
finality.

An L2 receipt does not, by itself, prove that the state has been posted to
Ethereum L1 or that the history is irreversible under every relevant finality
model. This project did not capture a network-specific settlement or finality
signal, so it reports receipt speed only.

The same discipline applies to sequencers. The Arbitrum and Base runs showed
normal successful operation. They did not reproduce a sequencer outage,
censorship event, or forced-inclusion path. A production threat model should
ask what happens to repayment, liquidation, oracle updates, and timestamp-based
accrual if the sequencer is delayed or unavailable. That is an important L2
security question, but it is not a finding demonstrated by these runs.

## What this project proves—and what it does not

The evidence supports these bounded conclusions:

- the existing accounting identity held after successful lifecycle runs;
- elapsed block timestamps affected interest when the next accrual-triggering
  call executed;
- the current oracle price affected health factor and liquidation eligibility;
- canonical receipts established observed transaction ordering;
- the same contracts could be deployed and exercised on one L1 testnet and two
  L2 testnets.

It does not prove universal L1/L2 performance, production oracle safety,
sequencer outage resistance, censorship resistance, or finality at receipt
time. It also does not claim to test deadline enforcement: this lending path
contains no AMM swap deadline, and no deadline feature was added just to create
one.

## Reproduce the analysis

The repository contains the deployment metadata, scripts, security note, and
machine-readable cross-network report. With the local raw evidence available,
the report can be regenerated using:

```powershell
powershell -ExecutionPolicy Bypass -File exploration/scripts/analyze-cross-network.ps1
```

See the [cross-network analysis](deployments/exploration-cross-network-analysis.md),
[security interpretation](L1_L2_SECURITY_NOTE.md), and
[exploration README](exploration/README.md) for the detailed evidence and
limitations.

The main lesson is simple: deploying the same contract on different networks
does not produce three identical environments. The code may be unchanged, but
transaction inclusion, fees, ordering, timestamps, tooling, oracle trust, and
finality assumptions all become part of the audit surface. The right response
is not to generalize from a few receipts. It is to measure carefully, state the
trust assumptions, and keep every conclusion proportional to the evidence.
