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
# resumable: re-run it with FROM_DAY set to the last day it logged (it only fills rows whose
# rc_exact is NULL; a value already there is never replaced).
#
# Per day it logs, per rollup, the rows it filled and the NULL rows it found but could not fill
# because their op_count/op_bytes no longer match what the chain gives (those keep the estimate).
# A NULL row the recomputed day has no group for is not counted.
#
# A node replayed on HAF 1.28.8 has rc_cost from hardfork 20 on. A node UPGRADED to 1.28.8
# without a replay has it only from the upgrade on: the script checks the hardfork-20 day first
# and stops if it has no recorded cost there, unless FROM_DAY is given (set it to the upgrade day).
#
# What it costs - see "Exact RC in the daily rollups" in README.md. In short: a day is ~28,800
# blocks, so the split alone is ~5-10 s per day (measured 1.7 s per 10,000 recent blocks, 3.4 s
# per 10,000 from 2021), ~4-8 hours over full history, before the three rollups' own day queries
# and the UPDATEs; a whole run has not been timed. Most filled rows are UPDATEs that also write a
# new index entry, and the space that frees is reused, not returned to the OS. Re-running
# recomputes every day in the range, filled or not: resume with FROM_DAY.
#
# Before hardfork 20 (2018-09-25) there is no RC to record, so the default range starts there.
# On a HAF without rc_cost it stops at once (exit 2). Full history is roughly 2,900 days.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

FROM_DAY_GIVEN="${FROM_DAY:+yes}"
: "${FROM_DAY:=2018-09-25}"
: "${TO_DAY:=}"

wait_for_postgres

# No error swallowing in these probes: a failed connection must stop the script (set -e on the
# assignment), not read as "no recorded cost".
#
# A HAF without the column has nothing to fill at all, whatever FROM_DAY says - and it cannot even
# parse the hardfork-20 probe below - so this is asked first, always.
available="$(psql_cmd -Atc "SELECT haf_stats_app.rc_cost_available()")"
if [[ "${available}" != "t" ]]; then
    echo "This HAF has no hafd.transactions.rc_cost (it needs HAF 1.28.8 or later): nothing to fill." >&2
    exit 2
fi

if [[ -z "${FROM_DAY_GIVEN}" ]]; then
    # Hardfork 20's first block with RC is 26,256,744. No recorded cost in the next 10,000 blocks
    # means this HAF was not replayed on 1.28.8: history has no rc_cost to backfill from.
    recorded="$(psql_cmd -Atc "
        SELECT EXISTS (
            SELECT 1 FROM hafd.transactions
            WHERE block_num BETWEEN 26256744 AND 26266743 AND rc_cost IS NOT NULL
        )
    ")"
    if [[ "${recorded}" != "t" ]]; then
        echo "No recorded RC cost at hardfork 20: this HAF was not replayed on 1.28.8." >&2
        echo "Set FROM_DAY to the day HAF was upgraded, or later; earlier days have nothing to fill." >&2
        exit 2
    fi
fi

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
    result="$(psql_cmd -Atc "SELECT string_agg(rollup || '=' || rows_set || ' (mismatched ' || rows_mismatched || ')', ', ') FROM haf_stats_app.backfill_rc_exact('${day}'::DATE)")"
    log "${day}: ${result:-no blocks}"
done

log "rc_exact backfill complete through ${TO_DAY}."
