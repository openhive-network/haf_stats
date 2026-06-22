-- =============================================================================
-- haf_stats Regression Test Schema  (mirrors balance_tracker/tests/regression/sql)
-- =============================================================================
-- Holds external ground-truth metrics (computed from a canonical hived node by
-- generate_fixture.py and committed as account_metrics_dump.json.gz) and the
-- comparison bookkeeping. compare_account_metrics() (02_compare.sql) checks the
-- live haf_stats endpoints against these expected values and records any
-- divergence in differing_metrics. Test-only: install_app.sh does NOT install it.
-- =============================================================================

SET ROLE haf_stats_owner;

DO $$
BEGIN
    CREATE SCHEMA haf_stats_test AUTHORIZATION haf_stats_owner;
EXCEPTION WHEN duplicate_schema THEN
    RAISE NOTICE 'Schema haf_stats_test already exists, skipping creation';
END $$;

-- Expected per-account metrics for the 2016-04 window, from the hived snapshot.
CREATE TABLE IF NOT EXISTS haf_stats_test.expected_account_metrics (
    account                   TEXT PRIMARY KEY,
    posts                     INT    DEFAULT 0,
    comments                  INT    DEFAULT 0,
    votes_cast                INT    DEFAULT 0,
    transfer_income_hive_nai  BIGINT DEFAULT 0,
    transfer_income_ops       INT    DEFAULT 0,
    transfer_expense_hive_nai BIGINT DEFAULT 0,
    transfer_expense_ops      INT    DEFAULT 0
);

-- One row per (account, field) where the live endpoint disagrees with expected.
CREATE TABLE IF NOT EXISTS haf_stats_test.differing_metrics (
    account  TEXT,
    field    TEXT,
    expected NUMERIC,
    actual   NUMERIC
);

RESET ROLE;
