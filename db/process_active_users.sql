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
-- Recomputes active_users_period_counts for every day/week/month period that
-- includes a day >= _lo, exactly (re-aggregates active_users_daily and
-- active_user_ops_daily). The ON CONFLICT upsert is idempotent, so callers pass a
-- recent _lo for the cheap incremental refresh (current period + slack) and the
-- genesis day for a one-time full rebuild on an already-synced node. Daily distinct
-- is just COUNT(*) - the (day, op_class, account_id) PK already guarantees one row
-- per account per day; week/month need COUNT(DISTINCT account_id). active_accounts
-- comes from the membership table, operations from the additive op counter, joined
-- per (period, op_class).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.refresh_active_users_periods(_lo DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- day: distinct-per-day == row count of the membership PK
    INSERT INTO haf_stats_backend.active_users_period_counts (period_type, period, op_class, active_accounts, operations)
    SELECT 'day', COALESCE(a.period, o.period), COALESCE(a.op_class, o.op_class), COALESCE(a.acct, 0), COALESCE(o.ops, 0)
    FROM (
        SELECT day AS period, op_class, COUNT(*) AS acct
        FROM haf_stats_backend.active_users_daily
        WHERE day >= _lo
        GROUP BY day, op_class
    ) a
    FULL JOIN (
        SELECT day AS period, op_class, operations AS ops
        FROM haf_stats_backend.active_user_ops_daily
        WHERE day >= _lo
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
        WHERE day >= DATE_TRUNC('week', _lo)::DATE
        GROUP BY 1, 2
    ) a
    FULL JOIN (
        SELECT DATE_TRUNC('week', day)::DATE AS period, op_class, SUM(operations) AS ops
        FROM haf_stats_backend.active_user_ops_daily
        WHERE day >= DATE_TRUNC('week', _lo)::DATE
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
        WHERE day >= DATE_TRUNC('month', _lo)::DATE
        GROUP BY 1, 2
    ) a
    FULL JOIN (
        SELECT DATE_TRUNC('month', day)::DATE AS period, op_class, SUM(operations) AS ops
        FROM haf_stats_backend.active_user_ops_daily
        WHERE day >= DATE_TRUNC('month', _lo)::DATE
        GROUP BY 1, 2
    ) o ON o.period = a.period AND o.op_class = a.op_class
    ON CONFLICT (period_type, op_class, period) DO UPDATE SET
        active_accounts = EXCLUDED.active_accounts,
        operations = EXCLUDED.operations;
END;
$$;

-- ---------------------------------------------------------------------------
-- Processor
--
-- One scan of the operation stream feeds both tables. Optimisation notes follow the
-- in-repo siblings (process_content_stats, process_account_cohorts) and the
-- balance_tracker / hafbe HAF processors that run over the same high-volume stream:
--
--  * Bound the scan by operation id as well as block_num. hafd.operation_id(b, 0) is
--    the first op id in block b, so the half-open id range
--    [op_id(first,0), op_id(last+1,0)) is exactly this block range and lets the planner
--    range-scan the operations primary key (the canonical haf_block_explorer idiom).
--
--  * Pre-exclude virtual ops (is_virtual) before the LATERAL so
--    get_required_authorities is never evaluated on the ~half of the stream that can
--    never yield an author.
--
--  * Resolve hafd accounts AFTER fan-out, once per DISTINCT actor name (a busy voting
--    bot recurs thousands of times per batch). name_ids is MATERIALIZED so the lookup
--    runs once over the small distinct-name set and hash-joins back, instead of one
--    index probe per actor row - the !370 / process_account_vesting_stats idiom.
--
--  * resolved is MATERIALIZED: it is read four times below (membership x2, op counts
--    x2 via the ALL rollup) and must not re-drive the operations scan each time.
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
    _block_day DATE;
BEGIN

WITH authored AS MATERIALIZED (
    -- One row per (op_id, signer). get_required_authorities fans multisig custom_json
    -- into one row per signer; authorless real ops (pow/pow2) are dropped by the
    -- INNER LATERAL join. The crash-safe wrapper (haf_stats_app.sql) is used in place
    -- of the raw HAF function: a handful of legacy ops past the 5M CI cap FC_ASSERT
    -- inside it ("Asset amount cannot be negative"), which would abort the batch and
    -- restart-loop the processor; the wrapper yields no rows for such an op.
    SELECT
        ov.id              AS op_id,
        ra.account_name    AS actor_name,
        b.created_at::DATE AS day,
        (CASE
            WHEN ov.op_type_id = 0 THEN 3::SMALLINT                 -- vote_operation
            WHEN ov.op_type_id = 1
             AND COALESCE(ov.body_value ->> 'parent_author', '') = ''
                                   THEN 1::SMALLINT                 -- comment_operation: post
            WHEN ov.op_type_id = 1 THEN 2::SMALLINT                 -- comment_operation: comment
            WHEN ov.op_type_id = 2 THEN 4::SMALLINT                 -- transfer_operation
            WHEN ov.op_type_id = 18 THEN 5::SMALLINT                -- custom_json_operation
            ELSE NULL::SMALLINT                                     -- other authored op: ALL rollup only
         END) AS op_class
    FROM hive.operations_view ov
    JOIN hafd.blocks b ON b.num = ov.block_num
    CROSS JOIN LATERAL haf_stats_app.get_required_authorities_safe(ov.body) ra
    WHERE ov.block_num BETWEEN _first_block AND _last_block
      AND ov.id >= hafd.operation_id(_first_block, 0)
      AND ov.id <  hafd.operation_id(_last_block + 1, 0)
      AND ov.op_type_id IN (SELECT id FROM hafd.operation_types WHERE NOT is_virtual)
),
-- Resolve the DISTINCT actor-name set once (anti-seq-scan idiom).
name_ids AS MATERIALIZED (
    SELECT av.name, av.id
    FROM hive.accounts_view av
    WHERE av.name IN (SELECT DISTINCT actor_name FROM authored)
),
resolved AS MATERIALIZED (
    SELECT a.op_id, a.day, a.op_class, ni.id AS account_id
    FROM authored a
    JOIN name_ids ni ON ni.name = a.actor_name
),
-- Presence set + per-account op counts: per-class rows plus the -1 ALL rollup
-- (every authored op). COUNT(DISTINCT op_id), not COUNT(*): get_required_authorities
-- can emit the same account under several roles for one op, and that is still one
-- operation for that account.
membership AS (
    SELECT day, op_class, account_id, COUNT(DISTINCT op_id) AS ops
    FROM resolved
    WHERE op_class IS NOT NULL
    GROUP BY day, op_class, account_id
    UNION ALL
    SELECT day, -1::SMALLINT, account_id, COUNT(DISTINCT op_id)
    FROM resolved
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
    FROM resolved
    WHERE op_class IS NOT NULL
    GROUP BY day, op_class
    UNION ALL
    SELECT day, -1::SMALLINT, COUNT(DISTINCT op_id)
    FROM resolved
    GROUP BY day
)
INSERT INTO haf_stats_backend.active_user_ops_daily (day, op_class, operations)
SELECT day, op_class, operations FROM op_counts
ON CONFLICT (day, op_class) DO UPDATE SET
    operations = active_user_ops_daily.operations + EXCLUDED.operations;

-- Refresh the get_daily_active_users rollup. Like account_cohort_retention this is the
-- dominant per-batch cost yet feeds a coarse metric, so refresh only when the range
-- crosses a ~1200-block (~1 hour) boundary, and only periods recent enough to still
-- change. The lower bound is derived from the batch's FIRST block (not the last) minus
-- one month of slack, so refresh covers every period this batch touched even if a large
-- catch-up batch spans several months of chain time - the build stays gap-free without
-- assuming a bound on batch size. Older periods are final and keep their last-written
-- values. A fresh replay builds the whole rollup this way as chain time advances; an
-- already-synced node needs a one-time full refresh
-- (SELECT haf_stats_app.refresh_active_users_periods(<genesis day>)).
IF (_last_block / 1200) <> ((_first_block - 1) / 1200) THEN
    SELECT created_at::DATE INTO _block_day FROM hafd.blocks WHERE num = _first_block;
    PERFORM haf_stats_app.refresh_active_users_periods(
        (DATE_TRUNC('month', _block_day) - INTERVAL '1 month')::DATE
    );
END IF;

END;
$$;

RESET ROLE;
