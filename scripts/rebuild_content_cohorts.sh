#!/bin/bash
# Rebuild content-creator cohort membership and 30/90/180-day retention from raw
# HAF data (get_network_author_retention).
#
# REQUIRED when deploying this feature onto an ALREADY-SYNCED node. The forward
# per-batch processor only fills haf_stats_backend.author_cohort_members from
# deploy time onward, so without this rebuild the historical cohorts are missing
# and the install hook's summary backfill (which rebuilds author_cohort_retention
# FROM the members table) has nothing to aggregate. On a from-genesis replay the
# forward path already fills both, so this step is only needed for existing nodes.
#
# Reads haf_stats_backend.network_author_daily (the chain-exact created-content
# set maintained by process_content_stats / get_network_content_volume), so that
# feature must be installed with its history present before running this. Step 1
# (first-post detection) reads hive.operations_view directly and does not need it.
#
# Stop the haf_stats processor before running this script -- stop the haf-stats-process
# container, which is the only thing that works under both the legacy loop and the HAF
# driver -- and keep it stopped until this command finishes. The script refuses to start
# while a processor is connected, and re-checks after the replay (#98).
#
# The rebuild commits once per batch so it can process full history without one
# enormous transaction.
#
# For a one-time full-history rebuild, set a large BATCH_SIZE. Content cohorts are
# heavy per block -- Step 1 scans comment_operation and Step 2 rescans the pending
# members' 180-day window each batch -- so the 10000 default means ~10,760 batches
# (and repeated pending rescans) over full mainnet history. Measured on testapi:
# BATCH_SIZE=1000000 rebuilds full history (~107.6M blocks) in ~1h35m. The smaller
# default suits incremental / bounded-range rebuilds.
#
# This TRUNCATEs author_cohort_retention before rebuilding, so on an
# already-populated node GET /rpc/get_network_author_retention returns [] from the
# start of the run until the final refresh -- treat the rebuild as a maintenance
# window (the "stop the processor" step above already implies downtime).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

: "${BATCH_SIZE:=10000}"
: "${FROM_BLOCK:=1}"
: "${TO_BLOCK:=}"

wait_for_postgres

if [[ -z "${TO_BLOCK}" ]]; then
    TO_BLOCK="$(
        psql_cmd -Atc "SELECT COALESCE(MAX(num), 0) FROM hafd.blocks"
    )"
fi

# Validate before the arithmetic rather than inside it. `(( 09 < 1 ))` is an octal error
# that returns 1, and errexit is suppressed inside an `if`, so the range check silently
# passes -- measured on this script: it TRUNCATEs, the replay loop runs ZERO batches, the
# final refresh runs over the empty table, and it exits 0 reporting success. The four
# scripts that already called require_number refuse the same input with exit 2. (#98)
require_number "BATCH_SIZE" "${BATCH_SIZE}"
require_number "FROM_BLOCK" "${FROM_BLOCK}"
require_number "TO_BLOCK" "${TO_BLOCK}"

if (( FROM_BLOCK < 1 || TO_BLOCK < FROM_BLOCK || BATCH_SIZE < 1 )); then
    echo "Invalid range or batch size: FROM_BLOCK=${FROM_BLOCK}, TO_BLOCK=${TO_BLOCK}, BATCH_SIZE=${BATCH_SIZE}" >&2
    exit 2
fi

refuse_if_processor_live

log "Rebuilding content cohorts for blocks ${FROM_BLOCK}-${TO_BLOCK} in batches of ${BATCH_SIZE}."
log "The haf_stats processor must remain stopped until this command finishes."

psql_cmd -c "
    TRUNCATE TABLE
        haf_stats_backend.author_cohort_retention,
        haf_stats_backend.author_cohort_members;
"

first="${FROM_BLOCK}"
while (( first <= TO_BLOCK )); do
    last=$((first + BATCH_SIZE - 1))
    if (( last > TO_BLOCK )); then
        last="${TO_BLOCK}"
    fi

    log "Processing cohort rebuild blocks ${first}-${last}..."
    psql_cmd -c "SELECT haf_stats_app.process_content_cohorts(${first}, ${last});"
    first=$((last + 1))
done

refuse_if_processor_started_during_rebuild \
    "Its head-block writes landed in the cohort tables mid-rebuild, so membership is part" \
    "rebuilt and part head-block. Do not trust the retention summary either way: the" \
    "processor refreshes it itself on ~hourly block boundaries, so a catch-up range" \
    "will have rebuilt recent cohorts from that partial membership, while cohorts older" \
    "than its ~7-8 month floor stay as this rebuild's TRUNCATE left them -- empty."

psql_cmd -c "
    SELECT haf_stats_app.refresh_author_cohort_retention(
        (SELECT created_at FROM hafd.blocks WHERE num = ${TO_BLOCK}),
        NULL,
        NULL
    );
"

log "Content cohort rebuild complete."
