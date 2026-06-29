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
# Stop the haf_stats processor before running this script. The rebuild commits
# once per batch so it can process full history without one enormous transaction.

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

if (( FROM_BLOCK < 1 || TO_BLOCK < FROM_BLOCK || BATCH_SIZE < 1 )); then
    echo "Invalid range or batch size: FROM_BLOCK=${FROM_BLOCK}, TO_BLOCK=${TO_BLOCK}, BATCH_SIZE=${BATCH_SIZE}" >&2
    exit 2
fi

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

psql_cmd -c "
    SELECT haf_stats_app.refresh_author_cohort_retention(
        (SELECT created_at FROM hafd.blocks WHERE num = ${TO_BLOCK}),
        NULL,
        NULL
    );
"

log "Content cohort rebuild complete."
