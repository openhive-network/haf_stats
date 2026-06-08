# haf_stats — Integration Verification & Schema Divergences

First end-to-end bring-up of the app against a real HAF node (2026-06-04). This
records what was verified, the schema/contract divergences found, the fix
applied, and the related **Known TODO** in [`README.md`](../README.md#known-todos)
(the project's "verification issues").

## What was verified

| Check | How | Result |
|---|---|---|
| Tavern endpoint suite (CI stack) | `docker-compose-ci.yml` (mocked `hafd` + seed data) against the real `endpoint_schema.sql` | **12/12 passed** |
| Full test stack | `docker-compose-test.yml` — bounded replay from a pre-synced block_log, full install + process + PostgREST + Tavern | Install + context create + Tavern green (see D7) |
| Live endpoints vs real node | Manual `curl` against a fully-replayed 5M-block HAF node | All return plausible data (table below) |

### Live endpoint verification (real node, blocks 1–5,000,000 = 2016 data)

| Endpoint | Result | Plausibility |
|---|---|---|
| `get_version` | `"5043417"` | git hash (after install fix #2) |
| `get_health` | `last_processed_block: 5000000` | matches replay height |
| `get_account_financial_summary` | 20 rows for `stellabelle` (2016) | Author/Curation/Witness/Transfer/Power Up/Down categories |
| `get_account_rc_footprint` | `[]` | correct — RC ops are HF20 (2018+), absent in 2016; RC consumption is also blocked on standard HAF (see D5) |
| `get_network_rc_utilization` | `[]` | same reason (see D5) |
| `get_network_hp_distribution` | 8 buckets, 92,190 accounts | ~69% in 1–10 HP — plausible long-tail |
| `get_network_account_funnel` | 7 monthly cohorts w/ 7/30/90d retention | plausible early-network retention |

## Divergences found & fixed

### D1 — Owner role `NOINHERIT` cannot create the HAF context
`db/builtin_roles.sql` created `haf_stats_owner LOGIN NOINHERIT`. As a NOINHERIT
member of `hive_applications_owner_group` it cannot `INSERT`/`UPDATE`
`hafd.contexts`, so `hive.app_create_context()` fails with *permission denied for
table contexts*, and `main()` cannot advance the block pointer.
**Fix:** create the role `LOGIN INHERIT` (like the working `btracker_owner`); the
existing `GRANT hive_applications_owner_group TO haf_stats_owner` then inherits by
default, since PG16+ takes a membership's inherit flag from the member role's
attribute at grant time. (Explicit `WITH INHERIT TRUE` also works at runtime but
isn't parseable by sqlfluff 3.3.0, so it would fail the `sql-lint` CI gate.)
Related: README TODO #3 (HAF lifecycle).

### D2 — `version.sql` generated but never executed
The `Dockerfile` writes `db/version.sql` (the `git_hash` INSERT) but nothing ran
it, so `get_version()` / `get_health.version` returned `NULL`.
**Fix:** `scripts/install_app.sh` now runs `db/version.sql` when present. The
generated `version.sql` also `TRUNCATE`s `app_version` before inserting, so the
re-runnable install keeps it a singleton (no accumulating/stale rows).

### D3 — `block_num` filter (investigated, **reverted** — not the bottleneck)
Initial hypothesis: because `hive.operations_view.block_num` is computed as
`hafd.operation_id_to_block_num(id)`, `WHERE block_num BETWEEN …` would be
non-sargable and seq-scan `hafd.operations`. This was **wrong**: `EXPLAIN` shows
the predicate uses the functional index `hive_operations_block_num_trx_in_block_idx`
(an index scan, not a seq scan). btracker uses the same `block_num BETWEEN` pattern
(`db/btracker_app.sql`), and an `operation_id`-range rewrite is index-equivalent
(it just switches to `pk_hive_operations`). The change was therefore **reverted**
to plain `block_num BETWEEN _first_block AND _last_block` to match btracker and
keep the diff minimal. The real cost was D4. (hafbe does use `operation_id`
ranges, so either style is idiomatic in HAF apps.)

### D4 — `process_financial` joins the heavyweight `blocks_view` (perf) — the real fix
Each of its 9 queries joined `hive.blocks_view` (a wide UNION view over reversible
+ irreversible blocks) just for `created_at`. Joining it repeatedly is the actual
bottleneck: `process_financial(1,20000)` took **224 s** with `blocks_view` vs
**~0.2 s** with `hafd.blocks`. btracker hits the same issue and solves it by
**materializing** `blocks_view` (its source literally comments
`-- WHY MATERIALIZED: Prevents repeated joins to hive.blocks_view.`).
**Fix:** `process_financial` joins `hafd.blocks` directly (cohorts already did).
After this, `process_block_range(1,1000000)` runs in ~12 s.

### D5 — `process_rc` op-type names missing the `hive::protocol::` prefix
`hafd.operation_types` stores fully-qualified names (e.g.
`hive::protocol::custom_json_operation`, id 18). `process_rc` looked up
`'custom_json_operation'` (no prefix) → `NULL` → custom_json DApp attribution
silently lost.
**Fix:** use the prefixed name (matches `process_financial`).
**BLOCKED (README TODO #2 / issues #3, #18) — the whole RC footprint feature is
non-functional on standard HAF.** Confirmed on three independent environments:
- 2016 local node and **mainnet 1.28.6 @ block ~107M**: `hafd.operation_types`
  has **no** `rc`/`resource`/`mana`/`statuses` op type at all.
- btracker (the working sibling) reads RC only via `custom_json` `id='rc'`
  (delegations), never an `rc_account_statuses` op type.
- **Live mainnet deployment** (`testapi.hivescan.info`): `get_account_rc_footprint`
  and `get_network_rc_utilization` return `[]` for every account *and* the
  all-account/all-time network aggregate — i.e. `rc_operation_log` is empty
  network-wide, not "everyone has 0 RC" (impossible: RC is consumed by every op).

Root cause: per-transaction RC **consumption** (`rc_account_statuses_operation`)
is RC-plugin mana accounting in the `hive::plugins::rc` namespace; HAF's
`sql_serializer` only captures `hive::protocol::*` ops, so it never enters
`hive.operations_view`. The op-name prefix fix is necessary-but-insufficient —
there is no source data. Decision for the owner: drop the RC footprint feature,
or build a dedicated RC-plugin→HAF ingest. (Note: issue #3 was closed on a wrong
premise — it fixed body-shape parsing for an op that never arrives.)

### D6 — `get_network_hp_distribution` cross-schema btracker mismatch
The function assumed btracker stores `nai` as the string `'@@000000037'`, but
this btracker stores `nai` as a smallint code (`13`=HBD, `21`=HIVE, `37`=VESTS),
giving *invalid input syntax for type smallint*. A second bug: the final
`SELECT`/`ORDER BY` referenced `bucket`, ambiguous with the `RETURNS TABLE` OUT
param.
**Fix (endpoints/endpoint_schema.sql):** `b.nai = 37`; qualify `balances.bucket`.
Also requires the documented grant (`GRANT USAGE ON SCHEMA btracker_app` +
`SELECT ON btracker_app.current_account_balances TO haf_stats_user`).

**Deployment dependency (NOT an architectural flaw).** Reading btracker's table
cross-schema is a *standard* HAF pattern: the hafbe stack bundles balance_tracker
as a git submodule (`haf_block_explorer/.gitmodules` → `submodules/btracker`) and
installs it into the **same** HAF database. So `hp-distribution` is fine *when
co-located* — verified locally where `hafbe_app`, `btracker_app`, `haf_stats_app`,
`reptracker_app` all share one `haf_block_log` DB and the endpoint returns the 8
buckets. On the live deployment (`testapi.hivescan.info`) it returns a clean
`[]` instead, which is the `EXCEPTION WHEN undefined_table` path (a *missing grant*
would raise `insufficient_privilege`, which the function does **not** catch → a
5xx, not `[]`). So `btracker_app` simply isn't visible to haf_stats there. Two
deployment causes:
1. haf_stats deployed in a **separate** HAF database from the btracker stack; or
2. **schema-name mismatch** — hafbe installs btracker under a *configurable*
   schema (default **`hafbe_bal`**, via `--btracker-schema`), but haf_stats
   **hardcodes** `btracker_app.current_account_balances`. If btracker is installed
   as `hafbe_bal`, the hardcoded reference fails even when co-located.

**Fix (operational, not a redesign):** co-locate haf_stats in the same HAF DB as
btracker (the hafbe model) + the grant, **and** align the schema name — either
install btracker as `btracker_app`, or parameterize the schema in
`get_network_hp_distribution` (as hafbe already does via `--btracker-schema`).

### D7 — Test stack could not host a HAF app context
`docker-compose-test.yml` ran HAF with `--skip-hived` against an **empty** DB, so
`hafd.events_queue`/`hafd.fork` were empty and `app_create_context()` failed the
`fk_hive_app_context (events_id → hafd.events_queue)` FK. The committed command
also pointed at a non-existent `/home/hived/run_hived.sh` (the image entrypoint is
`docker_entrypoint.sh`, driven by `--replay --stop-at-block=N`).
**Fix:** the `haf` service now mounts the pre-synced block_log and replays a
bounded range (`REPLAY_STOP_AT_BLOCK`, default 100000) so real HAF state exists;
the healthcheck waits for `MAX(num) >= REPLAY_STOP_AT_BLOCK` before install runs.
Related: README TODO #6 (HAF version/state must match app assumptions).

### D8 — Test-stack API host-port clash
`haf-stats-api` hard-bound host `3001`, which collides with other local HAF
services. Tavern reaches the API over the compose network, so the host mapping is
only for manual access.
**Fix:** parameterized as `${TEST_API_PORT:-3001}:3000`.

## Issue #20 follow-up items (review of MR !9) — status

Live-node verification of the 5 review items in issue **#20**:

- **#20.1** (Med, `hafd.blocks` columns for hp_distribution): columns **exist** —
  feared cause is a non-issue. The *actual* every-request failure was the btracker
  `nai` smallint mismatch (**D6**), which the review missed; now fixed. **Closed.**
- **#20.2** (Med, `transacting_account_id` on `account_operations_view`): column
  **exists** (`integer`); cohort processor runs clean. **Verified — closeable.**
- **#20.3** (Design, full-table aggregate every call): **fixed** — step 3 now
  restricts the `GROUP BY` to recent cohorts
  (`WHERE cohort_month >= DATE_TRUNC('month', _block_time - INTERVAL '90 days') - INTERVAL '1 month'`),
  so recompute is bounded to a fixed window instead of all history. (Verified:
  `HashAggregate` rows 7→5 on the 2016 dataset; the scan/upsert no longer grows
  with chain age.)
- **#20.4** (Minor, early partial-data disclosure): **fixed** — `active_at_Nd` is
  revealed only once `cohort_month + 1 month + N days <= _block_time`. (Verified:
  the most-recent cohort's `active_at_7d` flipped from an understated 5742 to
  `null` until its window truly elapses.)
- **#20.5** (Low, empty `hafd.blocks` → silent `[]`): **documented** rather than
  raised, to stay consistent with the function's existing graceful-degradation
  (`EXCEPTION WHEN undefined_table`) and not break the CI fixture (which seeds an
  empty `hafd.blocks`). The `[]`-means-"not ready" contract is now in the OpenAPI
  description and a code comment.

### D9 — `integration-tests` would have tested a stale image
The CI stages run `lint → test → build`, so `integration-tests` (stage `test`)
runs *before* `docker-build` (stage `build`) — and `docker-build` only tags
`$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA` without pushing. `docker-compose-test.yml`
runs `${HAF_STATS_REGISTRY}/haf_stats:${HAF_STATS_VERSION}` (= `…:latest`), so the
job would have pulled the registry's existing `:latest` and tested *that*, not the
commit under review (a green run would not have meant the MR works).
**Fix:** the job pins `HAF_STATS_VERSION=$CI_COMMIT_SHORT_SHA` and `docker build`s
that exact tag into the dind daemon before `run_tests.sh`. The SHA tag doesn't
exist in the registry, so compose must use the freshly built image.

**Status — kept commented (pipeline parity with develop).** The job replays from a
pre-synced block_log at `docker/blockchain/`, which CI runners don't have
(it's gitignored / local-only). So enabling it would fail every MR pipeline.
balance_tracker gets its block_log from the Hive CI infra — a runner-mounted
`/blockchain/block_log_5m` plus an NFS replay cache — orchestrated by the
`common-ci-configuration` HAF templates it `include`s (`haf_data_preparation`,
`haf_app_testing`). **Follow-up:** wire haf_stats into those templates, then enable
the job. The job body is verified to work locally (build-this-commit's-image +
bounded replay).

### D10 — Missing input validation on RC endpoints (latent 500) — found by edge testing
`get_network_rc_utilization` passed `_granularity` straight into
`DATE_TRUNC(_granularity, …)` with no validation; an unsupported unit (e.g.
`fortnight`) raises `unit "..." not recognized` → HTTP 500. It only looked fine on
the 2016 node because `rc_operation_log` is empty (DATE_TRUNC never evaluated);
with one injected RC row it errors. `get_account_rc_footprint` likewise accepted
any `_group_by` (silently falling back to `op_type`). `get_account_financial_summary`
already guarded its granularity, so this was an inconsistency.
**Fix:** both converted to `plpgsql` with an enum guard
(`RAISE SQLSTATE '22023'` → HTTP 400), mirroring the financial-summary validation.
Columns qualified / positional `ORDER BY` to avoid OUT-parameter ambiguity.
Verified: bad values → 400; valid values still aggregate correctly (day/week/month,
op_type/app) against injected rows.

### D11 — Embedded OpenAPI spec stale + generator truncation bug (review follow-up)
`root()`'s embedded OpenAPI was stale: it had 6 of the 7 paths but was **missing
`/network/account-funnel`** and the **`#20.5` HP empty-array description**. Two root causes:
1. `root()` hand-wrote a `LANGUAGE sql` **static** JSON instead of the sibling
   generator pattern (a plpgsql `root()` with a `-- openapi-spec` marker that
   `scripts/openapi_rewrite.sh` fills), so regeneration never touched it.
2. `scripts/openapi_rewrite.sh` passed an **absolute** input path; `process_openapi.py`
   does `output_dir / Path(input)`, and Python's `Path(out) / Path('/abs')` returns
   the absolute path — so the generator opened the **source itself** with `mode='w'`
   and truncated it to 0 bytes.
**Fix:** converted `root()` to the plpgsql `-- openapi-spec` pattern (btracker as
reference) and fixed the wrapper to run from the repo root with a **relative** input
path. Regenerated — all 7 paths + the `#20.5` description now present; verified the
function installs and `root()->'paths'` returns every endpoint. (`endpoint_schema.sql`
is in `.sqlfluffignore`, so it's exempt from the sql-lint gate regardless.)

### Review-follow-up hardening (D1/D2/D9)
- **D1 idempotency:** `builtin_roles.sql` now `ALTER ROLE … INHERIT` + `REVOKE`/`GRANT`s
  the group membership, so a re-install over an earlier `NOINHERIT` role/membership is
  repaired (PG16 freezes a membership's inherit flag at grant time).
- **D2 singleton:** generated `version.sql` `TRUNCATE`s before insert (see D2).
  `app_status` is seeded the same way — `INSERT … WHERE NOT EXISTS` so re-install
  can't add a duplicate `(TRUE, 0)` row that `get_health` (`LIMIT 1`, no `ORDER BY`)
  might otherwise return as block 0.
- **D9 registry:** `integration-tests` derives `HAF_STATS_REGISTRY` from
  `$CI_REGISTRY_IMAGE` instead of a hardcoded URL, so the built tag always matches
  the compose image; for this project (whose `$CI_REGISTRY_IMAGE` ends in
  `/haf_stats`) it also matches `docker-build`'s tag.

## Verification TODOs confirmed *resolved* against the real node

- **TODO #1 (`hafd.blocks` supply columns):** present — `total_vesting_fund_hive,
  total_vesting_shares, total_reward_fund_hive, virtual_supply, current_supply,
  current_hbd_supply`. (`get_network_supply` itself is still unimplemented.)
- **TODO #3 (`app_next_iteration` signature):** node exposes
  `(IN _context hafd.context_name, OUT _blocks_range hive.blocks_range,
  IN _override_max_batch int, IN _limit int)` — the develop `main()` call matches.
- **TODO #4 (`is_virtual`):** `hive.operations_view` does **not** expose
  `is_virtual`, but `hafd.operation_types` does; the develop code already filters
  via `operation_types.is_virtual`, so the concern is moot.

## Open / not yet resolved (decisions for the maintainer)

- **RC footprint feature is blocked** (D5): no source data on standard HAF. Needs a
  dedicated RC-plugin→HAF ingest, or drop the feature.
- **`hp-distribution` requires btracker co-located** in the same DB + the schema name
  aligned (D6): the endpoint hardcodes `btracker_app`, while hafbe installs btracker
  under a configurable schema (default `hafbe_bal`).
- **`integration-tests` enablement** (D7/D9): kept commented; enable once haf_stats is
  wired into the `common-ci-configuration` HAF data-prep templates so CI has a
  block_log (the btracker pattern).
