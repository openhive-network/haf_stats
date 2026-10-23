-- =============================================================================
-- content_oracle_fixture.sql -- a closed world for tests/parity/content_vs_hivemind.sql (#63).
--
-- Loaded ONLY by tests/ci_content_oracle.sh, inside a transaction it always rolls back:
-- it empties hafd.blocks, the hivemind_app double and both content tables, so it must
-- never be committed. It adds what the stub lane lacks and the guard needs: hive.blocks_view,
-- hive.get_current_stage_name (driven by the ci.hivemind_stage setting, default 'live'),
-- hive_posts.block_num_created with the two indexes the guard requires, hive_state and a
-- hivemind_app context row.
--
-- The world (last complete day 2025-03-05):
--   * 2025-03-01..05, one block per day: ora-a 1 post + 2 comments a day, ora-b 1 post a
--     day, and on 03-03 ora-b also writes 60 comments. haf_stats counts ONE more comment
--     than hivemind on 03-03: 63 vs 62, and floor(62 * 2%) = 1, the hivemind#394 tolerance
--     at its edge.
--   * 2025-02-10 (block 9000050): ora-a 1 post, inside the 30-day author window but not
--     the last week, so a narrowed window loses it.
--   * the 2025-03-02 block is at 00:00:01: hivemind's created_at (3 s earlier) falls on
--     03-01, so selecting hivemind rows by created_at day instead of block disagrees.
--   * every day of 2023-06, one block per day, ora-a 1 post + 1 comment: whatever day of
--     the month the guard's monthly sample rotates to, it has content to compare.
--   * hafd ids (81001/81002) differ from hivemind's (91001/91002): authors map by name.
-- haf_stats rows are derived from the hivemind rows below, so baseline agreement is by
-- construction and each case in the runner breaks exactly one thing.
-- =============================================================================

DELETE FROM hafd.blocks;
DELETE FROM hivemind_app.hive_posts;
DELETE FROM haf_stats_backend.network_content_daily;
DELETE FROM haf_stats_backend.account_content_daily;

DO $$
BEGIN
    IF to_regclass('hive.blocks_view') IS NULL THEN
        EXECUTE 'CREATE VIEW hive.blocks_view AS SELECT num, created_at FROM hafd.blocks';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION hive.get_current_stage_name(_context TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(NULLIF(current_setting('ci.hivemind_stage', TRUE), ''), 'live')
$$;

ALTER TABLE hivemind_app.hive_posts ADD COLUMN IF NOT EXISTS block_num_created INT;
CREATE INDEX hive_posts_block_num_created_idx ON hivemind_app.hive_posts (block_num_created);
CREATE INDEX hive_posts_author_id_created_at_id_idx ON hivemind_app.hive_posts (author_id, created_at, id);
CREATE TABLE hivemind_app.hive_state (last_completed_block_num INT NOT NULL);

INSERT INTO hivemind_app.hive_accounts (id, name) VALUES (91001, 'ora-a'), (91002, 'ora-b');
INSERT INTO hafd.accounts (id, name) VALUES (81001, 'ora-a'), (81002, 'ora-b');

-- Blocks: 2023-06-01..30 -> 9000001..30; 2025-02-10 -> 9000050; 2025-03-01..05 ->
-- 9000101..105; head 9000106 on 2025-03-06, so 2025-03-05 is the last complete day.
INSERT INTO hafd.blocks (num, created_at)
SELECT 9000000 + d, TIMESTAMP '2023-05-31 12:00:00' + d * INTERVAL '1 day' FROM generate_series(1, 30) AS d
UNION ALL
SELECT 9000050, TIMESTAMP '2025-02-10 12:00:00'
UNION ALL
SELECT 9000100 + d, TIMESTAMP '2025-02-28 12:00:00' + d * INTERVAL '1 day' FROM generate_series(1, 6) AS d;
UPDATE hafd.blocks SET created_at = TIMESTAMP '2025-03-02 00:00:01' WHERE num = 9000102;

-- hivemind rows: created_at 3 s before the block, as hivemind records it.
INSERT INTO hivemind_app.hive_posts (id, author_id, community_id, depth, counter_deleted, created_at, block_num_created)
SELECT 900000 + row_number() OVER (), x.author_id, NULL, x.depth, 0, b.created_at - INTERVAL '3 seconds', b.num
FROM (
    SELECT 9000000 + d AS num, 91001 AS author_id, k AS depth
    FROM generate_series(1, 30) AS d, generate_series(0, 1) AS k
    UNION ALL
    SELECT 9000050, 91001, 0
    UNION ALL
    SELECT 9000100 + d, 91001, k FROM generate_series(1, 5) AS d, (VALUES (0), (1), (2)) AS v(k)
    UNION ALL
    SELECT 9000100 + d, 91002, 0 FROM generate_series(1, 5) AS d
    UNION ALL
    SELECT 9000103, 91002, 1 FROM generate_series(1, 60)
) AS x
JOIN hafd.blocks b ON b.num = x.num;

-- haf_stats rows from the same creations, bucketed by block day.
INSERT INTO haf_stats_backend.account_content_daily (account_id, day, posts, comments)
SELECT CASE p.author_id WHEN 91001 THEN 81001 ELSE 81002 END, b.created_at::DATE,
       count(*) FILTER (WHERE p.depth = 0), count(*) FILTER (WHERE p.depth > 0)
FROM hivemind_app.hive_posts p JOIN hafd.blocks b ON b.num = p.block_num_created
GROUP BY 1, 2;

INSERT INTO haf_stats_backend.network_content_daily (day, posts, comments)
SELECT day, SUM(posts), SUM(comments) FROM haf_stats_backend.account_content_daily GROUP BY day;

-- The hivemind#394 excess: one comment hivemind dropped on 2025-03-03 (62 -> 1 allowed).
UPDATE haf_stats_backend.network_content_daily SET comments = comments + 1 WHERE day = DATE '2025-03-03';
UPDATE haf_stats_backend.account_content_daily SET comments = comments + 1
WHERE account_id = 81002 AND day = DATE '2025-03-03';

UPDATE hafd.contexts SET current_block_num = 9000106, irreversible_block = 9000106 WHERE name = 'haf_stats';
INSERT INTO hafd.contexts (name, current_block_num, irreversible_block) VALUES ('hivemind_app', 9000106, 9000106);
INSERT INTO hivemind_app.hive_state (last_completed_block_num) VALUES (9000106);
