# L1/L2 Exploration Harness

This directory contains measurement tooling for the L1/L2 exploration project.
It deploys and observes the existing contracts; it does not change the core
lending logic.

## Milestone 11: validate configuration

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File exploration/scripts/validate-config.ps1
```

The validator checks that the three RPC variables exist and writes a harmless
sample record to stdout. It never prints or stores a private key.

## Milestone 12: deploy fresh contracts to Sepolia

The wrapper expects `SEPOLIA_RPC_URL` and an explicit process-level
`DEPLOYER_PRIVATE_KEY`. The key is not added to `.env.example` and must never
be committed.

```powershell
$env:DEPLOYER_PRIVATE_KEY = '<testnet-only-private-key>'
powershell -ExecutionPolicy Bypass -File exploration/scripts/deploy-sepolia.ps1
Remove-Item Env:DEPLOYER_PRIVATE_KEY
```

The wrapper:

1. runs the separate `ExplorationDeploy` script;
2. reads Foundry's broadcast file;
3. queries receipts and block timestamps for the four CREATE transactions;
4. writes `deployments/exploration-sepolia.json`.

The output contains public addresses, transaction hashes, block data, gas,
fees, and explorer links. It does not contain private keys or RPC URLs.

If broadcasting succeeded but metadata collection failed, rerun in recovery
mode after fixing the collector:

```powershell
powershell -ExecutionPolicy Bypass -File exploration/scripts/deploy-sepolia.ps1 -CollectOnly
```

Use a dedicated testnet wallet. Do not use a mainnet key.

## Milestone 13: Sepolia baseline lifecycle

After a fresh deployment, run the complete lifecycle harness:

```powershell
$env:DEPLOYER_PRIVATE_KEY = '<testnet-only-private-key>'
powershell -ExecutionPolicy Bypass -File exploration/scripts/run-sepolia-lifecycle.ps1
Remove-Item Env:DEPLOYER_PRIVATE_KEY
```

The harness reuses the deployed contracts and performs minting, approvals,
supply, collateral deposit, borrow, and repay. Minting is only testnet funding
through the existing mock-token interfaces; no lending calculations are
recreated off-chain. It records before/after on-chain reads, every receipt,
block number/timestamp, gas, fees, and explorer links in
`deployments/exploration-sepolia-lifecycle.json`.

It asserts that the final principal debt and total borrowed amount are zero and
that the observed pool DAI balance equals:

`totalDaiSupplied - totalDaiBorrowed + totalReserves`.

## Milestone 14: real-time timestamp and interest accrual

This experiment creates a new borrower position, records the on-chain state,
waits in the PowerShell process, and then calls `repay(0)`. In this protocol,
`repay(0)` is useful as an observation trigger: it executes `_accrueInterest()`
and debt settlement but transfers zero mDAI. The wait itself cannot mutate the
contract; the later transaction is what applies the elapsed `block.timestamp`
interval.

Run three 60-second observations:

```powershell
$env:DEPLOYER_PRIVATE_KEY = '<testnet-only-private-key>'
powershell -ExecutionPolicy Bypass -File exploration/scripts/run-sepolia-timestamp-experiment.ps1
Remove-Item Env:DEPLOYER_PRIVATE_KEY
```

The setup phase contains several transactions. The wrapper therefore uses a
1,000,000 gas limit by default; override it with `-GasLimit` if an RPC/provider
requires a different ceiling.

If setup partially succeeded, use `-SkipSetup` after confirming that the actor
already has collateral and debt. This waits and triggers accrual without
creating another position:

```powershell
powershell -ExecutionPolicy Bypass -File exploration/scripts/run-sepolia-timestamp-experiment.ps1 -SkipSetup -Runs 1
```

For a quick smoke run, use `-Runs 1 -WaitSeconds 10`. The JSON output records
before/after block timestamps, block numbers, `lastAccrualTimestamp`,
`borrowIndex`, principal/live debt, every setup/trigger receipt, gas, fees, and
explorer links. This measures receipt-triggered accrual behavior; it is not a
claim that interest is continuously written to storage while nobody calls the
pool.

## Milestone 15: oracle price and liquidation behavior

This experiment uses three roles: the borrower, the owner of the mock oracle,
and the liquidator. It records a healthy position, changes the mock WETH
price, records the resulting health factor, and executes the existing
`liquidate` path. The oracle owner is an explicit trust assumption: this is
not evidence that a production oracle can be manipulated in the same way.

By default all roles fall back to `DEPLOYER_PRIVATE_KEY`, which is convenient
for one testnet wallet only if that wallet owns the deployed oracle. For
separate roles, set `ORACLE_OWNER_PRIVATE_KEY` and
`LIQUIDATOR_PRIVATE_KEY` as process-level variables. Never commit them.

```powershell
$env:DEPLOYER_PRIVATE_KEY = '<borrower-testnet-private-key>'
$env:ORACLE_OWNER_PRIVATE_KEY = '<deployment-owner-private-key>'
$env:LIQUIDATOR_PRIVATE_KEY = '<liquidator-testnet-private-key>'
powershell -ExecutionPolicy Bypass -File exploration/scripts/run-sepolia-oracle-liquidation.ps1
Remove-Item Env:DEPLOYER_PRIVATE_KEY, Env:ORACLE_OWNER_PRIVATE_KEY, Env:LIQUIDATOR_PRIVATE_KEY
```

The default setup supplies 1,000 mDAI, deposits 1 mWETH, and borrows 500
mDAI. It then changes the mock WETH price from the deployment value of
2,000e18 to 500e18. Use `-SkipSetup` only after confirming that the borrower
already has a suitable debt/collateral position. The JSON output records
prices, health factors, balances, reserves, receipts, gas, fees, and explorer
links before and after liquidation.

## Milestone 16: rapid transactions and delayed interaction

This runner submits several separate `repay(0)` transactions asynchronously,
polls their canonical receipts, and records both local submission order and
receipt block/transaction order. It then waits before sending one more
`repay(0)` interaction. The wait does not mutate state; the later transaction
is what applies interest accrual using the block timestamp.

Run it with the current borrower wallet:

```powershell
powershell -ExecutionPolicy Bypass `
  -File .\exploration\scripts\run-sepolia-ordering-delay-experiment.ps1
```

The default creates a borrower position, submits three burst transactions,
waits 60 seconds, and submits one delayed interaction. If a suitable debt
position already exists, use `-SkipSetup` to avoid adding another position.
Use `-BurstCount 3 -DelaySeconds 10` for a shorter smoke run. Evidence is
written to `deployments/exploration-sepolia-ordering-delay-results.json`.
The output deliberately calls receipt latency a receipt measurement only; it
does not treat a receipt as settlement or finality.

## Milestone 17: Arbitrum Sepolia replication

Set `ARBITRUM_SEPOLIA_RPC_URL` and use a funded testnet-only wallet. The
deployment wrapper uses the same `ExplorationDeploy` script and writes fresh
Arbitrum addresses to a separate metadata file:

```powershell
$env:DEPLOYER_PRIVATE_KEY = '<testnet-only-private-key>'
powershell -ExecutionPolicy Bypass `
  -File .\exploration\scripts\deploy-arbitrum-sepolia.ps1
```

Run the complete lifecycle three times by default:

```powershell
powershell -ExecutionPolicy Bypass `
  -File .\exploration\scripts\run-arbitrum-sepolia-lifecycle.ps1
```

Use `-Runs 1` for a smoke test. Deployment metadata is written to
`deployments/exploration-arbitrum-sepolia.json`; lifecycle evidence is written
to the ignored local JSON result file. The recorder confirms chain ID,
contract wiring, owner, oracle, debt clearing, and the accounting identity.
It records gas used and effective gas price separately and currently leaves
provider-specific L2 fee components null rather than inventing them.
