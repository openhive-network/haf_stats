SET ROLE haf_stats_owner;

-- Feature: content & engagement stats. One processor, four consumers that share
-- the same comment-op and vote-op scans (so the two highest-volume op streams are
-- read once per batch, not once per feature):
--   * get_account_content_stats    — per-account posts/comments/votes/replies
--                                    (table account_content_daily)
--   * get_network_content_volume   — network-wide created posts/comments + authors
--                                    (tables network_content_daily +
--                                    network_author_daily, state comment_registry)
--   * get_network_vote_stats       — network-wide vote activity
--                                    (tables network_vote_daily + network_voter_daily)
--   * get_network_engagement       — per-post vote/reply counts for engagement quality
--                                    metrics (avg votes/comments per post, zero-
--                                    engagement percentages; table post_engagement)
--
-- Author rewards are NOT stored here: they already live in
-- haf_stats_backend.account_financial_daily (process_financial.sql) and the
-- account endpoint JOINs them in, so there is nothing to re-process.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_content_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    posts INT NOT NULL DEFAULT 0,
    comments INT NOT NULL DEFAULT 0,
    votes_cast INT NOT NULL DEFAULT 0,
    votes_received INT NOT NULL DEFAULT 0,
    replies_received INT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day)
);

-- No secondary index: the primary key (account_id, day) already serves the
-- endpoint's predicate (account_id = X AND day BETWEEN a AND b) and nothing orders
-- these rows by day, so the DESC on the old idx_acd_account_day bought nothing a
-- btree cannot get from a backward scan. Dropped rather than just deleted so
-- deployed nodes reclaim its 4.0 GB on the next install (issue #53); CONCURRENTLY
-- is permitted here for the same reason as idx_acm_created_at in
-- process_account_cohorts.sql. Re-running this finishes an interrupted drop.
DROP INDEX CONCURRENTLY IF EXISTS haf_stats_backend.idx_acd_account_day;

GRANT SELECT ON haf_stats_backend.account_content_daily TO haf_stats_user;

-- Content-volume state & aggregates (get_network_content_volume), populated from
-- the same comment-op scan as the per-account stats below.
--
-- The chain treats comment_operation as CREATE only when no comment with that
-- (author, permlink) exists; otherwise it is an EDIT of the stored comment. And
-- delete_comment_operation erases the comment object, so the same key can be
-- created again later (comment_evaluator / delete_comment_evaluator in hived,
-- libraries/chain/hive_evaluator_social.cpp). Raw op counts therefore overstate
-- created content by every edit (~24% of comment ops in the first 5M blocks are
-- edits). comment_registry mirrors the chain's live-comment set — the minimal
-- state needed to classify each op the way the chain itself does (find_comment
-- hit = edit), including re-creation after delete.

CREATE TABLE IF NOT EXISTS haf_stats_backend.comment_registry (
    author_id INT NOT NULL,
    permlink TEXT NOT NULL,
    PRIMARY KEY (author_id, permlink)
);

GRANT SELECT ON haf_stats_backend.comment_registry TO haf_stats_user;

-- Community dimension for get_account_community_activity (issue #47, backend for
-- block_explorer_ui#761). NULL = not in a community (personal blog, or one of the
-- legacy tag categories that predate communities entirely).
--
-- This has to be materialized per comment because a raw comment_operation names only
-- its IMMEDIATE parent, while a reply belongs to its ROOT post's community — verified
-- on chain: @blocktrades/ticn6q sits at depth 6 with parent_permlink
-- 're-blocktrades-2026717t192753168z', yet carries category hive-139531, the root's
-- community. Every comment therefore stores its resolved community so the next reply
-- down inherits it in one lookup instead of a walk to the root.
--
-- It lives here rather than in a parallel table because this table's ~277 bytes/row
-- (951,749 rows / 264 MB over the first 5M blocks) is almost entirely the (author_id,
-- permlink) key and its index; a second table keyed the same way would pay all of that
-- again, where a column pays only the value bytes.
-- Guarded: no ACCESS EXCLUSIVE lock on a node that already has this column (#96).
SELECT haf_stats_app.apply_schema_migration(
    NOT EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = 'haf_stats_backend.comment_registry'::REGCLASS
            AND a.attname = 'community'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_backend.comment_registry
     ADD COLUMN IF NOT EXISTS community TEXT',
    'comment_registry.community'
);

-- Per-account, per-community created content (get_account_community_activity).
-- Shape mirrors account_custom_json_daily (process_custom_json.sql): additive upsert,
-- exactly-once per block range, same as every other daily counter here.
--
-- Only community-affiliated activity is stored. The endpoint derives the
-- "Personal blog / No community" bucket by subtracting these from
-- account_content_daily, so the buckets reconcile with get_account_content_stats by
-- construction (both count creations off the same `classified` rows) and this table
-- stays empty for all pre-2019 history.
CREATE TABLE IF NOT EXISTS haf_stats_backend.account_community_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    community TEXT NOT NULL,
    posts INT NOT NULL DEFAULT 0,
    comments INT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, community)
);

-- No secondary index: the primary key (account_id, day, community) already leads with the
-- endpoint's predicate (account_id = X AND day BETWEEN a AND b), so an (account_id, day)
-- index would be a redundant prefix that only costs write throughput on the hottest
-- processor path. (account_content_daily carried exactly that redundancy until issue
-- #53 dropped it; it was never a reason to copy it forward.)
GRANT SELECT ON haf_stats_backend.account_community_daily TO haf_stats_user;

-- Drop it where a previous revision of this branch created it.
DROP INDEX IF EXISTS haf_stats_backend.idx_acomd_account_day;

-- Per-post engagement state for get_network_engagement.
-- One row per unique root post (parent_author = ''). post_day is the FIRST
-- creation date: re-creation after a delete is ON CONFLICT DO NOTHING, so the
-- post keeps its original day and PK row. This means total_posts here counts
-- distinct posts dated by first creation, whereas network_content_daily.posts
-- counts every create event by its own day — the two diverge by the number of
-- re-creations (small; ~155 over the first 5M blocks).
-- vote_count and reply_count accumulate across processor batches via bulk UPDATE.
CREATE TABLE IF NOT EXISTS haf_stats_backend.post_engagement (
    author_id INT NOT NULL,
    permlink TEXT NOT NULL,
    post_day DATE NOT NULL,
    vote_count INT NOT NULL DEFAULT 0,
    reply_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (author_id, permlink)
);

-- CONCURRENTLY for the same reason as idx_acm_created_at in
-- process_account_cohorts.sql: install_app.sh loads this file with a plain
-- psql -f (no --single-transaction), so each statement autocommits and
-- CONCURRENTLY is permitted, avoiding an ACCESS EXCLUSIVE lock if the table is
-- already populated on an upgrade. (post_engagement is new, so this is
-- belt-and-suspenders, but keeps the index DDL uniform.)
--
-- Heal an INVALID leftover from an interrupted CONCURRENTLY build first;
-- otherwise CREATE ... IF NOT EXISTS would skip it forever (see the same guard
-- in process_account_cohorts.sql).
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'haf_stats_backend'
          AND c.relname = 'idx_pe_post_day'
          AND NOT i.indisvalid
    ) THEN
        DROP INDEX haf_stats_backend.idx_pe_post_day;
    END IF;
END $$;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_pe_post_day
ON haf_stats_backend.post_engagement (post_day);

GRANT SELECT ON haf_stats_backend.post_engagement TO haf_stats_user;

-- Pre-aggregated endpoint rollup for get_network_engagement. One row per (period_type, period)
-- with five additive metrics; the endpoint reconstructs avg_votes_per_post = sum_votes /
-- total_posts, avg_comments_per_post = sum_replies / total_posts, and the zero-engagement
-- percentages, so a wide range is a single indexed range scan instead of a COUNT/AVG/FILTER over
-- the whole post set. period is DATE_TRUNC(period_type, day); period_type is 'day'|'week'|'month'.
-- Every post belongs to exactly one creation-day, so all five metrics are ADDITIVE across days:
-- the 'week'/'month' rows are just the SUM of their period's 'day' rows (including the
-- zero_vote_posts / zero_comment_posts "created that period with no votes/replies yet" counts,
-- which split per creation-day with no double counting). That is what lets the refresh roll
-- day -> week/month by summing this table's own tiny 'day' slice (~one row per day) rather than
-- re-scanning the millions-of-rows post_engagement per period.
CREATE TABLE IF NOT EXISTS haf_stats_backend.engagement_period_counts (
    period_type TEXT NOT NULL,
    period DATE NOT NULL,
    total_posts BIGINT NOT NULL DEFAULT 0,
    sum_votes BIGINT NOT NULL DEFAULT 0,
    sum_replies BIGINT NOT NULL DEFAULT 0,
    zero_vote_posts BIGINT NOT NULL DEFAULT 0,
    zero_comment_posts BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (period_type, period)
);

GRANT SELECT ON haf_stats_backend.engagement_period_counts TO haf_stats_user;

-- Staging set of post CREATION days whose post_engagement counts changed since the last rollup
-- refresh. Unlike votes/content (keyed by activity day = current block day), a vote or reply
-- landing on an OLD post mutates that post's old creation-day period, which the forward
-- block-window refresh would never revisit. So every post_engagement insert/update records its
-- post_day here (see the processor), and the ~1200-block boundary drains this set: it recomputes
-- the 'day' rollup rows for exactly these (possibly scattered, possibly ancient) days and re-rolls
-- their week/month periods - exact, and bounded by the days actually touched this window, NOT a
-- contiguous genesis..now range. A regular (logged) table so a crash cannot silently drop
-- un-drained days and leave the rollup permanently behind (it is tiny - a few days per hour).
CREATE TABLE IF NOT EXISTS haf_stats_backend.engagement_touched_days (
    day DATE NOT NULL PRIMARY KEY
);

GRANT SELECT ON haf_stats_backend.engagement_touched_days TO haf_stats_user;

-- Daily created-content counters (additive across batches). edits is stored too
-- so the invariant posts + comments + edits = raw comment_operation count stays
-- verifiable per day against hive.operations_view.
CREATE TABLE IF NOT EXISTS haf_stats_backend.network_content_daily (
    day DATE NOT NULL,
    posts INT NOT NULL DEFAULT 0,
    comments INT NOT NULL DEFAULT 0,
    edits INT NOT NULL DEFAULT 0,
    PRIMARY KEY (day)
);

GRANT SELECT ON haf_stats_backend.network_content_daily TO haf_stats_user;

-- One row per (day, author) that created content; unique_authors is NOT additive
-- (an author active in two batches on the same day must count once), so the
-- endpoint COUNT(DISTINCT)s this set at the requested grain — same membership
-- pattern as network_voter_daily below. A dedicated table beats a partial index
-- on account_content_daily (day, account_id) WHERE posts > 0 OR comments > 0:
-- partial-index predicate columns are HOT-blocking, so that index would turn
-- every counter update on the busiest table into a non-HOT update.
CREATE TABLE IF NOT EXISTS haf_stats_backend.network_author_daily (
    day DATE NOT NULL,
    author_id INT NOT NULL,
    PRIMARY KEY (day, author_id)
);

GRANT SELECT ON haf_stats_backend.network_author_daily TO haf_stats_user;

-- Pre-aggregated endpoint rollup for get_network_content_volume. posts/comments are
-- additive across days, but unique_authors is NOT (an author active on several days in a
-- week/month counts once), so the endpoint previously COUNT(DISTINCT author_id)-scanned the
-- whole network_author_daily membership on every request - fine at the 30-day daily default
-- but several seconds on wide week/month ranges (past the Wax 2s client timeout). Mirroring
-- network_vote_period_counts below, we precompute one row per (period_type, period): the
-- additive posts/comments summed and the distinct author count materialised. period is
-- DATE_TRUNC(period_type, day); period_type is 'day' | 'week' | 'month'. PK (period_type,
-- period) makes the endpoint's period-range read a single index range scan.
CREATE TABLE IF NOT EXISTS haf_stats_backend.network_content_period_counts (
    period_type TEXT NOT NULL,
    period DATE NOT NULL,
    posts BIGINT NOT NULL DEFAULT 0,
    comments BIGINT NOT NULL DEFAULT 0,
    unique_authors BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (period_type, period)
);

GRANT SELECT ON haf_stats_backend.network_content_period_counts TO haf_stats_user;

-- Network-wide vote aggregates (get_network_vote_stats), populated from the same
-- vote-op scan as the per-account stats below. Two tables, because the metrics
-- split by how they combine across block-range batches:
--   network_vote_daily   — additive per-day counters (ON CONFLICT ... col = col + ...).
--   network_voter_daily  — one row per (day, voter); unique_voters is NOT additive
--                          (a voter active in two batches on the same day must count
--                          once), so we store the distinct (day, voter) set
--                          idempotently and COUNT(DISTINCT) in the endpoint at the
--                          requested grain. Same membership-table pattern as account
--                          cohorts (process_account_cohorts.sql).

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_vote_daily (
    day DATE NOT NULL,
    upvotes INT NOT NULL DEFAULT 0,
    downvotes INT NOT NULL DEFAULT 0,
    unvotes INT NOT NULL DEFAULT 0,
    self_votes INT NOT NULL DEFAULT 0,
    PRIMARY KEY (day)
);

GRANT SELECT ON haf_stats_backend.network_vote_daily TO haf_stats_user;

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_voter_daily (
    day DATE NOT NULL,
    voter_id INT NOT NULL,
    PRIMARY KEY (day, voter_id)
);

GRANT SELECT ON haf_stats_backend.network_voter_daily TO haf_stats_user;

-- Pre-aggregated endpoint rollup for get_network_vote_stats. unique_voters is
-- non-additive (a voter active on several days in a week/month counts once), so the
-- endpoint cannot sum daily counts and previously COUNT(DISTINCT voter_id)-scanned the
-- whole network_voter_daily membership on every request - fine at 90-day daily grain
-- but several seconds for 52-week / all-time ranges (past the Wax 2s client timeout).
-- Mirroring active_users_period_counts (process_active_users), we precompute one row per
-- (period_type, period): the additive vote counters summed and the distinct voter count
-- materialised. period is DATE_TRUNC(period_type, day); period_type is 'day' | 'week' |
-- 'month'. downvote_pct is derived in the endpoint, not stored. The refresh is exact - a
-- full re-aggregation of affected periods, no approximation. PK (period_type, period)
-- makes the endpoint's period-range read a single index range scan.
CREATE TABLE IF NOT EXISTS haf_stats_backend.network_vote_period_counts (
    period_type TEXT NOT NULL,
    period DATE NOT NULL,
    upvotes BIGINT NOT NULL DEFAULT 0,
    downvotes BIGINT NOT NULL DEFAULT 0,
    unvotes BIGINT NOT NULL DEFAULT 0,
    self_votes BIGINT NOT NULL DEFAULT 0,
    unique_voters BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (period_type, period)
);

GRANT SELECT ON haf_stats_backend.network_vote_period_counts TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Community resolution (issue #47) — shared by BOTH comment-scan paths
--
-- The hard part is not the pattern match, it is that the whole batch is written by a
-- single statement whose data-modifying CTEs all see the pre-statement snapshot (see
-- the comment on insert_posts below). A reply looking its parent up in comment_registry
-- therefore MISSES every parent created in the same batch — and with 1,000,000-block
-- rebuild batches (rebuild_content_volume.sh) a post and its whole reply tree normally
-- land together, so that is the common case, not an edge case.
--
-- So the comment scan stages this batch's created comments into a per-transaction temp
-- table, and a SECOND statement resolves communities over stage + registry with a
-- recursive walk that follows in-batch parent chains to any depth. Staging off
-- `classified` rather than re-scanning the op stream is what keeps this to zero extra
-- scans AND reuses the create-vs-edit decision instead of re-deriving it — re-deriving
-- it independently is exactly how issues #13/#42/#45 happened.
--
-- The stage holds ONE ROW PER CREATION EVENT, keyed by the operation id. Any coarser
-- grain silently merges creations that belong in different buckets, and every such
-- merge was a real bug:
--   * a key created as a ROOT, deleted, and re-created as a REPLY on the same day —
--     this exists on mainnet (testing001/'testing6', blocks 4010780 / 4011017 / 4011023,
--     all 2016-08-12) — was counted twice as a reply and never as a post, so the
--     endpoint's buckets stopped summing to get_account_content_stats;
--   * a key created outside a community and re-created inside one (or vice versa) on the
--     same day had BOTH creations credited to the community.
-- Per-event staging also lets inheritance be resolved at the child's own point in time
-- rather than against the parent's end-of-batch state.
--
-- Temp + ON COMMIT DROP is the same per-batch scratch pattern as
-- haf_stats_batch_authored_ops (process_block_range.sql): no WAL, no bloat, and the
-- rebuild script's one-transaction-per-batch loop cleans up after itself.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.prepare_community_batch_stage;
CREATE OR REPLACE FUNCTION haf_stats_app.prepare_community_batch_stage()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- Probe first rather than leaning on IF NOT EXISTS: the tables survive for the life of
    -- the transaction, so a multi-batch rebuild loop would otherwise emit one "already
    -- exists, skipping" NOTICE per batch. Same guard shape as prepare_batch_authored_ops.
    IF TO_REGCLASS('pg_temp.haf_stats_community_batch_stage') IS NOT NULL THEN
        TRUNCATE haf_stats_community_batch_stage;
        TRUNCATE haf_stats_community_batch_removed;
        RETURN;
    END IF;

    CREATE TEMP TABLE haf_stats_community_batch_stage (
        -- The creation's operation id. One row per CREATION EVENT, never per key or per
        -- day: see the header above for the merges this prevents. It also orders events,
        -- which is what makes point-in-time inheritance possible.
        id BIGINT PRIMARY KEY,
        author_id INT NOT NULL,
        permlink TEXT NOT NULL,
        -- NULL for a root post; otherwise the parent comment's key.
        parent_author_id INT,
        parent_permlink TEXT,
        is_root BOOLEAN NOT NULL,
        day DATE NOT NULL,
        -- The community this creation addressed DIRECTLY: set only for a root post whose
        -- category is a registered community. Replies inherit instead.
        own_community TEXT
    ) ON COMMIT DROP;

    -- Both walk directions are index lookups; without these the resolver re-scans the
    -- whole stage once per recursion level.
    CREATE INDEX ON haf_stats_community_batch_stage (author_id, permlink, id);
    CREATE INDEX ON haf_stats_community_batch_stage (parent_author_id, parent_permlink, id);

    -- Communities of comments this batch DELETED, captured before the row disappears.
    -- A reply created earlier in the same batch than its parent's deletion still belongs
    -- to that parent's community, but by the time the resolver runs the registry row is
    -- already gone.
    CREATE TEMP TABLE haf_stats_community_batch_removed (
        author_id INT NOT NULL,
        permlink TEXT NOT NULL,
        community TEXT,
        PRIMARY KEY (author_id, permlink)
    ) ON COMMIT DROP;
END;
$$;

-- Resolve every staged creation's community, then write both outputs. Runs as its own
-- statement AFTER the comment scan, so this batch's rows are already in comment_registry
-- (with community still NULL) — which is why the earlier-batch base case below must
-- exclude parents that have a staged creation of their own, or an in-batch parent would
-- resolve to its own not-yet-computed NULL.
DROP FUNCTION IF EXISTS haf_stats_app.resolve_community_batch;
CREATE OR REPLACE FUNCTION haf_stats_app.resolve_community_batch()
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
BEGIN

WITH RECURSIVE resolved AS (
    -- Base 1: root creations. own_community is already the answer (NULL when the category
    -- is not a registered community).
    SELECT s.id, s.author_id, s.permlink, s.own_community AS community
    FROM haf_stats_community_batch_stage s
    WHERE s.is_root
    UNION ALL
    -- Base 2: replies with no staged creation of their parent BEFORE them, so the parent
    -- dates from an earlier batch: take its stored community, or the value captured just
    -- before this batch deleted it.
    SELECT s.id, s.author_id, s.permlink, COALESCE(r.community, rm.community)
    FROM haf_stats_community_batch_stage s
    LEFT JOIN haf_stats_backend.comment_registry r
        ON r.author_id = s.parent_author_id AND r.permlink = s.parent_permlink
    LEFT JOIN haf_stats_community_batch_removed rm
        ON rm.author_id = s.parent_author_id AND rm.permlink = s.parent_permlink
    WHERE NOT s.is_root
      AND NOT EXISTS (
          SELECT 1
          FROM haf_stats_community_batch_stage p
          WHERE p.author_id = s.parent_author_id
            AND p.permlink = s.parent_permlink
            AND p.id < s.id
      )
    UNION ALL
    -- Recursive: replies inherit from the parent creation that was LIVE when the reply was
    -- made - the parent's latest staged creation before this reply, not its end-of-batch
    -- state. A parent deleted and re-created into another community mid-batch therefore
    -- does not retroactively move the replies that were made under the earlier one.
    -- Terminates: every step strictly increases id and the parent relation is a forest.
    SELECT s.id, s.author_id, s.permlink, res.community
    FROM resolved res
    JOIN haf_stats_community_batch_stage s
        ON s.parent_author_id = res.author_id
       AND s.parent_permlink = res.permlink
       AND s.id > res.id
    WHERE NOT s.is_root
      AND NOT EXISTS (
          SELECT 1
          FROM haf_stats_community_batch_stage p
          WHERE p.author_id = s.parent_author_id
            AND p.permlink = s.parent_permlink
            AND p.id < s.id
            AND p.id > res.id
      )
),
-- The key's state after this batch is its LAST creation's community. Written even when
-- NULL: a comment re-created outside any community must CLEAR the stored value, or the
-- whole reply subtree beneath it keeps inheriting a community it no longer belongs to.
final_state AS (
    SELECT DISTINCT ON (author_id, permlink) author_id, permlink, community
    FROM resolved
    ORDER BY author_id, permlink, id DESC
),
mark_registry AS (
    UPDATE haf_stats_backend.comment_registry r
    SET community = f.community
    FROM final_state f
    WHERE r.author_id = f.author_id
      AND r.permlink = f.permlink
      AND r.community IS DISTINCT FROM f.community
)
-- Every creation is bucketed by the community IT went to: for a root that is its own
-- category, for a reply the community it inherited at that moment. COUNT(*) FILTER is 0
-- (never NULL) for an empty filter, unlike SUM.
INSERT INTO haf_stats_backend.account_community_daily AS acd
    (account_id, day, community, posts, comments)
SELECT
    s.author_id,
    s.day,
    res.community,
    COUNT(*) FILTER (WHERE s.is_root)::INT,
    COUNT(*) FILTER (WHERE NOT s.is_root)::INT
FROM resolved res
JOIN haf_stats_community_batch_stage s ON s.id = res.id
WHERE res.community IS NOT NULL
GROUP BY s.author_id, s.day, res.community
ON CONFLICT (account_id, day, community) DO UPDATE SET
    posts    = acd.posts    + EXCLUDED.posts,
    comments = acd.comments + EXCLUDED.comments;

END;
$$;

-- ---------------------------------------------------------------------------
-- Rollup refresh (feeds get_network_vote_stats)
--
-- Recomputes network_vote_period_counts for every day/week/month period touched
-- by [_lo, _hi], exactly (re-aggregates network_vote_daily counters +
-- network_voter_daily voter set). Passing NULL _hi keeps the old full-refresh
-- behavior from _lo forward for one-time repairs on already-synced nodes. Daily
-- unique_voters needs no DISTINCT (the (day, voter) PK already gives one row per
-- voter per day, so COUNT(*)); week/month need COUNT(DISTINCT voter_id). Counters
-- come from the additive table, voters from the membership table, FULL JOIN per
-- period so a period present in only one table is still written.
-- ---------------------------------------------------------------------------

-- A previous app version defined this as a 1-argument function. An in-place upgrade runs
-- CREATE OR REPLACE for the 2-arg form below but leaves that legacy 1-arg overload in
-- place, and a 1-arg call would then be ambiguous between them ("function ... is not
-- unique"). Drop the legacy signature so only the single 2-arg form (with a defaulted
-- _hi) remains; 1-arg callers (install_app.sh full refresh) resolve to it unambiguously.
DROP FUNCTION IF EXISTS haf_stats_app.refresh_network_vote_periods(DATE);

CREATE OR REPLACE FUNCTION haf_stats_app.refresh_network_vote_periods(
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
    -- day: distinct-per-day unique_voters == row count of the (day, voter) PK
    INSERT INTO haf_stats_backend.network_vote_period_counts
        (period_type, period, upvotes, downvotes, unvotes, self_votes, unique_voters)
    SELECT 'day', COALESCE(c.period, v.period),
           COALESCE(c.upvotes, 0), COALESCE(c.downvotes, 0), COALESCE(c.unvotes, 0),
           COALESCE(c.self_votes, 0), COALESCE(v.voters, 0)
    FROM (
        SELECT day AS period, upvotes, downvotes, unvotes, self_votes
        FROM haf_stats_backend.network_vote_daily
        WHERE day >= _lo
          AND (_hi IS NULL OR day <= _hi)
    ) c
    FULL JOIN (
        SELECT day AS period, COUNT(*) AS voters
        FROM haf_stats_backend.network_voter_daily
        WHERE day >= _lo
          AND (_hi IS NULL OR day <= _hi)
        GROUP BY day
    ) v ON v.period = c.period
    ON CONFLICT (period_type, period) DO UPDATE SET
        upvotes = EXCLUDED.upvotes, downvotes = EXCLUDED.downvotes,
        unvotes = EXCLUDED.unvotes, self_votes = EXCLUDED.self_votes,
        unique_voters = EXCLUDED.unique_voters;

    -- week
    INSERT INTO haf_stats_backend.network_vote_period_counts
        (period_type, period, upvotes, downvotes, unvotes, self_votes, unique_voters)
    SELECT 'week', COALESCE(c.period, v.period),
           COALESCE(c.upvotes, 0), COALESCE(c.downvotes, 0), COALESCE(c.unvotes, 0),
           COALESCE(c.self_votes, 0), COALESCE(v.voters, 0)
    FROM (
        SELECT DATE_TRUNC('week', day)::DATE AS period,
               SUM(upvotes) AS upvotes, SUM(downvotes) AS downvotes,
               SUM(unvotes) AS unvotes, SUM(self_votes) AS self_votes
        FROM haf_stats_backend.network_vote_daily
        WHERE day >= _week_lo
          AND (_week_hi IS NULL OR day < _week_hi)
        GROUP BY 1
    ) c
    FULL JOIN (
        SELECT DATE_TRUNC('week', day)::DATE AS period, COUNT(DISTINCT voter_id) AS voters
        FROM haf_stats_backend.network_voter_daily
        WHERE day >= _week_lo
          AND (_week_hi IS NULL OR day < _week_hi)
        GROUP BY 1
    ) v ON v.period = c.period
    ON CONFLICT (period_type, period) DO UPDATE SET
        upvotes = EXCLUDED.upvotes, downvotes = EXCLUDED.downvotes,
        unvotes = EXCLUDED.unvotes, self_votes = EXCLUDED.self_votes,
        unique_voters = EXCLUDED.unique_voters;

    -- month
    INSERT INTO haf_stats_backend.network_vote_period_counts
        (period_type, period, upvotes, downvotes, unvotes, self_votes, unique_voters)
    SELECT 'month', COALESCE(c.period, v.period),
           COALESCE(c.upvotes, 0), COALESCE(c.downvotes, 0), COALESCE(c.unvotes, 0),
           COALESCE(c.self_votes, 0), COALESCE(v.voters, 0)
    FROM (
        SELECT DATE_TRUNC('month', day)::DATE AS period,
               SUM(upvotes) AS upvotes, SUM(downvotes) AS downvotes,
               SUM(unvotes) AS unvotes, SUM(self_votes) AS self_votes
        FROM haf_stats_backend.network_vote_daily
        WHERE day >= _month_lo
          AND (_month_hi IS NULL OR day < _month_hi)
        GROUP BY 1
    ) c
    FULL JOIN (
        SELECT DATE_TRUNC('month', day)::DATE AS period, COUNT(DISTINCT voter_id) AS voters
        FROM haf_stats_backend.network_voter_daily
        WHERE day >= _month_lo
          AND (_month_hi IS NULL OR day < _month_hi)
        GROUP BY 1
    ) v ON v.period = c.period
    ON CONFLICT (period_type, period) DO UPDATE SET
        upvotes = EXCLUDED.upvotes, downvotes = EXCLUDED.downvotes,
        unvotes = EXCLUDED.unvotes, self_votes = EXCLUDED.self_votes,
        unique_voters = EXCLUDED.unique_voters;
END;
$$;

-- ---------------------------------------------------------------------------
-- Rollup refresh (feeds get_network_content_volume)
--
-- Recomputes network_content_period_counts for every day/week/month period touched by
-- [_lo, _hi], exactly (re-aggregates network_content_daily counters + network_author_daily
-- author set). Direct sibling of refresh_network_vote_periods above: posts/comments come
-- from the additive counter table, unique_authors from the (day, author) membership. Daily
-- unique_authors needs no DISTINCT (the (day, author) PK gives one row per author per day,
-- so COUNT(*)); week/month need COUNT(DISTINCT author_id). FULL JOIN per period so a period
-- present in only one table is still written. Passing NULL _hi keeps the full-refresh-from-
-- _lo behaviour for one-time backfills on already-synced nodes.
-- ---------------------------------------------------------------------------

-- Drop the legacy 1-arg signature (see refresh_network_vote_periods) so a 1-arg call
-- resolves unambiguously to the 2-arg form below.
DROP FUNCTION IF EXISTS haf_stats_app.refresh_network_content_periods(DATE);

CREATE OR REPLACE FUNCTION haf_stats_app.refresh_network_content_periods(
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
    -- day: distinct-per-day unique_authors == row count of the (day, author) PK
    INSERT INTO haf_stats_backend.network_content_period_counts
        (period_type, period, posts, comments, unique_authors)
    SELECT 'day', COALESCE(c.period, a.period),
           COALESCE(c.posts, 0), COALESCE(c.comments, 0), COALESCE(a.authors, 0)
    FROM (
        SELECT day AS period, posts, comments
        FROM haf_stats_backend.network_content_daily
        WHERE day >= _lo
          AND (_hi IS NULL OR day <= _hi)
    ) c
    FULL JOIN (
        SELECT day AS period, COUNT(*) AS authors
        FROM haf_stats_backend.network_author_daily
        WHERE day >= _lo
          AND (_hi IS NULL OR day <= _hi)
        GROUP BY day
    ) a ON a.period = c.period
    ON CONFLICT (period_type, period) DO UPDATE SET
        posts = EXCLUDED.posts, comments = EXCLUDED.comments,
        unique_authors = EXCLUDED.unique_authors;

    -- week
    INSERT INTO haf_stats_backend.network_content_period_counts
        (period_type, period, posts, comments, unique_authors)
    SELECT 'week', COALESCE(c.period, a.period),
           COALESCE(c.posts, 0), COALESCE(c.comments, 0), COALESCE(a.authors, 0)
    FROM (
        SELECT DATE_TRUNC('week', day)::DATE AS period,
               SUM(posts) AS posts, SUM(comments) AS comments
        FROM haf_stats_backend.network_content_daily
        WHERE day >= _week_lo
          AND (_week_hi IS NULL OR day < _week_hi)
        GROUP BY 1
    ) c
    FULL JOIN (
        SELECT DATE_TRUNC('week', day)::DATE AS period, COUNT(DISTINCT author_id) AS authors
        FROM haf_stats_backend.network_author_daily
        WHERE day >= _week_lo
          AND (_week_hi IS NULL OR day < _week_hi)
        GROUP BY 1
    ) a ON a.period = c.period
    ON CONFLICT (period_type, period) DO UPDATE SET
        posts = EXCLUDED.posts, comments = EXCLUDED.comments,
        unique_authors = EXCLUDED.unique_authors;

    -- month
    INSERT INTO haf_stats_backend.network_content_period_counts
        (period_type, period, posts, comments, unique_authors)
    SELECT 'month', COALESCE(c.period, a.period),
           COALESCE(c.posts, 0), COALESCE(c.comments, 0), COALESCE(a.authors, 0)
    FROM (
        SELECT DATE_TRUNC('month', day)::DATE AS period,
               SUM(posts) AS posts, SUM(comments) AS comments
        FROM haf_stats_backend.network_content_daily
        WHERE day >= _month_lo
          AND (_month_hi IS NULL OR day < _month_hi)
        GROUP BY 1
    ) c
    FULL JOIN (
        SELECT DATE_TRUNC('month', day)::DATE AS period, COUNT(DISTINCT author_id) AS authors
        FROM haf_stats_backend.network_author_daily
        WHERE day >= _month_lo
          AND (_month_hi IS NULL OR day < _month_hi)
        GROUP BY 1
    ) a ON a.period = c.period
    ON CONFLICT (period_type, period) DO UPDATE SET
        posts = EXCLUDED.posts, comments = EXCLUDED.comments,
        unique_authors = EXCLUDED.unique_authors;
END;
$$;

-- ---------------------------------------------------------------------------
-- Rollup refresh (feeds get_network_engagement)
--
-- Two entry points that maintain engagement_period_counts directly from post_engagement:
--   refresh_engagement_full()     — rebuild everything. Install-time backfill on an already-synced
--                                   node + manual repairs. Clears the rollup, stages every
--                                   creation-day, and delegates to refresh_engagement_touched (so the
--                                   roll-up logic lives once). Costs two post_engagement scans (one
--                                   to stage the distinct days, one in touched to recompute them) vs
--                                   the endpoint/hot path's zero - acceptable for a one-time backfill.
--   refresh_engagement_touched()  — forward path, called on the ~1200-block boundary: recompute the
--                                   'day' rows for the creation-days staged in
--                                   engagement_touched_days, re-roll their week/month periods from
--                                   those 'day' rows, then drain the staging set.
-- Both roll week/month by summing the rollup's own 'day' slice (~one row per day) rather than
-- re-scanning the millions-of-rows post_engagement per period.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.refresh_engagement_full;
CREATE OR REPLACE FUNCTION haf_stats_app.refresh_engagement_full()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- Rebuild from scratch: clear the rollup, stage every creation-day, then let the touched path
    -- (which computes the 'day' rows from post_engagement and rolls week/month from them) fill it
    -- all. Keeps the day/week/month roll-up SQL in one place (refresh_engagement_touched).
    TRUNCATE haf_stats_backend.engagement_period_counts;

    INSERT INTO haf_stats_backend.engagement_touched_days (day)
    SELECT DISTINCT post_day FROM haf_stats_backend.post_engagement
    ON CONFLICT (day) DO NOTHING;

    PERFORM haf_stats_app.refresh_engagement_touched();
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.refresh_engagement_touched;
CREATE OR REPLACE FUNCTION haf_stats_app.refresh_engagement_touched()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- Nothing mutated since the last refresh -> nothing to do (cheap common case for a LIVE
    -- batch on the boundary that produced no comments/votes).
    IF NOT EXISTS (SELECT 1 FROM haf_stats_backend.engagement_touched_days) THEN
        RETURN;
    END IF;

    -- 1. Recompute the 'day' rollup rows for exactly the touched creation-days (each an
    -- idx_pe_post_day range). A day is only staged when a post with that post_day was inserted or
    -- had its vote/reply count changed, and post_engagement rows are never deleted, so every touched
    -- day still has >= 1 post - a 'day' row can only need upsert, never removal.
    INSERT INTO haf_stats_backend.engagement_period_counts
        (period_type, period, total_posts, sum_votes, sum_replies, zero_vote_posts, zero_comment_posts)
    SELECT 'day', pe.post_day,
           COUNT(*),
           SUM(pe.vote_count),
           SUM(pe.reply_count),
           COUNT(*) FILTER (WHERE pe.vote_count = 0),
           COUNT(*) FILTER (WHERE pe.reply_count = 0)
    FROM haf_stats_backend.post_engagement pe
    WHERE pe.post_day IN (SELECT day FROM haf_stats_backend.engagement_touched_days)
    GROUP BY pe.post_day
    ON CONFLICT (period_type, period) DO UPDATE SET
        total_posts = EXCLUDED.total_posts, sum_votes = EXCLUDED.sum_votes,
        sum_replies = EXCLUDED.sum_replies, zero_vote_posts = EXCLUDED.zero_vote_posts,
        zero_comment_posts = EXCLUDED.zero_comment_posts;

    -- 2. Re-roll every week/month a touched day falls in by summing the rollup's own 'day' rows for
    -- that period - ALL of the period's days, not just the touched ones, so the totals stay exact
    -- even when only some of the period's days changed this window. The 'day' rows read here include
    -- the ones just upserted in step 1 (a later statement in the same function sees them); reading
    -- and writing engagement_period_counts in one statement is safe because the SELECT filters
    -- period_type = 'day' while the INSERT only writes 'week'/'month' rows.
    INSERT INTO haf_stats_backend.engagement_period_counts
        (period_type, period, total_posts, sum_votes, sum_replies, zero_vote_posts, zero_comment_posts)
    SELECT 'week', DATE_TRUNC('week', d.period)::DATE,
           SUM(d.total_posts), SUM(d.sum_votes), SUM(d.sum_replies),
           SUM(d.zero_vote_posts), SUM(d.zero_comment_posts)
    FROM haf_stats_backend.engagement_period_counts d
    WHERE d.period_type = 'day'
      AND DATE_TRUNC('week', d.period)::DATE IN (
          SELECT DISTINCT DATE_TRUNC('week', day)::DATE FROM haf_stats_backend.engagement_touched_days)
    GROUP BY 2   -- col 1 is the literal 'week'; group by the truncated date (col 2)
    ON CONFLICT (period_type, period) DO UPDATE SET
        total_posts = EXCLUDED.total_posts, sum_votes = EXCLUDED.sum_votes,
        sum_replies = EXCLUDED.sum_replies, zero_vote_posts = EXCLUDED.zero_vote_posts,
        zero_comment_posts = EXCLUDED.zero_comment_posts;

    INSERT INTO haf_stats_backend.engagement_period_counts
        (period_type, period, total_posts, sum_votes, sum_replies, zero_vote_posts, zero_comment_posts)
    SELECT 'month', DATE_TRUNC('month', d.period)::DATE,
           SUM(d.total_posts), SUM(d.sum_votes), SUM(d.sum_replies),
           SUM(d.zero_vote_posts), SUM(d.zero_comment_posts)
    FROM haf_stats_backend.engagement_period_counts d
    WHERE d.period_type = 'day'
      AND DATE_TRUNC('month', d.period)::DATE IN (
          SELECT DISTINCT DATE_TRUNC('month', day)::DATE FROM haf_stats_backend.engagement_touched_days)
    GROUP BY 2   -- col 1 is the literal 'month'; group by the truncated date (col 2)
    ON CONFLICT (period_type, period) DO UPDATE SET
        total_posts = EXCLUDED.total_posts, sum_votes = EXCLUDED.sum_votes,
        sum_replies = EXCLUDED.sum_replies, zero_vote_posts = EXCLUDED.zero_vote_posts,
        zero_comment_posts = EXCLUDED.zero_comment_posts;

    DELETE FROM haf_stats_backend.engagement_touched_days;
END;
$$;

-- ---------------------------------------------------------------------------
-- Processor
--
-- Optimisation notes (patterns borrowed from haf_block_explorer / balance_tracker
-- HAF processors, which run over the same high-volume operation stream):
--
--  * One statement, each table written once. The comment and vote ops come from the
--    batch's staged rows (prepare_batch_ops, db/process_block_range.sql), each read ONCE
--    into a MATERIALIZED CTE that fans out to every consumer (PG would otherwise inline
--    the CTE and re-read per consumer). The comment ops feed the comment_registry state,
--    the network_content_daily counters, the network_author_daily author set,
--    account_content_daily (the author's posts/comments AND the parent author's
--    replies_received) and post_engagement (per-root-post reply counts); the vote ops
--    feed account_content_daily (votes_cast/received), the network_vote_daily counters,
--    the network_voter_daily voter set and post_engagement (per-post vote counts). The
--    two feeds of account_content_daily are one upsert, and those of post_engagement one
--    INSERT (new posts) plus one UPDATE (existing posts). delete_comment/ineffective_delete
--    ops are read too, but their volume is negligible.
--
--  * Count CREATES, not ops. comment_operation doubles as the edit op: the chain
--    decides create-vs-edit by whether (author, permlink) already exists, and an
--    account's post_count increments only in the create path
--    (comment_evaluator::do_apply). The processor replays exactly that decision
--    via comment_registry — including delete -> re-create (a new comment, counts
--    again) and ineffective deletes (the chain keeps a comment whose delete
--    emitted ineffective_delete_comment_operation; that vop is applied inside the
--    failed delete, so it pairs with the immediately preceding delete op by id).
--    posts / comments / replies_received / unique authors all count actual
--    creations; edits land only in network_content_daily.edits.
--
--  * prepare_batch_ops bounds its read by operation id: hafd.operation_id(b, 0) is the
--    first op id in block b, so the half-open id range [op_id(first,0), op_id(last+1,0))
--    is exactly this block range and range-scans the operations primary key — the
--    canonical haf_block_explorer idiom (process_account_stats.sql,
--    process_block_operations.sql). hive.account_operations_view is no alternative: it is
--    keyed by account_id, so a block-range scan there is a full seq scan — see
--    process_account_cohorts (#21) — and the roles (voter vs author, author vs
--    parent_author) are only in the op body anyway.
--
--  * Resolve hafd.accounts AFTER pre-aggregation. We GROUP BY account name + day
--    inside the CTE first, then join hafd.accounts on the (much smaller) aggregated
--    set, instead of probing accounts once per raw operation.
--
--  * GROUP BY collapses duplicates within a batch so the ON CONFLICT DO UPDATE never
--    targets the same (account_id, day) row twice within one statement.
--
--  * Use body_value (the op 'value' object) directly rather than body -> 'value'.
--
--  * jit = OFF: these are short, index-driven per-batch statements where JIT
--    compilation is pure overhead.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.process_content_stats;
CREATE OR REPLACE FUNCTION haf_stats_app.process_content_stats(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _first_day DATE;
    _last_day DATE;
    _refresh_lo_block INT;
    _high_water INT;
    _timed BOOLEAN;
    _t TIMESTAMPTZ;
BEGIN

-- Recurrence guard for issue #42. Every counter below accumulates additively
-- (network_content_daily, account_content_daily, network_vote_daily), so replaying
-- an already-counted block range silently doubles it — that is exactly how #42
-- happened. The haf_stats HAF context is NON-FORKING (hive.app_context_set_non_forking,
-- haf_stats_app.sql), so blocks are delivered strictly forward and never re-delivered
-- by a reorg: the block path is the only caller (process_block_range <- main, or <- process_blocks under the HAF driver) and always
-- passes _first_block = last_processed_block + 1. Any range overlapping the high-water
-- mark is therefore an out-of-band reprocess, and reprocessing is never what the caller
-- wants here. Refuse it instead of silently double-counting.
SELECT COALESCE(MAX(last_processed_block), 0) INTO _high_water
FROM haf_stats_app.app_status;

IF _first_block <= _high_water THEN
    RAISE EXCEPTION 'process_content_stats: refusing to reprocess blocks %..% (already counted through %). Its counters are additive, so this would double-count them (issue #42).',
        _first_block, _last_block, _high_water
        USING HINT = 'To repair content volume, run scripts/rebuild_content_volume.sh (it TRUNCATEs and replays cleanly). To re-replay from scratch, reset haf_stats_app.app_status.last_processed_block to 0 first.';
END IF;

PERFORM haf_stats_app.prepare_community_batch_stage();
PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[0, 1, 17, 73]);

-- Comment and vote ops: ONE statement over the batch's staged ops, each table written once.
--   comment_registry      — live-comment set, the create-vs-edit decision state
--   network_content_daily — daily created posts/comments + edits counters
--   network_author_daily  — distinct (day, author) set for exact unique authors
--   account_content_daily — author's posts/comments + parent's replies_received, and the
--                           voter's votes_cast + author's votes_received
--   post_engagement       — per-post reply and vote counts (insert new root posts seeded with
--                           this batch's counts + update the posts that already existed)
--   network_vote_daily    — daily up/down/un/self counters
--   network_voter_daily   — distinct (day, voter) set for exact unique voters
--   community stage       — this batch's created comments, for resolve_community_batch()
WITH comment_ops AS MATERIALIZED (
    SELECT
        ov.op_id                            AS id,
        ov.body_value ->> 'author'          AS author,
        ov.body_value ->> 'permlink'        AS permlink,
        ov.body_value ->> 'parent_author'   AS parent_author,
        ov.body_value ->> 'parent_permlink' AS parent_permlink,
        ov.day,
        ov.block_num
    FROM haf_stats_batch_ops ov
    WHERE ov.op_type_id = 1   -- hive::protocol::comment_operation
),
-- delete_comment ops (17) interleaved with ineffective_delete_comment vops (73).
-- The vop is emitted while the failed delete applies, so its id is the very next
-- event for that comment; a delete immediately followed by its vop did nothing.
delete_events AS (
    SELECT
        ov.body_value ->> 'author'   AS author,
        ov.body_value ->> 'permlink' AS permlink,
        ov.op_id                     AS id,
        ov.op_type_id = 73           AS is_vop
    FROM haf_stats_batch_ops ov
    WHERE ov.op_type_id IN (17, 73)
),
effective_deletes AS (
    SELECT author, permlink, id
    FROM (
        SELECT
            author,
            permlink,
            id,
            is_vop,
            LEAD(is_vop) OVER (PARTITION BY author, permlink ORDER BY id) AS next_is_vop
        FROM delete_events
    ) d
    WHERE NOT is_vop AND next_is_vop IS DISTINCT FROM TRUE
),
-- Interleave comment + effective-delete events per comment in op order: after a
-- comment op the comment exists (created or edited), after an effective delete
-- it does not. So a comment op is a CREATE iff the previous event is a delete —
-- or it has no previous event in the batch and no registry row from earlier ones.
seq AS (
    SELECT
        id,
        author,
        permlink,
        parent_author,
        parent_permlink,
        day,
        block_num,
        is_comment,
        LAG(is_comment) OVER w  AS prev_is_comment,
        LEAD(id) OVER w IS NULL AS is_last
    FROM (
        SELECT id, author, permlink, parent_author, parent_permlink, day, block_num, TRUE AS is_comment
        FROM comment_ops
        UNION ALL
        SELECT id, author, permlink, NULL, NULL, NULL, NULL, FALSE
        FROM effective_deletes
    ) e
    WINDOW w AS (PARTITION BY author, permlink ORDER BY id)
),
-- One accounts resolution + registry probe per distinct comment, not per op.
comment_keys AS (
    SELECT
        k.author,
        k.permlink,
        a.id AS author_id,
        r.author_id IS NOT NULL AS pre_exists
    FROM (SELECT DISTINCT author, permlink FROM seq) k
    JOIN hafd.accounts a ON a.name = k.author
    LEFT JOIN haf_stats_backend.comment_registry r
        ON r.author_id = a.id AND r.permlink = k.permlink
),
classified AS (
    SELECT
        s.id,
        s.parent_author,
        s.parent_permlink,
        s.day,
        s.block_num,
        s.is_comment,
        s.is_last,
        k.author_id,
        k.permlink,
        s.is_comment AND COALESCE(NOT s.prev_is_comment, NOT k.pre_exists) AS is_create
    FROM seq s
    JOIN comment_keys k ON k.author = s.author AND k.permlink = s.permlink
),
-- Stage this batch's comment CREATIONS for resolve_community_batch() (issue #47) — one
-- row per creation event, keyed by op id. Any coarser grain merges creations that belong
-- in different buckets (root vs reply, community vs personal blog) and silently breaks
-- the endpoint's sum-to-get_account_content_stats invariant; see the header on
-- prepare_community_batch_stage.
-- The block_num floor makes the whole community feature free for pre-2019 ranges: no
-- community can exist before hivemind's start block, so nothing is staged at all.
community_stage AS (
    INSERT INTO haf_stats_community_batch_stage
        (id, author_id, permlink, parent_author_id, parent_permlink,
         is_root, day, own_community)
    SELECT
        c.id,
        c.author_id,
        c.permlink,
        pa.id,
        c.parent_permlink,
        c.parent_author = '',
        c.day,
        -- A root post's category is its community only if that community was already
        -- registered at this block: a category can look like a community name years
        -- before (or without) the account ever existing.
        CASE
            WHEN c.parent_author = ''
             AND EXISTS (
                 SELECT 1
                 FROM haf_stats_backend.community_registry cr
                 WHERE cr.community = c.parent_permlink
                   AND cr.created_block <= c.block_num
             )
                THEN c.parent_permlink
        END
    FROM classified c
    LEFT JOIN hafd.accounts pa ON pa.name = c.parent_author
    WHERE c.is_create
      AND c.block_num >= haf_stats_app.community_start_block()
),
-- End-of-batch registry state: a comment is present iff its last event is a
-- comment op. The add/remove key sets are disjoint (is_last is unique per key),
-- so the two data-modifying CTEs cannot touch the same row.
registry_add AS (
    INSERT INTO haf_stats_backend.comment_registry (author_id, permlink)
    SELECT author_id, permlink
    FROM classified
    WHERE is_last AND is_comment
    ON CONFLICT (author_id, permlink) DO NOTHING
),
registry_remove AS (
    DELETE FROM haf_stats_backend.comment_registry r
    USING classified c
    WHERE c.is_last AND NOT c.is_comment
      AND r.author_id = c.author_id AND r.permlink = c.permlink
    RETURNING r.author_id, r.permlink, r.community
),
-- Keep the deleted comments' communities for resolve_community_batch: a reply made
-- earlier in this same batch still inherits from the parent that is being removed here,
-- but the registry row it would have read is gone by the time the resolver runs.
stage_removed_communities AS (
    INSERT INTO haf_stats_community_batch_removed (author_id, permlink, community)
    SELECT author_id, permlink, community
    FROM registry_remove
    ON CONFLICT (author_id, permlink) DO NOTHING
),
network_counts AS (
    INSERT INTO haf_stats_backend.network_content_daily AS ncd (day, posts, comments, edits)
    SELECT
        day,
        COUNT(*) FILTER (WHERE is_create AND parent_author = ''),
        COUNT(*) FILTER (WHERE is_create AND parent_author <> ''),
        COUNT(*) FILTER (WHERE NOT is_create)
    FROM classified
    WHERE is_comment
    GROUP BY day
    ON CONFLICT (day) DO UPDATE SET
        posts    = ncd.posts    + EXCLUDED.posts,
        comments = ncd.comments + EXCLUDED.comments,
        edits    = ncd.edits    + EXCLUDED.edits
),
network_authors AS (
    INSERT INTO haf_stats_backend.network_author_daily (day, author_id)
    SELECT DISTINCT day, author_id
    FROM classified
    WHERE is_create
    ON CONFLICT (day, author_id) DO NOTHING
),
contrib AS (
    -- created content, already keyed by author id via comment_keys
    SELECT
        author_id AS account_id,
        day,
        COUNT(*) FILTER (WHERE parent_author = '')  AS posts,
        COUNT(*) FILTER (WHERE parent_author <> '') AS comments,
        0::BIGINT                                   AS replies_received
    FROM classified
    WHERE is_create
    GROUP BY author_id, day
    UNION ALL
    -- replies received, credited to the parent author of each created reply
    SELECT
        a.id,
        r.day,
        0, 0,
        r.replies
    FROM (
        SELECT parent_author, day, COUNT(*) AS replies
        FROM classified
        WHERE is_create AND parent_author <> ''
        GROUP BY parent_author, day
    ) r
    JOIN hafd.accounts a ON a.name = r.parent_author
),
-- post_engagement: this batch's direct replies, pre-aggregated to one row per
-- parent post (resolve parent author_id once per pair, not per reply op).
-- parent_permlink rides through seq -> classified, so this counts straight off
-- classified — one row per created reply. The earlier version re-joined classified
-- to comment_ops on (author, permlink), which (a) referenced classified.author,
-- a column it does not project, and (b) fanned a reply created and edited in the
-- same batch into N rows, overcounting. Replies-to-replies fall out for free:
-- only root posts (parent_author = '') ever enter post_engagement, so a comment
-- parent matches nothing in insert_posts/update_engagement below.
batch_replies AS (
    SELECT a.id AS author_id, agg.parent_permlink AS permlink, agg.cnt
    FROM (
        SELECT parent_author, parent_permlink, COUNT(*) AS cnt
        FROM classified
        WHERE is_create AND parent_author <> ''
        GROUP BY parent_author, parent_permlink
    ) agg
    JOIN hafd.accounts a ON a.name = agg.parent_author
),
vote_ops AS MATERIALIZED (
    SELECT
        ov.body_value ->> 'voter'                                  AS voter,
        ov.body_value ->> 'author'                                 AS author,
        ov.body_value ->> 'permlink'                               AS permlink,
        (ov.body_value ->> 'weight')::INT                          AS weight,
        (ov.body_value ->> 'voter') = (ov.body_value ->> 'author') AS is_self,
        ov.day
    FROM haf_stats_batch_ops ov
    WHERE ov.op_type_id = 0   -- hive::protocol::vote_operation
),
-- post_engagement: this batch's votes per voted post (upvotes + downvotes; unvotes
-- (weight=0) are retractions not engagement). Pre-aggregate to distinct (author, permlink)
-- pairs first, then resolve author_id once per pair — O(distinct voted posts) not O(raw vote ops).
batch_votes AS (
    SELECT a.id AS author_id, agg.permlink, agg.cnt
    FROM (
        SELECT vo.author, vo.permlink, COUNT(*) AS cnt
        FROM vote_ops vo
        WHERE vo.weight != 0
        GROUP BY vo.author, vo.permlink
    ) agg
    JOIN hafd.accounts a ON a.name = agg.author
),
-- One row per post this batch replied to or voted on, so each post_engagement row is written
-- once below whichever of the two it got.
batch_engagement AS (
    SELECT e.author_id, e.permlink, SUM(e.replies) AS replies, SUM(e.votes) AS votes
    FROM (
        SELECT br.author_id, br.permlink, br.cnt AS replies, 0 AS votes FROM batch_replies br
        UNION ALL
        SELECT bv.author_id, bv.permlink, 0, bv.cnt FROM batch_votes bv
    ) e
    GROUP BY e.author_id, e.permlink
),
-- Insert new root posts, seeding reply_count and vote_count with the replies and votes that
-- arrived in THIS batch (LEFT JOIN batch_engagement). Seeding here — rather than leaving it to
-- update_engagement — is what makes a post and its early replies and votes land correctly when
-- they share one (large, backfill) batch: data-modifying CTEs all see the pre-statement
-- snapshot, so update_engagement below cannot see the rows insert_posts just added. ON CONFLICT
-- DO NOTHING: is_create also fires on re-creation after a delete, but the PK row already
-- exists, so the seed is dropped and update_engagement (which DOES see that pre-existing row)
-- adds the batch's counts — counted once. A post created, deleted and created again within
-- the batch has two creations here; DISTINCT ON keeps the first, so its post_day is the day it
-- was first created, as it is when the re-creation lands in a later batch.
insert_posts AS (
    INSERT INTO haf_stats_backend.post_engagement (author_id, permlink, post_day, vote_count, reply_count)
    SELECT DISTINCT ON (c.author_id, c.permlink)
        c.author_id, c.permlink, c.day, COALESCE(be.votes, 0), COALESCE(be.replies, 0)
    FROM classified c
    LEFT JOIN batch_engagement be
        ON be.author_id = c.author_id AND be.permlink = c.permlink
    WHERE c.is_create AND c.parent_author = ''
    ORDER BY c.author_id, c.permlink, c.id
    ON CONFLICT (author_id, permlink) DO NOTHING
    -- RETURNING yields only genuinely-inserted rows (ON CONFLICT skips re-creations),
    -- i.e. this batch's new posts, so their creation-day gets total_posts refreshed.
    RETURNING post_day
),
-- Add this batch's replies and votes to posts that existed before the statement. Posts just
-- inserted by insert_posts are invisible here (same snapshot), so they match no row and are
-- not double-counted — their counts were already seeded above.
update_engagement AS (
    UPDATE haf_stats_backend.post_engagement pe
    SET reply_count = pe.reply_count + be.replies,
        vote_count  = pe.vote_count  + be.votes
    FROM batch_engagement be
    WHERE pe.author_id = be.author_id
      AND pe.permlink  = be.permlink
    -- The post's creation-day may be old; record it so its engagement period is re-rolled
    -- by the boundary hook (the forward block-window refresh would never revisit it).
    RETURNING pe.post_day
),
-- Stage every touched post creation-day (new posts + replied-to or voted posts) for the
-- boundary hook's refresh_engagement_touched(). A data-modifying CTE not read by the main
-- statement still runs, so this executes even though account_content_daily below ignores it.
stage_touched_engagement AS (
    INSERT INTO haf_stats_backend.engagement_touched_days (day)
    SELECT post_day FROM insert_posts
    UNION
    SELECT post_day FROM update_engagement
    ON CONFLICT (day) DO NOTHING
),
-- Per-account: votes cast (voter) and votes received (author).
vote_contrib AS (
    SELECT voter AS account_name, day, COUNT(*) AS votes_cast, 0::BIGINT AS votes_received
    FROM vote_ops
    GROUP BY voter, day
    UNION ALL
    SELECT author AS account_name, day, 0, COUNT(*)
    FROM vote_ops
    GROUP BY author, day
),
-- Network-wide daily counters (additive across batches).
daily AS (
    SELECT
        day,
        COUNT(*) FILTER (WHERE weight > 0) AS upvotes,
        COUNT(*) FILTER (WHERE weight < 0) AS downvotes,
        COUNT(*) FILTER (WHERE weight = 0) AS unvotes,
        COUNT(*) FILTER (WHERE is_self)    AS self_votes
    FROM vote_ops
    GROUP BY day
),
upsert_counts AS (
    INSERT INTO haf_stats_backend.network_vote_daily AS nvd
        (day, upvotes, downvotes, unvotes, self_votes)
    SELECT day, upvotes, downvotes, unvotes, self_votes
    FROM daily
    ON CONFLICT (day) DO UPDATE SET
        upvotes    = nvd.upvotes    + EXCLUDED.upvotes,
        downvotes  = nvd.downvotes  + EXCLUDED.downvotes,
        unvotes    = nvd.unvotes    + EXCLUDED.unvotes,
        self_votes = nvd.self_votes + EXCLUDED.self_votes
),
-- Distinct (day, voter) presence set, resolved to account id once per pair. The
-- counters above never touch hafd.accounts, so an (impossible) unknown voter can
-- never drop a counted vote.
network_voters AS (
    INSERT INTO haf_stats_backend.network_voter_daily (day, voter_id)
    SELECT DISTINCT vo.day, a.id
    FROM vote_ops vo
    JOIN hafd.accounts a ON a.name = vo.voter
    ON CONFLICT (day, voter_id) DO NOTHING
)
-- The content and the vote columns of a row in one upsert: GROUP BY collapses the content
-- contributions (already keyed by account id) and the vote contributions (resolved here) to
-- one row per (account_id, day), so ON CONFLICT never hits a row twice.
INSERT INTO haf_stats_backend.account_content_daily
    (account_id, day, posts, comments, votes_cast, votes_received, replies_received)
SELECT
    c.account_id,
    c.day,
    SUM(c.posts)::INT,
    SUM(c.comments)::INT,
    SUM(c.votes_cast)::INT,
    SUM(c.votes_received)::INT,
    SUM(c.replies_received)::INT
FROM (
    SELECT ct.account_id, ct.day, ct.posts, ct.comments, 0 AS votes_cast, 0 AS votes_received, ct.replies_received
    FROM contrib ct
    UNION ALL
    SELECT a.id, vc.day, 0, 0, vc.votes_cast, vc.votes_received, 0
    FROM vote_contrib vc
    JOIN hafd.accounts a ON a.name = vc.account_name
) c
GROUP BY c.account_id, c.day
ON CONFLICT (account_id, day) DO UPDATE SET
    posts            = account_content_daily.posts            + EXCLUDED.posts,
    comments         = account_content_daily.comments         + EXCLUDED.comments,
    votes_cast       = account_content_daily.votes_cast       + EXCLUDED.votes_cast,
    votes_received   = account_content_daily.votes_received   + EXCLUDED.votes_received,
    replies_received = account_content_daily.replies_received + EXCLUDED.replies_received;

-- Resolve the staged batch's communities and write comment_registry.community +
-- account_community_daily. Must be a SEPARATE statement: the community of a reply whose
-- parent was created just above is only knowable once that INSERT is visible.
PERFORM haf_stats_app.resolve_community_batch();

-- Refresh the get_network_vote_stats and get_network_content_volume rollups on a ~1200-block
-- (~1h) boundary. Recompute every day/week/month period that received data since the previous
-- refresh. A batch fires whenever it crosses a 1200-block bucket boundary, so every block
-- processed since the previous fire lies either in the bucket containing this batch's first
-- block (LIVE batches that did not cross a boundary accumulate there, and can spill into the
-- previous calendar day) or in this batch itself (a MASSIVE catch-up batch may span many
-- buckets); the lower bound reaches back to that bucket's start, ((_first_block - 1) / 1200)
-- * 1200, anchored on _first_block (not _last_block) so coverage stays correct even when a
-- firing batch spans several buckets after a skipped one. See process_active_users for the
-- full rationale. The vote and content rollups key on activity day = block day, so their
-- block-window [_first_day, _last_day] refresh is exact. Engagement is different: its lifetime
-- counts mutate posts by their (possibly old) creation-day, so it drives off the
-- engagement_touched_days set staged above rather than the block window - refresh_engagement_
-- touched() ignores _first_day/_last_day and drains exactly the touched creation-days. An
-- already-synced node can still run full refreshes with
-- SELECT haf_stats_app.refresh_network_vote_periods(<genesis day>, NULL) (and the
-- refresh_network_content_periods sibling / refresh_engagement_full()).
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

    -- Per-refresh timings: see report_processor_timing (db/process_block_range.sql).
    _timed := current_setting('haf_stats.processor_timings', TRUE) = 'on';
    IF _timed THEN _t := clock_timestamp(); END IF;
    PERFORM haf_stats_app.refresh_network_vote_periods(_first_day, _last_day);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('refresh_network_vote_periods', _first_block, _last_block, _t, '{}', 'process_content_stats'); END IF;
    PERFORM haf_stats_app.refresh_network_content_periods(_first_day, _last_day);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('refresh_network_content_periods', _first_block, _last_block, _t, '{}', 'process_content_stats'); END IF;

    -- Engagement drain. Drains every boundary, same as the vote/content refreshes above and the
    -- staging set is emptied each time, so a boundary only re-aggregates the creation-days actually
    -- touched by THIS batch (never a growing backlog). It re-aggregates by creation-day rather than
    -- block-day, so a lifetime count on an old post refreshes that post's old period - the reason
    -- for the engagement_touched_days staging. (A previous version deferred this during full-bucket
    -- catch-up to spread the work, but a bulk replay-then-serve flow - e.g. sync to head then run
    -- the API - never produces the small LIVE batch that would trigger the deferred drain, leaving
    -- the rollup permanently empty, so the drain must run unconditionally.)
    IF _timed THEN _t := clock_timestamp(); END IF;
    PERFORM haf_stats_app.refresh_engagement_touched();
    IF _timed THEN _t := haf_stats_app.report_processor_timing('refresh_engagement_touched', _first_block, _last_block, _t, '{}', 'process_content_stats'); END IF;
END IF;

END;
$$;

-- Drop the orphaned function that caused issue #42. process_content_volume_backfill
-- was never in this repo (git has no record of it) but existed as DB-only drift on at
-- least one deployment: an owner-only, unguarded, additive upsert into exactly
-- comment_registry / network_content_daily / network_author_daily — the three tables
-- issue #42 found doubled, and nothing else. That match (posts/comments 2x, authors
-- untouched because their upsert is idempotent, siblings clean) makes it the
-- near-certain cause: someone called it over an already-counted range and it silently
-- added those counts a second time. Drop it on every install/migration, not just by
-- hand on the affected node, so the loaded gun cannot be reloaded or reused elsewhere.
DROP FUNCTION IF EXISTS haf_stats_app.process_content_volume_backfill(INT, INT);

-- Content rebuild path for get_network_content_volume AND get_account_content_stats.
-- This is a NARROW DUPLICATE of the comment-op classification in process_content_stats
-- (the comment_ops … network_authors CTEs above): same scan, same create-vs-edit rule.
-- It writes the three network content-volume outputs — comment_registry,
-- network_content_daily, network_author_daily — plus the CONTENT columns of
-- account_content_daily (posts, comments, replies_received), all from the one shared
-- `classified` CTE. It writes nothing else: no votes_cast/votes_received (a separate
-- vote scan the script preserves — see below), no post_engagement, no boundary rollup
-- refresh. process_content_stats cannot be reused for a rebuild because its shared scan
-- also feeds votes/engagement and re-running it would re-double them.
--
-- account_content_daily's content columns were added here to repair a stale over-report
-- (issue: account posts counted raw comment ops, incl. edits, before the create/edit
-- dedup landed in #13 — and account_content_daily had no rebuild path). The account
-- upsert MUST share this same genesis registry replay: is_create is comment_registry-
-- stateful, so a separate pass run after the network rebuild would see a fully-populated
-- registry and misclassify every op as an edit. Because both the network and account
-- counts read the identical `classified` rows, SUM(account.posts) == network.posts by
-- construction (the parity guard asserts it).
--
-- IMPORTANT: the classification below MUST stay in lockstep with the matching block in
-- process_content_stats. tests/parity/content_volume_rebuild_consistency.sql runs both
-- over the same blocks and fails CI on any drift.
--
-- Used by scripts/rebuild_content_volume.sh, which TRUNCATEs the three network tables
-- and ZEROES account_content_daily's content columns (it cannot TRUNCATE that table —
-- votes_cast/votes_received come from a scan this path does not reproduce), then calls
-- this for ascending, non-overlapping batches from block 1. All the counters stay
-- additive (a calendar day spans many batches); that is correct as long as the rebuild
-- starts from a truncated/zeroed slate and never reprocesses a block range. The script
-- reseals network_content_period_counts afterward (that endpoint reads only the rollup;
-- account_content_daily is read directly, no reseal needed).
--
-- This function is itself additive and just as unguarded as the one dropped above —
-- it is safe ONLY by the convention that rebuild_content_volume.sh always TRUNCATEs the
-- network tables and zeroes the account content columns before calling it. It is
-- owner-only and reachable solely through that script, so this is accepted as a second
-- "loaded gun" rather than fixed here; do not call it directly outside the script.
DROP FUNCTION IF EXISTS haf_stats_app.process_content_volume;
CREATE OR REPLACE FUNCTION haf_stats_app.process_content_volume(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
BEGIN

PERFORM haf_stats_app.prepare_community_batch_stage();
PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[1, 17, 73]);

WITH comment_ops AS MATERIALIZED (
    SELECT
        ov.op_id                            AS id,
        ov.body_value ->> 'author'          AS author,
        ov.body_value ->> 'permlink'        AS permlink,
        ov.body_value ->> 'parent_author'   AS parent_author,
        ov.body_value ->> 'parent_permlink' AS parent_permlink,
        ov.day,
        ov.block_num
    FROM haf_stats_batch_ops ov
    WHERE ov.op_type_id = 1   -- hive::protocol::comment_operation
),
-- delete_comment ops (17) interleaved with ineffective_delete_comment vops (73).
-- The vop is emitted while the failed delete applies, so its id is the very next
-- event for that comment; a delete immediately followed by its vop did nothing.
delete_events AS (
    SELECT
        ov.body_value ->> 'author'   AS author,
        ov.body_value ->> 'permlink' AS permlink,
        ov.op_id                     AS id,
        ov.op_type_id = 73           AS is_vop
    FROM haf_stats_batch_ops ov
    WHERE ov.op_type_id IN (17, 73)
),
effective_deletes AS (
    SELECT author, permlink, id
    FROM (
        SELECT
            author,
            permlink,
            id,
            is_vop,
            LEAD(is_vop) OVER (PARTITION BY author, permlink ORDER BY id) AS next_is_vop
        FROM delete_events
    ) d
    WHERE NOT is_vop AND next_is_vop IS DISTINCT FROM TRUE
),
-- Interleave comment + effective-delete events per comment in op order: after a
-- comment op the comment exists (created or edited), after an effective delete
-- it does not. So a comment op is a CREATE iff the previous event is a delete —
-- or it has no previous event in the batch and no registry row from earlier ones.
seq AS (
    SELECT
        id,
        author,
        permlink,
        parent_author,
        parent_permlink,
        day,
        block_num,
        is_comment,
        LAG(is_comment) OVER w  AS prev_is_comment,
        LEAD(id) OVER w IS NULL AS is_last
    FROM (
        SELECT id, author, permlink, parent_author, parent_permlink, day, block_num, TRUE AS is_comment
        FROM comment_ops
        UNION ALL
        SELECT id, author, permlink, NULL, NULL, NULL, NULL, FALSE
        FROM effective_deletes
    ) e
    WINDOW w AS (PARTITION BY author, permlink ORDER BY id)
),
-- One accounts resolution + registry probe per distinct comment, not per op.
comment_keys AS (
    SELECT
        k.author,
        k.permlink,
        a.id AS author_id,
        r.author_id IS NOT NULL AS pre_exists
    FROM (SELECT DISTINCT author, permlink FROM seq) k
    JOIN hafd.accounts a ON a.name = k.author
    LEFT JOIN haf_stats_backend.comment_registry r
        ON r.author_id = a.id AND r.permlink = k.permlink
),
classified AS (
    SELECT
        s.id,
        s.parent_author,
        s.parent_permlink,
        s.day,
        s.block_num,
        s.is_comment,
        s.is_last,
        k.author_id,
        k.permlink,
        s.is_comment AND COALESCE(NOT s.prev_is_comment, NOT k.pre_exists) AS is_create
    FROM seq s
    JOIN comment_keys k ON k.author = s.author AND k.permlink = s.permlink
),
-- Stage this batch's comment CREATIONS for resolve_community_batch() (issue #47) — one
-- row per creation event, keyed by op id. Any coarser grain merges creations that belong
-- in different buckets (root vs reply, community vs personal blog) and silently breaks
-- the endpoint's sum-to-get_account_content_stats invariant; see the header on
-- prepare_community_batch_stage.
-- The block_num floor makes the whole community feature free for pre-2019 ranges: no
-- community can exist before hivemind's start block, so nothing is staged at all.
community_stage AS (
    INSERT INTO haf_stats_community_batch_stage
        (id, author_id, permlink, parent_author_id, parent_permlink,
         is_root, day, own_community)
    SELECT
        c.id,
        c.author_id,
        c.permlink,
        pa.id,
        c.parent_permlink,
        c.parent_author = '',
        c.day,
        -- A root post's category is its community only if that community was already
        -- registered at this block: a category can look like a community name years
        -- before (or without) the account ever existing.
        CASE
            WHEN c.parent_author = ''
             AND EXISTS (
                 SELECT 1
                 FROM haf_stats_backend.community_registry cr
                 WHERE cr.community = c.parent_permlink
                   AND cr.created_block <= c.block_num
             )
                THEN c.parent_permlink
        END
    FROM classified c
    LEFT JOIN hafd.accounts pa ON pa.name = c.parent_author
    WHERE c.is_create
      AND c.block_num >= haf_stats_app.community_start_block()
),
-- End-of-batch registry state: a comment is present iff its last event is a
-- comment op. The add/remove key sets are disjoint (is_last is unique per key),
-- so the two data-modifying CTEs cannot touch the same row.
registry_add AS (
    INSERT INTO haf_stats_backend.comment_registry (author_id, permlink)
    SELECT author_id, permlink
    FROM classified
    WHERE is_last AND is_comment
    ON CONFLICT (author_id, permlink) DO NOTHING
),
registry_remove AS (
    DELETE FROM haf_stats_backend.comment_registry r
    USING classified c
    WHERE c.is_last AND NOT c.is_comment
      AND r.author_id = c.author_id AND r.permlink = c.permlink
    RETURNING r.author_id, r.permlink, r.community
),
-- Keep the deleted comments' communities for resolve_community_batch: a reply made
-- earlier in this same batch still inherits from the parent that is being removed here,
-- but the registry row it would have read is gone by the time the resolver runs.
stage_removed_communities AS (
    INSERT INTO haf_stats_community_batch_removed (author_id, permlink, community)
    SELECT author_id, permlink, community
    FROM registry_remove
    ON CONFLICT (author_id, permlink) DO NOTHING
),
network_counts AS (
    INSERT INTO haf_stats_backend.network_content_daily AS ncd (day, posts, comments, edits)
    SELECT
        day,
        COUNT(*) FILTER (WHERE is_create AND parent_author = ''),
        COUNT(*) FILTER (WHERE is_create AND parent_author <> ''),
        COUNT(*) FILTER (WHERE NOT is_create)
    FROM classified
    WHERE is_comment
    GROUP BY day
    ON CONFLICT (day) DO UPDATE SET
        posts    = ncd.posts    + EXCLUDED.posts,
        comments = ncd.comments + EXCLUDED.comments,
        edits    = ncd.edits    + EXCLUDED.edits
),
-- Per-account created content — a byte-for-byte copy of the account path in
-- process_content_stats (its contrib CTE + account_content_daily INSERT), reading the
-- same `classified` set as network_counts above. Posts/comments regroup the identical
-- is_create rows network_counts counts, differing only in the GROUP BY dimension, so
-- SUM(account.posts) == network.posts by construction. replies_received credits the
-- parent author of each created reply. Additive; rebuild_content_volume.sh zeroes these
-- three columns before the batch loop so a day spanning batches accumulates from 0.
contrib AS (
    -- created content, already keyed by author id via comment_keys
    SELECT
        author_id AS account_id,
        day,
        COUNT(*) FILTER (WHERE parent_author = '')  AS posts,
        COUNT(*) FILTER (WHERE parent_author <> '') AS comments,
        0::BIGINT                                   AS replies_received
    FROM classified
    WHERE is_create
    GROUP BY author_id, day
    UNION ALL
    -- replies received, credited to the parent author of each created reply
    SELECT
        a.id,
        r.day,
        0, 0,
        r.replies
    FROM (
        SELECT parent_author, day, COUNT(*) AS replies
        FROM classified
        WHERE is_create AND parent_author <> ''
        GROUP BY parent_author, day
    ) r
    JOIN hafd.accounts a ON a.name = r.parent_author
),
-- Data-modifying CTE, unreferenced by the terminal INSERT below, so (like registry_add/
-- remove and network_counts) it executes exactly once. The INSERT column list omits
-- votes_cast/votes_received: on conflict they are left untouched (preserved), and a
-- genuinely new row takes the table default 0. GROUP BY collapses the two contrib
-- branches into one row per (account_id, day) so ON CONFLICT never hits a row twice.
account_content_upsert AS (
    INSERT INTO haf_stats_backend.account_content_daily
        (account_id, day, posts, comments, replies_received)
    SELECT
        c.account_id,
        c.day,
        SUM(c.posts)::INT,
        SUM(c.comments)::INT,
        SUM(c.replies_received)::INT
    FROM contrib c
    GROUP BY c.account_id, c.day
    ON CONFLICT (account_id, day) DO UPDATE SET
        posts            = account_content_daily.posts            + EXCLUDED.posts,
        comments         = account_content_daily.comments         + EXCLUDED.comments,
        replies_received = account_content_daily.replies_received + EXCLUDED.replies_received
)
-- network_author_daily promoted to the main statement so the data-modifying CTEs above
-- (registry_add/remove, network_counts, account_content_upsert) all execute exactly once.
INSERT INTO haf_stats_backend.network_author_daily (day, author_id)
SELECT DISTINCT day, author_id
FROM classified
WHERE is_create
ON CONFLICT (day, author_id) DO NOTHING;

-- Same second statement as the live path, for the same reason: an in-batch parent's
-- community is only knowable once the statement above has landed. Keeping this in a
-- shared function (rather than a copy) is what stops the two paths drifting on the one
-- piece of logic the rebuild consistency test cannot express as a column comparison.
PERFORM haf_stats_app.resolve_community_batch();

END;
$$;

RESET ROLE;
