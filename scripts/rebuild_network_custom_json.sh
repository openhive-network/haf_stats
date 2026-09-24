#!/bin/bash
# Backfill network-wide custom_json usage (network_custom_json_daily) from raw HAF data.
#
# process_network_custom_json is additive, so a re-run would double-count; this script
# TRUNCATEs first and then sweeps the full history once. Run it on a fresh deploy (the forward
# processor only fills blocks from here on) to give the network custom_json usage endpoints
# historical coverage, or to rebuild after a logic change.
#
# The rebuild covers exactly [1, last_processed_block] and both ends are fixed, because it
# TRUNCATEs the whole table first:
#   * It MUST start at block 1: a partial start leaves the pre-FROM_BLOCK days empty forever
#     (the forward processor already passed them and never revisits).
#   * It MUST end at last_processed_block: a SHORT rebuild strands blocks (TO_BLOCK, tip] empty
#     (the processor resumes at tip+1 and never revisits them); a LONG one double-counts after
#     restart. So TO_BLOCK must equal last_processed_block.
#
# Stop the haf_stats processor before running this script -- stop the haf-stats-process
# container, which is the only thing that works under both the legacy loop and the HAF
# driver -- and keep it stopped until this finishes; the script
# REFUSES to start if it is still live, and re-checks at the end. The rebuild commits once per
# batch so it can process full history without one enormous transaction.
#
# IF THIS SCRIPT FAILS OR IS INTERRUPTED PART-WAY, the table is left describing only a prefix of
# history while app_status.last_processed_block still points at the tip. Do NOT start the
# processor: re-run this script to completion first (each run starts from a clean TRUNCATE, so
# re-running is always safe — and after a failure it is mandatory).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

: "${BATCH_SIZE:=10000}"
: "${TO_BLOCK:=}"

# FROM_BLOCK is intentionally NOT configurable: the TRUNCATE wipes the whole table, so a partial
# start would leave [1, FROM_BLOCK) empty with no other writer to fill it. Reject an override
# loudly rather than silently creating a gap.
if [[ -n "${FROM_BLOCK:-}" && "${FROM_BLOCK}" != "1" ]]; then
    echo "FROM_BLOCK is not configurable and must be 1 (got '${FROM_BLOCK}'): the rebuild TRUNCATEs the whole table, so a partial start would leave [1, FROM_BLOCK) permanently empty." >&2
    exit 2
fi
readonly FROM_BLOCK=1

# Guard the interrupted/failed case, which no range check can catch: TRUNCATE and every completed
# batch have already committed, so the table describes a prefix of history while
# app_status.last_processed_block still points at the tip. Restarting the processor then resumes
# past the gap and never refills it.
rebuild_started=0
on_exit() {
    local rc=$?
    if (( rc != 0 && rebuild_started == 1 )); then
        echo "" >&2
        echo "!!! NETWORK CUSTOM_JSON REBUILD DID NOT COMPLETE (exit ${rc}) !!!" >&2
        echo "network_custom_json_daily now describes only the blocks replayed so far, while" >&2
        echo "app_status.last_processed_block still points at the tip." >&2
        echo "" >&2
        echo "DO NOT START THE PROCESSOR: it would resume past the gap (tip+1) and never refill" >&2
        echo "the missing days, so get_network_custom_json_usage / get_network_top_custom_json" >&2
        echo "would under-report that range permanently." >&2
        echo "" >&2
        echo "Re-run this script to completion first (it re-TRUNCATEs from a clean slate, so" >&2
        echo "re-running is always safe)." >&2
    fi
    return $rc
}
# INT/TERM as well as EXIT: a Ctrl-C or `docker stop` mid-replay leaves the same partial state as
# a failed batch, and the operator must see the warning either way.
trap 'exit 130' INT
trap 'exit 143' TERM
trap on_exit EXIT

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

# Equality, not "<=": a short rebuild strands (TO_BLOCK, tip] empty, a long one double-counts.
if (( TO_BLOCK != app_block )); then
    echo "TO_BLOCK must equal the app's last processed block (${app_block}); got ${TO_BLOCK}." >&2
    echo "A short rebuild leaves blocks (${TO_BLOCK}, ${app_block}] empty (the processor resumes at $((app_block + 1)) and never revisits them); a long one double-counts after restart." >&2
    exit 2
fi

refuse_if_processor_live

log "Rebuilding network custom_json usage through app block ${TO_BLOCK} in batches of ${BATCH_SIZE}."
log "The haf_stats processor must remain stopped until this command finishes."

rebuild_started=1
psql_cmd -c "
    TRUNCATE TABLE haf_stats_backend.network_custom_json_daily;
"

first="${FROM_BLOCK}"
while (( first <= TO_BLOCK )); do
    last=$((first + BATCH_SIZE - 1))
    if (( last > TO_BLOCK )); then
        last="${TO_BLOCK}"
    fi

    log "Processing network custom_json rebuild blocks ${first}-${last}..."
    psql_cmd -c "SELECT haf_stats_app.process_network_custom_json(${first}, ${last});"
    first=$((last + 1))
done

refuse_if_processor_started_during_rebuild "Its head-block writes have double-counted onto the rebuilt table."

rebuild_started=0
log "Network custom_json rebuild complete."
