-- PostgREST-exposed API functions for haf_stats.
-- All functions live in haf_stats_endpoints and are callable by haf_stats_user.

CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_version()
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT git_hash FROM haf_stats_app.app_version LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_health()
RETURNS TABLE (
    status               TEXT,
    last_processed_block INT,
    version              TEXT
)
LANGUAGE sql STABLE
AS $$
    SELECT
        'ok'::TEXT                                               AS status,
        s.last_processed_block,
        (SELECT git_hash FROM haf_stats_app.app_version LIMIT 1) AS version
    FROM haf_stats_app.app_status s
    LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-account financial summary
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_financial_summary(
    _account     TEXT,
    _from        DATE DEFAULT (NOW() - INTERVAL '1 year')::DATE,
    _to          DATE DEFAULT NOW()::DATE,
    _granularity TEXT DEFAULT 'month'   -- 'day' | 'week' | 'month'
)
RETURNS TABLE (
    period    TEXT,
    category  TEXT,
    direction TEXT,
    hive_nai  BIGINT,
    hbd_nai   BIGINT,
    vests_nai BIGINT,
    op_count  INT
)
LANGUAGE sql STABLE
AS $$
    SELECT
        TO_CHAR(DATE_TRUNC(_granularity, afd.day), 'YYYY-MM-DD') AS period,
        afd.category,
        afd.direction,
        SUM(afd.hive_nai)::BIGINT,
        SUM(afd.hbd_nai)::BIGINT,
        SUM(afd.vests_nai)::BIGINT,
        SUM(afd.op_count)::INT
    FROM haf_stats_backend.account_financial_daily afd
    JOIN hafd.accounts ha ON ha.id = afd.account_id
    WHERE ha.name  = _account
      AND afd.day BETWEEN _from AND _to
    GROUP BY 1, 2, 3
    ORDER BY 1, 2, 3;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;
