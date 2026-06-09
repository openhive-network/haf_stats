SET ROLE haf_stats_owner;

-- Feature: per-account content & engagement stats (get_account_content_stats).
-- Creates the aggregation table and the block processor that populates it.
--
-- Author rewards are NOT stored here: they already live in
-- haf_stats_backend.account_financial_daily (process_financial.sql) and the
-- endpoint JOINs them in, so there is nothing to re-process.

-- ---------------------------------------------------------------------------
-- Table
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
--    MASSIVE_PROCESSING.
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

-- Vote ops: votes_cast credited to the voter, votes_received to the author.
WITH vote_ops AS MATERIALIZED (
    SELECT
        ov.body_value ->> 'voter'  AS voter,
        ov.body_value ->> 'author' AS author,
        b.created_at::DATE         AS day
    FROM hive.operations_view ov
    JOIN hafd.blocks b ON b.num = ov.block_num
    WHERE ov.op_type_id = 0   -- hive::protocol::vote_operation
      AND ov.block_num BETWEEN _first_block AND _last_block
),
contrib AS (
    SELECT voter AS account_name, day, COUNT(*) AS votes_cast, 0::BIGINT AS votes_received
    FROM vote_ops
    GROUP BY voter, day
    UNION ALL
    SELECT author AS account_name, day, 0, COUNT(*)
    FROM vote_ops
    GROUP BY author, day
)
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
    votes_received = account_content_daily.votes_received + EXCLUDED.votes_received;

END;
$$;

RESET ROLE;
