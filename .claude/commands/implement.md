Now implement this milestone according to the plan.

After implementation is done, spawn separate subagents to write tests
(.t.sol) for this milestone — one subagent per vulnerability category
below. Each subagent should focus only on its assigned category, so
its reasoning doesn't get diluted across unrelated concerns.

Only spawn agents for categories genuinely relevant to this
milestone's code — skip the rest and briefly say why.

1. **Reentrancy agent** — check every function that makes an external
   call (transfer, call, any interaction with another contract). For
   each one: is state updated BEFORE the external call (CEI pattern)?
   Write tests simulating a malicious contract re-entering.

2. **Access control agent** — for every function that changes state,
   determine who should and shouldn't be allowed to call it. Write
   tests confirming unauthorized callers revert, and authorized ones
   succeed.

3. **Integer edge case agent** — check behavior at zero values (zero
   debt, zero collateral, zero balance) and at maximum values. Write
   tests for each boundary, especially anywhere division occurs.

4. **Rounding direction agent** — for every calculation involving
   multiplication and division, check the order of operations and
   determine which direction rounding favors (protocol vs. user).
   Write tests asserting rounding favors the safer direction.

5. **Oracle/price manipulation agent** — for every function that reads
   price data, check what happens if the price changes mid-transaction
   or between calls. Write tests simulating price changes at critical
   moments (e.g. right before liquidation).

6. **State consistency agent** — identify any two state variables that
   must remain mathematically consistent with each other (e.g. total
   supply vs. sum of balances). Write tests asserting this invariant
   holds after every state-changing function.

7. **Milestone-specific logic agent** — categories 1-6 cover general
   Solidity vulnerability patterns, but won't catch bugs specific to
   THIS milestone's unique business logic. Re-read this milestone's
   requirements in SPEC.md, then ask: "if I misunderstood or
   mis-implemented any specific requirement here, what would that look
   like?" Focus on logic correctness against the spec, not generic
   security patterns already covered above. Write tests for anything
   found.

After each subagent finishes, report back:
- Which category actually applied to this milestone (skip categories
  that genuinely don't apply, and briefly say why)
- What specific vulnerability, if any, each agent found
- The test file(s) written per category

Do NOT let any subagent silently skip a category that does apply —
if a category is relevant but the agent found nothing wrong, it should
still report "checked, no issue found," not just skip reporting.