#!/bin/bash
# Backfill per-account custom_json activity (account_custom_json_daily) from raw HAF data.
#
# process_custom_json is additive, so a re-run would double-count; this script TRUNCATEs
# first and then sweeps the full history once. Run it on a fresh deploy (the forward
# processor only fills blocks from here on) to give the DApp-footprint endpoint historical
# coverage, or to rebuild after a registry/logic change.
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
# Above 100,000 blocks per batch haf_stats_app.exact_rc_for_range declines to split the RC
# (db/exact_rc.sql), so the rebuilt rows would carry no rc_exact - after a TRUNCATE that may have
# removed exact ones. Refuse rather than lose them silently.
if (( BATCH_SIZE > 100000 )); then
    echo "BATCH_SIZE=${BATCH_SIZE} is above 100,000: the rebuilt rows would lose their exact RC (rc_exact). Use 100000 or less." >&2
    exit 2
fi

if (( TO_BLOCK > app_block )); then
    echo "TO_BLOCK=${TO_BLOCK} exceeds the app's last processed block (${app_block}); rebuilding ahead of the app would double-count those blocks after restart." >&2
    exit 2
fi

refuse_if_processor_live

log "Rebuilding custom_json activity through app block ${TO_BLOCK} in batches of ${BATCH_SIZE}."
log "The haf_stats processor must remain stopped until this command finishes."

psql_cmd -c "
    TRUNCATE TABLE haf_stats_backend.account_custom_json_daily;
"

first="${FROM_BLOCK}"
while (( first <= TO_BLOCK )); do
    last=$((first + BATCH_SIZE - 1))
    if (( last > TO_BLOCK )); then
        last="${TO_BLOCK}"
    fi

    log "Processing custom_json rebuild blocks ${first}-${last}..."
    psql_cmd -c "SELECT haf_stats_app.process_custom_json(${first}, ${last});"
    first=$((last + 1))
done

refuse_if_processor_started_during_rebuild "Its head-block writes have double-counted onto the rebuilt table."

log "Custom_json rebuild complete."
