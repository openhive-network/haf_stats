#!/usr/bin/env bash
# =============================================================================
# haf_stats Regression Test  (mirrors balance_tracker/tests/regression/run_test.sh)
# =============================================================================
# Compares the live haf_stats account-scoped endpoints against EXTERNAL ground
# truth captured from a canonical hived node (account_metrics_dump.json.gz, built
# by generate_fixture.py via condenser_api.get_account_history). This validates
# CORRECTNESS using a source that shares nothing with haf_stats — complementing
# tests/parity (independent in-DB re-derivation) and endpoint-local tests/tavern
# .pat.json files (exact-value regression guard).
#
#   exit 0 -> every expected field matches
#   exit 1 -> one or more fields differ (printed)
#
# Prereqs: haf_stats installed AND processed over a HAF DB replayed to >= ~1.1M
# blocks (closes the 2016-04 window the fixture targets).
#
# Recreate the fixture (needs internet; CI does not):
#   python3 generate_fixture.py --node https://api.hive.blog
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/arg_guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/arg_guard.sh"

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-haf_admin}"

while [ $# -gt 0 ]; do
    case "$1" in
        --host=*) require_flag_value "$1"; POSTGRES_HOST="${1#*=}" ;;
        --port=*) require_flag_value "$1"; POSTGRES_PORT="${1#*=}" ;;
        --user=*) require_flag_value "$1"; POSTGRES_USER="${1#*=}" ;;
        --help|-h) echo "Usage: $0 [--host=H] [--port=P] [--user=U]"; exit 0 ;;
        *) echo "ERROR: unknown option: $1"; exit 1 ;;
    esac
    shift
done

DB="postgresql://${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/haf_block_log"
PSQL=(psql "$DB" -v ON_ERROR_STOP=on)

echo "=============================================="
echo " haf_stats Regression Test (vs hived snapshot)"
echo "   $POSTGRES_HOST:$POSTGRES_PORT  user=$POSTGRES_USER"
echo "=============================================="

echo "Step 1: install test schema..."
"${PSQL[@]}" -f "$SCRIPT_DIR/sql/00_schema.sql" >/dev/null

echo "Step 2: load expected data from hived fixture..."
python3 "$SCRIPT_DIR/load_expected_metrics.py" "$SCRIPT_DIR/account_metrics_dump.json.gz" | "${PSQL[@]}" >/dev/null

echo "Step 3: install + run comparison..."
"${PSQL[@]}" -f "$SCRIPT_DIR/sql/02_compare.sql" >/dev/null
"${PSQL[@]}" -c "SELECT haf_stats_test.compare_account_metrics();" >/dev/null

echo "Step 4: results"
"${PSQL[@]}" -c "SELECT account, field, expected, actual FROM haf_stats_test.differing_metrics ORDER BY account, field;"
DIFF=$("${PSQL[@]}" -t -A -c "SELECT COUNT(*) FROM haf_stats_test.differing_metrics;")

if [ "$DIFF" -eq 0 ]; then
    echo "=============================================="
    echo " SUCCESS: all endpoints match the hived snapshot"
    echo "=============================================="
    exit 0
fi
echo "=============================================="
echo " FAILURE: $DIFF field(s) differ from hived ground truth"
echo "=============================================="
exit 1
