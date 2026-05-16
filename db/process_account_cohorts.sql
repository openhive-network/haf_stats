-- Feature: new account cohort retention (get_network_account_funnel endpoint).
--
-- Tracks what percentage of accounts created in a given month are still active
-- (have at least one non-virtual operation) at 7, 30, and 90 days after creation.
--
-- Two tables:
--   account_cohort_members  — one row per account, tracks per-account activity flags
--   account_cohort_retention — one row per month, the pre-aggregated endpoint data
--
-- The processor runs on every block range and:
--   1. Records newly created accounts (creation op in block range)
--   2. Updates activity flags for pending members that appear in this range
--   3. Recomputes the cohort retention summary

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_cohort_members (
    account_id INT PRIMARY KEY,
    cohort_month DATE NOT NULL,
    created_at TIMESTAMP NOT NULL,
    active_7d BOOLEAN NOT NULL DEFAULT FALSE,
    active_30d BOOLEAN NOT NULL DEFAULT FALSE,
    active_90d BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_acm_cohort
ON haf_stats_backend.account_cohort_members (cohort_month);

CREATE INDEX IF NOT EXISTS idx_acm_pending
ON haf_stats_backend.account_cohort_members (created_at)
WHERE NOT active_90d;

GRANT SELECT ON haf_stats_backend.account_cohort_members TO haf_stats_user;

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_cohort_retention (
    cohort_month DATE PRIMARY KEY,
    new_accounts INT NOT NULL DEFAULT 0,
    active_at_7d INT,
    active_at_30d INT,
    active_at_90d INT
);

GRANT SELECT ON haf_stats_backend.account_cohort_retention TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_account_cohorts(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _block_time TIMESTAMP;
BEGIN
    SELECT created_at INTO _block_time FROM hafd.blocks WHERE num = _last_block;

    -- Step 1: Record newly created accounts in this block range.
    -- Covers account_create_operation, account_create_with_delegation_operation,
    -- and create_claimed_account_operation — all use new_account_name in body.
    INSERT INTO haf_stats_backend.account_cohort_members
        (account_id, cohort_month, created_at)
    SELECT
        a.id,
        DATE_TRUNC('month', hb.created_at)::DATE,
        hb.created_at
    FROM hive.operations_view ov
    JOIN hafd.blocks hb  ON hb.num  = ov.block_num
    JOIN hafd.accounts a ON a.name  = (ov.body -> 'value' ->> 'new_account_name')
    WHERE ov.block_num BETWEEN _first_block AND _last_block
      AND ov.op_type_id IN (
          SELECT id FROM hafd.operation_types
          WHERE name IN (
              'account_create_operation',
              'account_create_with_delegation_operation',
              'create_claimed_account_operation'
          )
      )
    ON CONFLICT (account_id) DO NOTHING;

    -- Step 2: Mark activity flags for pending cohort members that have
    -- non-virtual ops in this block range, within their 90-day window.
    -- Uses transacting_account_id (the account that signed/spent RCs).
    UPDATE haf_stats_backend.account_cohort_members acm
    SET
        active_7d  = acm.active_7d  OR (ra.earliest_ts <= acm.created_at + INTERVAL '7 days'),
        active_30d = acm.active_30d OR (ra.earliest_ts <= acm.created_at + INTERVAL '30 days'),
        active_90d = acm.active_90d OR (ra.earliest_ts <= acm.created_at + INTERVAL '90 days')
    FROM (
        SELECT
            aov.transacting_account_id  AS account_id,
            MIN(hb.created_at)          AS earliest_ts
        FROM hive.account_operations_view aov
        JOIN hafd.blocks hb ON hb.num = aov.block_num
        WHERE aov.block_num BETWEEN _first_block AND _last_block
          AND aov.op_type_id NOT IN (
              SELECT id FROM hafd.operation_types WHERE is_virtual = TRUE
          )
        GROUP BY aov.transacting_account_id
    ) ra
    WHERE acm.account_id = ra.account_id
      AND NOT acm.active_90d
      AND acm.created_at >= _block_time - INTERVAL '90 days';

    -- Step 3: Recompute cohort retention summary from member flags.
    -- active_at_Nd is NULL while the Nd window has not yet fully elapsed
    -- for the cohort (some members may still become active).
    INSERT INTO haf_stats_backend.account_cohort_retention
        (cohort_month, new_accounts, active_at_7d, active_at_30d, active_at_90d)
    SELECT
        cohort_month,
        COUNT(*)                                                                AS new_accounts,
        CASE WHEN cohort_month + INTERVAL '7 days'  <= _block_time
             THEN COUNT(*) FILTER (WHERE active_7d)  ELSE NULL END             AS active_at_7d,
        CASE WHEN cohort_month + INTERVAL '30 days' <= _block_time
             THEN COUNT(*) FILTER (WHERE active_30d) ELSE NULL END             AS active_at_30d,
        CASE WHEN cohort_month + INTERVAL '90 days' <= _block_time
             THEN COUNT(*) FILTER (WHERE active_90d) ELSE NULL END             AS active_at_90d
    FROM haf_stats_backend.account_cohort_members
    GROUP BY cohort_month
    ON CONFLICT (cohort_month) DO UPDATE SET
        new_accounts  = EXCLUDED.new_accounts,
        active_at_7d  = EXCLUDED.active_at_7d,
        active_at_30d = EXCLUDED.active_at_30d,
        active_at_90d = EXCLUDED.active_at_90d;
END;
$$;
