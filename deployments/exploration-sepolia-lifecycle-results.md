# Sepolia Milestone 13 — Observed Lifecycle Results

This is the durable evidence record for the first live Sepolia lifecycle.
Values below are recorded from the public chain or from terminal output saved
during the experiment. This file intentionally distinguishes observed facts
from interpretation.

## Experiment identity

- Network: Ethereum Sepolia
- Chain ID: `11155111`
- Scenario: supply → collateral deposit → borrow → repay
- Deployment date: 2026-09-26
- Deployer used for the fresh deployment:
  `0x8e08e32f987ab4aa089f84cfa0f5d026b304876c`
- Lifecycle actor:
  `0xE5d91dD73d1906787ac13879FC427FAcc5AD5698`
- Explorer: [Sepolia Etherscan](https://sepolia.etherscan.io/)

## Deployed contract addresses

| Contract | Address |
|---|---|
| MockWETH | `0xbe75d1066e3e8957b89195bb6820610b777cf373` |
| MockDAI | `0xcf80b6ce6a30bffe08e3205752562a88f72d0929` |
| MockPriceOracle | `0x8859e060875717c27898131ec78c02481a435c68` |
| LendingPool | `0x790dab9909a5f1f98c56c7e001cf8fb7b6aed687` |

Deployment metadata, gas, fees, and deployment transaction links are also
stored in [`exploration-sepolia.json`](./exploration-sepolia.json).

## Lifecycle transaction evidence

The automated lifecycle executed the funding, approvals, supply, collateral
deposit, and borrow calls. Its first repayment attempt ran out of gas.

| Action | Transaction | Result | Notes |
|---|---|---|---|
| mWETH mint | `0x9b9651bb54c63c45203245cdc5071784e1e03dce3c97508452148672a4ca3e8e` | Successful | [View](https://sepolia.etherscan.io/tx/0x9b9651bb54c63c45203245cdc5071784e1e03dce3c97508452148672a4ca3e8e) |
| mDAI mint | `0xdcafcb19272a74367bfc7c240240251742567d9c2a587229069ed049c41cc782` | Successful | [View](https://sepolia.etherscan.io/tx/0xdcafcb19272a74367bfc7c240240251742567d9c2a587229069ed049c41cc782) |
| mWETH approval | `0xd57c3a0882ceeff14caa563a5373a329c868ab0cc9004907d70ac2bdd30a5463` | Successful | [View](https://sepolia.etherscan.io/tx/0xd57c3a0882ceeff14caa563a5373a329c868ab0cc9004907d70ac2bdd30a5463) |
| mDAI supply approval | `0xf42b3948027eb885b6fb6bac010c6ffb06771d72a132ffa949b4bcb3e2a7ec29` | Successful | [View](https://sepolia.etherscan.io/tx/0xf42b3948027eb885b6fb6bac010c6ffb06771d72a132ffa949b4bcb3e2a7ec29) |
| Supply | `0x71105c175fe81d0288795e6698c1e5820ee9577dd7d6e265244ee3d623dc8c59` | Successful | [View](https://sepolia.etherscan.io/tx/0x71105c175fe81d0288795e6698c1e5820ee9577dd7d6e265244ee3d623dc8c59) |
| Collateral deposit | `0x22240df7f69b6ec3c7a4cee2926ad9cd7e9373e2ea7839310fbb8f564b614716` | Successful | [View](https://sepolia.etherscan.io/tx/0x22240df7f69b6ec3c7a4cee2926ad9cd7e9373e2ea7839310fbb8f564b614716) |
| Borrow | `0xfa55a4ebe7eeae9e18e04b7ded257ff1ca113f20354a59bcc573eada6982d8f2` | Successful | [View](https://sepolia.etherscan.io/tx/0xfa55a4ebe7eeae9e18e04b7ded257ff1ca113f20354a59bcc573eada6982d8f2) |
| Repay approval recovery | `0xf0300f4cb73119e7ed5aac1a95d86be76947a81cf0f97bd2513065342fe32bed` | Successful | [View](https://sepolia.etherscan.io/tx/0xf0300f4cb73119e7ed5aac1a95d86be76947a81cf0f97bd2513065342fe32bed) |
| Initial repay attempt | `0x4beb8c67c981b663468468ecd03d4cb82fe2141ac80f42a28aa8f29710029a7c` | Failed | 85,633 gas; trace showed `ReentrancySentryOOG`, interpreted as out-of-gas during the `nonReentrant` entry path. |
| Manual repay recovery | `0x8e01f851b6f53f5d67cf4d0c6f2121bcfed7b1ec4c942dd31798ca17565b0dbe` | Successful | 114,305 gas; [View](https://sepolia.etherscan.io/tx/0x8e01f851b6f53f5d67cf4d0c6f2121bcfed7b1ec4c942dd31798ca17565b0dbe) |

The automated collector did not finish because the first repayment failed.
The final approval and repayment were therefore performed manually with a
larger gas limit.

## Final on-chain state after recovery

These values were read with `cast call` after the successful manual repayment.

| Read | Observed value |
|---|---:|
| `totalDaiSupplied` | `1000000214041095890200` |
| `totalReserves` | `23782343987800` |
| `totalDaiBorrowed` | `0` |
| `principalDebt(actor)` | `0` |
| DAI balance of LendingPool | `1000000237823439878000` |

Accounting check:

```text
totalDaiSupplied - totalDaiBorrowed + totalReserves
= 1000000214041095890200 - 0 + 23782343987800
= 1000000237823439878000
= observed pool DAI balance
```

Result: the accounting identity passed after recovery, and the actor’s debt
was zero.

## What this experiment does and does not prove

Observed:

- The deployed contracts accepted the complete supply/collateral/borrow flow.
- Repayment cleared the actor’s debt and total borrowed amount.
- The pool balance matched the tracked-supply, borrowed, and reserve values.
- The first repayment attempt needed more gas than the automatically selected
  limit; the manual retry succeeded with a `300000` gas limit.

Not yet measured by this experiment:

- Real-time delayed interest accrual over a deliberate wall-clock interval.
- Receipt speed distributions or confirmation/finality comparisons.
- L2 behavior on Arbitrum Sepolia or Base Sepolia.
- A complete automatically generated before/after lifecycle JSON record.

The failed transaction is evidence about this particular RPC/gas-estimation
run, not by itself a protocol vulnerability finding. The blog should describe
it as an operational observation and explain that the transaction reverted,
so its state changes were rolled back while its gas was still consumed.
