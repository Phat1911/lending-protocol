# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

# Lending Protocol

Minimal Aave/Compound-style lending protocol — see [SPEC.md](SPEC.md) for full spec.

Built incrementally against [PLAN.md](PLAN.md), which breaks the build into
milestones (checklist + per-milestone scope/rationale). Check it before
starting new work to see what's done and what the next milestone's exact
boundaries are — some milestones deliberately stop short of full spec
compliance (e.g. a view function added before the code path that would make
it load-bearing) so hard mechanics can be understood in isolation. Don't
"complete" a milestone's scope early just because the spec would allow it.

## Commands

```
forge build                              # compile
forge test                               # run full suite
forge test -vvvv                         # run full suite, verbose traces (debugging)
forge test --match-path test/Foo.t.sol   # run one test file
forge test --match-test test_Name        # run one test by name
forge fmt                                # format Solidity
forge script script/Deploy.s.sol --rpc-url <url> --private-key <key>  # deploy
```

After each milestone, run `forge build` then `forge test -vv` scoped to that
milestone's new test file (per PLAN.md's Verification section) before moving
on.

## Project Structure

Foundry layout:

```
src/
  LendingPool.sol       # core contract: deposits, borrow, repay, liquidate
  MockPriceOracle.sol    # owner-settable price feed (mapping token => price)
  mocks/
    MockWETH.sol         # 18-decimal ERC20, public mint()
    MockDAI.sol          # 18-decimal ERC20, public mint()
test/
  *.t.sol                # Foundry tests (Solidity), per §11 of SPEC.md
script/
  Deploy.s.sol           # deploy + wire mWETH/mDAI/oracle at deploy time
foundry.toml
```

Only two assets exist (`mWETH` collateral-only, `mDAI` borrow/supply) — no
asset registry. Don't add one.

## Coding Style

- Solidity, OpenZeppelin contracts (`Ownable`, `Pausable`, `ReentrancyGuard`,
  `SafeERC20`).
- All external state-changing functions: `nonReentrant`, call
  `_accrueInterest()` first, and respect `whenNotPaused`.
- Use `SafeERC20` (`safeTransfer`/`safeTransferFrom`) for all token moves,
  never raw `transfer`/`transferFrom`.
- Fixed-point math scaled to `1e18` throughout (prices, indices, health
  factor, rates in bps where noted).
- No stored/cached health factor — always compute live from current oracle
  price and current index-scaled balances.
- Keep it minimal: two fixed tokens, single owner, no timelock/DAO, no
  partial liquidation, no flash loans — don't build toward these (see
  SPEC.md §10, "Explicitly Out of Scope").

## Rules (Security Constraints)

- **Checks-effects-interactions**: update all internal state (balances,
  indices, debt) before any external call/token transfer, in every
  state-changing function.
- **Reentrancy guard**: `nonReentrant` on every external state-changing
  function (deposit, withdraw, borrow, repay, liquidate).
- **Access control**: risk parameters (LTV, liquidation threshold,
  liquidation bonus, reserve factor, rate-curve params), reserve
  withdrawal, and pause/unpause are `onlyOwner`.
- **Pausability**: `whenNotPaused` on deposit/withdraw/borrow/repay/
  liquidate; owner can pause/unpause anytime.
- **Interest accrual ordering**: `_accrueInterest()` must run first, before
  any balance/health-factor logic, in every state-changing function.
- **Health factor invariants**:
  - `withdrawCollateral` must keep health factor `>= 1e18` after the
    withdrawal.
  - `borrow` must keep health factor `>= 1e18` after the borrow.
  - `liquidate` must revert if health factor `>= 1e18` (can't liquidate a
    safe position).
- **Liquidity invariant**: `withdrawSupply` must not exceed currently
  unborrowed `mDAI` liquidity.
- **Liquidation correctness**: full-debt-repay only (no partial/close
  factor); seizure = `repaidDebtValueUSD * 1.10` in `mWETH`, capped at the
  borrower's actual collateral balance if insufficient (bad debt is
  accepted, not solved — don't add a socialized-loss mechanism).
- **Repay overpayment**: `repay(amount)` must cap/refuse repayment beyond
  actual outstanding debt (no overpay leaving negative debt).
- **Oracle trust boundary**: `MockPriceOracle` is intentionally
  unrealistic — don't add production
  hardening here, it's explicitly out of scope. However, we also recognize some potential risks associated with it down the line.