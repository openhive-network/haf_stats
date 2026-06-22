#!/bin/bash
# Rebuild account-cohort membership and D7/D30/D90 retention from raw HAF data.
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

log "Rebuilding account cohorts for blocks ${FROM_BLOCK}-${TO_BLOCK} in batches of ${BATCH_SIZE}."
log "The haf_stats processor must remain stopped until this command finishes."

psql_cmd -c "
    TRUNCATE TABLE
        haf_stats_backend.account_cohort_retention,
        haf_stats_backend.account_cohort_members;
"

first="${FROM_BLOCK}"
while (( first <= TO_BLOCK )); do
    last=$((first + BATCH_SIZE - 1))
    if (( last > TO_BLOCK )); then
        last="${TO_BLOCK}"
    fi

    log "Processing cohort rebuild blocks ${first}-${last}..."
    psql_cmd -c "SELECT haf_stats_app.process_account_cohorts(${first}, ${last});"
    first=$((last + 1))
done

psql_cmd -c "
    SELECT haf_stats_app.refresh_account_cohort_retention(
        (SELECT created_at FROM hafd.blocks WHERE num = ${TO_BLOCK}),
        NULL,
        NULL
    );
"

log "Account cohort rebuild complete."
