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
  rebuild_network_custom_json.sh
                            Rebuilds network custom_json usage (network_custom_json_daily)
                            on already-synced nodes (forward-only otherwise)

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

## API Endpoints

All endpoints are served via PostgREST. Base URL: `http://localhost:3001`

| Endpoint | Status | Processor | Description |
|---|---|---|---|
| `GET /rpc/get_version` | ✅ Live | — | App git hash |
| `GET /rpc/get_health` | ✅ Live | — | Last processed block + version |
| `GET /rpc/get_account_financial_summary` | ✅ Live | process_financial.sql | Per-account incoming/outgoing by category, granularity |
| `GET /rpc/get_account_content_stats` | ✅ Live | process_content_stats.sql | Per-account posts/comments/votes/replies + author rewards, granularity |
| `GET /rpc/get_account_community_activity` | ✅ Live | process_content_stats.sql + process_community_registry.sql | Per-account created posts/comments grouped by community (replies attributed to their ROOT post's community), plus a personal-blog bucket that makes the buckets sum to `get_account_content_stats` |
| `GET /rpc/get_account_interactions` | ✅ Live | *(on-demand, no processor)* | Per-account outgoing interactions by type (reply/vote/transfer/reblog/follow) and counterparty; Top-N partners per type plus an `Others` band |
| `GET /rpc/get_account_rc_footprint` | ✅ Live | process_rc.sql | Estimated RC for an account's signed ops, grouped by op type or DApp (`group_by=app` resolves custom_json ids to DApp names via `custom_json_app_registry`); read-time rates (#32/#33) |
| `GET /rpc/get_network_rc_utilization` | ✅ Live | process_network_ops.sql | Network-wide estimated RC per op type per period (read-time rates); op-type granularity, no per-DApp breakdown |
| `GET /rpc/get_network_custom_json_usage` | ✅ Live | process_network_custom_json.sql | Per-id network custom_json usage over time (op_count, op_bytes, estimated RC), granularity |
| `GET /rpc/get_network_top_custom_json` | ✅ Live | process_network_custom_json.sql | Most-used custom_json ids/DApps/categories by op_count, op_bytes, or estimated RC (`group_by=id/app/category`); `app`/`category` partition the window, so they append an `Others` band for everything past `limit_count` and always sum to the window total |
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

PostgREST's own connection carries a `statement_timeout` (`options=-c statement_timeout=30s` in
`PGRST_DB_URI`), so a pathological request fails cleanly instead of holding one of its 20 pool
slots for minutes while the client has already given up — PostgreSQL never notices a disconnect,
since `client_connection_check_interval` defaults to 0.

It has to be on the **connection**, and the two obvious alternatives both silently do nothing:

* A `SET statement_timeout` **function attribute never arms** — the timer is set when the
  top-level statement begins, and changing the GUC from inside that statement does not re-arm it.
  Verified: a 2 s `pg_sleep` runs to completion under a 200 ms in-statement timeout.
* **`ALTER ROLE haf_stats_user SET statement_timeout` is dead config** in the production stack.
  Role settings apply at login, and PostgreSQL explicitly does not process them for `SET ROLE`;
  PostgREST logs in as `haf_stats_owner` and switches roles per request.

The connection form is verified to arm (a 2 s sleep cancelled at 200 ms), and it bounds API
queries only — the block processor uses its own connection, and its batches legitimately run
long.

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
