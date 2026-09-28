# Cross-network fee, timing, and block-behavior analysis

Generated: 2026-09-28T11:48:54.5370163Z

This report is generated from the local raw evidence files. Every summary row links back to transaction hashes in the JSON report. It compares receipt observations only; it does not claim settlement or finality.

## Summary rows

| Network | Chain ID | Scenario | Run | Tx count | Gas total | Total fee (wei) | Receipt latency median/range (s) | Block range | L2 fee components |
|---|---:|---|---:|---:|---:|---:|---|---|---|
| arbitrum-sepolia | 421614 | baseline-lifecycle | 1 | 9 | 769142 | 24155106295142 | not recorded | 313280146-313280175 | missing |
| arbitrum-sepolia | 421614 | baseline-lifecycle | 2 | 9 | 562115 | 17671918002115 | not recorded | 313280350-313280381 | missing |
| arbitrum-sepolia | 421614 | baseline-lifecycle | 3 | 9 | 562113 | 17634477252113 | not recorded | 313280555-313280585 | missing |
| arbitrum-sepolia | 421614 | deployment | 1 | 4 | 5957602 | 185721539779602 | not recorded | 313278960-313278987 | missing |
| base-sepolia | 84532 | baseline-lifecycle | 1 | 9 | 568273 | 3409638000000 | not recorded | 47409277-47409291 | missing |
| base-sepolia | 84532 | baseline-lifecycle | 2 | 9 | 553973 | 3323838000000 | not recorded | 47409297-47409309 | missing |
| base-sepolia | 84532 | baseline-lifecycle | 3 | 9 | 553973 | 3323838000000 | not recorded | 47409315-47409331 | missing |
| base-sepolia | 84532 | deployment | 1 | 4 | 5718162 | 34308972000000 | not recorded | 47408192-47408197 | missing |
| sepolia | 11155111 | baseline-lifecycle | 1 | 1 | 85633 |  | not recorded |  | missing |
| sepolia | 11155111 | deployment | 1 | 4 | 5718162 | 6114059507888110 | not recorded | 11790490-11790496 | missing |
| sepolia | 11155111 | oracle-price-and-liquidation | 1 | 3 | 355821 | 360473981901840 | not recorded | 11790537-11790546 | missing |
| sepolia | 11155111 | rapid-transactions-and-delayed-interaction | 1 | 4 | 304820 | 323777125515370 | 25.551 / 5.784-26.467 | 11790752-11790759 | missing |
| sepolia | 11155111 | real-time-timestamp-interest-accrual | 1 | 1 | 98331 | 101708102775123 | not recorded | 11790324-11790324 | missing |
| sepolia | 11155111 | real-time-timestamp-interest-accrual | 2 | 1 | 98331 | 104010550082817 | not recorded | 11790331-11790331 | missing |
| sepolia | 11155111 | real-time-timestamp-interest-accrual | 3 | 1 | 98331 | 104351250281547 | not recorded | 11790338-11790338 | missing |

## Network progression

| Network | Chain ID | Observed transaction count | Observed block range | Observed timestamp range |
|---|---:|---:|---|---|
| base-sepolia | 84532 | 31 | 47408192-47409331 | 1790584672-1790586950 |
| arbitrum-sepolia | 421614 | 31 | 313278960-313280585 | 1790515792-1790516200 |
| sepolia | 11155111 | 15 | 11790324-11790759 | 1790475828-1790481072 |

Block numbers are compared only within each network. An Arbitrum or Base block number is not treated as an L1-equivalent height or as evidence of a shared cadence.

## Limitations

- The Sepolia baseline lifecycle is preserved as Markdown rather than a machine-readable JSON result; the known failed initial repay is included, but the other baseline transactions are not re-parsed into this report.
- The current Arbitrum and Base lifecycle recorders expose no provider-specific L2 fee decomposition; this remains visible as l2FeeComponentStatus=missing.
- These are public testnet observations from particular RPC/provider conditions, not universal performance guarantees.
- No network-specific settlement/finality source was recorded by these scripts; receipt latency is therefore the measured timing comparison.

## Reproduction

```powershell
powershell -ExecutionPolicy Bypass -File exploration/scripts/analyze-cross-network.ps1
```

The detailed transaction records, hashes, explorer URLs, and source files are in exploration-cross-network-analysis.json.
