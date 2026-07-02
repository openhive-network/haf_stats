#!/bin/bash
# Rebuild per-account financial daily aggregates from raw HAF data.
#
# Required after the issue #26 rename: the category VALUES changed (human-readable
# 'Transfer'/'Author Reward' + income/expense -> canonical op-type names +
# incoming/outgoing), so the old rows are keyed differently and the new
# canonical-keyed upserts never overwrite them. A TRUNCATE + reprocess is the
# only way to restore historical coverage on an already-populated deployment.
# Stop the processor first, run install_app.sh (it migrates the direction CHECK,
# deletes legacy rows, and drops op_financial_categories), then run this script.
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

app_block="$(
    psql_cmd -Atc "
        SELECT COALESCE(MAX(last_processed_block), 0)
        FROM haf_stats_app.app_status
    "
)"

if [[ -z "${TO_BLOCK}" ]]; then
    TO_BLOCK="${app_block}"
fi

if (( FROM_BLOCK < 1 || TO_BLOCK < FROM_BLOCK || BATCH_SIZE < 1 )); then
    echo "Invalid range or batch size: FROM_BLOCK=${FROM_BLOCK}, TO_BLOCK=${TO_BLOCK}, BATCH_SIZE=${BATCH_SIZE}" >&2
    exit 2
fi

if (( TO_BLOCK > app_block )); then
    echo "TO_BLOCK=${TO_BLOCK} exceeds the app's last processed block (${app_block}); rebuilding ahead of the app would double-count those blocks after restart." >&2
    exit 2
fi

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

# process_financial's per-batch hook restates the monthly rollup as it goes, but a
# final remainder batch shorter than the ~1200-block gate would not fire it, so seal
# the last processed month explicitly (cheap: one month) to guarantee full coverage.
log "Sealing the final month of the financial monthly rollup..."
psql_cmd -c "
    SELECT haf_stats_app.refresh_financial_monthly(
        (SELECT DATE_TRUNC('month', created_at)::DATE FROM hafd.blocks WHERE num = ${TO_BLOCK}));
"

log "Financial rebuild complete."
