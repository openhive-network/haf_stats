#!/bin/bash
# Rebuild network content-volume (get_network_content_volume) AND per-account content
# (get_account_content_stats) aggregates from raw HAF data.
#
# Required to repair issue #42: network_content_daily counts posts/comments with an
# additive upsert (posts = ncd.posts + EXCLUDED.posts), so any out-of-band reprocess
# of an already-counted block range double-counts them (authors, an ON CONFLICT DO
# NOTHING membership set, stay correct). A TRUNCATE + clean genesis reprocess is the
# only way to restore correct history on an affected deployment.
#
# It ALSO repairs a stale over-report in account_content_daily's content columns: before
# the create/edit dedup landed (#13), the account path counted raw comment ops (edits
# included) as posts, and that table had no rebuild path, so affected deployments kept the
# inflation permanently. This rebuild recomputes posts/comments/replies_received creates-
# only in the same genesis registry replay. It ZEROES those three columns rather than
# truncating account_content_daily, because votes_cast/votes_received come from a separate
# vote scan this path does not reproduce and are already correct — they are preserved.
#
# It is ALSO the only way to populate the community dimension (#47:
# comment_registry.community + account_community_daily) on a deployment that synced before
# that feature existed. Those cannot be self-healed at install time like the other rollups,
# because a comment's community is inherited from its root post and the create-vs-edit
# classification that identifies creations only replays correctly from genesis.
#
# This calls haf_stats_app.process_content_volume — a narrow path that writes only the
# content tables — NOT process_content_stats, whose shared scan also feeds votes/engagement
# and would re-double those if re-run.
#
# The rebuild covers exactly [1, last_processed_block]. Both ends are mandatory:
#   * It MUST start at block 1: create-vs-edit classification replays comment_registry
#     from genesis, so a partial-range rebuild misclassifies.
#   * It MUST end at last_processed_block: a SHORT rebuild strands comment_registry at
#     TO_BLOCK while the processor resumes at last_processed_block + 1 and never revisits
#     the gap, so the gap's days are lost forever and later edits of comments created
#     there are miscounted as new posts. A LONG one double-counts after restart.
#
# Stop the haf_stats processor before running this script (SELECT
# haf_stats_app.stop_processing(); or stop the haf-stats-process container) and keep it
# stopped until this command finishes; the script refuses to start if it is still live.
# The rebuild commits once per batch so it can process full history without one enormous
# transaction. The endpoint keeps serving the previous rollup until the final reseal
# transaction commits, so it never returns partial history.
#
# IF THIS SCRIPT FAILS OR IS INTERRUPTED PART-WAY, the content tables are left in a
# partial state and comment_registry is stranded mid-replay (account_content_daily's
# content columns are zeroed-then-partially-rebuilt and under-report). Do NOT start the
# processor: re-run this script to completion first (each run starts from a clean TRUNCATE
# and re-zeroes the account content columns, so re-running is always safe — and after a
# failure it is mandatory).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Content volume is heavy per block (two operations_view scans + window functions per
# batch), and each batch is its own psql process. At the old 10000 default, full mainnet
# (~107.6M blocks) meant ~10,760 connect/plan cycles; 1000000 keeps that to ~108 batches.
# See the equivalent note for rebuild_content_cohorts.sh in the README.
: "${BATCH_SIZE:=1000000}"
: "${TO_BLOCK:=}"

# FROM_BLOCK is intentionally NOT configurable: the registry replay must start at genesis.
# Reject an explicit override loudly rather than silently ignoring it.
if [[ -n "${FROM_BLOCK:-}" && "${FROM_BLOCK}" != "1" ]]; then
    echo "FROM_BLOCK is not configurable and must be 1 (got '${FROM_BLOCK}'): create/edit classification replays comment_registry from genesis, so a partial-range rebuild misclassifies." >&2
    exit 2
fi
readonly FROM_BLOCK=1

# Guard the interrupted/failed case, which no range check can catch: TRUNCATE and every
# completed batch have already committed, so the tables describe a prefix of history while
# app_status.last_processed_block still points at the tip. Restarting the processor then
# resumes past the gap with a stranded registry and corrupts counts permanently.
rebuild_started=0
on_exit() {
    local rc=$?
    if (( rc != 0 && rebuild_started == 1 )); then
        echo "" >&2
        echo "!!! CONTENT-VOLUME REBUILD DID NOT COMPLETE (exit ${rc}) !!!" >&2
        echo "network_content_daily / network_author_daily / comment_registry /" >&2
        echo "account_community_daily are now in a" >&2
        echo "PARTIAL state: they describe only the blocks replayed so far, while" >&2
        echo "app_status.last_processed_block still points at the tip. account_content_daily's" >&2
        echo "content columns (posts/comments/replies_received) are likewise zeroed-then-" >&2
        echo "partially-rebuilt and under-report until the rebuild completes." >&2
        echo "" >&2
        echo "DO NOT START THE PROCESSOR. It would resume past the gap with a stranded" >&2
        echo "comment_registry: the gap's days would be lost from network_content_daily" >&2
        echo "forever, and later edits of comments created there would be miscounted as" >&2
        echo "new posts (the issue #42 corruption, reintroduced)." >&2
        echo "" >&2
        echo "Re-run this script to completion first (it re-zeroes and re-TRUNCATEs from a" >&2
        echo "clean slate, so re-running is always safe)." >&2
    fi
    return $rc
}
# INT/TERM as well as EXIT: a Ctrl-C or `docker stop` mid-replay leaves exactly the same
# partial state as a failed batch, and the operator must see the warning either way.
trap 'exit 130' INT
trap 'exit 143' TERM
trap on_exit EXIT

require_number() {
    local name="$1" value="$2"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "${name} must be a non-negative integer; got '${value}'." >&2
        exit 2
    fi
}

# Detect a live processor. Scoped to THIS database (pg_stat_activity is cluster-wide, so
# an unrelated HAF app running its own main() elsewhere must not block us). Matching on a
# leading CALL keeps this from matching its own SELECT.
count_live_processors() {
    psql_cmd -Atc "
        SELECT COUNT(*)
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND datname = current_database()
          AND state <> 'idle'
          AND BTRIM(query) ILIKE 'CALL%haf_stats_app.main%'
    "
}

wait_for_postgres

require_number "BATCH_SIZE" "${BATCH_SIZE}"
if (( BATCH_SIZE < 1 )); then
    echo "BATCH_SIZE must be >= 1; got ${BATCH_SIZE}." >&2
    exit 2
fi

app_block="$(
    psql_cmd -Atc "
        SELECT COALESCE(MAX(last_processed_block), 0)
        FROM haf_stats_app.app_status
    "
)"
require_number "app_status.last_processed_block" "${app_block}"

if [[ -z "${TO_BLOCK}" ]]; then
    TO_BLOCK="${app_block}"
fi
require_number "TO_BLOCK" "${TO_BLOCK}"

if (( app_block < 1 )); then
    echo "The app has processed no blocks (last_processed_block=${app_block}); nothing to rebuild." >&2
    exit 2
fi

# Equality, not "<=". See the header: both a short and a long rebuild corrupt.
if (( TO_BLOCK != app_block )); then
    echo "TO_BLOCK must equal the app's last processed block (${app_block}); got ${TO_BLOCK}." >&2
    echo "A short rebuild strands comment_registry at TO_BLOCK: the processor resumes at $((app_block + 1)) and never revisits the gap, so the gap's days are lost from network_content_daily and later edits of comments created there are miscounted as new posts. A long one double-counts after restart." >&2
    exit 2
fi

# Assign, then validate: `if (( $(cmd) > 0 ))` would FAIL OPEN if psql returned an empty
# string (connection reset, server restart) — `(( > 0 ))` is an arithmetic syntax error
# returning 1, and set -e is suppressed inside an `if` condition, so the guard would
# silently conclude "no processor" and TRUNCATE while one is live.
live_procs="$(count_live_processors)"
require_number "live_processor_count" "${live_procs}"

if (( live_procs > 0 )); then
    echo "The haf_stats processor is still running; refusing to rebuild." >&2
    echo "Stop it first: SELECT haf_stats_app.stop_processing();  (or stop the haf-stats-process container), then re-run." >&2
    exit 2
fi

log "Rebuilding content-volume + per-account content aggregates through app block ${TO_BLOCK} in batches of ${BATCH_SIZE}."
log "The haf_stats processor must remain stopped until this command finishes."

# comment_registry is scratch state: a full genesis->TO_BLOCK replay leaves it in the
# exact live-comment set the stopped processor had, so live processing resumes cleanly.
#
# account_content_daily is NOT truncated: votes_cast/votes_received come from a SEPARATE
# vote scan that process_content_volume does not reproduce, and they are already correct.
# Zero only the three content columns; the additive account upsert in process_content_volume
# rebuilds them from 0, and the vote columns are preserved. The zeroing MUST run here, in
# the same clean-slate statement as the TRUNCATEs and unconditionally on every run: the
# upsert is additive, so re-running after an interrupted rebuild would otherwise add correct
# counts on top of a partial rebuild (the #42 double-count class). Re-zeroing every run makes
# restart safe, exactly as re-TRUNCATE does for the network tables.
#
# account_community_daily (#47) IS truncated: unlike account_content_daily it has no
# columns from another scan to preserve, and process_content_volume rebuilds it in full.
# Its per-comment source of truth is comment_registry.community, which the TRUNCATE above
# clears with the rest of the registry, so the two are re-derived together — this is also
# the only way to backfill the community dimension onto an already-synced deployment,
# since the create-vs-edit classification only replays correctly from genesis.
rebuild_started=1
psql_cmd -c "
    TRUNCATE TABLE haf_stats_backend.network_content_daily;
    TRUNCATE TABLE haf_stats_backend.network_author_daily;
    TRUNCATE TABLE haf_stats_backend.comment_registry;
    TRUNCATE TABLE haf_stats_backend.account_community_daily;
    UPDATE haf_stats_backend.account_content_daily
       SET posts = 0, comments = 0, replies_received = 0;
"

first="${FROM_BLOCK}"
while (( first <= TO_BLOCK )); do
    last=$(( first + BATCH_SIZE - 1 ))
    if (( last > TO_BLOCK )); then
        last=$(( TO_BLOCK ))
    fi

    log "Processing content-volume rebuild blocks ${first}-${last}..."
    psql_cmd -c "SELECT haf_stats_app.process_content_volume(${first}, ${last});"
    first=$(( last + 1 ))
done

# The pre-flight check is inherently TOCTOU over a multi-minute replay, so re-check before
# publishing: a processor started mid-rebuild would have been appending head blocks through
# the additive upsert onto tables we were rebuilding from block 1. (stop_processing() makes
# main() return, so process_blocks.sh exits and the container can restart under its restart
# policy, re-arming itself via allow_processing() — this is a plausible race, not a theoretical
# one.) Assign-then-validate for the same fail-open reason as the pre-flight check.
live_procs="$(count_live_processors)"
require_number "live_processor_count" "${live_procs}"

if (( live_procs > 0 )); then
    echo "The haf_stats processor STARTED DURING the rebuild; its head-block writes have" >&2
    echo "double-counted onto the rebuilt tables. Stop it and re-run this script." >&2
    exit 2
fi

# Reseal the endpoint rollup from the rebuilt daily tables. psql runs a multi-statement
# -c string as one implicit transaction, so readers see the old rollup until it commits,
# then the corrected one — never an empty or partial series. The lower bound is derived
# from the data (not a hardcoded genesis constant) so no day can fall below it and be
# dropped from the day/week grain; NULL _hi means refresh through the end of history.
log "Resealing network_content_period_counts from the rebuilt daily tables..."
psql_cmd -c "
    TRUNCATE TABLE haf_stats_backend.network_content_period_counts;
    SELECT haf_stats_app.refresh_network_content_periods(
        (SELECT MIN(day) FROM haf_stats_backend.network_content_daily), NULL);
"

# The reseal has committed, so the network rollup is published and account_content_daily's
# content is fully rebuilt and correct. Clear rebuild_started BEFORE the cosmetic dead-row
# cleanup below: if that DELETE fails the data is NOT corrupt (all-zero rows sum to nothing),
# so on_exit must not raise the "content tables partial / do not start the processor" alarm.
rebuild_started=0

# Drop dead all-zero account rows the live processor never creates. Zeroing content columns
# on a stale (author, day) whose content was all edits — with no votes and no received
# replies — leaves a (0,0,0,0,0) row that a from-scratch install would never write; the
# endpoint would surface it as a spurious all-zero period. Rows that still carry votes or
# replies are kept.
#
# The predicate names every metric column: if one is ever added to account_content_daily, add
# it here too, or a row non-zero only in the new column would be wrongly deleted. The parity
# guard (tests/parity/content_volume_rebuild_consistency.sql) asserts this DELETE removes zero
# rows on real data, so an over-broad predicate fails CI. The full-table scan and the earlier
# zeroing UPDATE are both negligible beside the rebuild's genesis-wide operation scans, and the
# zeroing is HOT-eligible (no indexed column changes) — simpler and interruption-safe versus a
# TRUNCATE + restore-votes dance, which would need a scratch table shared across separate psql
# batch processes plus its own interruption cleanup.
log "Removing dead all-zero account_content_daily rows..."
psql_cmd -c "
    DELETE FROM haf_stats_backend.account_content_daily
     WHERE posts = 0 AND comments = 0 AND replies_received = 0
       AND votes_cast = 0 AND votes_received = 0;
"

log "Content-volume + per-account content rebuild complete."
