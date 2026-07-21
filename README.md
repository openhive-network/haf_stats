# haf_stats

A HAF application providing financial categorization, RC attribution, delegation graph traversal, proxy chain resolution, and supply time-series for the Hive blockchain.

## Scope

Serves as the backend data layer for:
- **Item 7** — HAF Backend APIs (financial analysis per user, RC footprint, network supply)
- **Item 4** — RC Footprint & DApp Usage Dashboard
- **Item 5** — Influence & Delegation Map (graph traversal only)
- **Item 6** — Hive Reporting Dashboard (supply, RC utilization, HP distribution)

### What this app covers

Only endpoints with **no equivalent in any existing HAF API**. Before adding anything new, check the existing APIs at `api.syncad.com`.

| Endpoint | Unique because |
|---|---|
| `get_account_financial_summary` | Categorized incoming/outgoing flows per account — not in any existing API |
| `get_account_rc_footprint` | RC cost by op type and DApp — not in any existing API |
| `get_account_content_stats` | Per-account posting & engagement (posts/comments/votes/replies) + author rewards — not aggregated in any existing API |
| `get_account_community_activity` | Per-account posts/comments grouped by community — hivemind's `bridge` API returns paginated post *lists* with a community field, never per-community counts |
| `get_network_rc_utilization` | Network-wide RC consumption by category — not in any existing API |
| `get_network_supply` | HIVE/HBD/VESTS supply **time-series** — existing TVL endpoint is snapshot-only |
| `get_network_hp_distribution` | Bucketed HP stake distribution — existing top-holders is a ranked list, not bucketed |
| `get_network_vote_stats` | Network-wide vote activity time-series (up/down/unvotes, self-votes, unique voters) — no existing API aggregates votes |
| `get_network_content_volume` | Posts/comments **created** per period + unique authors (chain-exact: edits excluded, delete→re-create counted) — no existing API aggregates content volume |
| `get_network_author_retention` | First-post author cohorts + 30/90/180-day created-content retention (edits excluded) — distinct from all-account funnel retention |
| `get_network_top_accounts` | Time-bounded multi-metric account leaderboard (rewards, transfers, HP, op counts) — balance-api has per-account history only, hafbe has witness rankings only |
| `get_hp_delegation_graph` | Recursive delegation graph from a root account — per-account list exists in balance-api, recursive traversal does not |
| `get_governance_proxy_chains` | Recursive proxy chain traversal (A→B→C→D) — hafbe-api has single-level proxy-power only |

### What is covered elsewhere — do not re-implement

| Data | Covered by |
|---|---|
| HP delegations per account (list) | `balance-api /accounts/{account}/delegations` |
| RC delegations per account (list) | `balance-api /accounts/{account}/rc-delegations` |
| Witness list, voter counts, vote history | `hafbe-api /witnesses` and sub-routes |
| DHF proposal vote history (per-proposal audit log) | `hafbe-api` — MR 485 (`get_proposal_votes_history`) |
| DHF proposal voter counts (aggregate) | `hafbe-api` — belongs there for governance consistency |
| Transaction throughput time-series | `hafbe-api /transaction-statistics` |
| Transfer volume aggregates | `balance-api /transfer-statistics` |
| DAU / total accounts | `hafbe-api` (in development) |
| TVL (current snapshot) | `balance-api /total-value-locked` |

## Architecture

Follows the standard HAF app pattern:

```
hived (consensus node)
  └─ sql_serializer → PostgreSQL (hafd schema)
                          └─ haf_stats (this app)
                               ├─ haf_stats_backend  (tables)
                               ├─ haf_stats_endpoints (PostgREST API)
                               └─ haf_stats_app       (control + main loop)
```

All business logic lives in PL/pgSQL. No application server.

## Directory Structure

```
db/
  builtin_roles.sql         Role definitions
  haf_stats_app.sql         Schemas, control tables, HAF context, main() loop
  process_block_range.sql   Block range dispatcher (calls all processors in order)
  process_financial.sql     ✓ Author rewards, curation, interest, transfers, power-up/down
  process_rc.sql            ⚠ RC cost attribution — BLOCKED: rc_account_statuses ops are not captured by HAF (see docs/VERIFICATION.md)
  process_content_cohorts.sql
                            ✓ First-post author retention cohorts
  process_community_registry.sql
                            ✓ Community names/types/titles from account_created + community
                            custom_json ops (owner/admin gated)
  process_delegations.sql   HP delegation current state (graph traversal only; per-account list → balance-api)
  process_governance.sql    Proxy chain current state only (witness + DHF proposal data → hafbe-api)
  process_network_stats.sql Supply snapshots from hafd.blocks (DAU/tx stats → hafbe-api)

endpoints/
  endpoint_schema.sql       All PostgREST-exposed SQL functions
  rewrite_rules.conf        nginx URL → RPC function mappings

scripts/
  common.sh                 Shared variables and helpers
  install_app.sh            One-time schema installation
  process_blocks.sh         Starts the infinite block-processing loop
  rebuild_account_cohorts.sh
                            Rebuilds account cohorts after definition changes
  rebuild_content_cohorts.sh
                            Rebuilds content-creator cohorts (required on already-synced nodes)
  rebuild_community_registry.sh
                            Re-derives community names/types/titles (idempotent; install
                            self-heals an empty registry, so this is for forced rebuilds)
  rebuild_content_volume.sh
                            Rebuilds network content-volume tables and per-account content
                            columns (repairs double-counts / stale post over-reporting) and
                            populates the community dimension on already-synced nodes
  rebuild_financial.sh      Rebuilds account financial aggregates after category changes

docker/
  docker-compose.yml        Production stack (4 services)
  docker-compose-test.yml   Fast test stack (pre-synced block_log)
  .env                      Image versions and registry

tests/
  tavern/                   API integration tests (pytest + Tavern)
```

## Quick Start (Development)

**Prerequisites:** Docker, a pre-synced HAF `block_log` snapshot in `docker/blockchain/`.

```bash
cd docker
cp .env .env.local   # edit versions as needed
docker compose -f docker-compose-test.yml up --abort-on-container-exit
```

**Production:**

```bash
cd docker
docker compose up -d
```

### Rebuilding account cohorts

Changes to account-creation or retention definitions require rebuilding the
historical cohort tables. Stop the block processor, then run:

```bash
./scripts/rebuild_account_cohorts.sh
```

`FROM_BLOCK`, `TO_BLOCK`, and `BATCH_SIZE` may be supplied as environment
variables. Restart the processor after the rebuild completes.

### Rebuilding content cohorts

`get_network_author_retention` builds its cohort membership
(`author_cohort_members`) only by processing blocks forward, so deploying it onto
an already-synced node leaves the historical cohorts empty — the install hook only
rebuilds the summary *from* that membership table. Run this one-time backfill
after install, with the block processor stopped:

```bash
./scripts/rebuild_content_cohorts.sh
```

It reads `network_author_daily`, so `get_network_content_volume` must already be
installed with its history present. `FROM_BLOCK`, `TO_BLOCK`, and `BATCH_SIZE` may
be supplied as environment variables. Restart the processor after it completes.

For a one-time full-history rebuild, raise `BATCH_SIZE` well above the `10000`
default — content cohorts are heavy per block (a `comment_operation` scan plus a
180-day pending-member rescan each batch), so `BATCH_SIZE=1000000` rebuilds full
mainnet history (~107.6M blocks) in roughly 1h35m versus ~10,760 batches at the
default. The script `TRUNCATE`s `author_cohort_retention` first, so on an
already-populated node `get_network_author_retention` returns `[]` until the
rebuild's final refresh — run it as a maintenance window.

### Rebuilding financial aggregates

The financial category/direction vocabulary changed in issue #26 (canonical
op-type names + `incoming`/`outgoing`). On an already-populated deployment the old
rows are keyed differently and are never overwritten, so they must be cleared and
reprocessed. Stop the block processor first, re-run `install_app.sh` (it migrates
and validates the direction CHECK, deletes legacy rows, and drops the legacy
`op_financial_categories` table), then:

```bash
./scripts/rebuild_financial.sh
```

`FROM_BLOCK`, `TO_BLOCK`, and `BATCH_SIZE` may be supplied as environment
variables. By default `TO_BLOCK` is the app's recorded `last_processed_block`,
not the HAF head; values beyond `last_processed_block` are rejected so restarting
the processor cannot process rebuilt blocks a second time. Restart the processor
after the rebuild completes.

### Rebuilding content volume

`get_network_content_volume`'s daily counters (`network_content_daily`) are
accumulated with an **additive** upsert (`posts = posts + EXCLUDED.posts`), because
a calendar day is assembled from many block-range batches. That makes the counters
non-idempotent: any out-of-band reprocess of an already-counted block range
double-counts posts/comments (issue #42). Author counts are a membership set and
stay correct. **Do not** repair by hand-running `SELECT process_content_stats(...)`
— that reintroduces the double-count (and re-doubles votes/engagement, which share
that scan). Use this script, which drives the narrow `process_content_volume` and
starts from a clean slate:

```bash
./scripts/rebuild_content_volume.sh
```

This same script also repairs a stale over-report in **`account_content_daily`**'s
content columns (`get_account_content_stats`): before the create/edit dedup landed
(#13) the per-account path counted raw comment ops — edits included — as posts, and
unlike the network tables `account_content_daily` had no rebuild path, so affected
deployments kept the inflation permanently. `process_content_volume` now rebuilds its
`posts`/`comments`/`replies_received` creates-only from the same genesis registry
replay (so `SUM(account.posts) == network.posts` by construction). It **zeroes** those
three columns rather than truncating the table, because `votes_cast`/`votes_received`
come from a separate vote scan this path does not reproduce and are already correct —
they are preserved untouched. One rebuild therefore fixes both defects at once.

The rebuild covers exactly `[1, last_processed_block]`, clears the three network content
tables (and zeroes the account content columns), replays ascending batches, then reseals
the endpoint rollup `network_content_period_counts` in one transaction. Because the
network endpoint reads only that rollup — refreshed last — it keeps serving the previous
series until the reseal commits, so it never returns partial history. `account_content_daily`
is read directly (no rollup), so `get_account_content_stats` shows low/growing counts
during the offline rebuild window — the same accepted behavior as `rebuild_financial.sh`.

The range is fixed at both ends, not merely defaulted, because content volume carries
cross-batch state (`comment_registry`) that the other rebuild scripts do not:

* The start block is always `1` and is not configurable — create-vs-edit classification
  replays the registry from genesis, so a partial-range rebuild misclassifies.
* `TO_BLOCK` must equal `last_processed_block` (its default). A **short** rebuild
  strands the registry at `TO_BLOCK` while the processor resumes at
  `last_processed_block + 1` and never revisits the gap: the gap's days stay missing
  from `network_content_daily` forever, and later edits of comments created there are
  miscounted as new posts. A **long** one double-counts after restart.

> **If the rebuild fails or is interrupted part-way, do not start the processor.** The
> `TRUNCATE`/zeroing and every completed batch have already committed, so the tables
> describe only a prefix of history while `last_processed_block` still points at the tip
> (`account_content_daily`'s content columns are likewise zeroed-then-partially-rebuilt
> and under-report). Restarting the processor would resume past the gap with a stranded
> registry and corrupt the counts permanently. Re-run the script to completion first —
> each run re-`TRUNCATE`s the network tables and re-zeroes the account content columns
> from a clean slate, so re-running is always safe, and after a failure it is mandatory.

`BATCH_SIZE` defaults to `1000000`: content volume is heavy per block and each batch is
its own `psql` process, so full mainnet history (~107.6M blocks) is ~108 batches rather
than the ~10,760 the old `10000` default would have cost. Measured read-only against a
~108M-block mainnet node: ~1.5h for the scan/classify pipeline alone (throughput tracks
comment-op density, not block count — 2019 is the heaviest era, not 2023), plus the three
`INSERT`s (`network_author_daily` alone ends up ~21M rows) and per-batch connect/plan
overhead on top. **Budget ~2–4h wall-clock for a full genesis rebuild on a mainnet-sized
node.** The processor must stay stopped for the entire run — not just for the duration,
but because `haf_stats` falls behind on votes/engagement/account stats while it's down and
needs time to catch up afterward. Plan the maintenance window accordingly.

The script refuses to start while a `haf_stats_app.main` backend is live, and re-checks
before the reseal in case one started mid-rebuild — stop the processor first
(`SELECT haf_stats_app.stop_processing();` or stop the `haf-stats-process` container)
and restart it after the rebuild completes.

Recurrence is also blocked at the database level: `process_content_stats` now refuses any
block range at or below `app_status.last_processed_block`, so the out-of-band reprocess
that caused #42 raises instead of silently double-counting. The HAF context is
non-forking, so the live loop only ever moves strictly forward and is unaffected.

The likely proximate cause of #42 — `process_content_volume_backfill`, an unguarded
additive-upsert function that was never committed to this repo but existed as drift on at
least one deployment, writing exactly the three tables found doubled — is dropped by
`install_app.sh` on every install/migration, not just by hand on the affected node.
`process_content_volume` (above) is itself additive and unguarded in the same way; it is
safe only because `rebuild_content_volume.sh` always `TRUNCATE`s first. Do not call either
function directly outside that script.

This is also the **only** way to populate the community dimension
(`comment_registry.community` + `account_community_daily`, feeding
`get_account_community_activity`) on a deployment that synced before that feature landed.
It cannot be self-healed at install time like the other rollups: a comment's community is
inherited from its root post, and the create-vs-edit classification that identifies
creations only replays correctly from genesis. Run
`./scripts/rebuild_community_registry.sh` **first** (so the classification sees a complete
registry), then `./scripts/rebuild_content_volume.sh`.

### Rebuilding the community registry

`community_registry` / `community_role` hold community names, types and titles. Unlike the
content rebuilds, `process_community_registry` is **idempotent** — registration is
`ON CONFLICT DO NOTHING` and roles/titles are last-writer-wins over an ordered replay — so
`install_app.sh` self-heals the table automatically whenever it is empty and the app has
already processed blocks. Use the script only when it is *not* empty and must be
re-derived, e.g. after changing the authorization rules:

```bash
./scripts/rebuild_community_registry.sh
```

The range starts at Hivemind's community start block (37,500,000), not block 1: no account
created before it is ever a community, so earlier blocks cannot contribute. `FROM_BLOCK` is
not configurable, because roles are ordered state — an account can only grant a role it
already holds — so a partial start would drop the grants that authorize later
`setRole`/`updateProps` ops.

## API Endpoints

All endpoints are served via PostgREST. Base URL: `http://localhost:3001`

| Endpoint | Status | Processor | Description |
|---|---|---|---|
| `GET /rpc/get_version` | ✅ Live | — | App git hash |
| `GET /rpc/get_health` | ✅ Live | — | Last processed block + version |
| `GET /rpc/get_account_financial_summary` | ✅ Live | process_financial.sql | Per-account incoming/outgoing by category, granularity |
| `GET /rpc/get_account_content_stats` | ✅ Live | process_content_stats.sql | Per-account posts/comments/votes/replies + author rewards, granularity |
| `GET /rpc/get_account_community_activity` | ✅ Live | process_content_stats.sql + process_community_registry.sql | Per-account created posts/comments grouped by community (replies attributed to their ROOT post's community), plus a personal-blog bucket that makes the buckets sum to `get_account_content_stats` |
| `GET /rpc/get_account_rc_footprint` | ✅ Live | process_rc.sql | Estimated RC for an account's signed ops, grouped by op type or DApp (`group_by=app` resolves custom_json ids to DApp names via `custom_json_app_registry`); read-time rates (#32/#33) |
| `GET /rpc/get_network_rc_utilization` | ✅ Live | process_network_ops.sql | Network-wide estimated RC per op type per period (read-time rates); op-type granularity, no per-DApp breakdown |
| `GET /rpc/get_network_supply` | Pending | process_network_stats.sql | HIVE/HBD/VESTS supply time-series |
| `GET /rpc/get_network_hp_distribution` | ✅ Live | *(cross-schema btracker_app)* | HP stake bucketed distribution |
| `GET /rpc/get_governance_influence_concentration` | ✅ Live | process_governance_concentration.sql | Current HP concentration snapshot: Gini, top 1%/10% share, holder count, median and mean HP |
| `GET /rpc/get_daily_active_users` | ✅ Live | process_active_users.sql | Distinct authoring accounts + operation volume per period, by op-type filter and granularity |
| `GET /rpc/get_network_vote_stats` | ✅ Live | process_content_stats.sql | Network-wide vote activity (up/down/unvotes, self-votes, unique voters), granularity |
| `GET /rpc/get_network_content_volume` | ✅ Live | process_content_stats.sql | Posts/comments created + unique authors per period (create-vs-edit aware), granularity |
| `GET /rpc/get_network_author_retention` | ✅ Live | process_content_cohorts.sql | First-post author cohorts with created-content retention at 30/90/180 days |
| `GET /rpc/get_network_top_accounts` | ✅ Live | *(reads financial + active-users tables)* | Top N accounts by rewards, transfer volume, HP balance, or op count |
| `GET /rpc/get_hp_delegation_graph` | Shelved | — | No concrete consumer identified yet |
| `GET /rpc/get_governance_proxy_chains` | Shelved | — | Proxy chains shallow in practice; single-level in hafbe-api |

## Community Attribution

Communities are hivemind state, and there is no hivemind schema on a HAF node running this
app, so `get_account_community_activity` derives them from raw operations. The rules, taken
from hivemind's `hive/indexer/community.py` and verified against live chain data:

* A community is an account matching `^hive-[1-3][0-9]{4,6}$`, registered when that account
  is **created at or after block 37,500,000** (hivemind's `start_block`). An identically
  named account created earlier is never a community, so no pre-2019 content can belong to
  one — the whole feature is a no-op over that history.
* A **root post** belongs to the community named by its `parent_permlink` (its category),
  when that community was already registered at the post's block. Note this is the
  `parent_permlink`, *not* `json_metadata.community`: the old spec describes the latter, but
  live frontends use the former (`@behiver/hivepulseapp-…` posts to `hive-139531` with an
  empty `parent_author` and `parent_permlink = hive-139531`, and no `community` key in its
  metadata).
* A **reply** belongs to its **root post's** community, not its immediate parent's. Verified
  on chain: `@blocktrades/ticn6q` sits at depth 6 with `parent_permlink =
  re-blocktrades-2026717t192753168z`, yet carries `category: hive-139531` — the root's
  community. A raw `comment_operation` names only its immediate parent, so every comment's
  resolved community is stored on `comment_registry.community` and the next reply down
  inherits it in one lookup.
* **Titles** come from `custom_json` ops with `id: "community"` carrying
  `["updateProps", {"community": …, "props": {"title": …}}]`, and are accepted only from a
  signer holding owner/admin — otherwise any account could rename any community. Roles are
  tracked from `setRole` ops, seeded with the community account itself as owner.

Two deliberate divergences from hivemind, documented on the endpoint too: a post is
attributed to the community it **addressed**, whereas hivemind additionally withholds the
assignment when the author is muted there or lacks posting rights in a journal/council
community; and only owner/admin roles are modelled, since nothing but title authorization
needs them.

## DApp Attribution

`custom_json` operations are attributed to DApps via `haf_stats_backend.custom_json_app_registry`, a longest-prefix `starts_with` match from a custom_json id to a DApp name + category. This drives `get_account_dapp_footprint` (full per-DApp/per-category dashboard) and the `group_by=app` mode of `get_account_rc_footprint` (ids that share a DApp roll up under one name; unmatched ids keep their raw id).

Apps are classified into a **9-category system** (8 assigned + the `Uncategorized` fallback for unmatched ids), shared with the block_explorer_ui RC Footprint dashboard:

| Category | Examples |
|---|---|
| Social Graph | follow, reblog, community |
| Social Front-Ends | PeakD, Ecency, InLeo, Liketu |
| Gaming | Splinterlands (`sm_`), Rising Star, dCity, Rabona, NextColony, Genesis League Sports (`gls-`), PeakMonsters (`pm_`) |
| DeFi & Tokens | Hive Engine (`ssc-`/`he_`/`scot_`), LeoDex, dLease, TribalDex |
| NFTs | NFT Showroom, NFTMart, DLUX |
| Media & Content | 3Speak, D.Buzz, Engrave |
| Community & Social DApps | Curangel, Actifit, OCD, TravelFeed |
| Governance & Infrastructure | RC delegations, SPK Network, Hive Keychain, VSC, Podping (`podping`/`pp_`) |

To add or recategorize a DApp:

```sql
INSERT INTO haf_stats_backend.custom_json_app_registry
    (app_id_pattern, app_name, category, homepage)
VALUES ('my_app_', 'My App', 'Gaming', NULL)
ON CONFLICT (app_id_pattern) DO UPDATE SET
    app_name = excluded.app_name, category = excluded.category, homepage = excluded.homepage;
```

Submit additions via MR to `db/seed_data.sql` (the registry upserts on install, so edits to existing rows are reconciled).

## Known TODOs

> **Verification status** (details in [`docs/VERIFICATION.md`](docs/VERIFICATION.md)):
> - **#1 supply columns** — RESOLVED: `total_vesting_shares`, `total_vesting_fund_hive`,
>   `total_reward_fund_hive`, `virtual_supply`, `current_supply`, `current_hbd_supply`
>   all exist on `hafd.blocks` on a live node.
> - **#2 rc_account_statuses body** — **BLOCKED, not just unverified:** that op type is
>   absent from HAF's catalog on 2016, mainnet, and the live deployment. RC consumption
>   lives in the `hive::plugins::rc` namespace, which `sql_serializer` does not capture,
>   so the RC footprint endpoints return `[]` on any standard HAF node.
> - **#3 app_next_iteration** — RESOLVED: the develop `main()` already matches the live
>   signature `(IN _context, OUT _blocks_range hive.blocks_range, IN max_batch, IN limit)`.
> - **#4 is_virtual** — moot: the code filters via `hafd.operation_types.is_virtual`
>   (which exists), not `hive.operations_view`.
>
> The original pre-verification text is kept below for history.

### 1. Verify `hafd.blocks` supply column names

**File:** `db/process_network_stats.sql` — `process_supply_snapshot()` function

`process_network_stats.sql` reads supply figures directly from `hafd.blocks`. The exact column names vary by HAF version and are currently marked as placeholders. Before enabling supply snapshots, run:

```sql
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'hafd' AND table_name = 'blocks'
ORDER BY ordinal_position;
```

Expected columns (names may differ): `current_supply`, `virtual_supply`, `current_hbd_supply`,
`total_vesting_fund_hive`, `total_vesting_shares`, `total_reward_fund_hive`.
Update the `SELECT` list in `process_supply_snapshot()` to match what the query returns.

---

### 2. Confirm `rc_account_statuses_operation` body schema

**File:** `db/process_rc.sql` — `process_rc()` function

The processor currently assumes **one account per virtual op**, extracting:
```
body -> 'value' -> 'account'              (account name)
body -> 'value' -> 'previous_rc'          (mana before tx)
body -> 'value' -> 'rc' -> 'current_mana' (mana after tx)
```

On a live node, inspect a sample op to confirm:
```sql
SELECT body
FROM hive.operations_view
WHERE op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'rc_account_statuses_operation' LIMIT 1)
LIMIT 5;
```

If the op instead batches accounts in an array under `body -> 'value' -> 'account_statuses'`,
replace the single-row extraction with `jsonb_array_elements(body -> 'value' -> 'account_statuses')`
(the `jsonb_array_elements` approach is already drafted in `-- Feature` comments in that file).

---

### 3. Confirm `hive.app_next_iteration` signature

**File:** `db/haf_stats_app.sql` — `main()` function

The main loop calls:
```sql
PERFORM hive.app_next_iteration(_context, _first_block, _last_block);
```

The exact signature (parameter names, OUT vs INOUT, return type) varies by HAF version. Confirm on a live node:
```sql
\df hive.app_next_iteration
```
or:
```sql
SELECT pg_get_functiondef(oid)
FROM pg_proc
WHERE proname = 'app_next_iteration' AND pronamespace = 'hive'::regnamespace;
```

If the signature differs — for example if `_first_block` / `_last_block` are returned as a composite type rather than INOUT parameters — adjust the `DECLARE` block and `PERFORM` call accordingly.

---

### 4. Confirm `is_virtual` column exists on `hive.operations_view`

**File:** `db/process_rc.sql` — `user_ops` CTE

The RC processor filters non-virtual ops with `AND is_virtual = FALSE`. If `hive.operations_view`
does not expose this column (some HAF versions route virtual ops to a separate
`hive.virtual_operations_view`), replace the filter with a join exclusion or switch
the RC event source to `hive.virtual_operations_view`:

```sql
-- Alternative if virtual_operations_view exists:
FROM hive.virtual_operations_view ov
WHERE ov.op_type_id = _rc_vop_type_id ...
```

Check available views with:
```sql
SELECT table_name FROM information_schema.views WHERE table_schema = 'hive';
```

---

### 5. Pending endpoints (not yet implemented)

The following are in scope but not yet added to `endpoint_schema.sql`:

| Endpoint | Processor needed | Notes |
|---|---|---|
| `get_network_supply` | `process_network_stats.sql` | Blocked on TODO #1 (hafd.blocks column names) |

Shelved (valid ideas, no concrete consumer identified yet):

| Endpoint | Reason |
|---|---|
| `get_hp_delegation_graph` | Recursive graph traversal — per-account list already in balance-api; no frontend consumer identified |
| `get_governance_proxy_chains` | Proxy chains are shallow in practice; single-level case covered by hafbe-api |

Endpoints confirmed out of scope for haf_stats:

| Endpoint | Reason |
|---|---|
| `get_governance_dhf_proposals` | DHF proposal vote history in hafbe MR 485; aggregate voter counts belong there too for governance consistency |
| `get_governance_witness_votes` | Fully covered by `hafbe-api /witnesses` and sub-routes |
| `get_hp_delegation_account` | Fully covered by `balance-api /accounts/{account}/delegations` |
| `get_account_rc_delegations` | Fully covered by `balance-api /accounts/{account}/rc-delegations` |
| `get_network_transactions` | Fully covered by `hafbe-api /transaction-statistics` |
| `get_network_transfer_volume` | Fully covered by `balance-api /transfer-statistics` |

---

### 6. Pin `HAF_VERSION` in `.env`

**File:** `docker/.env`

`HAF_VERSION` is currently set to `latest`. Before running against mainnet, pin it to a specific
image tag that matches the HAF node you are connecting to (e.g., `1.27.5`). A version mismatch
between the app's SQL assumptions and the running HAF node is the most likely source of
schema-related errors at startup.
