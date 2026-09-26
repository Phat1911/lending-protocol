# L1/L2 Lending Protocol Exploration Specification

## 1. Purpose

Build a small, evidence-based exploration project around the existing lending
protocol to understand how Ethereum L1 and L2 behavior affects deployment,
testing, and smart-contract security auditing.

The project must deploy and exercise the existing contracts on:

- Ethereum Sepolia (L1)
- Arbitrum Sepolia (L2)
- Base Sepolia (L2)

The core lending logic must not be rewritten. The result must be suitable for
a recruiter or portfolio reviewer: a reproducible repository artifact plus a
medium-length blog-style write-up of approximately 1,200–1,800 words.

## 2. Goals

The project has two equal priorities:

1. Observe real protocol and network behavior across one L1 and two L2s.
2. Translate those observations into clearly bounded smart-contract security
   questions relevant to this codebase.

The project should teach and demonstrate:

- deployment differences and operational requirements;
- `block.timestamp` and `block.number` observations;
- gas used, gas price, and total fee differences;
- receipt latency and variability;
- the distinction between receipt, settlement, and finality;
- delayed interaction and timestamp-based interest accrual;
- oracle/admin trust and liquidation behavior;
- L2 sequencer risks as a threat-model consideration.

## 3. Non-goals

- Do not build a rollup, bridge, sequencer, or oracle system.
- Do not rewrite or materially modify `src/LendingPool.sol`.
- Do not add a deadline feature to the lending pool.
- Do not claim to have tested deadline enforcement; the current repository has
  no deadline-based function and no AMM in `src/`.
- Do not claim that a small testnet sample proves universal network behavior.
- Do not represent the mock oracle as production-grade.

Small external scripts, measurement helpers, and test-only harnesses are
allowed. Any auxiliary probe must be clearly separated from the production
contracts and labeled as such.

## 4. Existing protocol surface

Reuse the existing contracts and deployment pattern:

- `src/LendingPool.sol`
- `src/mocks/MockWETH.sol`
- `src/mocks/MockDAI.sol`
- `src/MockPriceOracle.sol`
- `script/Deploy.s.sol`

The central timestamp behavior is:

- the constructor initializes `lastAccrualTimestamp` from `block.timestamp`;
- state-changing entry points call `_accrueInterest()`;
- `_accrueInterest()` computes elapsed time from
  `block.timestamp - lastAccrualTimestamp`;
- `repay()` calls `_accrueInterest()` before settling debt.

Existing local tests may use `vm.warp`; live testnet scripts must use real
elapsed time and read actual receipts and blocks.

## 5. Required experiment checklist

Run the same conceptual checklist on all three networks:

1. Deploy the four existing contracts and record deployment metadata.
2. Perform the basic supply/borrow/repay lifecycle.
3. Wait between interactions and observe timestamp-based interest accrual.
4. Change the oracle price and exercise the health-factor/liquidation path.
5. Submit several transactions close together and record block numbers,
   timestamps, gas, fees, and receipt latency.
6. Include a delayed interaction and document sequencer downtime/censorship as
   a security consideration rather than pretending to reproduce an outage.

The oracle and liquidation scenario must state clearly that the mock oracle is
owner-controlled. A price change is an intentional experiment, not evidence
that a production oracle can be manipulated in the same way.

## 6. Measurement protocol

### 6.1 Repetitions

Run ordinary repeatable transactions three times per network where practical.
Report median and observed range for latency. Deployment and liquidation may
be one carefully documented run each because they are setup or scenario-level
operations.

The evidence-based completion standard is:

- all three network deployments complete;
- at least one complete scenario run per network;
- three repeats for ordinary transactions where practical;
- failures, skipped repeats, and unavailable infrastructure are recorded.

### 6.2 Required per-transaction data

Store machine-readable records, preferably JSON or CSV, containing at least:

- network name and chain ID;
- scenario and run number;
- sender address label, never a private key;
- contract/function and input summary;
- transaction hash;
- block number;
- block timestamp;
- submission timestamp from the local script;
- receipt timestamp from the local script;
- receipt status;
- `gasUsed`;
- `effectiveGasPrice` where available;
- total fee paid;
- L2-specific fee fields where the RPC exposes them;
- RPC endpoint label/provider, if useful for diagnosing variance;
- explorer URL;
- error/retry notes.

Use wall-clock timestamps only for latency measurement. Use on-chain block
timestamps and block numbers for protocol observations.

### 6.3 Timing vocabulary

Use these terms precisely:

- **Receipt/inclusion time:** submission to a successful transaction receipt.
- **Settlement:** L2 batch or state commitment information observable on L1,
  when practical.
- **Finality:** stronger permanence of the relevant chain history.

Receipt speed is the primary directly measured comparison. Settlement/finality
is a separate L2 security note and should only be measured when a reliable,
network-appropriate observation method is available.

## 7. Security analysis scope

The analysis covers both protocol-level and L2-specific risks.

### 7.1 Protocol-level questions

- Does interest accrue from the observed elapsed `block.timestamp` when the
  next state-changing call occurs?
- What happens after a long delay before the next interaction?
- Does an oracle price change immediately affect health factor and liquidation?
- Which admin and oracle permissions are trust assumptions?
- Are liquidation, repayment, and interest-index transitions consistent across
  networks?

### 7.2 L2-specific questions

- How quickly do submitted transactions receive receipts?
- How do block numbers and timestamps advance relative to L1?
- What does a fast L2 receipt mean compared with L1 settlement/finality?
- What happens operationally if the sequencer is delayed, unavailable, or
  censoring transactions?
- Could delayed user action affect repayment, liquidation, or oracle freshness?

Sequencer outage/censorship is a documented threat-model consideration unless
the selected public testnets expose a safe, reproducible way to observe it.

## 8. Trust model

The following parties are untrusted or potentially adversarial:

- ordinary users;
- borrowers;
- suppliers;
- liquidators;
- transaction senders attempting to exploit ordering or timing.

The following are explicit trust assumptions to document:

- the pool owner controls risk parameters and pause operations;
- the mock oracle owner can set prices;
- the testnet RPC and sequencer may affect visibility and timing;
- mock-token minting is a test/dev convenience, not a production asset model.

Do not silently classify an owner-controlled oracle price change as a protocol
bug. Report it as a trust boundary and explain what production oracle
hardening would be required.

## 9. Repository structure and implementation guidance

Prefer a separate exploration area, for example:

```text
exploration/
  README.md
  data/
  scripts/
  results/
  abi/                 # only if needed by external tooling
```

The exact directory names are implementation defaults and may be adjusted if
the existing Foundry layout makes another arrangement clearer.

Add network configuration to Foundry/environment handling without committing
secrets. Use explicit network names and chain IDs rather than relying on the
currently selected RPC.

The exploration scripts should fail clearly when required environment
variables are absent. They should support dry-run/local validation where
practical, but local simulation must not be presented as a substitute for the
three real testnet deployments.

## 10. Wallet and secret handling

Use a dedicated testnet-only wallet. Store its private key and RPC URLs only in
local environment variables or an ignored `.env` file. Never commit private
keys, seed phrases, or authenticated RPC URLs.

The repository may publish public deployer addresses, transaction hashes,
contract addresses, and explorer links.

## 11. Public artifact

Produce a blog-style write-up of approximately 1,200–1,800 words for a
recruiter or portfolio reviewer. It should include:

1. the question and why the existing lending protocol was reused;
2. the three networks and experiment method;
3. a compact results table;
4. timestamp/block-number observations;
5. gas and fee comparison;
6. receipt timing with median/range where three runs exist;
7. a clearly separated receipt-versus-settlement/finality explanation;
8. security observations and explicit trust assumptions;
9. limitations, failed runs, and what was not measured;
10. reproduction instructions and links to supporting data.

Use the four-part evidence pattern:

- Observation: what was measured.
- Assumption: what the contract or operator relies on.
- Risk question: what could go wrong if it fails.
- Conclusion: what the evidence supports, without overstating it.

## 12. Acceptance criteria

The implementation is complete when:

- the existing contracts compile without core-logic rewrites;
- deployments exist on Sepolia, Arbitrum Sepolia, and Base Sepolia;
- deployment addresses and transaction hashes are recorded;
- the six required scenario categories are implemented or explicitly
  documented as unavailable;
- ordinary transactions have three runs where practical;
- raw measurements are stored in a reproducible machine-readable format;
- gas, fee, block, timestamp, and receipt data can be traced to transactions;
- delayed interaction and oracle/liquidation behavior are covered;
- sequencer outage is treated as a documented threat model unless safely
  reproducible;
- the write-up distinguishes observations from general claims;
- no secrets are committed;
- existing tests still pass.

## 13. Decisions made without asking

These low-level decisions are intentionally autonomous so implementation can
proceed without another design interview:

- **Use Foundry-compatible scripts and tests.** The repository already uses
  Foundry, so this minimizes new tooling and keeps local/live workflows close.
- **Deploy fresh copies on each network.** This makes addresses, ownership,
  configuration, and measured behavior comparable instead of mixing old
  Sepolia state with new L2 state.
- **Use machine-readable JSON or CSV plus a human-readable summary.** Raw data
  makes claims auditable; tables make the portfolio artifact readable.
- **Record transaction hashes and explorer links.** These provide public,
  independently checkable evidence without exposing credentials.
- **Use median and range for repeated latency.** Confirmation time is noisy;
  three runs support a useful summary without pretending to statistical rigor.
- **Treat deployment and liquidation as scenario-level observations.** They
  are not ordinary repeated calls and may require special setup or funding.
- **Prefer `receipt` terminology for directly measured inclusion.** It is more
  precise than calling every successful RPC response “finality.”
- **Do not add a generic deadline probe in the first implementation.** The
  current lending pool has no deadline logic, so adding one would blur the
  difference between an observation about this protocol and a separate lesson.
- **Keep the existing `SPEC.md` untouched.** It specifies the original lending
  protocol; this file specifies the separate L1/L2 exploration project.
- **Put beginner explanations in `note1.md`.** The portfolio specification
  stays concise and implementation-oriented while the learning record remains
  available.
- **Create `PLAN.md` later if desired.** This specification is the source of
  truth; a future plan can break it into implementation milestones without
  changing scope.
