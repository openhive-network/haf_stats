#!/usr/bin/env bash
# =============================================================================
# run_verification.sh — correctness guards for the real-data values, run against
# the already-up integration test stack (docker-compose-test.yml, left running by
# run_tests.sh --keep). Mirrors balance_tracker's parity + regression tests.
#
#   1. tests/parity/mainnet_metrics_parity.sql
#        Independent in-DB re-derivation from the raw operation stream vs the
#        haf_stats endpoint output. RAISEs (psql exits non-zero) on any mismatch.
#   2. tests/regression/ (vs external hived snapshot)
#        Loads account_metrics_dump.json.gz (captured from a canonical hived node)
#        and compares the account-scoped endpoints against it.
#
# Both run inside the `haf` container (it has psql + the DB on a local socket as
# haf_admin), so no TCP/pg_hba or extra DB driver is needed.
# Run from the repo root. Exits non-zero if either guard fails.
# =============================================================================
set -euo pipefail

COMPOSE=(docker compose --env-file docker/.env -f docker/docker-compose-test.yml)
PSQL_IN_HAF() { "${COMPOSE[@]}" exec -T haf psql -U haf_admin -d haf_block_log -v ON_ERROR_STOP=on "$@"; }

echo "===== Guard 1/2: parity (independent in-DB re-derivation) ====="
"${COMPOSE[@]}" cp tests/parity/mainnet_metrics_parity.sql haf:/tmp/parity.sql
PSQL_IN_HAF -f /tmp/parity.sql

echo "===== Guard 2/2: regression (vs external hived snapshot) ====="
"${COMPOSE[@]}" cp tests/regression/sql/00_schema.sql haf:/tmp/reg_00.sql
"${COMPOSE[@]}" cp tests/regression/sql/02_compare.sql haf:/tmp/reg_02.sql
# Render the committed hived fixture into INSERT statements (needs python3 on the job host).
python3 tests/regression/load_expected_metrics.py tests/regression/account_metrics_dump.json.gz > /tmp/reg_load.sql
"${COMPOSE[@]}" cp /tmp/reg_load.sql haf:/tmp/reg_load.sql
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

echo "===== Correctness guards PASSED (parity + external regression) ====="
