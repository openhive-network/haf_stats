#!/bin/bash
# Fill the exact RC of past days into the three daily rollups (#44, part 2).
#
# network_op_daily, network_custom_json_daily and account_custom_json_daily carry rc_exact, the
# RC their operations' transactions recorded (HAF 1.28.8 and later). The processor fills it for
# what it processes from now on. Rows it built before the column existed are NULL, and the
# endpoints price those with the estimate. This script fills them, one day at a time, through
# haf_stats_app.backfill_rc_exact(day), which recomputes the day from the chain and writes
# rc_exact only (never op_count or op_bytes), and only on rows whose counts it reproduces.
#
# Unlike the rebuild_*.sh scripts it is NOT destructive and does NOT need the processor stopped:
# it only writes days the processor has finished, and the function refuses any other day. It is
# resumable: re-run it with FROM_DAY set to the last day it logged, or simply again (rows that
# are already exact are left alone).
#
# Before hardfork 20 (2018-09-25) there is no RC to record, so the default range starts there.
# On a HAF without rc_cost it changes nothing.
#
# Cost: one day of operations per call. Measured on a 1.28.8 node, the exact shares for 10,000
# recent blocks (~218,000 operations) take ~1.7 s; a recent day is about three times that,
# repeated for each of the three rollups. Full history is roughly 2,900 days.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

: "${FROM_DAY:=2018-09-25}"
: "${TO_DAY:=}"

wait_for_postgres

# The last day the processor has FINISHED: the day before the one its last processed block is in.
last_done_day="$(
    psql_cmd -Atc "
        SELECT (b.created_at::DATE - 1)::TEXT
        FROM hafd.blocks AS b
        WHERE b.num = (SELECT MAX(s.last_processed_block) FROM haf_stats_app.app_status AS s)
    "
)"
if [[ -z "${last_done_day}" ]]; then
    echo "The processor has not finished any day yet (no last processed block); nothing to backfill." >&2
    exit 2
fi

if [[ -z "${TO_DAY}" ]]; then
    TO_DAY="${last_done_day}"
fi

for d in "${FROM_DAY}" "${TO_DAY}"; do
    if ! [[ "${d}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "Not a YYYY-MM-DD day: '${d}'" >&2
        exit 2
    fi
done
if [[ "${TO_DAY}" > "${last_done_day}" ]]; then
    echo "TO_DAY=${TO_DAY} is not finished by the processor yet (its last finished day is ${last_done_day})." >&2
    exit 2
fi
if [[ "${FROM_DAY}" > "${TO_DAY}" ]]; then
    echo "Nothing to do: FROM_DAY=${FROM_DAY} is after TO_DAY=${TO_DAY}." >&2
    exit 0
fi

log "Filling rc_exact for ${FROM_DAY} .. ${TO_DAY}, one day per transaction."

days="$(
    psql_cmd -Atc "
        SELECT d::DATE::TEXT
        FROM generate_series('${FROM_DAY}'::DATE, '${TO_DAY}'::DATE, INTERVAL '1 day') AS d
    "
)"
for day in ${days}; do
    result="$(psql_cmd -Atc "SELECT string_agg(rollup || '=' || rows_set, ' ') FROM haf_stats_app.backfill_rc_exact('${day}'::DATE)")"
    log "${day}: ${result:-no blocks}"
done

log "rc_exact backfill complete through ${TO_DAY}."
