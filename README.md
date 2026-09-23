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
| `get_account_interactions` | Per-account outgoing interactions grouped by counterparty — every existing API groups an account's activity by op type or DApp, never by *who it was with* |
| `get_network_rc_utilization` | Network-wide RC consumption by category — not in any existing API |
| `get_network_custom_json_usage` | Per-`id` network custom_json usage time-series (op counts, bytes, estimated RC) — no existing API breaks custom_json out by id |
| `get_network_top_custom_json` | Leaderboard of most-used custom_json ids / DApps / categories — no existing API ranks custom_json actions |
| `get_witness_missed_blocks` | Windowed missed-vs-produced blocks per witness, with the produced-slot denominator that makes a reliability rate meaningful — hafbe-api exposes only a **lifetime** cumulative `missed_blocks` counter on the witness list, never a time-bounded figure or a series |
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
| Witness list, current rank, voter counts, vote history | `hafbe-api /witnesses` and sub-routes — haf_stats owns only the missed-block **time series** (`get_witness_missed_blocks`), and deliberately returns no rank/is_active so the two never drift |
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
  op_type_registry.sql      Every hafd.operation_types name / hardcoded op id the processors
                            depend on, plus the install-time assertion that verifies them
  process_financial.sql     ✓ Author rewards, curation, interest, transfers, power-up/down
  process_rc.sql            ⚠ RC cost attribution — BLOCKED: rc_account_statuses ops are not captured by HAF (see docs/VERIFICATION.md)
  process_content_cohorts.sql
                            ✓ First-post author retention cohorts
  process_community_registry.sql
                            ✓ Community names/types/titles from account_created + community
                            custom_json ops (owner/admin gated)
  process_witness_blocks.sql
                            ✓ Per-witness blocks produced + scheduled slots missed, per day
  process_network_stats.sql Supply snapshots from hafd.blocks (DAU/tx stats → hafbe-api)

Dockerfile                  App image (one image, three services, dispatched by verb)
Dockerfile.rewriter         The public REST surface: nginx + endpoints/rewrite_rules.conf

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
  rebuild_network_custom_json.sh
                            Rebuilds network custom_json usage (network_custom_json_daily)
                            on already-synced nodes (forward-only otherwise)
  rebuild_witness_blocks.sh Rebuilds per-witness block production (witness_blocks_daily)
                            on already-synced nodes (install self-heals an empty table)

docker/
  docker-compose.yml        Production stack (5 services + a profiled teardown)
  docker-compose-test.yml   Fast test stack (pre-synced block_log; no rewriter)
  .env                      Image versions, registry and host ports
  haf_stats_nginx.conf.template
                            The rewriter's nginx config; the entrypoint substitutes
                            POSTGREST_HOST/PORT and inlines endpoints/rewrite_rules.conf
  rewriter_entrypoint.sh    Renders the template above, then execs nginx
  docker-compose-ci.yml     CI stub stack: builds Dockerfile.rewriter and runs the
                            tavern suite against it, with no HAF instance
  docker-compose-ci-test.yml
                            CI stack for the install/reinstall and regression lanes
  overrides/                Compose overrides layered on by CI (fast healthchecks, ci.yml)
  docker_entrypoint.sh      Dispatches install_app / process_blocks / uninstall_app
  block-processing-healthcheck.sh
                            In-image healthcheck for haf-stats-process

tests/
  tavern/                   API integration tests (pytest + Tavern)
```

## Quick Start (Development)

**Prerequisites:** Docker, a pre-synced HAF `block_log` snapshot in `docker/blockchain/`.

```bash
cd docker
# edit docker/.env directly -- compose reads THAT file, not .env.local
docker compose -f docker-compose-test.yml up --abort-on-container-exit
```

**Production:**

```bash
cd docker
docker compose up -d
```

> ⚠️ **`latest` tracks develop HEAD, and it is the shipped default.** `.env` ships
> `HAF_STATS_VERSION=latest`, and since #66 CI republishes `latest` for both the app
> image and the rewriter on every green develop pipeline. So both lanes now work from a
> clean clone — and both follow develop unless you pin. Pin a version or a SHA for
> anything you need to reproduce.
>
> This block previously said no `latest` existed and told you to pin a published SHA;
> that was true until #66 and is why these lanes used to fail loudly instead of moving
> underneath you. One behaviour change worth knowing: `haf-stats-rewriter` is the one
> service with a `build:` stanza, so it used to fall back to building your working
> tree when the pull failed. It now pulls instead — edit the rewriter and run the
> documented command and your change is silently absent unless you pass `--build`. The
> **development** stack above has no rewriter and no `build:`; it reads
> `${HAF_STATS_VERSION}` from `.env` with no default of its own, so it follows `latest`
> the same way, and a pin that does not resolve has nothing to fall back on.
>
> To pin, one variable covers the app image and the rewriter:
>
> ```bash
> HAF_STATS_VERSION=<8-hex-sha> docker compose up -d
> ```
>
> **The rewriter image was renamed** from `haf_stats/rewriter` to
> `haf_stats/postgrest-rewriter`, the name the sibling apps use
> ([#83](https://gitlab.syncad.com/hive/haf_stats/-/issues/83)). CI publishes only the new
> name; the old one is no longer updated. A SHA built **before** the rename exists only
> under the old name, so pinning one of those needs the rewriter set explicitly — the
> whole reference, tag included:
>
> ```bash
> HAF_STATS_VERSION=<old-sha> \
> HAF_STATS_REWRITER_IMAGE=registry.gitlab.syncad.com/hive/haf_stats/rewriter:<old-sha> \
>   docker compose up -d
> ```
>
> Without it the rewriter pull fails and Compose quietly builds your working tree instead.
>
> This is **this repo's** Compose file, where `HAF_STATS_REWRITER_IMAGE` is the whole
> image reference. haf_api_node's variable of the same name takes **no tag** — its
> `haf_stats.yaml` appends `:${HAF_STATS_VERSION}` — so there the value is
> `registry.gitlab.syncad.com/hive/haf_stats/rewriter`, without `:<old-sha>`.

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

The script refuses to start while the block processor is connected — under either loop,
matched by its `haf_stats_block_processing` application name — and re-checks before the
reseal in case one started mid-rebuild. **Stop the `haf-stats-process` container first**
and restart it after the rebuild completes.

`SELECT haf_stats_app.stop_processing();` stops only the legacy `CALL main()` loop. Under
the generic HAF driver (#85) the registry-era equivalent is
`SELECT hive.app_pause('haf_stats');`, which needs a HAF carrying the application
registry. Stopping the container works under both, which is why it is the instruction.

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
creations only replays correctly from genesis.

The community classification needs a populated `community_registry`, which
**`install_app.sh` has already backfilled** (step 8a, batched). So the upgrade recipe is:

```bash
./scripts/install_app.sh                     # backfills community_registry, batched
psql -c "SELECT COUNT(*) FROM haf_stats_backend.community_registry"   # expect > 0
./scripts/rebuild_content_volume.sh          # derives the per-comment community dimension
```

Only run `rebuild_community_registry.sh` if that count is 0, or if the registry must be
re-derived after a rules change — running it routinely adds a second full-history sweep for
nothing.

### Rebuilding the community registry

`community_registry` / `community_role` hold community names and titles, plus the type
implied by the community's name at registration (hivemind's later `updateProps` type
changes are not tracked). Unlike the content rebuilds, `process_community_registry` is
**idempotent** — registration is `ON CONFLICT DO NOTHING` and roles/titles are
last-writer-wins over an ordered replay — which is why `install_app.sh` can backfill it
directly. Use the script only when the table is *not* empty and must be re-derived, e.g.
after changing the authorization rules:

```bash
./scripts/rebuild_community_registry.sh
```

The range starts at Hivemind's community start block (37,500,000), not block 1: no account
created before it is ever a community, so earlier blocks cannot contribute. `FROM_BLOCK` is
not configurable, because roles are ordered state — an account can only grant a role it
already holds — so a partial start would drop the grants that authorize later
`setRole`/`updateProps` ops.

## Operation-Type Dependencies

Processors resolve Hive operation types by **name**, not by literal id:

```sql
SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_missed_operation'
```

That is deliberate. Non-virtual op ids are consensus-ordered and stable, but **virtual** ids are
assigned after the non-virtual block, so adding one non-virtual operation at a hardfork shifts
every virtual id at once.

The catch is that name resolution fails **silently**. A renamed op makes the lookup return `NULL`,
the aggregation arm matches no rows, and the endpoint reports zeros with no error anywhere. This is
a real failure mode, not a hypothetical one: `hive::protocol::sps_fund_operation` was renamed to
`dhf_funding_operation` and no longer resolves on any current node, and `docs/VERIFICATION.md` (D5)
records the same class of bug inside this app — `process_rc` looked up `'custom_json_operation'`
without the `hive::protocol::` prefix, got `NULL`, and silently lost every custom_json attribution.

**`db/op_type_registry.sql` is the single place these dependencies are declared** — both the names
resolved at runtime and the handful of op ids the code hardcodes (`0` vote, `1` comment,
`2` transfer, `17` delete_comment, `18` custom_json, and `73` `ineffective_delete_comment`, which is
*virtual* and therefore the unstable one). `scripts/install_app.sh` runs
`haf_stats_app.assert_op_types()` twice — once at step 3d, before anything writes data, and again at
step 8f once the endpoints exist.

The first call is positioned deliberately. Step 8 backfills `witness_blocks_daily`, and that
processor's produced arm writes a full table even when its missed arm has gone blind; since
`backfill_rollup_if_empty` only ever fires on an empty rollup, a late assertion would fail *after*
the wrong data became permanent.

### What aborts the install, and what only warns

**Fatal** — something is broken on this node *right now*, in a way that yields wrong or empty data
with no other symptom:

| | |
|---|---|
| a registered name no longer resolves | that lookup is `NULL` today |
| a registered id no longer carries its name | that filter reads a different operation |
| a name is looked up **without** the `hive::protocol::` prefix | that lookup is `NULL` today — this is D5 again |

**Warning** — the registry and the code have drifted apart, but nothing is broken on this node:
code resolves a name the registry does not declare; the registry declares a name no installed
function resolves any more; code hardcodes an op id the registry does not declare.

That split is a correctness decision, not a soft one. This app only drops the exact signatures it
immediately recreates — never a whole schema — so a *renamed* or *re-signatured* function's body
persists in `pg_proc`, and bodies accumulate across releases. If a later release renames a
processor and deletes its now-unused registry row, the orphaned body still carries that literal; a
*fatal* drift check would abort every subsequent install, and since `haf-stats-process` gates on
setup completing and `haf-stats-api` on process being healthy, the whole stack would stay down over
a bookkeeping mismatch — recoverable only by a manual `DROP FUNCTION` on the production node. Drift
is a code-review concern; broken data is an install concern.

The one fatal arm that *is* driven by the code scan — the unprefixed-lookup check — is therefore
scoped at step 3d to the schemas step 3 has just reloaded, and only runs across the endpoints at
step 8f, once step 6 has replaced those bodies. Without that, a release fixing a shipped unprefixed
lookup in an endpoint would abort against the stale body it was about to replace.

**Adding a processor that needs a new op type: add a row to
`haf_stats_app.expected_op_type_names()`.** The scan reads installed function bodies — both classic
`AS $$…$$` bodies and SQL-standard `BEGIN ATOMIC` ones, which keep their body in `prosqlbody` and
leave `prosrc` empty — so forgetting is not silent. It cannot see a name or id assembled at runtime
by `format()` or concatenation, or one that lives outside a function body (a view definition, a
column default); those still have to be registered by hand. Removing a dependency means deleting
its row, and the assertion warns when one is left behind.

`haf_stats_app.scanned_op_type_literals()` and `haf_stats_app.scanned_op_type_ids()` expose the two
scans directly, which is how the drift arms are tested (a `WARNING` is not catchable in plpgsql).

### If a fatal arm is blocking a node that must come up

`HAF_STATS_SKIP_OP_TYPE_ASSERT=1 ./scripts/install_app.sh` downgrades the fatal arms to a single
loud warning. The check still runs and still prints the whole diagnosis — it just does not stop the
install, and it does **not** report success. Fix the cause and unset it.

**On a compose deployment that invocation does nothing.** `install_app.sh` runs inside the
`haf-stats-setup` container, whose service definition (in `haf_api_node`, not this repo) declares no
pass-through for the variable — so setting it on the host leaves the container at the default and
the install aborts again with the same message. Measured: with the variable exported on the host, a
`compose up` of that service still saw `HAF_STATS_SKIP_OP_TYPE_ASSERT=0`. It has to reach the
container:

```bash
docker compose -p haf -f <compose-file> run --rm \
    -e HAF_STATS_SKIP_OP_TYPE_ASSERT=1 haf-stats-setup
```

`run` reuses the service's own `command`, so the `--swagger-url=` argument is preserved (verified),
and it honours `depends_on`, so it waits for HAF to be healthy exactly as the normal install does.
The alternative is to add `HAF_STATS_SKIP_OP_TYPE_ASSERT` to that service's `environment:` block,
which is the better fix if the node needs it more than once.

It is there for the one case the step-3d scoping cannot reach: an **orphaned** function body left in
`pg_proc` by an earlier release, carrying a lookup that no longer exists anywhere in the source
tree. Nothing in a new release can replace a body whose signature it no longer ships, so without the
hatch the only route back is a manual `DROP FUNCTION` on the node — while `haf-stats-process` and
`haf-stats-api` stay down. The arm-4 message names the function and the `DROP FUNCTION` recovery for
exactly that reason.

The assertion is read-only and safe to run by hand at any time:

```bash
psql -d haf_block_log -c "SELECT haf_stats_app.assert_op_types();"
```

It warns and returns — never fails — when `hafd.operation_types` is absent or when the caller lacks
`USAGE` on schema `hafd`; neither is a statement about the app. An *empty* catalog is a hard
failure: that is a HAF node on which every op-type lookup in every processor would return `NULL`.

## Container image contract

`Dockerfile` builds one image used by three services, dispatched by
`docker/docker_entrypoint.sh` — the same `install_app` / `process_blocks` /
`uninstall_app` trio every `haf_api_node` app image exposes, which is what lets a module
file say `command: ["install_app"]` rather than reaching into the image for a script
path.

| Verb | Runs | Notes |
|------|------|-------|
| `install_app [--swagger-url=BASE] [--host=] [--port=] [--user=] [--schema=haf_stats_app] [--is_forking=FALSE]` | `scripts/install_app.sh` | idempotent; safe to re-run |
| `process_blocks [--host=] [--port=] [--user=]` | `scripts/process_blocks.sh` | infinite loop |
| `uninstall_app [--force] [--host=] [--port=] [--user=]` | `scripts/uninstall_app.sh` | destructive |

Connection settings default from the environment (`POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_DB`, `POSTGRES_USER`); `--host=` / `--port=` / `--user=` override them and the
entrypoint forwards them, so a runbook copied from an upstream app works here.
`--postgres-host=`, `--postgres-port=` and `--postgres-user=` are accepted as synonyms
because that is balance_tracker's spelling. An argument no option loop recognises is an
error rather than being silently discarded.

`--postgres-url=` (also spelled `--url=`) is **recognised and refused**, with a message
pointing at `--host`/`--port`/`--user`. `haf_api_node`'s `hivemind.yaml` does pass
`--postgres-url=postgresql://haf_admin@haf/haf_block_log` to its uninstall service, and
all three of balance_tracker's scripts take the flag -- so this is a real gap, tracked in
issue #59.

It is refused rather than honoured because honouring it moved only the psql connection.
Every message, and the teardown's type-the-database-name confirmation, still read
`POSTGRES_HOST`/`POSTGRES_DB`, so the script dropped schemas on the URI's host while
reporting the discrete one -- in the gate whose stated purpose is catching "the right
command against the wrong host". Refusing is safe here, unlike for `--schema`: the flag
appears in exactly one upstream module file, on a service with no `restart:` key.

Two more flags are accepted only for module-file compatibility, and **both warn and
continue** rather than refusing. `--schema=` naming anything but `haf_stats_app` is
ignored with a warning, because the three schema names are fixed in the SQL; so is
`--is_forking=TRUE`, because `db/haf_stats_app.sql` creates the context non-forking.

Refusing either would be worse than useless. Upstream module files put
`restart: on-failure` on their app services — `balance_tracker.yaml` carries it on
block-processing, which is also where it passes `--schema=` — so exiting non-zero over a
flag this app cannot act on either way is a permanent crash-loop that blocks the whole
stack. (This repo's own `docker/docker-compose.yml` has no `restart:` key at all; an
earlier version of this paragraph claimed `haf-stats-setup` carried one, which was
imported from the sibling app and is false here.)

Anything that is not a verb but *is* runnable is still executed, so the previous
`command: ["/app/scripts/process_blocks.sh"]` form keeps working, and an argument
starting with `-` goes to bash — except `--help`, `-h`, `-?`, which print the
dispatcher's own usage.

### Block-processing healthcheck

The image ships `/app/block-processing-healthcheck.sh` — the path
`reputation_tracker.yaml` and its siblings hardcode — and `docker/docker-compose.yml`
attaches it to `haf-stats-process`. It is **not** declared as a `HEALTHCHECK` in the
Dockerfile: upstream does not, and an image-level check would also land on the one-shot
install and uninstall containers.

It replaces `psql -U haf_stats_user -c 'SELECT 1'`, which proved PostgreSQL answers and
nothing about whether `haf_stats_app.main()` was still running — and which connected as
`haf_stats_user`, a role that cannot see `hafd.contexts` rows. The mechanism is RLS on a
role outside `hive_applications_group`, not the `NOINHERIT` flag: `db/builtin_roles.sql`
grants `SELECT` on `hafd` directly, and sets `NOINHERIT` only where it creates the role
itself — on a HAF-provisioned node the role is `INHERIT` and in the group.

The signal is `hafd.contexts.last_active_at`, HAF's own column, written once per
`hive.app_next_iteration`. Healthy when it is fresher than
`HAF_STATS_HEALTHCHECK_MAX_AGE_SECONDS` (default 300) **and** later than this
container's start, or when `hive.is_app_in_sync()`.

Be precise about that column: it is written with a clock **one iteration old**
(`__now := NOW()` is a DECLARE initializer taking `transaction_timestamp()` of the
caller's still-open transaction), so the observed age spans up to *two* iteration
durations — 300s tolerates iterations of roughly 150s. It is also not a sub-batch
heartbeat, so on a long MASSIVE batch this check **can report unhealthy on a healthy
replay**. The window is a deliberately wide guess; narrow it once a batch has been timed.

### Building the image

From the **repository root** (the examples above `cd docker` first, and `docker/` holds no
`Dockerfile`):

```bash
docker build --build-arg GIT_HASH="$(git rev-parse --short=8 HEAD)" -t haf_stats:local .
```

`GIT_HASH` is what `GET /version` and `get_health.version` report.

- **Pass the argument.** Omit it and the build bakes `unspecified`, which
  `install_app` warns about. It reads as unset on purpose: an earlier default of `unknown`
  looked like a value someone had chosen, so a node could claim a version it was not
  running. `hive/haf_fyp` uses the same placeholder for the same condition.
- **`--short=8`, not plain `--short`.** CI passes `CI_COMMIT_SHORT_SHA`, a fixed **eight**
  characters. git's `--short` follows `core.abbrev`, which is `auto`: seven for this
  repository today, but it grows with the object count and a global setting overrides it.
  Without the explicit width a hand-build of the same commit reports `ab66896` where CI's
  image and its registry tag say `ab668960`, and the two cannot be matched.

**Then point the stack at it, or nothing will use it.** `HAF_STATS_IMAGE` means different
things in the two places it appears — the same inversion this file notes for the rewriter
variable:

```bash
# here: HAF_STATS_IMAGE is the WHOLE reference
HAF_STATS_IMAGE=haf_stats:local docker compose up -d

# hive/haf_api_node's haf_stats.yaml: the repository WITHOUT a tag, which it appends from
# HAF_STATS_VERSION
HAF_STATS_IMAGE=haf_stats HAF_STATS_VERSION=local
```

Skip that and `docker compose up -d` resolves `HAF_STATS_VERSION` (`latest`, from
`docker/.env`) against the registry and silently ignores the image you just built. The
`postgrest-rewriter` is a second image, built from `Dockerfile.rewriter` and pinned by the
same `HAF_STATS_VERSION`, so a local app image beside a registry rewriter is the mismatch
this README warns about elsewhere — move both or neither.

**A rebuild on its own changes nothing on a running node.** `GIT_HASH` is baked into
`db/version.sql` at build time, but the value an endpoint serves is written to
`haf_stats_app.app_version` by `install_app` (step 2b). Correcting a version is therefore a
rebuild **and** a re-install — which an ordinary `docker compose up -d` does for you,
because `haf-stats-setup` starts unconditionally (see "Redeploying against a node under
load").

If a node already reports `unspecified`, or a 7-character hash, that is this defect
rather than a mystery: it was built without the argument, or without the width.
`install_app` says so on every install now.

## Redeploying against a node under load

`install_app` re-runs on **every** `docker compose up -d` — `haf-stats-setup` starts
unconditionally, while PostgREST is *not* restarted with it. So an ordinary redeploy
replays the schema underneath live traffic. ([#79](https://gitlab.syncad.com/hive/haf_stats/-/issues/79))

**Every function a request can reach is now replaced atomically.** `install_app` loads
these with `--single-transaction`:

| file | what it defines |
|---|---|
| `endpoints/endpoint_schema.sql` | all 25 `haf_stats_endpoints.*` functions, plus `to_filter_date` and 7 other helpers |
| `db/process_rc.sql` | `rc_rate`, `rc_avg_cost`, `account_op_seq_range` |
| `db/process_community_registry.sql` | `community_start_block` |
| `db/process_governance_concentration.sql`, `db/process_hp_distribution.sql` | their refresh functions (no request calls them; included because it costs nothing) |

`db/sync_status.sql` wraps *itself* in `BEGIN`/`COMMIT`, so `/sync-status` was always
safe. Those five files plus that one cover every `haf_stats_app` function the endpoint
schema actually calls — verified by parsing the SQL with comments and string literals
stripped, because grepping raw text counts commented-out mentions as call sites.

Inside one transaction the catalogue change is invisible to other sessions until commit,
so concurrent callers keep resolving the previous definition and then see the new one.
Callers do not block — not because functions take no lock, but because function *lookup
and execution* take none. (`DROP FUNCTION` does take an `ACCESS EXCLUSIVE` lock on the
`pg_proc` entry; that is why PostgreSQL can drop a function while it runs.) A failed load
now rolls back and leaves the previous definitions in place, where before it could leave
a function dropped.

**What this does not cover:**

- **Concurrent DDL.** Another session altering one of these functions now waits for the
  whole file rather than one statement. The teardown path documented in
  `docker/docker-compose.yml` is one such case; it degrades to `uninstall_app.sh`'s
  `lock_timeout` rather than hanging.
- **Processor-only functions** in the other `db/` files are still replayed
  statement-by-statement. Nothing serves them, so no request can land in the window.
- **A long-running call.** Catalogue lookups take a fresh snapshot per statement, so a
  single multi-statement PL/pgSQL call can plan some sub-statements before the commit
  and some after. Identical code either side makes that a no-op; a genuine upgrade can
  mix old and new within one request.
- **PostgREST's prepared statements.** If a redeploy changes an endpoint's *return
  type*, pooled connections raise `cached plan must not change result type` (`0A000`)
  until they are recycled. Atomic at the commit instant, but not prevented.

Four `db/` files — `process_account_cohorts`, `process_active_users`,
`process_content_stats`, `process_financial` — use `CREATE`/`DROP INDEX CONCURRENTLY`,
which PostgreSQL refuses inside a transaction block, so they can never be loaded this
way. `db/haf_stats_app.sql` is left non-atomic for a different reason: it writes the
`app_status` singleton and creates two unique indexes, so an atomic load takes `SHARE` on
tables `haf-stats-process` writes on every iteration. Nothing a request calls is defined
there.

**A hand-run load needs the flag too.** The guarantee comes from how the file is loaded,
not from the file:

```bash
psql -v ON_ERROR_STOP=on --single-transaction -f endpoints/endpoint_schema.sql
```

**If you are redeploying under real load** and want no exposure at all, drain the
HAProxy backend or stop the API container first:

```bash
cd docker
docker compose stop haf-stats-api   # or drain the backend at the proxy
docker compose up -d                # replays the schema, and restarts the API itself
```

A request that lands in one of the remaining windows gets `function ... does not exist`,
which PostgREST returns as **500** — not a retryable 503, so clients will not back off
and retry on their own.

## Uninstalling

**Destructive and irreversible.** Drops the HAF context, all three schemas `CASCADE`
— including `haf_stats_backend`, which holds the rollups — and both roles.

```bash
docker compose -f docker/docker-compose.yml stop haf-stats-process haf-stats-api
docker compose -f docker/docker-compose.yml run --rm haf-stats-uninstall
```

**`run --rm`, not `--profile haf-stats-uninstall up`.** Upstream documents the `up` form
and it is safe there because upstream profiles every app service; in this file nothing
else is profile-gated, so `up` would also start `haf-stats-setup` (whose command is
`install_app`) alongside the teardown. The session guard would not catch it either —
that service connects as `haf_admin`, which the guard does not count.

The script refuses while anything is connected as a `haf_stats` role, because
`DROP SCHEMA ... CASCADE` needs an `AccessExclusiveLock` and would otherwise block rather
than fail. Run `scripts/uninstall_app.sh` directly without `--force` to get a
type-the-database-name confirmation. It reports what it could not remove rather than
stopping at the first error, and re-running is safe.

## Base URL published in the OpenAPI document

`GET /` serves `haf_stats_endpoints.root()`, whose `servers:` entry tells every generated
client and every Swagger *Try it out* where to send requests. That value is
deployment-specific, so it is **not** baked into the image:

```sh
install_app --swagger-url=/haf-stats-api    # behind a haf_api_node route (the default)
install_app --swagger-url=/                 # this repo's stack, where the rewriter is the root
install_app --swagger-url=https://api.example.com   # an absolute origin
```

The value is stored in `haf_stats_app.app_config` at install time and read by `root()` on
every request. It must be an **absolute path** or an **`http(s)` origin**; anything else —
a bare hostname, say — is ignored and `/haf-stats-api` is used instead.

> That rejection is deliberate rather than fussy. `haf_api_node` passes
> `--swagger-url=${PUBLIC_HOSTNAME}`, and `PUBLIC_HOSTNAME` is a bare hostname, so taking
> it literally would publish `servers: [{url: "your.hostname.com"}]` — not a URL at all.
> Ignoring it leaves the correct node default in place, so this works with the node
> exactly as it is configured today. (An `http(s)` value must carry a path for the same
> reason: a bare origin would send clients to `https://host/network/engagement`, which a
> node does not route.)
>
> Before this, `--swagger-url` set `custom.swagger_url` on the installer's own psql
> session and **nothing ever read it** — PostgREST connects later on its own pool and
> could never have seen it. The flag looked like the way to set the base URL and did
> nothing at all.


## API Endpoints

> **The development lane is different.** `docker/docker-compose-test.yml` (used by the
> Quick Start above) starts **no rewriter** and publishes PostgREST itself on
> `${TEST_API_PORT:-3001}`. The clean paths below exist only in the full
> `docker/docker-compose.yml` stack; on the test lane call `/rpc/<function>` directly.

Served by the **rewriter** (`haf-stats-rewriter`), which maps these clean paths onto PostgREST `/rpc/` calls. Base URL: `http://localhost:3001`.

`docker compose up -d` publishes the rewriter on `3001` and PostgREST itself on `3000`.

> ⚠️ **This changed.** PostgREST used to be published on `3001` (`docker/.env` shipped `API_PORT=3001`), which is why the base URL below looked right while every path under it 404'd. If you call `/rpc/` directly, it moved to **3000**. The paths below only exist on the rewriter -- calling them on `:3000` returns 404, because there they are `/rpc/<function>` instead. `GET /` on the rewriter serves the curated OpenAPI document (this needs `PGRST_DB_ROOT_SPEC=root`, which the shipped compose sets).

> The document's `servers:` entry follows the deployment. This stack installs with `--swagger-url=/`, because here the rewriter **is** the root, so Swagger UI's *Try it out* resolves against `localhost:3001` directly. Behind a node the argument is ignored and the default `/haf-stats-api` stands — see *Base URL published in the OpenAPI document* above. ([#70](https://gitlab.syncad.com/hive/haf_stats/-/issues/70))

| Endpoint | Status | Processor | Description |
|---|---|---|---|
| `GET /version` | ✅ Live | — | App git hash |
| `GET /health` | ✅ Live | — | Last processed block + version (the app's own `app_status` clock) |
| `GET /sync-status` | ✅ Live | — | Uniform HAF-app freshness signal: the block HAF's own context pointer says this node has consumed, plus its UTC timestamp |
| `GET /account/{account}/financial-summary` | ✅ Live | process_financial.sql | Per-account incoming/outgoing by category, granularity |
| `GET /account/{account}/content-stats` | ✅ Live | process_content_stats.sql | Per-account posts/comments/votes/replies + author rewards, granularity |
| `GET /account/{account}/community-activity` | ✅ Live | process_content_stats.sql + process_community_registry.sql | Per-account created posts/comments grouped by community (replies attributed to their ROOT post's community), plus a personal-blog bucket that makes the buckets sum to `get_account_content_stats` |
| `GET /account/{account}/interactions` | ✅ Live | *(on-demand, no processor)* | Per-account outgoing interactions by type (reply/vote/transfer/reblog/follow) and counterparty; Top-N partners per type plus an `Others` band |
| `GET /account/{account}/rc-footprint` | ✅ Live | process_rc.sql | Estimated RC for an account's signed ops, grouped by op type or DApp (`group_by=app` resolves custom_json ids to DApp names via `custom_json_app_registry`); read-time rates (#32/#33) |
| `GET /account/{account}/rc-footprint-timeline` | ✅ Live | process_rc.sql | Per-account estimated RC as a paginated per-OPERATION ledger (timestamp, block_num, op_type, app, custom_json_id, rc_consumed, op_seq) -- not a period series like `/network/rc-utilization`; op-type / DApp / category filters, `before_seq` paging |
| `GET /account/{account}/dapp-footprint` | ✅ Live | process_custom_json.sql | Per-account custom_json activity resolved to DApp names and categories |
| `GET /network/daily-active-users` | ✅ Live | process_active_users.sql | Distinct authoring accounts + operation volume per period, by op-type filter and granularity |
| `GET /network/content-volume` | ✅ Live | process_content_stats.sql | Posts/comments created + unique authors per period (create-vs-edit aware), granularity |
| `GET /network/engagement` | ✅ Live | process_content_stats.sql | Network-wide posts, average votes/comments per post and zero-engagement shares, by period |
| `GET /network/vote-stats` | ✅ Live | process_content_stats.sql | Network-wide vote activity (up/down/unvotes, self-votes, unique voters), granularity |
| `GET /network/author-retention` | ✅ Live | process_content_cohorts.sql | First-post author cohorts with created-content retention at 30/90/180 days |
| `GET /network/account-funnel` | ✅ Live | process_account_cohorts.sql | New-account cohorts and how many stay active at 7/30/90 days |
| `GET /network/top-accounts` | ✅ Live | *(reads financial + active-users tables)* | Top N accounts by rewards, transfer volume, HP balance, or op count |
| `GET /network/hp-distribution` | ✅ Live | process_hp_distribution.sql | HP stake bucketed distribution, served from a precomputed snapshot (the processor is what reads `btracker_app`) |
| `GET /network/rc-utilization` | ✅ Live | process_network_ops.sql | Network-wide estimated RC per op type per period (read-time rates); op-type granularity, no per-DApp breakdown |
| `GET /network/custom-json-usage` | ✅ Live | process_network_custom_json.sql | Per-id network custom_json usage over time (op_count, op_bytes, estimated RC), granularity |
| `GET /network/top-custom-json` | ✅ Live | process_network_custom_json.sql | Most-used custom_json ids/DApps/categories by op_count, op_bytes, or estimated RC (`group_by=id/app/category`); `app`/`category` partition the window, so they append an `Others` band for everything past `limit_count` and always sum to the window total |
| `GET /governance/influence-concentration` | ✅ Live | process_governance_concentration.sql | Current HP concentration snapshot: Gini, top 1%/10% share, holder count, median and mean HP |
| `GET /witnesses/missed-blocks` | ✅ Live | process_witness_blocks.sql | Missed vs produced blocks per witness. Omit `granularity` for a leaderboard (`order_by=missed/rate/last_missed`), set it for a series; `witness=` filters to one. Includes zero-miss producers so `rate` has a baseline; no `rank`/`is_active` (hafbe owns those) |
| `GET /custom-json-app-registry` | ✅ Live | seed_data.sql | The custom_json id -> DApp name/category registry the resolvers use |

### `/health` and `/sync-status` report different clocks, on purpose

`get_health` reports `haf_stats_app.app_status.last_processed_block` — the app's own
bookkeeping row. `get_sync_status` reports `hafd.contexts.current_block_num` for the
`haf_stats` context — HAF's authoritative pointer, and the same source
`hafbe_backend.sync_status()` and haf_fyp's `/sync-status` expose, so a monitor can treat
every HAF app identically (#55).

They are one clock: `haf_stats_app.main()` writes both from the same variable in the same
transaction, so on a node the processor drives they agree exactly. A persistent
disagreement means the HAF context was reset out from under the data — re-running
`scripts/install_app.sh` repairs the pointer — **stop the block processor first**: the repair
declines with a warning while the context is attached, which it is on any redeploy against a
running stack, so an install with `haf-stats-process` up exits 0 without fixing anything. Note
it *raises* a lagging pointer and cannot lower one, so it is not a way to force a replay (the
warning the function itself emits names that procedure). `tests/parity/context_vs_app_status.sql`
(guard 6 in `scripts/run_verification.sh`) fails if the two ever drift.

`/sync-status` reads through the SECURITY DEFINER `haf_stats_app.sync_status()`
(`db/sync_status.sql`), because `hafd.contexts` is protected by row-level security that
admits only `hive_applications_group` — a group carrying `TRUNCATE` on that table, which
the unauthenticated PostgREST role must not hold. It answers **503** rather than 200 when
the HAF instance is in massive sync or the context is not visible; a 200 there would hide a
privilege misconfiguration behind a healthy-looking body.

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

Known divergences from hivemind, documented on the endpoint too:

* **Deleted content.** We count creations; hivemind's `hive_posts` holds what is currently
  live. This is the main reason a figure here can exceed hivemind's, and it is deliberate —
  it is what makes the buckets reconcile with `get_account_content_stats`.
* **Roles below admin.** Only owner/admin are modelled, since nothing but title
  authorization needs them, so a title set through a `mod` grant is not reproduced.
* **`type_id`** is derived from the community name at registration. Hivemind seeds it the
  same way but lets a later `updateProps` change it; we do not follow that.

Muting is explicitly **not** a divergence, contrary to a claim in an earlier revision of
this document: hivemind's `process_community_post` resolves `community_id` from the
category (root) or the parent (reply) *before* any role check, and a muted or non-member
author only sets `hive_posts.is_muted`. The post still belongs to the community on both
sides.

### Checking the derivation against hivemind

Hivemind is itself a HAF app, so on a node that runs it, `hivemind_app` sits in the **same
database**. haf_stats deliberately does not read it — a hard dependency would break this
app's standalone architecture, and hivemind counts currently-**live** content while we
count **creations**, which is exactly what makes the endpoint's buckets sum to
`get_account_content_stats`. But where it is present it makes an excellent **oracle**, and
it is the only way to exercise the community path on real data (the CI replay is 2016
history, which predates communities entirely):

```bash
psql -f tests/parity/community_vs_hivemind.sql      # also runs via run_verification.sh
```

Read-only, takes no locks, and skips cleanly when `hivemind_app` is absent. It fails on
communities we attribute content to that hivemind does not know, communities hivemind
registered that we missed, titles that disagree (the direct test of the owner/admin gate),
and any (account, community) pair where we counted **fewer** than hivemind. It only reports
— never fails on — the reverse, since our creations-based excess over hivemind's live
content is expected and equals the deleted content. `tests/hivemind_oracle_fixture.sql`
stubs a `hivemind_app` in the CI stack so the oracle's dynamic-SQL path is exercised there
rather than lying dormant until it first meets a production node.

### Real-data parity without a mainnet replay

Everything the resolver consumes for a comment — `author`, `permlink`, `parent_author`,
`parent_permlink` — is returned by `condenser_api.get_content` for any post, and hivemind
hands over the **answer** in the same response: `category` is the thread root's community,
propagated to every descendant. So real threads can be replayed as the raw
`comment_operation`s they came from and checked against hivemind's own verdict, without a
multi-TB mainnet HAF:

```bash
python3 tests/tools/gen_mainnet_community_fixture.py > tests/mainnet_community_fixture.sql
```

The generated fixture is **committed**, so CI needs no network. It currently holds 120 real
nodes across 8 communities and 2 legacy tag categories, up to **depth 8** — replayed in a
single batch, so most parent links resolve in-batch, which is the case a plain
`comment_registry` lookup gets wrong. It asserts our derived community equals hivemind's for
every node, and self-guards: it fails if a regenerated sample loses its deep replies, its
community content, or its legacy-category negatives. The same nodes are mirrored into the
`hivemind_app` stub, so the oracle above runs over real communities and accounts too.

## Interaction Graph

`get_account_interactions` (#48, backend for `block_explorer_ui#762`) answers "to whom do my
interactions flow?" — per-account **outgoing** interactions grouped by `(type, partner)` for
`reply`, `vote`, `transfer`, `reblog` and `follow`, as Top-N partners per type plus an
`Others` band. The unit is always an interaction **count**; transfer amounts and vote weights
never affect it, so the bands stay comparable.

It is the app's first **on-demand** aggregate — no table, no processor, no backfill. That is a
deliberate reversal of the usual pattern here, forced by measurement: over blocks 4,000,000–5,000,000
there are 1,924,303 vote ops but 715,119 distinct `(voter, author)` pairs and **1,455,953**
distinct `(voter, author, day)` rows — a daily rollup would compress the op stream only
**1.32×**, because the social graph is mostly a long tail (66% of pairs occur exactly once).
Extrapolated to mainnet that is a ~1-billion-row table for votes alone, to serve a widget that
only ever renders a handful of partners. Reading the ops directly instead reuses the same
`hive.account_operations_view` + `haf_stats_app.account_op_seq_range` path
`get_account_rc_footprint` already relies on.

**Budget the cold cache, not the warm one.** The cost is a random heap fetch per op, and those
bodies are scattered across the account's whole history. On a fully-resident test database a
50,000-op ceiling looked like ~0.5 s; measured on a full multi-TB node it cost ~0.6–0.9 ms/op
of random I/O, putting a *moderate* account (~43k ops) at **28 s cold** and heavy accounts near
**90 s** — past any sane proxy read timeout, and the exact random-read profile that starves
co-tenant apps on a shared node. Arbitrary account lookups on a multi-TB node are cold far more
often than warm, so the cold figure is the one that governs.

The ceiling is **4,000 ops per op type**, and the number that matters is `ntypes × cap`: a
default request budgets op types 0/1/2/18 independently, so its worst case is **16,000** bodies,
~10–14 s cold — inside the API `statement_timeout` with margin. (Per-type budgeting is what keeps
a band consistent with its own `type_filter` drill-down, but it does multiply the total: the same
structure at a 10,000 ceiling would be 40,000 ops, which straddles the timeout.)

When the ceiling bites, the oldest day inside the served set was only *partially* scanned, so its
ops are **dropped rather than counted**. Paying for rows and then discarding them is deliberate:
it makes the counts and the disclosed window describe exactly the same period, so re-deriving
totals over `[covered_from, to_date]` reproduces the endpoint's own answer.
`tests/parity/interactions_cap.sql` asserts precisely that, per band.

Rules worth knowing, all of them chosen against measurements rather than taste:

* **Outgoing** means the account SIGNED the op (`transacting_account_id = account_id`) — the
  same predicate the RC footprint uses for "who paid". Verified exact against a direct
  `hafd.operations` scan for all four op types, with no loss and no double count.
* **Self-interactions are excluded.** A `You → vote → You` ribbon is a self-loop the sankey
  cannot draw, and for some accounts self-votes would dominate the top partners.
  `network_vote_daily.self_votes` still reports them.
* **Delegations are excluded** — they belong to the Influence & Delegation Map. Only op types
  0/1/2/18 are ever scanned, so `delegate_vesting_shares` (40) cannot leak in.
* **`reply` and `reblog` are de-duplicated; `vote`, `transfer` and `follow` are not.** An edit
  reuses its comment's permlink, so raw op counts overstate replies by ~11% network-wide
  (18.6% for the account measured) — the same edits-are-not-creations rule `#13` established
  for content stats. A reblog is idempotent state in Hivemind. A re-vote or a
  follow→unfollow→re-follow, by contrast, is a genuinely repeated act. The de-dup key always
  includes the **partner**: `@calva`'s permlink `bitcoin-the-end-of-money-as-we-know-it` was
  created under one parent, deleted, then re-created under another — two real interactions
  with two different partners that a permlink-only key would silently collapse into one.
* **Retractions never count, in any band.** An unfollow (`what: []`), a mute
  (`what: ["ignore"]`), an un-reblog (the `delete` key) and an **unvote** (`weight = 0`,
  22,593 of the first 5M blocks' vote ops) all withdraw an action rather than perform one.
  `post_engagement` already refuses to count weight-0 votes as engagement; this applies the
  same rule uniformly.
* De-duplication is **window-scoped**, so an edit of a reply created before the window looks
  like an in-window creation. Measured at 0.012% of reply edges over 30 days and 0.195% over
  one day, and exactly zero for the default full-history window.

### Follows and reblogs without hivemind

Both are `custom_json`, which the issue flagged as possibly needing a hivemind join. They do
not: the counterparty is in the payload, and the same standalone-derivation argument as
[Community Attribution](#community-attribution) applies. Two shapes occur in real data and
**neither is rare** — over the first 5,000,000 blocks the split is **67% bare object** vs
**33% array-wrapped** `["follow", {...}]`, so a parser assuming either one drops a third to
two-thirds of the data:

```json
{"follower":"alice","following":"bob","what":["blog"]}
["reblog",{"account":"alice","author":"bob","permlink":"..."}]
```

The custom_json `id` is **not** a reliable discriminator (a reblog arrives under `id: "follow"`
in real data), so the operation is identified from the payload keys. Only a real follow counts,
and the test matches Hivemind's: it reads `what[0]` lower-cased, **not** "does `what` contain
blog". Containment would count `["posts","blog"]` — 254 such ops in the first 5M blocks — as a
follow, where Hivemind reads `posts` and does nothing. Hivemind also requires the payload's
self-declared actor (`follower` / `account`) to BE the signer and returns early otherwise, so
that check is applied too — without it the graph would be inflatable by the very account being
graphed, by signing a payload that names someone else.

Payloads are parsed with `haf_stats_app.try_jsonb`, a plpgsql exception trap — **not** SQL/JSON
`IS JSON`. That predicate is PostgreSQL 16+, and the stub endpoint-test gate runs
`postgres:14-alpine`; using it would fail `CREATE FUNCTION` there under `ON_ERROR_STOP` and take
down every stub-lane test, not just this endpoint's.

### Coverage disclosure

Because the work is done at read time, a very active account over a wide window could scan more
ops than is reasonable. Rather than failing such a request, the endpoint serves the most recent
`haf_stats_app.max_interaction_ops()` operations and reports the window it actually covered in
`covered_from` — partial **disclosure** rather than silent truncation, the pattern `#46`
established for author retention. Truncation is detected by **counting** the rows fetched (the
page asks for one more than the ceiling), not by comparing block numbers: when the boundary fell
inside a single block, "oldest kept" equalled "oldest available" and a truncated answer reported
full coverage. And because the boundary block's own day is only partly scanned, `covered_from`
starts the day *after* it rather than presenting a partial day as complete.

API queries run under a **30 s `statement_timeout`**, so a pathological request fails cleanly
instead of holding a PostgREST pool slot for minutes while the client has already given up —
PostgreSQL never notices a disconnect, since `client_connection_check_interval` defaults to 0.

**It is a role setting on `haf_stats_user`** (`db/builtin_roles.sql`), and it caps the API in
every deployment — measured on PostgREST v12.2.3:

| deployment | PostgREST logs in as | how the role setting applies |
|---|---|---|
| this repo's `docker/docker-compose.yml` | `haf_stats_owner`, and switches to `haf_stats_user` per request | PostgREST applies the settings of every role its login role is a member of **to each request**. That overrides the `options=-c statement_timeout=30s` on `PGRST_DB_URI` in both directions; the option stays only as a fallback in case the membership changes. |
| the haf_api_node stack (`haf_stats.yaml`) | `haf_stats_user`, **through PgBouncer** | at login. The URI option is not available here: the stack's PgBouncer rejects it with `FATAL: unsupported startup parameter in options: statement_timeout` (hive/haf_api_node!244). |
| a node that side-loads the app, e.g. testapi | `haf_stats_user`, direct | at login. testapi's URI carries no option, so its API was uncapped before #94. |

The sibling apps use the same mechanism (on testapi: `btracker_user` and `hafbe_user` 10 s,
`hafah_user` 15 s, `hivemind_user` 5000 ms); haf_stats' endpoints are heavier, hence 30 s.
Headroom, from testapi's PostgreSQL log (2026-07-14 → 09-16, every call of ≥ 1 s): the slowest
PostgREST calls took 21.9 s, 21.7 s and 21.5 s. The one call of 30 s or more took 48.8 s, 48.4 s
of it waiting for the lock the 03:30 UTC `refresh_top_accounts_alltime()` held while it rebuilt
the all-time tables with `TRUNCATE`. Since #95 it merges only the rows that changed and takes no lock a reader
waits for, so a top-accounts request no longer queues behind it.

A `SET statement_timeout` **attribute on a function** is not used. It does not arm when the
function is called directly in SQL — verified: a 2 s `pg_sleep` runs to completion under a
200 ms attribute — though PostgREST v12 does hoist it for RPC calls (measured: a 500 ms attribute
cancelled a 2 s sleep). One budget on the role is simpler to reason about than one per function.

The block processor logs in as `haf_stats_owner`, which deliberately carries **no** timeout —
its batches legitimately run long.

**Tested:** `install-test` logs in as `haf_stats_user` and asserts it gets 30 s, and as
`haf_stats_owner` and asserts it gets 0 — a superuser session cannot check either, since
`SET ROLE` does not apply role settings. That is a direct login to PostgreSQL 14; CI goes through
neither PostgREST nor PgBouncer. The PgBouncer path was measured separately in review of !97,
with haf_api_node's own PgBouncer image: the setting arms, and a 35 s sleep is cancelled.

**Deploying onto a running node.** A role setting is read when a connection is opened, so
connections already pooled keep their old value:

* this repo's compose, or a direct login like testapi: restart the PostgREST container.
* the haf_api_node stack: restarting PostgREST is **not** enough — PgBouncer hands the new client
  the same server connection. Run `RECONNECT haf_block_log` on PgBouncer's admin console (it
  cycles every app's server connections to that database), restart PgBouncer, or wait for its
  `server_lifetime` (3600 s in the stack's `pgbouncer.yaml`).

Every op type carries its **own** budget. A shared budget made the answer depend on the query:
votes sharing a page with replies and transfers reported a lower count than the same account
queried with `type_filter=vote`, where votes had the page to themselves — a band disagreeing with
its own drill-down. Per-type budgets also stop DApp `custom_json` (which yields no counterparty at
all) from ever evicting the vote, reply or transfer bands. The ceiling is a function rather than a
literal specifically so `tests/parity/interactions_cap.sql` can lower it and prove the guard both
fires and discloses — the busiest account in the CI corpus is far below any production-sane value,
so a hardcoded constant would leave the whole truncation path shipping unexecuted.

One limit is inherent: **`reblog` and `follow` both ride `custom_json`**, and share that budget
with every DApp `custom_json` the account signs. An account whose recent `custom_json` is
dominated by game or token traffic can lose both bands entirely, because the `id` that would let
us filter them lives in the op body — the very thing the budget exists to avoid fetching. Rather
than let that vanish silently, an empty band over a truncated window is reported as a single row
with a null partner, `interaction_count` 0 and `partners_merged` 0, carrying the `covered_from`
of the window that *was* scanned.

Read that row as *"nothing of this type inside the covered window, and the window is short"* — it
does **not** assert data was lost, because once the budget is exhausted the endpoint genuinely
cannot tell an account with no follows from one whose follows fell outside it. The guarantee runs
the other way: a band empty over a **fully covered** window emits no row at all, so an
unqualified absence is a real zero.

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
