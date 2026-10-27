#!/bin/bash
# Rebuild per-account financial daily aggregates from raw HAF data.
#
# REQUIRED after an install that recreated account_financial_daily: since issue #110 it
# stores the category as the op type id and the direction as a boolean, and an install
# that finds the earlier TEXT category/direction shape (either vocabulary -- the issue #26
# rename or the one before it) drops the table and creates it again EMPTY, with a warning.
# No row is converted; this TRUNCATE + reprocess (or a replay) is what restores history.
# Stop the processor first, run install_app.sh, then run this script.
#
# Stop the haf_stats processor before running this script -- stop the haf-stats-process
# container, which is the only thing that works under both the legacy loop and the HAF
# driver -- and keep it stopped until this command finishes. The script refuses to start
# while a processor is connected, and re-checks after the replay (#98).
#
# The rebuild commits once per batch so it can process full history without one
# enormous transaction.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

: "${BATCH_SIZE:=10000}"
: "${FROM_BLOCK:=1}"
: "${TO_BLOCK:=}"

wait_for_postgres

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

if (( TO_BLOCK > app_block )); then
    echo "TO_BLOCK=${TO_BLOCK} exceeds the app's last processed block (${app_block}); rebuilding ahead of the app would double-count those blocks after restart." >&2
    exit 2
fi

refuse_if_processor_live

log "Rebuilding financial aggregates through app block ${TO_BLOCK} in batches of ${BATCH_SIZE}."
log "The haf_stats processor must remain stopped until this command finishes."

psql_cmd -c "
    TRUNCATE TABLE haf_stats_backend.account_financial_daily;
    TRUNCATE TABLE haf_stats_backend.account_financial_monthly;
"

first="${FROM_BLOCK}"
while (( first <= TO_BLOCK )); do
    last=$((first + BATCH_SIZE - 1))
    if (( last > TO_BLOCK )); then
        last="${TO_BLOCK}"
    fi

    log "Processing financial rebuild blocks ${first}-${last}..."
    psql_cmd -c "SELECT haf_stats_app.process_financial(${first}, ${last});"
    first=$((last + 1))
done

refuse_if_processor_started_during_rebuild \
    "Its head-block writes have double-counted onto account_financial_daily, and the" \
    "monthly rollup restates itself from that table."

# process_financial's per-batch hook restates the monthly rollup as it goes, but a
# final remainder batch shorter than the ~1200-block gate would not fire it, so seal
# the last processed month explicitly (cheap: one month) to guarantee full coverage.
log "Sealing the final month of the financial monthly rollup..."
psql_cmd -c "
    SELECT haf_stats_app.refresh_financial_monthly(
        (SELECT DATE_TRUNC('month', created_at)::DATE FROM hafd.blocks WHERE num = ${TO_BLOCK}));
"

log "Financial rebuild complete."
