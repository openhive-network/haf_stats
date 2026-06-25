SET ROLE haf_stats_owner;

-- Feature: new account cohort retention (get_network_account_funnel endpoint).
--
-- Tracks what percentage of accounts created in a given month are still active
-- (authored an operation) at 7, 30, and 90 days after creation.
--
-- NOTE — this deliberately redefines the metric in TWO ways vs the prior
-- (develop) implementation; both are intentional and called out in the MR:
--   1. Activity SOURCE: "authored" now means the account is a required signing
--      authority of a non-virtual op (hive.get_required_authorities), not any
--      account_operations_view row. This excludes pow/pow2 mining, so a mining
--      bot is no longer counted as a retained user (2016-04: 508/203/231 ->
--      325/89/219).
--   2. Activity WINDOW: Day-N retention is now activity during the exact 24-hour
--      bracket [created_at + N days, created_at + N + 1 days), NOT the previous
--      cumulative "active within N days" (earliest op <= created + N days). The
--      bracket is the standard cohort-retention definition and makes D7/D30/D90
--      independent signals; the cumulative form made every later window
--      automatically true once an earlier one was.
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

-- The old idx_acm_pending partial index used WHERE NOT active_90d. That worked
-- only when active_90d meant "ever active within 90 days"; with true D90
-- retention, most accounts legitimately remain false forever and would bloat
-- the partial index. A full created_at index keeps the 91-day range probe
-- bounded without retaining a misleading notion of "pending".
--
-- CONCURRENTLY: this index swap is the one that can hit a populated table on an
-- upgrade (idx_acm_created_at is new; the pre-existing idx_acm_cohort is a
-- CREATE ... IF NOT EXISTS no-op there). install_app.sh loads each file with a
-- plain psql -f (no --single-transaction), so every statement autocommits and
-- CONCURRENTLY is permitted; it avoids the ACCESS EXCLUSIVE lock that would
-- otherwise stall the live processor while the index builds.
--
-- A CONCURRENTLY build interrupted partway leaves an INVALID index behind, which
-- the CREATE ... IF NOT EXISTS below would then skip forever. Drop any invalid
-- leftover first (plain DROP — a brief lock, but only on this rare recovery
-- path) so the create can rebuild it cleanly.
DROP INDEX CONCURRENTLY IF EXISTS haf_stats_backend.idx_acm_pending;
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'haf_stats_backend'
          AND c.relname = 'idx_acm_created_at'
          AND NOT i.indisvalid
    ) THEN
        DROP INDEX haf_stats_backend.idx_acm_created_at;
    END IF;
END $$;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_acm_created_at
ON haf_stats_backend.account_cohort_members (created_at);

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
-- Summary refresh
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.refresh_account_cohort_retention(
    _as_of TIMESTAMP,
    _from_month DATE = NULL,
    _to_month DATE = NULL
)
RETURNS VOID
LANGUAGE sql
AS $$
    INSERT INTO haf_stats_backend.account_cohort_retention
        (cohort_month, new_accounts, active_at_7d, active_at_30d, active_at_90d)
    SELECT
        cohort_month,
        COUNT(*) AS new_accounts,
        CASE WHEN MAX(created_at) + INTERVAL '8 days' <= _as_of
             THEN COUNT(*) FILTER (WHERE active_7d) ELSE NULL END AS active_at_7d,
        CASE WHEN MAX(created_at) + INTERVAL '31 days' <= _as_of
             THEN COUNT(*) FILTER (WHERE active_30d) ELSE NULL END AS active_at_30d,
        CASE WHEN MAX(created_at) + INTERVAL '91 days' <= _as_of
             THEN COUNT(*) FILTER (WHERE active_90d) ELSE NULL END AS active_at_90d
    FROM haf_stats_backend.account_cohort_members
    WHERE (_from_month IS NULL OR cohort_month >= _from_month)
      AND (_to_month IS NULL OR cohort_month <= _to_month)
    GROUP BY cohort_month
    ON CONFLICT (cohort_month) DO UPDATE SET
        new_accounts  = EXCLUDED.new_accounts,
        active_at_7d  = EXCLUDED.active_at_7d,
        active_at_30d = EXCLUDED.active_at_30d,
        active_at_90d = EXCLUDED.active_at_90d;
$$;

-- ---------------------------------------------------------------------------
-- Incremental processor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_account_cohorts(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
-- Planner pins mirror process_active_users: the Step 2 activity scan is an
-- operations PK range-scan + LATERAL, so keep jit off, raise the collapse
-- limits for the CTE chain, and disable bitmapscan so the id-range index scan
-- is preferred over a bitmap heap scan.
SET jit = OFF
SET from_collapse_limit = '16'
SET join_collapse_limit = '16'
SET enable_bitmapscan = 'off'
AS $$
DECLARE
    _block_time TIMESTAMP;
BEGIN
    SELECT created_at INTO _block_time FROM hafd.blocks WHERE num = _last_block;

    -- Step 1: Record newly created accounts in this block range.
    -- Driven by the virtual account_created_operation, which the chain emits
    -- exactly once per account at its creation, for EVERY creation mechanism —
    -- account_create / _with_delegation / create_claimed_account AND pow/pow2
    -- mining (the dominant path in early 2016). Counting only the explicit
    -- *_create ops undercounts massively pre-HF (e.g. 224 vs 6840 for 2016-04).
    -- account_created carries new_account_name and fires at the creation block, so
    -- it agrees with hafd.accounts.block_num (the parity guard checks against that).
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
      AND ov.op_type_id = (
          SELECT id FROM hafd.operation_types
          WHERE name = 'hive::protocol::account_created_operation'
      )
    ON CONFLICT (account_id) DO NOTHING;

    -- Step 2: Mark independent day-N retention flags. An account is retained at
    -- N days only when it AUTHORS a non-virtual operation during [N, N+1) days
    -- after creation. Early activation therefore does not automatically count as
    -- D30 or D90 retention.
    --
    -- "Authored" = the account is a required signing authority of the op
    -- (hive.get_required_authorities), the same definition process_active_users
    -- uses. This deliberately EXCLUDES pow/pow2 mining (authorless), so a mining
    -- bot re-mining at D7 is not counted as user retention.
    --
    -- Perf: drive from the shared authored-op set prepared by process_block_range
    -- (or lazily here for direct rebuild calls), not from the ever-growing member
    -- table. The previous member-driven probe scanned all ~12k members whose
    -- 91-day window overlapped the batch and index-probed account_operations once
    -- each — O(accumulated members), ~4.3s/batch and worsening as the cohort grows.
    -- account_operations has no block/operation_id index (only (account_id, ...)),
    -- so it cannot be range-scanned by block at all. The shared helper scans
    -- operations_view once for both this processor and process_active_users using
    -- the operation_id half-open range [op_id(first,0), op_id(last+1,0)).
    PERFORM haf_stats_app.prepare_batch_authored_ops(_first_block, _last_block);
    WITH batch_authored AS MATERIALIZED (
        -- Preserve the old retention grain: one row per account per op timestamp.
        SELECT DISTINCT account_id, op_time
        FROM haf_stats_batch_authored_ops
    )
    UPDATE haf_stats_backend.account_cohort_members acm
    SET
        active_7d  = acm.active_7d  OR ra.active_7d,
        active_30d = acm.active_30d OR ra.active_30d,
        active_90d = acm.active_90d OR ra.active_90d
    FROM (
        SELECT
            m.account_id,
            BOOL_OR(
                ba.op_time >= m.created_at + INTERVAL '7 days'
                AND ba.op_time < m.created_at + INTERVAL '8 days'
            ) AS active_7d,
            BOOL_OR(
                ba.op_time >= m.created_at + INTERVAL '30 days'
                AND ba.op_time < m.created_at + INTERVAL '31 days'
            ) AS active_30d,
            BOOL_OR(
                ba.op_time >= m.created_at + INTERVAL '90 days'
                AND ba.op_time < m.created_at + INTERVAL '91 days'
            ) AS active_90d
        FROM batch_authored ba
        JOIN haf_stats_backend.account_cohort_members m
              ON m.account_id = ba.account_id
        WHERE NOT (m.active_7d AND m.active_30d AND m.active_90d)
          AND ba.op_time >= m.created_at + INTERVAL '7 days'
          AND ba.op_time <  m.created_at + INTERVAL '91 days'
        GROUP BY m.account_id
    ) ra
    WHERE acm.account_id = ra.account_id
      AND (ra.active_7d OR ra.active_30d OR ra.active_90d);

    -- Step 3: Recompute cohort retention summary from member flags.
    --
    -- A cohort's Dn result is disclosed only after the latest-created member's
    -- [N,N+1) window has closed. refresh_account_cohort_retention derives this
    -- from MAX(created_at), avoiding both partial results and month-long delays.
    --
    -- #20.3: only recompute cohorts whose flags can still change. Step 2 stops
    -- updating members older than 90 days, so any cohort whose accounts are all
    -- >90 days old is final. Restrict the aggregate to recent cohorts instead of
    -- scanning the whole (ever-growing) table on every call. The extra month of
    -- slack keeps a cohort in scope until its 90-day disclosure has been written.
    --
    -- Perf (#21): the summary recompute is by far the dominant per-block cost,
    -- yet retention is a coarse metric with day-granular disclosure windows.
    -- Recompute only when the block range crosses a ~1200-block (~1 hour)
    -- boundary, rather than on every single block range — cutting this from the
    -- per-block hot path to roughly hourly. Multi-block (catch-up / massive)
    -- ranges that span a boundary still refresh it.
    IF (_last_block / 1200) <> ((_first_block - 1) / 1200) THEN
        PERFORM haf_stats_app.refresh_account_cohort_retention(
            _block_time,
            (
                DATE_TRUNC('month', _block_time - INTERVAL '91 days')
                - INTERVAL '1 month'
            )::DATE
        );
    END IF;
END;
$$;

RESET ROLE;
