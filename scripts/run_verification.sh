#!/usr/bin/env bash
# =============================================================================
# run_verification.sh — correctness guards for the real-data values. Mirrors
# balance_tracker's parity + regression tests.
#
#   1. tests/parity/mainnet_metrics_parity.sql
#        Independent in-DB re-derivation from the raw operation stream vs the
#        haf_stats endpoint output. RAISEs (psql exits non-zero) on any mismatch.
#   2. tests/regression/run_test.sh (vs external hived snapshot)
#        Loads account_metrics_dump.json.gz (captured from a canonical hived node)
#        and compares the account-scoped endpoints against it.
#   3. tests/parity/content_volume_rebuild_consistency.sql (issue #42)
#        Replays the rebuild path (process_content_volume) and asserts it
#        reproduces the live processor's content-volume tables exactly, plus
#        rebuilds account_content_daily's content columns correctly (SUM==network)
#        while preserving its vote columns. Rolls back, so the data tables are
#        left untouched.
#   4. tests/parity/community_vs_hivemind.sql (issue #47)
#        Where hivemind is co-located (hivemind_app in the same DB), compares our
#        raw-op community derivation against hivemind's own community_id. This is
#        the only check that can exercise the community path on real data — the CI
#        replay is 2016 history, which predates communities entirely. Read-only,
#        and skips cleanly when hivemind_app is absent.
#   5. tests/parity/interactions_cap.sql (issue #48)
#        Lowers get_account_interactions' op ceiling inside a rolled-back
#        transaction and asserts the guard both fires AND discloses the truncated
#        window. No tavern test can reach the ceiling (the busiest account in the
#        replay corpus is far below any sane value), so without this the whole
#        truncation path would ship unexecuted.
#   6. tests/parity/witness_blocks_rebuild_consistency.sql (issue #54)
#        witness_blocks_daily mixes two arithmetics in one upsert - the counters ADD
#        while first/last_missed_block merge with LEAST/GREATEST - so the table could
#        silently depend on how the chain was sliced into batches. Replays [1, tip]
#        batched (the shape rebuild_witness_blocks.sh uses) and again as a single
#        batch, asserts both reproduce live history byte-for-byte, then re-derives
#        from hafd and checks the endpoint against raw data. Finally counts op-86
#        rows RAW - no name parse, no accounts join - because every other stage shares
#        the processor's own premises and so cannot detect a missed arm that has gone
#        blind. TRUNCATEs and replays the table under ACCESS EXCLUSIVE inside a
#        REPEATABLE READ transaction that is ROLLED BACK, so the live table is left
#        exactly as found, pass or fail.
#   7. tests/parity/context_vs_app_status.sql (issue #55)
#        Asserts hafd.contexts.current_block_num and app_status.last_processed_block
#        agree. main() writes both in one transaction, so they can only diverge when
#        the HAF context was reset out from under the data — a state in which
#        GET /sync-status reports block 0 on a synced node and the processor replays
#        from genesis. Reads through the SECURITY DEFINER under the API role, so it
#        also covers that grant and RLS on hafd.contexts.
#
# Two connection modes:
#   * TCP (CI):    --host/--port/--user connect straight to the DB over TCP. Used
#                  by the regression-test CI job against the cached test stack
#                  (PostgreSQL reachable at docker:5432, PG_ACCESS=trust).
#   * compose (default, local): no --host given -> run psql inside the running
#                  `haf` container of docker-compose-test.yml (left up by
#                  run_tests.sh --keep), over its local socket as haf_admin.
#
# Run from the repo root. Exits non-zero if any guard fails.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=arg_guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/arg_guard.sh"

MODE="compose"
PG_HOST=""
PG_PORT="5432"
PG_USER="haf_admin"

for arg in "$@"; do
  case "$arg" in
    --host=*) require_flag_value "$arg"; PG_HOST="${arg#*=}"; MODE="tcp" ;;
    --port=*) require_flag_value "$arg"; PG_PORT="${arg#*=}" ;;
    --user=*) require_flag_value "$arg"; PG_USER="${arg#*=}" ;;
    --help|-h)
      echo "Usage: $0 [--host=H [--port=P] [--user=U]]"
      echo "  no args        run against docker-compose-test.yml's haf container (local)"
      echo "  --host=H ...    run over TCP against H:P as user U (CI)"
      exit 0 ;;
    *) echo "ERROR: unknown option: $arg"; exit 1 ;;
  esac
done

if [[ "$MODE" == "tcp" ]]; then
  DB="postgresql://${PG_USER}@${PG_HOST}:${PG_PORT}/haf_block_log"
  echo "Verification mode: TCP (${PG_HOST}:${PG_PORT} user=${PG_USER})"
  run_sql_file() { psql "$DB" -v ON_ERROR_STOP=on -f "$1"; }
else
  COMPOSE=(docker compose --env-file "${REPO_ROOT}/docker/.env" -f "${REPO_ROOT}/docker/docker-compose-test.yml")
  echo "Verification mode: docker compose exec (haf container)"
  run_sql_file() {
    "${COMPOSE[@]}" cp "$1" haf:/tmp/verification.sql
    "${COMPOSE[@]}" exec -T haf psql -U haf_admin -d haf_block_log -v ON_ERROR_STOP=on -f /tmp/verification.sql
  }
fi

cd "${REPO_ROOT}"

echo "===== Guard 1/7: parity (independent in-DB re-derivation) ====="
run_sql_file tests/parity/mainnet_metrics_parity.sql

echo "===== Guard 2/7: regression (vs external hived snapshot) ====="
if [[ "$MODE" == "tcp" ]]; then
  # run_test.sh natively speaks --host/--port/--user and runs psql on this host.
  bash tests/regression/run_test.sh --host="${PG_HOST}" --port="${PG_PORT}" --user="${PG_USER}"
else
  # No host-side TCP into the local haf image — drive psql inside the container.
  "${COMPOSE[@]}" cp tests/regression/sql/00_schema.sql haf:/tmp/reg_00.sql
  "${COMPOSE[@]}" cp tests/regression/sql/02_compare.sql haf:/tmp/reg_02.sql
  # Render the committed hived fixture into INSERT statements (needs python3 on the host).
  python3 tests/regression/load_expected_metrics.py tests/regression/account_metrics_dump.json.gz > /tmp/reg_load.sql
  "${COMPOSE[@]}" cp /tmp/reg_load.sql haf:/tmp/reg_load.sql
  PSQL_IN_HAF() { "${COMPOSE[@]}" exec -T haf psql -U haf_admin -d haf_block_log -v ON_ERROR_STOP=on "$@"; }
  PSQL_IN_HAF -f /tmp/reg_00.sql
  PSQL_IN_HAF -f /tmp/reg_load.sql
  PSQL_IN_HAF -f /tmp/reg_02.sql
  PSQL_IN_HAF -c "SELECT haf_stats_test.compare_account_metrics();"
  PSQL_IN_HAF -c "SELECT account, field, expected, actual FROM haf_stats_test.differing_metrics ORDER BY 1,2;"
  DIFF=$(PSQL_IN_HAF -tAc "SELECT COUNT(*) FROM haf_stats_test.differing_metrics;" | tr -d '[:space:]')
  if [ "${DIFF}" != "0" ]; then
    echo "REGRESSION FAILED: ${DIFF} field(s) differ from the hived snapshot"
    exit 1
  fi
fi

echo "===== Guard 3/7: content-volume rebuild consistency (issue #42) ====="
run_sql_file tests/parity/content_volume_rebuild_consistency.sql

echo "===== Guard 4/7: community derivation vs hivemind (issue #47) ====="
run_sql_file tests/parity/community_vs_hivemind.sql

echo "===== Guard 5/7: interactions op-ceiling guard (issue #48) ====="
run_sql_file tests/parity/interactions_cap.sql

echo "===== Guard 6/7: witness blocks rebuild consistency (issue #54) ====="
run_sql_file tests/parity/witness_blocks_rebuild_consistency.sql

echo "===== Guard 7/7: HAF context vs app_status parity (issue #55) ====="
run_sql_file tests/parity/context_vs_app_status.sql

echo "===== Correctness guards PASSED (parity + external regression + rebuild consistency + community oracle + interactions cap + witness rebuild + context parity) ====="
