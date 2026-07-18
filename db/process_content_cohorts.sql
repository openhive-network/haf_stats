SET ROLE haf_stats_owner;

-- Feature: content-creator cohort retention (get_network_author_retention).
--
-- Of the accounts that made their FIRST root post (parent_author = '') in a
-- given month, what percentage created content again at the 1-month, 3-month,
-- and 6-month marks. This is a decaying retention curve measured over three
-- contiguous, non-overlapping windows relative to each account's first post day:
--   active_30d  - created content again in days (0, 30]
--   active_90d  - created content again in days (30, 90]
--   active_180d - created content again in days (90, 180]
--
-- "Created content again" means a new post OR comment create, not an edit. The
-- processor reuses haf_stats_backend.network_author_daily, which is maintained by
-- process_content_stats.sql from the canonical comment_registry create-vs-edit
-- classifier (find_comment hit = edit, miss = create). Reusing that table keeps
-- this feature aligned with get_network_content_volume and avoids duplicating the
-- chain's comment_operation classification here.
--
-- The first root post itself is found directly from comment_operation where
-- parent_author = ''. In forward block processing, the first time an account
-- appears with a root post is necessarily the account's first root-post create;
-- an edit would require that (author, permlink) to already exist from an earlier
-- operation.
--
-- Retention windows are day-granular because network_author_daily is day-grain:
-- another create on the same calendar day as the first post is intentionally not
-- counted as retained. The metric is coarse by design. Disclosure is per-member:
-- a cohort member counts toward window N (eligible_at_Nd) only once its own N-day
-- window has fully elapsed (first_post_at + N days <= as_of), so a cohort populates
-- on a partial basis as its members mature rather than blanking until the whole
-- cohort month plus the horizon has elapsed.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.author_cohort_members (
    account_id INT PRIMARY KEY,
    cohort_month DATE NOT NULL,
    first_post_at TIMESTAMP NOT NULL,
    active_30d BOOLEAN NOT NULL DEFAULT FALSE,
    active_90d BOOLEAN NOT NULL DEFAULT FALSE,
    active_180d BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_achm_cohort
ON haf_stats_backend.author_cohort_members (cohort_month);

-- Step 2 drives from members whose 180-day window can still change and that have
-- not already hit all three windows. The partial index keeps that probe bounded.
CREATE INDEX IF NOT EXISTS idx_achm_pending
ON haf_stats_backend.author_cohort_members (first_post_at)
WHERE NOT (active_30d AND active_90d AND active_180d);

GRANT SELECT ON haf_stats_backend.author_cohort_members TO haf_stats_user;

CREATE TABLE IF NOT EXISTS haf_stats_backend.author_cohort_retention (
    cohort_month DATE PRIMARY KEY,
    first_post_accounts INT NOT NULL DEFAULT 0,
    eligible_at_30d INT,
    active_at_30d INT,
    eligible_at_90d INT,
    active_at_90d INT,
    eligible_at_180d INT,
    active_at_180d INT
);

-- Upgrade path for existing deployments: the eligible_at_Nd disclosure columns
-- were added to move author retention onto per-member (first_post_at-based)
-- eligibility; back-fill the schema on tables that predate them.
ALTER TABLE haf_stats_backend.author_cohort_retention ADD COLUMN IF NOT EXISTS eligible_at_30d INT;
ALTER TABLE haf_stats_backend.author_cohort_retention ADD COLUMN IF NOT EXISTS eligible_at_90d INT;
ALTER TABLE haf_stats_backend.author_cohort_retention ADD COLUMN IF NOT EXISTS eligible_at_180d INT;

GRANT SELECT ON haf_stats_backend.author_cohort_retention TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Summary refresh
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.refresh_author_cohort_retention(
    _as_of TIMESTAMP,
    _from_month DATE = NULL,
    _to_month DATE = NULL
)
RETURNS VOID
LANGUAGE sql
AS $$
    INSERT INTO haf_stats_backend.author_cohort_retention
        (cohort_month, first_post_accounts,
         eligible_at_30d,  active_at_30d,
         eligible_at_90d,  active_at_90d,
         eligible_at_180d, active_at_180d)
    SELECT
        cohort_month,
        COUNT(*) AS first_post_accounts,
        -- Per-milestone eligibility: a member counts toward day N only once its
        -- own window has fully elapsed (first_post_at + N days <= _as_of). pct_Nd
        -- = active_at_Nd / eligible_at_Nd, computed by the endpoint. active_at_Nd
        -- is no longer null-gated; a not-yet-matured cohort reports eligible_at_Nd
        -- = 0 and the endpoint's NULLIF turns pct into null.
        --
        -- Eligibility is timestamp-based (first_post_at + N days), matching the
        -- account-funnel model, while the active_Nd flags are day-granular. At a
        -- member's exact maturity instant the flag's calendar-day window may not be
        -- fully observed yet, so active_at_Nd can lag eligible_at_Nd by one member
        -- for at most part of a day, self-correcting on the next refresh. This is
        -- within the metric's day-granular coarseness and does not affect matured
        -- cohorts (the only ones whose values are final).
        COUNT(*) FILTER (WHERE first_post_at + INTERVAL '30 days'  <= _as_of)                AS eligible_at_30d,
        COUNT(*) FILTER (WHERE first_post_at + INTERVAL '30 days'  <= _as_of AND active_30d)  AS active_at_30d,
        COUNT(*) FILTER (WHERE first_post_at + INTERVAL '90 days'  <= _as_of)                AS eligible_at_90d,
        COUNT(*) FILTER (WHERE first_post_at + INTERVAL '90 days'  <= _as_of AND active_90d)  AS active_at_90d,
        COUNT(*) FILTER (WHERE first_post_at + INTERVAL '180 days' <= _as_of)                AS eligible_at_180d,
        COUNT(*) FILTER (WHERE first_post_at + INTERVAL '180 days' <= _as_of AND active_180d) AS active_at_180d
    FROM haf_stats_backend.author_cohort_members
    WHERE (_from_month IS NULL OR cohort_month >= _from_month)
      AND (_to_month IS NULL OR cohort_month <= _to_month)
    GROUP BY cohort_month
    ON CONFLICT (cohort_month) DO UPDATE SET
        first_post_accounts = EXCLUDED.first_post_accounts,
        eligible_at_30d     = EXCLUDED.eligible_at_30d,
        active_at_30d       = EXCLUDED.active_at_30d,
        eligible_at_90d     = EXCLUDED.eligible_at_90d,
        active_at_90d       = EXCLUDED.active_at_90d,
        eligible_at_180d    = EXCLUDED.eligible_at_180d,
        active_at_180d      = EXCLUDED.active_at_180d;
$$;

-- ---------------------------------------------------------------------------
-- Incremental processor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_content_cohorts(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _first_block_time TIMESTAMP;
    _block_time TIMESTAMP;
BEGIN
    SELECT created_at INTO _first_block_time FROM hafd.blocks WHERE num = _first_block;
    SELECT created_at INTO _block_time FROM hafd.blocks WHERE num = _last_block;

    -- Step 1: Register each account's first-ever root post (parent_author = '').
    --
    -- DISTINCT ON keeps the lowest op id per author within the batch; ON CONFLICT
    -- DO NOTHING keeps the earliest across all forward-processed batches. Scan
    -- operations_view by both block_num and the half-open operation-id range so
    -- the planner can use the same HAF id-range pattern as the other processors.
    WITH first_posts AS MATERIALIZED (
        SELECT DISTINCT ON (ov.body_value ->> 'author')
            ov.body_value ->> 'author' AS author,
            b.created_at               AS first_post_at
        FROM hive.operations_view ov
        JOIN hafd.blocks b ON b.num = ov.block_num
        WHERE ov.op_type_id = 1   -- hive::protocol::comment_operation
          AND ov.body_value ->> 'parent_author' = ''
          AND ov.block_num BETWEEN _first_block AND _last_block
          AND ov.id >= hafd.operation_id(_first_block, 0)
          AND ov.id <  hafd.operation_id(_last_block + 1, 0)
        ORDER BY ov.body_value ->> 'author', ov.id
    )
    INSERT INTO haf_stats_backend.author_cohort_members
        (account_id, cohort_month, first_post_at)
    SELECT
        a.id,
        DATE_TRUNC('month', fp.first_post_at)::DATE,
        fp.first_post_at
    FROM first_posts fp
    JOIN hafd.accounts a ON a.name = fp.author
    ON CONFLICT (account_id) DO NOTHING;

    -- Step 2: Set retention flags from the canonical created-content author set.
    --
    -- process_block_range calls process_content_stats immediately before this
    -- processor, so network_author_daily already includes this batch's create
    -- days. Flags are OR-ed in, making the update idempotent and exact across
    -- batches. nad.day > first_post_day excludes the seed day; by design,
    -- same-day second posts/comments do not count as retained.
    UPDATE haf_stats_backend.author_cohort_members acm
    SET
        active_30d  = acm.active_30d  OR ra.hit_30,
        active_90d  = acm.active_90d  OR ra.hit_90,
        active_180d = acm.active_180d OR ra.hit_180
    FROM (
        SELECT
            p.account_id,
            BOOL_OR(
                nad.day > p.first_post_day
                AND nad.day <= p.first_post_day + 30
            ) AS hit_30,
            BOOL_OR(
                nad.day > p.first_post_day + 30
                AND nad.day <= p.first_post_day + 90
            ) AS hit_90,
            BOOL_OR(
                nad.day > p.first_post_day + 90
                AND nad.day <= p.first_post_day + 180
            ) AS hit_180
        FROM (
            SELECT account_id, first_post_at::DATE AS first_post_day
            FROM haf_stats_backend.author_cohort_members
            WHERE NOT (active_30d AND active_90d AND active_180d)
              -- Bound by the batch START, not _block_time (the batch END): a
              -- catch-up / massive batch can span many days, and a member whose
              -- 180-day window reaches into the EARLY days of the batch must stay
              -- in scope. _block_time::DATE - 180 would exclude such members and
              -- drop their flags permanently, because the nad.day join below is
              -- restricted to this batch's span and no later batch re-scans those
              -- create days. _first_block_time::DATE - 180 matches that lower bound.
              AND first_post_at >= (_first_block_time::DATE - 180)
        ) p
        JOIN haf_stats_backend.network_author_daily nad
              ON nad.author_id = p.account_id
             AND nad.day BETWEEN _first_block_time::DATE AND _block_time::DATE
             AND nad.day > p.first_post_day
             AND nad.day <= p.first_post_day + 180
        GROUP BY p.account_id
    ) ra
    WHERE acm.account_id = ra.account_id
      AND (ra.hit_30 OR ra.hit_90 OR ra.hit_180);

    -- Step 3: Recompute cohort retention summary from member flags.
    --
    -- Disclosure is per-member: refresh_author_cohort_retention counts a member
    -- toward window N only once its own N-day window has elapsed (eligible_at_Nd),
    -- so recent cohorts populate on a partial basis as members mature.
    -- Refresh only near hourly block boundaries; retention is a coarse metric and
    -- the affected cohorts are exactly re-aggregated when the refresh fires.
    IF (_last_block / 1200) <> ((_first_block - 1) / 1200) THEN
        PERFORM haf_stats_app.refresh_author_cohort_retention(
            _block_time,
            (
                DATE_TRUNC('month', _block_time - INTERVAL '180 days')
                - INTERVAL '1 month'
            )::DATE
        );
    END IF;
END;
$$;

RESET ROLE;
