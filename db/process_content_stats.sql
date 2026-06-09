SET ROLE haf_stats_owner;

-- Feature: content & engagement stats. One processor, two consumers that share
-- the same comment-op and vote-op scans (so the two highest-volume op streams are
-- read once per batch, not once per feature):
--   * get_account_content_stats — per-account posts/comments/votes/replies
--                                 (table account_content_daily)
--   * get_network_vote_stats    — network-wide vote activity
--                                 (tables network_vote_daily + network_voter_daily)
--
-- Author rewards are NOT stored here: they already live in
-- haf_stats_backend.account_financial_daily (process_financial.sql) and the
-- account endpoint JOINs them in, so there is nothing to re-process.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_content_daily (
    account_id       INT  NOT NULL,
    day              DATE NOT NULL,
    posts            INT  NOT NULL DEFAULT 0,
    comments         INT  NOT NULL DEFAULT 0,
    votes_cast       INT  NOT NULL DEFAULT 0,
    votes_received   INT  NOT NULL DEFAULT 0,
    replies_received INT  NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day)
);

CREATE INDEX IF NOT EXISTS idx_acd_account_day
ON haf_stats_backend.account_content_daily (account_id, day DESC);

GRANT SELECT ON haf_stats_backend.account_content_daily TO haf_stats_user;

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
    day        DATE NOT NULL,
    upvotes    INT  NOT NULL DEFAULT 0,
    downvotes  INT  NOT NULL DEFAULT 0,
    unvotes    INT  NOT NULL DEFAULT 0,
    self_votes INT  NOT NULL DEFAULT 0,
    PRIMARY KEY (day)
);

GRANT SELECT ON haf_stats_backend.network_vote_daily TO haf_stats_user;

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_voter_daily (
    day      DATE NOT NULL,
    voter_id INT  NOT NULL,
    PRIMARY KEY (day, voter_id)
);

GRANT SELECT ON haf_stats_backend.network_voter_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- Optimisation notes (patterns borrowed from haf_block_explorer / balance_tracker
-- HAF processors, which run over the same high-volume operation stream):
--
--  * Two scans, not four. Comment ops (op_type_id = 1) yield BOTH the author's
--    posts/comments AND the parent author's replies_received; vote ops
--    (op_type_id = 0) yield BOTH votes_cast (voter) and votes_received (author).
--    Each op stream is scanned ONCE into a MATERIALIZED CTE, then unpivoted with
--    UNION ALL so the expensive operations_view scan + blocks join is not repeated
--    (PG would otherwise inline the CTE and scan twice). Votes are the single
--    highest-volume op on Hive, so halving the scans matters under
--    MASSIVE_PROCESSING. The vote-op scan does triple duty: the SAME MATERIALIZED
--    rows feed account_content_daily (votes_cast/received), the network_vote_daily
--    counters AND the network_voter_daily voter set — three outputs, one scan.
--
--  * Bound the scan by operation id as well as block_num. hafd.operation_id(b, 0)
--    is the first op id in block b, so the half-open id range
--    [op_id(first,0), op_id(last+1,0)) is exactly this block range and lets the
--    planner range-scan the operations primary key — the canonical
--    haf_block_explorer idiom (process_account_stats.sql, process_block_operations.sql).
--
--  * Drive from hive.operations_view by block_num. operations_view is indexed by
--    block_num; hive.account_operations_view is NOT (it is keyed by account_id),
--    so a block_num-range scan there is a full seq scan — see process_account_cohorts
--    (#21). We need to distinguish roles (voter vs author, author vs parent_author)
--    which only the op body carries, so operations_view is also the correct source.
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

CREATE OR REPLACE FUNCTION haf_stats_app.process_content_stats(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
BEGIN

-- Comment ops: author's posts (parent_author = '') and comments (reply),
-- plus replies_received credited to the parent author.
WITH comment_ops AS MATERIALIZED (
    SELECT
        ov.body_value ->> 'author'        AS author,
        ov.body_value ->> 'parent_author' AS parent_author,
        b.created_at::DATE                AS day
    FROM hive.operations_view ov
    JOIN hafd.blocks b ON b.num = ov.block_num
    WHERE ov.op_type_id = 1   -- hive::protocol::comment_operation
      AND ov.block_num BETWEEN _first_block AND _last_block
      AND ov.id >= hafd.operation_id(_first_block, 0)
      AND ov.id <  hafd.operation_id(_last_block + 1, 0)
),
contrib AS (
    -- authored content, keyed by the author
    SELECT
        author AS account_name,
        day,
        COUNT(*) FILTER (WHERE parent_author = '')  AS posts,
        COUNT(*) FILTER (WHERE parent_author <> '') AS comments,
        0::BIGINT                                   AS replies_received
    FROM comment_ops
    GROUP BY author, day
    UNION ALL
    -- replies received, keyed by the parent author (only actual replies)
    SELECT
        parent_author AS account_name,
        day,
        0, 0,
        COUNT(*)
    FROM comment_ops
    WHERE parent_author <> ''
    GROUP BY parent_author, day
)
INSERT INTO haf_stats_backend.account_content_daily
    (account_id, day, posts, comments, replies_received)
SELECT
    a.id,
    c.day,
    SUM(c.posts)::INT,
    SUM(c.comments)::INT,
    SUM(c.replies_received)::INT
FROM contrib c
JOIN hafd.accounts a ON a.name = c.account_name
GROUP BY a.id, c.day
ON CONFLICT (account_id, day) DO UPDATE SET
    posts            = account_content_daily.posts            + EXCLUDED.posts,
    comments         = account_content_daily.comments         + EXCLUDED.comments,
    replies_received = account_content_daily.replies_received + EXCLUDED.replies_received;

-- Vote ops: ONE scan, three outputs.
--   account_content_daily — votes_cast (voter) + votes_received (author)
--   network_vote_daily    — daily up/down/un/self counters
--   network_voter_daily   — distinct (day, voter) set for exact unique voters
-- The two INSERTs feeding account_content_daily and network_vote_daily are
-- data-modifying CTEs; the network_voter_daily INSERT is the main statement. All
-- read the single MATERIALIZED vote_ops, so the op stream is scanned once.
WITH vote_ops AS MATERIALIZED (
    SELECT
        ov.body_value ->> 'voter'                                  AS voter,
        ov.body_value ->> 'author'                                 AS author,
        (ov.body_value ->> 'weight')::INT                          AS weight,
        (ov.body_value ->> 'voter') = (ov.body_value ->> 'author') AS is_self,
        b.created_at::DATE                                         AS day
    FROM hive.operations_view ov
    JOIN hafd.blocks b ON b.num = ov.block_num
    WHERE ov.op_type_id = 0   -- hive::protocol::vote_operation
      AND ov.block_num BETWEEN _first_block AND _last_block
      AND ov.id >= hafd.operation_id(_first_block, 0)
      AND ov.id <  hafd.operation_id(_last_block + 1, 0)
),
-- Per-account: votes cast (voter) and votes received (author).
contrib AS (
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
upsert_account AS (
    INSERT INTO haf_stats_backend.account_content_daily
        (account_id, day, votes_cast, votes_received)
    SELECT
        a.id,
        c.day,
        SUM(c.votes_cast)::INT,
        SUM(c.votes_received)::INT
    FROM contrib c
    JOIN hafd.accounts a ON a.name = c.account_name
    GROUP BY a.id, c.day
    ON CONFLICT (account_id, day) DO UPDATE SET
        votes_cast     = account_content_daily.votes_cast     + EXCLUDED.votes_cast,
        votes_received = account_content_daily.votes_received + EXCLUDED.votes_received
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
)
-- Distinct (day, voter) presence set, resolved to account id once per pair. The
-- counters above never touch hafd.accounts, so an (impossible) unknown voter can
-- never drop a counted vote.
INSERT INTO haf_stats_backend.network_voter_daily (day, voter_id)
SELECT DISTINCT vo.day, a.id
FROM vote_ops vo
JOIN hafd.accounts a ON a.name = vo.voter
ON CONFLICT (day, voter_id) DO NOTHING;

END;
$$;

RESET ROLE;
