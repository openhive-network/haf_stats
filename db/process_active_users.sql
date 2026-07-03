SET ROLE haf_stats_owner;

-- Feature: daily active users (get_daily_active_users endpoint).
--
-- An "active user" is an account that authored (signed) at least one non-trivial
-- operation in a period; "operations" is the volume of such ops. Both are exact
-- (no HLL/approximation), bucketed at day grain and rolled up to week/month in the
-- endpoint.
--
-- Actor source: hive.get_required_authorities(op.body). It returns the account(s)
-- that had to sign an operation - voter (vote), author (comment), from (transfer),
-- and every required_posting_auths/required_auths signer (custom_json) - for ANY
-- operation, not just a hardcoded handful. This is the whole point of the function
-- (haf#281) and is what makes the ALL rollup a true "any authored op" count rather
-- than the union of a few known op types. Two consequences we rely on:
--   * Virtual ops (producer_reward, fills, ...) return no authority, so block/witness
--     activity is excluded for free. We also pre-filter them by is_virtual so the
--     function is never called on them (~half the op stream).
--   * A few non-virtual ops have no signer (pow/pow2 - mined blocks); the LATERAL
--     INNER-join drops them automatically.
--
-- op_class encodes the operation category. The named classes are a fixed,
-- endpoint-facing set; -1 is a RESERVED synthetic class meaning "ALL authored ops".
--   -1 = ALL  (every authored op, including op types beyond the named five)
--    1 = post           (comment_operation with empty parent_author)
--    2 = comment        (comment_operation with a parent_author)
--    3 = vote
--    4 = transfer
--    5 = custom_json
-- IMPORTANT: op_class = -1 is computed independently over the whole op stream. It is
-- NOT the sum of the per-class rows - account_update, witness ops, etc. are real
-- activity the five named classes do not cover. Never derive ALL by summing classes.
--
-- Two tables, split by how each metric combines across block-range batches (the same
-- counter/membership split as process_content_stats' network_vote_daily /
-- network_voter_daily):
--   active_users_daily      one row per (day, op_class, account_id). active_accounts
--                           is NOT additive across batches (an account active in two
--                           batches on the same day must count once), so we store the
--                           distinct presence set idempotently and COUNT(DISTINCT
--                           account_id) in the endpoint at the requested grain. Exact
--                           for week/month too. Each row also carries ops — the
--                           account's authored-op count for that day/class — which IS
--                           additive (op_id sets are disjoint across batches), used by
--                           get_network_top_accounts' transaction_count leaderboard.
--                           COUNT(DISTINCT op_id) per account, so an op listing the
--                           same signer under several roles still counts once for it.
--   active_user_ops_daily   additive per-(day, op_class) operation counter. operations
--                           is COUNT(DISTINCT op_id) within a batch (a multisig op is
--                           one operation, not one-per-signer); op_id ranges are
--                           disjoint across batches, so col = col + EXCLUDED is exact.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.active_users_daily (
    day DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    account_id INT NOT NULL,
    ops INT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_class, account_id)
);

-- Idempotent upgrade for installs that created the table before ops existed.
ALTER TABLE haf_stats_backend.active_users_daily
ADD COLUMN IF NOT EXISTS ops INT NOT NULL DEFAULT 0;

GRANT SELECT ON haf_stats_backend.active_users_daily TO haf_stats_user;

-- Covering index for get_network_top_accounts' transaction_count branch, which scans
-- WHERE op_class = -1 AND day BETWEEN _from AND _to, GROUP BY account_id (#29 item 6).
-- The PK (day, op_class, account_id) leads with day, so that query range-scans every
-- op_class across the window. Leading with op_class (an equality key) + day (the range)
-- and INCLUDE-ing account_id/ops lets the branch satisfy itself with an index-only scan
-- of just the op_class = -1 slice. CONCURRENTLY + INVALID-leftover heal for the same
-- reason as idx_pe_post_day (process_content_stats): install_app.sh loads this file with
-- a plain psql -f (statement autocommit), and active_users_daily is large, so a plain
-- build on an already-populated upgrade would take an ACCESS EXCLUSIVE lock.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'haf_stats_backend'
          AND c.relname = 'idx_aud_opclass_day'
          AND NOT i.indisvalid
    ) THEN
        DROP INDEX haf_stats_backend.idx_aud_opclass_day;
    END IF;
END $$;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aud_opclass_day
ON haf_stats_backend.active_users_daily (op_class, day) INCLUDE (account_id, ops);

CREATE TABLE IF NOT EXISTS haf_stats_backend.active_user_ops_daily (
    day DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    operations BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_class)
);

GRANT SELECT ON haf_stats_backend.active_user_ops_daily TO haf_stats_user;

-- Pre-aggregated endpoint rollup for get_daily_active_users. active_accounts is
-- non-additive (an account active on several days in a week/month counts once), so
-- the endpoint cannot sum daily counts and previously COUNT(DISTINCT)-scanned the
-- whole active_users_daily membership (500M+ rows, 80+ GB) on every request - several
-- seconds per call regardless of how few rows it returned, because all granularities
-- dedup the same member rows. Mirroring account_cohort_retention, we precompute one
-- row per (period_type, period, op_class) and let the endpoint do a cheap indexed
-- read. period is DATE_TRUNC(period_type, day); period_type is 'day' | 'week' |
-- 'month'; op_class matches active_users_daily (-1 = ALL, 1..5 named). The refresh is
-- exact - a full re-aggregation of the affected periods, no HLL/approximation. The PK
-- is ordered (period_type, op_class, period) to make the endpoint's
-- period-range-within-a-class read a single index range scan.
CREATE TABLE IF NOT EXISTS haf_stats_backend.active_users_period_counts (
    period_type TEXT NOT NULL,
    period DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    active_accounts BIGINT NOT NULL DEFAULT 0,
    operations BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (period_type, op_class, period)
);

GRANT SELECT ON haf_stats_backend.active_users_period_counts TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Rollup refresh (feeds get_daily_active_users)
--
-- Recomputes active_users_period_counts for every day/week/month period touched
-- by [_lo, _hi], exactly (re-aggregates active_users_daily and
-- active_user_ops_daily). Passing NULL _hi keeps the old full-refresh behavior
-- from _lo forward for one-time repairs on already-synced nodes. Daily distinct is
-- just COUNT(*) - the (day, op_class, account_id) PK already guarantees one row
-- per account per day; week/month need COUNT(DISTINCT account_id). active_accounts
-- comes from the membership table, operations from the additive op counter, joined
-- per (period, op_class).
-- ---------------------------------------------------------------------------

-- A previous app version defined this as a 1-argument function. An in-place upgrade runs
-- CREATE OR REPLACE for the 2-arg form below but leaves that legacy 1-arg overload in
-- place, and a 1-arg call would then be ambiguous between them ("function ... is not
-- unique"). Drop the legacy signature so only the single 2-arg form (with a defaulted
-- _hi) remains; 1-arg callers (install_app.sh full refresh) resolve to it unambiguously.
DROP FUNCTION IF EXISTS haf_stats_app.refresh_active_users_periods(DATE);

CREATE OR REPLACE FUNCTION haf_stats_app.refresh_active_users_periods(
    _lo DATE,
    _hi DATE DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _week_lo DATE := DATE_TRUNC('week', _lo)::DATE;
    _week_hi DATE := CASE
        WHEN _hi IS NULL THEN NULL
        ELSE (DATE_TRUNC('week', _hi)::DATE + INTERVAL '1 week')::DATE
    END;
    _month_lo DATE := DATE_TRUNC('month', _lo)::DATE;
    _month_hi DATE := CASE
        WHEN _hi IS NULL THEN NULL
        ELSE (DATE_TRUNC('month', _hi)::DATE + INTERVAL '1 month')::DATE
    END;
BEGIN
    -- day: distinct-per-day == row count of the membership PK
    INSERT INTO haf_stats_backend.active_users_period_counts (period_type, period, op_class, active_accounts, operations)
    SELECT 'day', COALESCE(a.period, o.period), COALESCE(a.op_class, o.op_class), COALESCE(a.acct, 0), COALESCE(o.ops, 0)
    FROM (
        SELECT day AS period, op_class, COUNT(*) AS acct
        FROM haf_stats_backend.active_users_daily
        WHERE day >= _lo
          AND (_hi IS NULL OR day <= _hi)
        GROUP BY day, op_class
    ) a
    FULL JOIN (
        SELECT day AS period, op_class, operations AS ops
        FROM haf_stats_backend.active_user_ops_daily
        WHERE day >= _lo
          AND (_hi IS NULL OR day <= _hi)
    ) o ON o.period = a.period AND o.op_class = a.op_class
    ON CONFLICT (period_type, op_class, period) DO UPDATE SET
        active_accounts = EXCLUDED.active_accounts,
        operations = EXCLUDED.operations;

    -- week
    INSERT INTO haf_stats_backend.active_users_period_counts (period_type, period, op_class, active_accounts, operations)
    SELECT 'week', COALESCE(a.period, o.period), COALESCE(a.op_class, o.op_class), COALESCE(a.acct, 0), COALESCE(o.ops, 0)
    FROM (
        SELECT DATE_TRUNC('week', day)::DATE AS period, op_class, COUNT(DISTINCT account_id) AS acct
        FROM haf_stats_backend.active_users_daily
        WHERE day >= _week_lo
          AND (_week_hi IS NULL OR day < _week_hi)
        GROUP BY 1, 2
    ) a
    FULL JOIN (
        SELECT DATE_TRUNC('week', day)::DATE AS period, op_class, SUM(operations) AS ops
        FROM haf_stats_backend.active_user_ops_daily
        WHERE day >= _week_lo
          AND (_week_hi IS NULL OR day < _week_hi)
        GROUP BY 1, 2
    ) o ON o.period = a.period AND o.op_class = a.op_class
    ON CONFLICT (period_type, op_class, period) DO UPDATE SET
        active_accounts = EXCLUDED.active_accounts,
        operations = EXCLUDED.operations;

    -- month
    INSERT INTO haf_stats_backend.active_users_period_counts (period_type, period, op_class, active_accounts, operations)
    SELECT 'month', COALESCE(a.period, o.period), COALESCE(a.op_class, o.op_class), COALESCE(a.acct, 0), COALESCE(o.ops, 0)
    FROM (
        SELECT DATE_TRUNC('month', day)::DATE AS period, op_class, COUNT(DISTINCT account_id) AS acct
        FROM haf_stats_backend.active_users_daily
        WHERE day >= _month_lo
          AND (_month_hi IS NULL OR day < _month_hi)
        GROUP BY 1, 2
    ) a
    FULL JOIN (
        SELECT DATE_TRUNC('month', day)::DATE AS period, op_class, SUM(operations) AS ops
        FROM haf_stats_backend.active_user_ops_daily
        WHERE day >= _month_lo
          AND (_month_hi IS NULL OR day < _month_hi)
        GROUP BY 1, 2
    ) o ON o.period = a.period AND o.op_class = a.op_class
    ON CONFLICT (period_type, op_class, period) DO UPDATE SET
        active_accounts = EXCLUDED.active_accounts,
        operations = EXCLUDED.operations;
END;
$$;

-- ---------------------------------------------------------------------------
-- Per-account monthly rollup (get_network_top_accounts performance, issue #37)
--
-- active_users_period_counts above is NETWORK-WIDE (one row per period/op_class with
-- an account COUNT + op total), so it cannot serve a per-account leaderboard. This
-- table pre-aggregates per-account op totals at month grain for the ALL rollup
-- (op_class -1) — the only class get_network_top_accounts' transaction_count metric
-- reads. Its purpose mirrors account_financial_monthly: a 365-day transaction_count
-- leaderboard scans ~6.9M daily rows (~4s warm, worse cold); reading full interior
-- months here and the partial edges from active_users_daily keeps it byte-exact and
-- fast. ops is additive, so a month total is just SUM of the daily ops.
CREATE TABLE IF NOT EXISTS haf_stats_backend.active_users_account_monthly (
    month DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    account_id INT NOT NULL,
    ops BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (month, op_class, account_id)
);

-- Leaderboard access path: an (op_class, month)-range scan across all accounts.
CREATE INDEX IF NOT EXISTS idx_auam_class_month
ON haf_stats_backend.active_users_account_monthly (op_class, month);

GRANT SELECT ON haf_stats_backend.active_users_account_monthly TO haf_stats_user;

-- Recompute every month touched by [_lo, _hi] exactly from active_users_daily, whole
-- months from their first day (see refresh_financial_monthly for the identical
-- rationale). Only op_class -1 is materialised (the sole consumer). REPLACE semantics;
-- NULL _hi restates from _lo forward for a one-time genesis backfill.
CREATE OR REPLACE FUNCTION haf_stats_app.refresh_active_users_account_monthly(
    _lo DATE,
    _hi DATE DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _month_lo DATE := DATE_TRUNC('month', _lo)::DATE;
BEGIN
    INSERT INTO haf_stats_backend.active_users_account_monthly (month, op_class, account_id, ops)
    SELECT DATE_TRUNC('month', au.day)::DATE, au.op_class, au.account_id, SUM(au.ops)::BIGINT
    FROM haf_stats_backend.active_users_daily au
    WHERE au.op_class = -1
      AND au.day >= _month_lo
      AND (_hi IS NULL OR au.day <= _hi)
    GROUP BY DATE_TRUNC('month', au.day)::DATE, au.op_class, au.account_id
    ON CONFLICT (month, op_class, account_id) DO UPDATE SET
        ops = EXCLUDED.ops;
END;
$$;

-- ---------------------------------------------------------------------------
-- Processor
--
-- The shared batch-authored temp table feeds both active users and account cohorts.
-- Optimisation notes follow the in-repo siblings (process_content_stats,
-- process_account_cohorts) and the balance_tracker / hafbe HAF processors that run
-- over the same high-volume stream:
--
--  * Bound the shared scan by operation id as well as block_num. hafd.operation_id(b, 0)
--    is the first op id in block b, so the half-open id range [op_id(first,0),
--    op_id(last+1,0)) is exactly this block range and lets the planner range-scan the
--    operations primary key (the canonical haf_block_explorer idiom).
--
--  * Pre-exclude virtual ops (is_virtual) before the LATERAL so
--    get_required_authorities is never evaluated on the ~half of the stream that can
--    never yield an author.
--
--  * Resolve hafd accounts AFTER fan-out, once per DISTINCT actor name in the shared
--    helper (a busy voting bot recurs thousands of times per batch). name_ids is
--    MATERIALIZED so the lookup runs once over the small distinct-name set and hash-joins
--    back, instead of one index probe per actor row - the !370 /
--    process_account_vesting_stats idiom.
--
--  * The shared temp table is read directly below. It is already materialized, so avoid
--    copying it into a second CTE worktable before the membership and op-count rollups.
--
--  * Planner pins mirror process_account_vesting_stats: raised collapse limits for the
--    long CTE chain, jit off (short index-driven statements), bitmapscan off so the
--    operations PK range-scan is preferred over a bitmap heap scan.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_active_users(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
SET from_collapse_limit = '16'
SET join_collapse_limit = '16'
SET enable_bitmapscan = 'off'
AS $$
DECLARE
    _first_day DATE;
    _last_day DATE;
    _refresh_lo_block INT;
BEGIN

    PERFORM haf_stats_app.prepare_batch_authored_ops(_first_block, _last_block);
    WITH
    -- Presence set + per-account op counts: per-class rows plus the -1 ALL rollup
    -- (every authored op). COUNT(DISTINCT op_id), not COUNT(*): get_required_authorities
    -- can emit the same account under several roles for one op, and that is still one
    -- operation for that account.
    membership AS (
        SELECT day, op_class, account_id, COUNT(DISTINCT op_id) AS ops
        FROM haf_stats_batch_authored_ops
        WHERE op_class IS NOT NULL
        GROUP BY day, op_class, account_id
        UNION ALL
        SELECT day, -1::SMALLINT, account_id, COUNT(DISTINCT op_id)
        FROM haf_stats_batch_authored_ops
        GROUP BY day, account_id
    ),
    -- ops is additive (DO UPDATE adds), so this table is now reprocess-sensitive:
    -- re-running the same block range double-counts ops. Safe because each block range
    -- is processed exactly once (op_id ranges are disjoint across batches) — the same
    -- exactly-once assumption the additive active_user_ops_daily counter already relies
    -- on. The presence aspect (one row per day/class/account) stays idempotent.
    ins_members AS (
        INSERT INTO haf_stats_backend.active_users_daily AS aud (day, op_class, account_id, ops)
        SELECT day, op_class, account_id, ops FROM membership
        ON CONFLICT (day, op_class, account_id) DO UPDATE SET
            ops = aud.ops + EXCLUDED.ops
        RETURNING 1
    ),
    -- Operation volume: COUNT(DISTINCT op_id) per class plus the -1 ALL rollup. DISTINCT
    -- collapses multisig fan-out so a multi-signer op counts as one operation.
    op_counts AS (
        SELECT day, op_class, COUNT(DISTINCT op_id) AS operations
        FROM haf_stats_batch_authored_ops
        WHERE op_class IS NOT NULL
        GROUP BY day, op_class
        UNION ALL
        SELECT day, -1::SMALLINT, COUNT(DISTINCT op_id)
        FROM haf_stats_batch_authored_ops
        GROUP BY day
    )
    INSERT INTO haf_stats_backend.active_user_ops_daily (day, op_class, operations)
    SELECT day, op_class, operations FROM op_counts
    ON CONFLICT (day, op_class) DO UPDATE SET
        operations = active_user_ops_daily.operations + EXCLUDED.operations;

-- Refresh the get_daily_active_users rollup. Like account_cohort_retention this is the
-- dominant per-batch cost yet feeds a coarse metric, so refresh only when the range
-- crosses a ~1200-block (~1 hour) boundary. Recompute every day/week/month period that
-- received data since the previous refresh. A batch fires whenever it crosses a 1200-block
-- bucket boundary, so every block processed since the previous fire lies either in the
-- bucket containing this batch's first block (LIVE batches that did not cross a boundary
-- accumulate there - up to ~1 hour, which can spill into the previous calendar day) or in
-- this batch itself (a MASSIVE catch-up batch may span many buckets). The lower bound
-- reaches back to that bucket's start, ((_first_block - 1) / 1200) * 1200 (the same bucket
-- the gate compares), which covers them all; anchoring on _first_block (not _last_block)
-- keeps coverage correct even when a firing batch spans several buckets after a skipped
-- one. Bounding _lo this tightly (vs the old genesis-ward scan) is the optimisation; _hi
-- just caps the upper end at this batch's last day. Each period is still recomputed exactly
-- from the membership/counter tables. A one-time full refresh remains available via
-- SELECT haf_stats_app.refresh_active_users_periods(<genesis day>, NULL).
IF (_last_block / 1200) <> ((_first_block - 1) / 1200) THEN
    _refresh_lo_block := GREATEST(((_first_block - 1) / 1200) * 1200, 1);
    SELECT created_at::DATE INTO _first_day FROM hafd.blocks WHERE num = _refresh_lo_block;
    SELECT created_at::DATE INTO _last_day  FROM hafd.blocks WHERE num = _last_block;
    -- _refresh_lo_block and _last_block are already-processed blocks, so their rows
    -- normally exist. Guard the pathological case (a missing hafd.blocks row from a gap or
    -- partial replay): a NULL _lo would make the refresh silently roll up nothing, so fall
    -- back to this batch's own first block (always present) to keep the touched days covered.
    IF _first_day IS NULL THEN
        SELECT created_at::DATE INTO _first_day FROM hafd.blocks WHERE num = _first_block;
    END IF;

    PERFORM haf_stats_app.refresh_active_users_periods(_first_day, _last_day);
    -- Same touched-day range feeds the per-account monthly leaderboard rollup (#37).
    PERFORM haf_stats_app.refresh_active_users_account_monthly(_first_day, _last_day);
END IF;

END;
$$;

RESET ROLE;
