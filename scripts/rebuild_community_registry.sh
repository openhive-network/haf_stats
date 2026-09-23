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
# Stop the haf_stats processor before running this script -- stop the haf-stats-process
# container, which is the only thing that works under both the legacy loop and the HAF
# driver -- and keep it stopped until this finishes; the script
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
: "${TO_BLOCK:=}"

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

if [[ -z "${TO_BLOCK}" ]]; then
    TO_BLOCK="${app_block}"
fi
require_number "TO_BLOCK" "${TO_BLOCK}"

if (( app_block < 1 )); then
    echo "The app has processed no blocks (last_processed_block=${app_block}); nothing to rebuild." >&2
    exit 2
fi

# Equality, not "<=": a short rebuild leaves communities registered in (TO_BLOCK, tip] missing,
# and the forward processor resumes at tip+1 and never revisits them.
if (( TO_BLOCK != app_block )); then
    echo "TO_BLOCK must equal the app's last processed block (${app_block}); got ${TO_BLOCK}." >&2
    echo "A short rebuild leaves communities registered in (${TO_BLOCK}, ${app_block}] missing; the processor resumes at $((app_block + 1)) and never revisits them." >&2
    exit 2
fi

if (( app_block < start_block )); then
    log "The app has only processed up to block ${app_block}, before the community start block (${start_block}); no community can exist yet. Nothing to do."
    exit 0
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
live_procs="$(count_live_processors)"
require_number "live_processor_count" "${live_procs}"
if (( live_procs > 0 )); then
    echo "The haf_stats processor STARTED DURING the rebuild; its head-block writes interleaved" >&2
    echo "with the ordered role replay. Stop it and re-run this script." >&2
    exit 2
fi

rebuild_started=0
log "Community registry rebuild complete: $(psql_cmd -Atc "SELECT COUNT(*) FROM haf_stats_backend.community_registry") communities registered."
