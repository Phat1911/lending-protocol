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
