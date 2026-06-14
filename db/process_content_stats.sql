SET ROLE haf_stats_owner;

-- Feature: content & engagement stats. One processor, three consumers that share
-- the same comment-op and vote-op scans (so the two highest-volume op streams are
-- read once per batch, not once per feature):
--   * get_account_content_stats    — per-account posts/comments/votes/replies
--                                    (table account_content_daily)
--   * get_network_content_volume   — network-wide created posts/comments + authors
--                                    (tables network_content_daily +
--                                    network_author_daily, state comment_registry)
--   * get_network_vote_stats       — network-wide vote activity
--                                    (tables network_vote_daily + network_voter_daily)
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

CREATE INDEX IF NOT EXISTS idx_acd_account_day
ON haf_stats_backend.account_content_daily (account_id, day DESC);

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

-- ---------------------------------------------------------------------------
-- Processor
--
-- Optimisation notes (patterns borrowed from haf_block_explorer / balance_tracker
-- HAF processors, which run over the same high-volume operation stream):
--
--  * Two heavy scans, not seven. Each op stream is scanned ONCE into a
--    MATERIALIZED CTE and fans out to every consumer (PG would otherwise inline
--    the CTE and re-scan per consumer). The comment-op scan feeds FOUR outputs:
--    the comment_registry state, the network_content_daily counters, the
--    network_author_daily author set, and account_content_daily (the author's
--    posts/comments AND the parent author's replies_received, unpivoted with
--    UNION ALL). The vote-op scan feeds THREE: account_content_daily
--    (votes_cast/received), the network_vote_daily counters and the
--    network_voter_daily voter set. A third scan exists for
--    delete_comment/ineffective_delete ops but their volume is negligible.
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

-- Comment ops: ONE scan, four outputs.
--   comment_registry      — live-comment set, the create-vs-edit decision state
--   network_content_daily — daily created posts/comments + edits counters
--   network_author_daily  — distinct (day, author) set for exact unique authors
--   account_content_daily — author's posts/comments + parent's replies_received
WITH comment_ops AS MATERIALIZED (
    SELECT
        ov.id,
        ov.body_value ->> 'author'        AS author,
        ov.body_value ->> 'permlink'      AS permlink,
        ov.body_value ->> 'parent_author' AS parent_author,
        b.created_at::DATE                AS day
    FROM hive.operations_view ov
    JOIN hafd.blocks b ON b.num = ov.block_num
    WHERE ov.op_type_id = 1   -- hive::protocol::comment_operation
      AND ov.block_num BETWEEN _first_block AND _last_block
      AND ov.id >= hafd.operation_id(_first_block, 0)
      AND ov.id <  hafd.operation_id(_last_block + 1, 0)
),
-- delete_comment ops (17) interleaved with ineffective_delete_comment vops (73).
-- The vop is emitted while the failed delete applies, so its id is the very next
-- event for that comment; a delete immediately followed by its vop did nothing.
delete_events AS (
    SELECT
        ov.body_value ->> 'author'   AS author,
        ov.body_value ->> 'permlink' AS permlink,
        ov.id,
        ov.op_type_id = 73           AS is_vop
    FROM hive.operations_view ov
    WHERE ov.op_type_id IN (17, 73)
      AND ov.block_num BETWEEN _first_block AND _last_block
      AND ov.id >= hafd.operation_id(_first_block, 0)
      AND ov.id <  hafd.operation_id(_last_block + 1, 0)
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
        author,
        permlink,
        parent_author,
        day,
        is_comment,
        LAG(is_comment) OVER w  AS prev_is_comment,
        LEAD(id) OVER w IS NULL AS is_last
    FROM (
        SELECT id, author, permlink, parent_author, day, TRUE AS is_comment
        FROM comment_ops
        UNION ALL
        SELECT id, author, permlink, NULL, NULL, FALSE
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
        s.parent_author,
        s.day,
        s.is_comment,
        s.is_last,
        k.author_id,
        k.permlink,
        s.is_comment AND COALESCE(NOT s.prev_is_comment, NOT k.pre_exists) AS is_create
    FROM seq s
    JOIN comment_keys k ON k.author = s.author AND k.permlink = s.permlink
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
)
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
