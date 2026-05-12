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
    status TEXT,
    last_processed_block INT,
    version TEXT
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
    _account TEXT,
    _from DATE DEFAULT (NOW() - INTERVAL '1 year')::DATE,
    _to DATE DEFAULT NOW()::DATE,
    _granularity TEXT DEFAULT 'month' -- 'day' | 'week' | 'month'
)
RETURNS TABLE (
    period TEXT,
    category TEXT,
    direction TEXT,
    hive_nai BIGINT,
    hbd_nai BIGINT,
    vests_nai BIGINT,
    op_count INT
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

-- ---------------------------------------------------------------------------
-- Feature: per-account RC footprint
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_rc_footprint(
    _account TEXT,
    _from DATE DEFAULT (NOW() - INTERVAL '30 days')::DATE,
    _to DATE DEFAULT NOW()::DATE,
    _group_by TEXT DEFAULT 'op_type' -- 'op_type' | 'app'
)
RETURNS TABLE (
    label TEXT,
    rc_consumed BIGINT,
    op_count BIGINT,
    pct NUMERIC
)
LANGUAGE sql STABLE
AS $$
    WITH base AS (
        SELECT
            CASE _group_by
                WHEN 'app' THEN COALESCE(rol.custom_json_id, 'non-custom_json')
                ELSE            COALESCE(ot.name, 'unknown')
            END      AS label,
            rol.rc_cost
        FROM haf_stats_backend.rc_operation_log rol
        JOIN hafd.accounts a ON a.id = rol.account_id
        LEFT JOIN hive.operation_types ot ON ot.id = rol.op_type_id
        WHERE a.name             = _account
          AND rol.timestamp::DATE BETWEEN _from AND _to
    ),
    totals AS (SELECT SUM(rc_cost) AS grand_total FROM base)
    SELECT
        label,
        SUM(rc_cost)::BIGINT                                          AS rc_consumed,
        COUNT(*)::BIGINT                                              AS op_count,
        ROUND(SUM(rc_cost) * 100.0 / NULLIF(t.grand_total, 0), 2)   AS pct
    FROM base, totals t
    GROUP BY label, t.grand_total
    ORDER BY rc_consumed DESC;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network-wide RC utilization by op type / DApp
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_rc_utilization(
    _from DATE DEFAULT (NOW() - INTERVAL '30 days')::DATE,
    _to DATE DEFAULT NOW()::DATE,
    _granularity TEXT DEFAULT 'day' -- 'day' | 'week' | 'month'
)
RETURNS TABLE (
    period TEXT,
    rc_total BIGINT,
    by_label JSONB -- keys: op_type_name for non-custom_json, custom_json id for custom_json ops
)
LANGUAGE sql STABLE
AS $$
    SELECT
        TO_CHAR(DATE_TRUNC(_granularity, rol."timestamp"), 'YYYY-MM-DD') AS period,
        SUM(rol.rc_cost)::BIGINT                                          AS rc_total,
        jsonb_object_agg(
            COALESCE(rol.custom_json_id, ot.name, 'unknown'),
            SUM(rol.rc_cost)::BIGINT
        )                                                                 AS by_label
    FROM haf_stats_backend.rc_operation_log rol
    LEFT JOIN hive.operation_types ot ON ot.id = rol.op_type_id
    WHERE rol."timestamp"::DATE BETWEEN _from AND _to
    GROUP BY DATE_TRUNC(_granularity, rol."timestamp")
    ORDER BY 1;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network HP stake distribution (bucketed)
-- Reads cross-schema from btracker_app (Balance Tracker).
-- Requires: GRANT SELECT ON btracker_app.current_account_balances TO haf_stats_user
--
-- TODO: calibrate VESTS thresholds against live data. Current values assume
-- ~2,000,000,000 raw units per HP (VESTS precision=6, 1 HP ≈ 2000 VESTS).
-- Run: SELECT MIN(balance), MAX(balance), AVG(balance)
--      FROM btracker_app.current_account_balances WHERE nai = '@@000000037';
-- to verify the unit scale before deploying.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_hp_distribution()
RETURNS TABLE (
    bucket TEXT,
    account_count BIGINT,
    pct_accounts NUMERIC
)
LANGUAGE sql STABLE
AS $$
    WITH balances AS (
        SELECT
            CASE
                WHEN balance < 2000000000            THEN '0–1 HP'
                WHEN balance < 20000000000           THEN '1–10 HP'
                WHEN balance < 200000000000          THEN '10–100 HP'
                WHEN balance < 2000000000000         THEN '100–1K HP'
                WHEN balance < 20000000000000        THEN '1K–10K HP'
                WHEN balance < 200000000000000       THEN '10K–100K HP'
                WHEN balance < 2000000000000000      THEN '100K–1M HP'
                ELSE                                      '1M+ HP'
            END   AS bucket,
            COUNT(*) AS cnt
        FROM btracker_app.current_account_balances
        WHERE nai = '@@000000037'
          AND balance > 0
        GROUP BY 1
    ),
    total AS (SELECT SUM(cnt) AS n FROM balances)
    SELECT
        bucket,
        cnt::BIGINT                              AS account_count,
        ROUND(cnt * 100.0 / total.n, 2)         AS pct_accounts
    FROM balances, total
    ORDER BY
        CASE bucket
            WHEN '0–1 HP'      THEN 1
            WHEN '1–10 HP'     THEN 2
            WHEN '10–100 HP'   THEN 3
            WHEN '100–1K HP'   THEN 4
            WHEN '1K–10K HP'   THEN 5
            WHEN '10K–100K HP' THEN 6
            WHEN '100K–1M HP'  THEN 7
            ELSE                    8
        END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;
