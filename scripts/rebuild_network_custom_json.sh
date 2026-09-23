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

require_number() {
    local name="$1" value="$2"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "${name} must be a non-negative integer; got '${value}'." >&2
        exit 2
    fi
}

# Detect a live processor. Scoped to THIS database (pg_stat_activity is cluster-wide). Matching a
# leading CALL keeps this from matching its own SELECT.
# UNDER THE GENERIC HAF DRIVER (#85) THE OLD PREDICATE WAS FALSE IN BOTH HALVES
# whenever the processor was live, so this refused nothing:
#
#   * the backend runs `CALL haf_stats_app.process_blocks(...)`, never
#     `CALL haf_stats_app.main(...)`, so the query-text match could not fire;
#   * it idles on the client between ranges BY DESIGN -- that is the point of the
#     driver -- so `state <> 'idle'` skipped it for most of the wall clock.
#
# The result would have been this script reporting "no processor", TRUNCATEing, and
# replaying from genesis through an additive upsert while the driver appended head
# blocks: the #42 double-count corruption the guard exists to prevent, plus permanent
# gaps where writes landed before the TRUNCATE. The post-reseal re-check below shares
# this function, so it was blind for the same two reasons.
#
# Both loops now tag themselves `haf_stats_block_processing` -- the driver through its
# connection URI, the legacy loop through PGAPPNAME (scripts/process_blocks.sh). The two
# query-text arms are belt-and-braces for a processor container still running an image
# from before that tag existed.
#
# The failure directions are NOT symmetric: a false positive costs an operator a retry,
# a false negative truncates under a live writer. So this over-matches on purpose, and
# there is no `state` filter -- scripts/uninstall_app.sh's session guard has always
# keyed this way and is the reason it still catches an idle driver backend.
_LIVE_PROCESSOR_MATCH="
          AND (
               application_name = 'haf_stats_block_processing'
            OR BTRIM(query) ILIKE 'CALL%haf_stats_app.main%'
            OR BTRIM(query) ILIKE 'CALL%haf_stats_app.process_blocks%'
          )"

count_live_processors() {
    psql_cmd -Atc "
        SELECT COUNT(*)
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND datname = current_database()
          ${_LIVE_PROCESSOR_MATCH}
    "
}

# WHAT is holding it, printed on refusal. Dropping the `state` filter bought correctness
# under the driver and cost this: a backend orphaned by an abrupt container loss stays in
# pg_stat_activity, still tagged and idle, until TCP keepalive reaps it -- and with
# postgres's default tcp_keepalives_idle = 0 that is the OS default, commonly two hours.
# The old predicate excluded such a zombie; this one matches it. Without naming the
# session, an operator who HAS stopped the container is told to stop the container.
# scripts/uninstall_app.sh reports its blocking sessions for the same reason.
report_live_processors() {
    psql_cmd -Atc "
        SELECT '  pid ' || pid
               || '  user=' || coalesce(usename, '?')
               || '  application_name=' || coalesce(nullif(application_name, ''), '(none)')
               || '  state=' || coalesce(state, '(hidden from this role)')
               || '  since ' || coalesce(to_char(backend_start, 'YYYY-MM-DD HH24:MI:SS'), '?')
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND datname = current_database()
          ${_LIVE_PROCESSOR_MATCH}
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

# Equality, not "<=": a short rebuild strands (TO_BLOCK, tip] empty, a long one double-counts.
if (( TO_BLOCK != app_block )); then
    echo "TO_BLOCK must equal the app's last processed block (${app_block}); got ${TO_BLOCK}." >&2
    echo "A short rebuild leaves blocks (${TO_BLOCK}, ${app_block}] empty (the processor resumes at $((app_block + 1)) and never revisits them); a long one double-counts after restart." >&2
    exit 2
fi

# Assign, then validate: `if (( $(cmd) > 0 ))` would FAIL OPEN if psql returned an empty string
# (connection reset) — `(( > 0 ))` is a syntax error returning 1, and set -e is suppressed inside
# an `if` condition, so the guard would silently conclude "no processor" and TRUNCATE while live.
live_procs="$(count_live_processors)"
require_number "live_processor_count" "${live_procs}"
if (( live_procs > 0 )); then
    echo "The haf_stats processor is still running; refusing to rebuild." >&2
    report_live_processors >&2 || true
    echo "Stop it first: stop the haf-stats-process container, then re-run." >&2
    echo "  If the container is ALREADY stopped, the session above is an orphaned backend" >&2
    echo "  left by an abrupt stop; it clears on TCP keepalive (often two hours) or at once" >&2
    echo "  with SELECT pg_terminate_backend(<pid>);" >&2
    echo "  Nothing else clears this check, and that is deliberate. It keys on the" >&2
    echo "  processor's CONNECTION, not on what the connection is doing, because under the" >&2
    echo "  HAF driver an idle connection is a working processor between ranges." >&2
    echo "  So: haf_stats_app.stop_processing() stops only the legacy CALL main() loop, and" >&2
    echo "  hive.app_pause('haf_stats') stops the driver taking new ranges but leaves it" >&2
    echo "  connected -- this check still refuses on both." >&2
    exit 2
fi

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

# The pre-flight check is TOCTOU over a multi-minute replay, so re-check: a processor started
# mid-rebuild would have been appending head blocks through the additive upsert onto the table we
# rebuilt from block 1. Assign-then-validate for the same fail-open reason as the pre-flight check.
live_procs="$(count_live_processors)"
require_number "live_processor_count" "${live_procs}"
if (( live_procs > 0 )); then
    echo "The haf_stats processor STARTED DURING the rebuild; its head-block writes have" >&2
    echo "double-counted onto the rebuilt table. Stop it and re-run this script." >&2
    exit 2
fi

rebuild_started=0
log "Network custom_json rebuild complete."
