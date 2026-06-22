# Real-data value verification

`tests/tavern-mainnet/test_real_data.tavern.yaml` asserts **exact** values for the
2016-04 window. Those values were originally produced by *running the endpoints*, so
on their own the tavern assertions only prove the endpoints are **deterministic** —
not that the numbers are **correct** (the oracle-circularity problem: "what if we
miscalculated the expected value?").

To close that gap we mirror balance_tracker's two correctness guards. Neither uses the
hardcoded constants as truth; each derives the value by an independent route.

| Guard | Mirrors | Source of truth | What it proves |
|-------|---------|-----------------|----------------|
| `tests/parity/mainnet_metrics_parity.sql` | btracker `tests/parity/impacted_balances_parity.sql` | The raw `hafd.operations` stream, re-aggregated by *different* SQL (window-function first-occurrence, etc.) that shares none of the processor's code or `haf_stats_backend` tables | Endpoint output == an independent in-DB derivation. RAISEs on any mismatch. |
| `tests/regression/` | btracker `tests/regression/` | An **external canonical hived node** (`condenser_api.get_account_history` via `api.hive.blog`), captured to `account_metrics_dump.json.gz` | Account-scoped endpoint output == a source entirely outside our DB and code. |

Both run in CI inside the integration stack (`scripts/run_verification.sh`, invoked by
the `integration-tests` job) and fail the job on any divergence.

## Verified (2016-04, against a full 5,000,000-block replay)

All 22 asserted fields reproduce under **both** guards:

| Endpoint | Value | Independent (raw ops) | External (hived) |
|----------|-------|:---:|:---:|
| content_volume | posts 489 / comments 616 / authors 135 | ✓ | — |
| vote_stats | 3004 / up 2709 / down 295 / unvote 0 / self 255 / voters 242 / 9.82% | ✓ | — |
| daily_active_users | accounts 3739 / ops 116298 | ✓ | — |
| top_accounts transfer_in (bittrex) | 320700219 / 971 ops | ✓ | ✓ |
| account_content_stats (tuck-fheman) | 54 / 100 / cast 112 / recv 265 / replies 86 | ✓ | ✓ (posts/comments/cast) |
| account_financial_summary (bittrex) | income 320700219·971 / expense 169015773·322 | ✓ | ✓ |
| account_funnel | new_accounts 6840 | ✓ | — |

(Network-wide aggregates have no native hived endpoint, so they are covered by the
in-DB parity guard; account-scoped values are additionally checked against hived.)

## Subtleties the verification exposed

- **Edits are not creates.** A naive count of every `comment_operation` gives **819
  posts / 732 comments** for April; the correct figures (**489 / 616**) count only the
  first-ever occurrence of each `(author, permlink)`. The parity guard re-derives this
  with a window function — a different method from the processor's `comment_registry`
  — and reaches the same numbers. A sloppy "independent" check would have wrongly
  flagged the correct value.

## Resolved: `new_accounts` now counts every creation mechanism

`account_funnel.new_accounts` originally counted only the explicit creation ops
(`account_create`, `_with_delegation`, `create_claimed_account`) — **224** for April —
which excluded **pow-mined accounts**, the dominant onboarding path in early Steem
(2016). The processor now derives new accounts from the **`account_created` virtual
op**, which the chain emits exactly once per account for *every* mechanism (explicit
+ pow/pow2), giving **6840** for April. Two independent canonical signals confirm this:
the `account_created` vop (processor) and `hafd.accounts.block_num` (parity guard) both
yield 6840.

## Running locally

```bash
DB=postgresql://haf_admin@<haf-host>:5432/haf_block_log     # replayed to >= ~1.1M blocks

# Guard 1 — parity (independent in-DB re-derivation)
psql "$DB" -v ON_ERROR_STOP=on -f tests/parity/mainnet_metrics_parity.sql

# Guard 2 — regression (vs external hived snapshot)
cd tests/regression && ./run_test.sh --host=<haf-host> --user=haf_admin

# Recreate the hived fixture (needs internet):
python3 tests/regression/generate_fixture.py --node https://api.hive.blog
```
