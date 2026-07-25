#!/bin/bash
# Rebuild the Hive community registry (community_registry + community_role) from raw HAF data.
#
# Registration comes from account_created ops naming a hive-[1-3]NNNNN account, and titles from
# custom_json id='community' updateProps ops that an owner/admin signed. Run this on a deployment
# that synced before the community feature existed (the forward processor only fills blocks from
# here on), or to re-derive after a logic change.
#
# Unlike the content rebuilds, process_community_registry is IDEMPOTENT — registration is
# ON CONFLICT DO NOTHING and roles/titles are last-writer-wins over an ordered replay — so
# re-running it can never double anything. install_app.sh therefore self-heals this table
# automatically when it is empty; this script exists for the case where it is NOT empty and must
# be re-derived from scratch (e.g. after changing the authorization rules).
#
# The rebuild covers exactly [community_start_block, last_processed_block]:
#   * The start is FIXED at Hivemind's community start block, not 1. No account created before it
#     is ever a community, so scanning earlier blocks would find nothing and cost a full extra
#     sweep of history.
#   * It MUST end at last_processed_block: a SHORT rebuild leaves communities registered in
#     (TO_BLOCK, tip] missing until they are next written to, and posts addressed to them in that
#     window would have already been classified as community-less.
#
# Stop the haf_stats processor before running this script (SELECT haf_stats_app.stop_processing();
# or stop the haf-stats-process container) and keep it stopped until this finishes; the script
# REFUSES to start if it is still live, and re-checks at the end.
#
# NOTE: this rebuilds the community NAMES and TITLES only. It does NOT re-derive which comment
# belongs to which community — that lives in comment_registry.community + account_community_daily,
# whose creation classification only replays correctly from genesis. Repair those with
# scripts/rebuild_content_volume.sh, and run it AFTER this script so the classification sees a
# complete registry.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Community ops are a thin slice of the op stream, so batches can be large; the cost is
# dominated by the per-batch index scan setup, not by the rows returned.
: "${BATCH_SIZE:=100000}"

# TO_BLOCK is intentionally NOT configurable, and is deliberately absent from the environment
# defaults above: the rebuild must end exactly at last_processed_block. A SHORT rebuild leaves
# communities registered in (TO_BLOCK, tip] missing while the processor resumes at tip+1 and
# never revisits them. Previously this was declared as a tunable that then rejected every value
# except its own default, so the only thing an operator could achieve by setting it was exit 2.
if [[ -n "${TO_BLOCK:-}" ]]; then
    echo "TO_BLOCK is not configurable: the rebuild must end at the app's last processed block." >&2
    echo "A short rebuild leaves communities registered in (TO_BLOCK, tip] missing; the processor resumes at tip+1 and never revisits them." >&2
    exit 2
fi

# FROM_BLOCK is intentionally NOT configurable: the role replay is ORDERED state (an account can
# only grant a role it already holds), so starting mid-history would lose the grants that
# authorize every later setRole/updateProps.
if [[ -n "${FROM_BLOCK:-}" ]]; then
    echo "FROM_BLOCK is not configurable: community roles are replayed in op order from the community start block, so a partial start would drop the grants that authorize later ops." >&2
    exit 2
fi

# Guard the interrupted/failed case. The replay is idempotent, so the data is not CORRUPT — but it
# is INCOMPLETE, and a processor restarted on top of it would classify posts against a registry
# that is missing communities.
rebuild_started=0
on_exit() {
    local rc=$?
    if (( rc != 0 && rebuild_started == 1 )); then
        echo "" >&2
        echo "!!! COMMUNITY REGISTRY REBUILD DID NOT COMPLETE (exit ${rc}) !!!" >&2
        echo "community_registry / community_role describe only the blocks replayed so far." >&2
        echo "" >&2
        echo "The data is not corrupt (the replay is idempotent), but it is INCOMPLETE: any" >&2
        echo "community registered after the last completed batch is missing, so" >&2
        echo "get_account_community_activity would report its posts under the personal-blog" >&2
        echo "bucket and show no title for it." >&2
        echo "" >&2
        echo "DO NOT START THE PROCESSOR until this has run to completion (re-running is always" >&2
        echo "safe; it re-TRUNCATEs and replays from a clean slate)." >&2
    fi
    return $rc
}
# INT/TERM as well as EXIT: a Ctrl-C or `docker stop` mid-replay leaves the same partial state as
# a failed batch, and the operator must see the warning either way.
trap 'exit 130' INT
trap 'exit 143' TERM
trap on_exit EXIT

# require_number / count_live_processors / assert_no_live_processor come from common.sh.

wait_for_postgres

require_number "BATCH_SIZE" "${BATCH_SIZE}"
if (( BATCH_SIZE < 1 )); then
    echo "BATCH_SIZE must be >= 1; got ${BATCH_SIZE}." >&2
    exit 2
fi

# Read the start block from the function rather than hardcoding it, so the constant has exactly
# one definition (db/process_community_registry.sql).
start_block="$(psql_cmd -Atc "SELECT haf_stats_app.community_start_block()")"
require_number "community_start_block" "${start_block}"

app_block="$(
    psql_cmd -Atc "
        SELECT COALESCE(MAX(last_processed_block), 0)
        FROM haf_stats_app.app_status
    "
)"
require_number "app_status.last_processed_block" "${app_block}"

# Always the app's head, per the TO_BLOCK note at the top of this file.
readonly TO_BLOCK="${app_block}"

if (( app_block < 1 )); then
    echo "The app has processed no blocks (last_processed_block=${app_block}); nothing to rebuild." >&2
    exit 2
fi

if (( app_block < start_block )); then
    log "The app has only processed up to block ${app_block}, before the community start block (${start_block}); no community can exist yet. Nothing to do."
    exit 0
fi

assert_no_live_processor "The haf_stats processor is still running; refusing to rebuild."

log "Rebuilding the community registry over blocks ${start_block}-${TO_BLOCK} in batches of ${BATCH_SIZE}."
log "The haf_stats processor must remain stopped until this command finishes."

# Truncate both together: community_role is seeded from registration, so keeping stale roles
# beside a fresh registry would let a revoked admin survive the rebuild.
rebuild_started=1
psql_cmd -c "
    TRUNCATE TABLE haf_stats_backend.community_role;
    TRUNCATE TABLE haf_stats_backend.community_registry;
"

first="${start_block}"
while (( first <= TO_BLOCK )); do
    last=$((first + BATCH_SIZE - 1))
    if (( last > TO_BLOCK )); then
        last="${TO_BLOCK}"
    fi

    log "Processing community registry rebuild blocks ${first}-${last}..."
    psql_cmd -c "SELECT haf_stats_app.process_community_registry(${first}, ${last});"
    first=$((last + 1))
done

# The pre-flight check is TOCTOU over a multi-minute replay, so re-check: a processor started
# mid-rebuild would have been writing head blocks onto a registry we were rebuilding from the
# start block, so the ordered role replay could have seen grants out of sequence.
assert_no_live_processor "The haf_stats processor STARTED DURING the rebuild; its head-block writes interleaved with the ordered role replay. Stop it and re-run this script."

# This sweep covered [start_block, app_block] from a truncated slate, so install_app.sh's
# step-8a backfill has nothing left to do — record it, or the next install would re-sweep.
# INSERT-if-missing before the UPDATE: an UPDATE against an empty table affects zero rows
# and reports success, which would silently leave the watermark unset and make the next
# install re-sweep all of history.
psql_cmd -c "
    INSERT INTO haf_stats_app.community_backfill_status (backfilled_through)
    SELECT ${TO_BLOCK}
    WHERE NOT EXISTS (SELECT 1 AS one FROM haf_stats_app.community_backfill_status);
    UPDATE haf_stats_app.community_backfill_status SET backfilled_through = ${TO_BLOCK};"

rebuild_started=0
log "Community registry rebuild complete: $(psql_cmd -Atc "SELECT COUNT(*) FROM haf_stats_backend.community_registry") communities registered."
