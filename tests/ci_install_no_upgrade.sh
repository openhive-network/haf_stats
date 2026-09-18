#!/bin/bash
# install-under-lock's command: a normal install that must also APPLY NO schema upgrade. (#96)
#
# install-again has just re-applied every guarded upgrade (tests/ci_break_schema.sql undid them
# first), so on this run every catalog test must answer "already applied". The helper,
# haf_stats_app.apply_schema_migration, prints `haf_stats: schema upgrade ...` only when it runs
# its DDL or waits to, so any such line here is a guard that is wrongly TRUE.
#
# tests/ci_lock_holder.sql catches a wrongly-TRUE guard too, but only on the statements that take
# ACCESS EXCLUSIVE. The DELETE (ROW EXCLUSIVE) and the VALIDATE (SHARE UPDATE EXCLUSIVE) queue no
# reader, so the holder never sees them -- and a DELETE guard stuck at TRUE would rescan
# account_financial_daily on every install.
set -uo pipefail

log="$(mktemp)"
/app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc="${PIPESTATUS[0]}"
if [ "$rc" -ne 0 ]; then
    echo "install-under-lock: install_app exited ${rc}" >&2
    exit "$rc"
fi

if grep -F 'haf_stats: schema upgrade' "$log" >&2; then
    echo "install-under-lock: FAIL - the lines above are schema upgrades run on a database install-again had already upgraded; their catalog test is wrongly TRUE (#96)" >&2
    exit 1
fi
echo "install-under-lock: no schema upgrade ran - every catalog test found its upgrade already applied"
