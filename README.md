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
| `get_network_rc_utilization` | Network-wide RC consumption by category — not in any existing API |
| `get_network_supply` | HIVE/HBD/VESTS supply **time-series** — existing TVL endpoint is snapshot-only |
| `get_network_hp_distribution` | Bucketed HP stake distribution — existing top-holders is a ranked list, not bucketed |
| `get_network_vote_stats` | Network-wide vote activity time-series (up/down/unvotes, self-votes, unique voters) — no existing API aggregates votes |
| `get_network_content_volume` | Posts/comments **created** per period + unique authors (chain-exact: edits excluded, delete→re-create counted) — no existing API aggregates content volume |
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

## API Endpoints

All endpoints are served via PostgREST. Base URL: `http://localhost:3001`

| Endpoint | Status | Processor | Description |
|---|---|---|---|
| `GET /rpc/get_version` | ✅ Live | — | App git hash |
| `GET /rpc/get_health` | ✅ Live | — | Last processed block + version |
| `GET /rpc/get_account_financial_summary` | ✅ Live | process_financial.sql | Per-account incoming/outgoing by category, granularity |
| `GET /rpc/get_account_content_stats` | ✅ Live | process_content_stats.sql | Per-account posts/comments/votes/replies + author rewards, granularity |
| `GET /rpc/get_account_rc_footprint` | ⚠️ Blocked | process_rc.sql | Returns `[]` — RC consumption ops are not in HAF's op stream (see Known TODOs #2 / `docs/VERIFICATION.md`) |
| `GET /rpc/get_network_rc_utilization` | ⚠️ Blocked | *(uses rc_operation_log)* | Returns `[]` — same RC ingest blocker as above |
| `GET /rpc/get_network_supply` | Pending | process_network_stats.sql | HIVE/HBD/VESTS supply time-series |
| `GET /rpc/get_network_hp_distribution` | ✅ Live | *(cross-schema btracker_app)* | HP stake bucketed distribution |
| `GET /rpc/get_daily_active_users` | ✅ Live | process_active_users.sql | Distinct authoring accounts + operation volume per period, by op-type filter and granularity |
| `GET /rpc/get_network_vote_stats` | ✅ Live | process_content_stats.sql | Network-wide vote activity (up/down/unvotes, self-votes, unique voters), granularity |
| `GET /rpc/get_network_content_volume` | ✅ Live | process_content_stats.sql | Posts/comments created + unique authors per period (create-vs-edit aware), granularity |
| `GET /rpc/get_network_top_accounts` | ✅ Live | *(reads financial + active-users tables)* | Top N accounts by rewards, transfer volume, HP balance, or op count |
| `GET /rpc/get_hp_delegation_graph` | Shelved | — | No concrete consumer identified yet |
| `GET /rpc/get_governance_proxy_chains` | Shelved | — | Proxy chains shallow in practice; single-level in hafbe-api |

## DApp Attribution

RC costs for `custom_json` operations are attributed to DApps via `haf_stats_backend.custom_json_app_registry`. To add a new DApp:

```sql
INSERT INTO haf_stats_backend.custom_json_app_registry
    (app_id_pattern, app_name, category)
VALUES ('my_app_', 'My App', 'Gaming');
```

Submit additions via MR to `db/seed_data.sql`.

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
