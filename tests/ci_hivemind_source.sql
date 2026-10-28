-- The hivemind content source (db/process_content_stats.sql, "Content source"), run for real in
-- the stub lane over tests/community_fixture.sql's synthetic content and the hivemind_app double
-- tests/hivemind_oracle_fixture.sql holds for it (one hive_posts row per creation, deletes and
-- re-creations included).
--
--   1. select_content_source: auto picks a readable hivemind, keeps a recorded source, treats a
--      deployment that processed blocks without a record as internal, refuses a switch on one
--      that has processed blocks unless asked to, and refuses hivemind it cannot read.
--   2. Equality: the content processors over the same blocks produce the same content volume,
--      account content, community activity, author cohorts, touched engagement days and
--      engagement rollup (engagement_period_counts) from either source, and the hivemind source
--      writes no comment_registry or post_engagement row. An upgraded hivemind deployment's
--      post_engagement is emptied once the rollup is rebuilt from hivemind, to the same rows.
--   3. The clamp: with hivemind's context behind the processor, no content-stats batch ends past
--      hivemind's head; the range is processed in the pieces hivemind has reached.
--   4. The wait: below hivemind's head nothing is processed and nothing falls back; it waits
--      (here bounded by haf_stats.hivemind_wait_timeout into an error). hivemind's completion
--      marker and a missing block_num_created index hold it back too.
--
-- One transaction, rolled back: the processors' output, the source record, hivemind's context
-- row, its index and hive_state are this file's alone.
\set ON_ERROR_STOP on

BEGIN;

-- A deployment that has processed nothing: the selection treats a processed one as decided, and
-- the processors refuse ranges at or below this (tests/mainnet_community_fixture.sql moves it).
UPDATE haf_stats_app.app_status SET last_processed_block = 0;

-- What a co-located hivemind has beside its tables: a context row and the index the source
-- reads hive_posts by.
CREATE INDEX ci_hive_posts_block_num_created ON hivemind_app.hive_posts (block_num_created);
INSERT INTO hafd.contexts (name, current_block_num, irreversible_block)
VALUES ('hivemind_app', 37500045, 37500045);

-- ---------------------------------------------------------------------------
-- 1. Selection
-- ---------------------------------------------------------------------------
DO $select$
DECLARE
    _got TEXT;
BEGIN
    DELETE FROM haf_stats_app.content_source_config;
    IF haf_stats_app.content_source() <> 'internal' THEN
        RAISE EXCEPTION 'content source: no record must read as internal, got %', haf_stats_app.content_source();
    END IF;

    _got := haf_stats_app.select_content_source('auto');
    IF _got <> 'hivemind' OR haf_stats_app.content_source() <> 'hivemind' THEN
        RAISE EXCEPTION 'content source: auto with a readable hivemind_app must record hivemind, got % (recorded %)', _got, haf_stats_app.content_source();
    END IF;

    -- Recorded, and blocks processed: a switch is refused...
    UPDATE haf_stats_app.app_status SET last_processed_block = 100;
    BEGIN
        PERFORM haf_stats_app.select_content_source('internal');
        RAISE EXCEPTION 'ci: switch accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%built from the hivemind content source; switching to internal needs a content rebuild%' THEN
            RAISE;
        END IF;
    END;
    -- ... auto keeps the record...
    IF haf_stats_app.select_content_source('auto') <> 'hivemind' THEN
        RAISE EXCEPTION 'content source: auto must keep the recorded hivemind';
    END IF;
    -- ... and the rebuild may switch it.
    IF haf_stats_app.select_content_source('internal', TRUE) <> 'internal' THEN
        RAISE EXCEPTION 'content source: an allowed switch must record internal';
    END IF;

    -- Processed blocks without a record: built by the internal path before the choice existed.
    DELETE FROM haf_stats_app.content_source_config;
    IF haf_stats_app.select_content_source('auto') <> 'internal' THEN
        RAISE EXCEPTION 'content source: auto on a processed deployment without a record must stay internal';
    END IF;
    UPDATE haf_stats_app.app_status SET last_processed_block = 0;

    -- hivemind the processor cannot read is refused, naming what it lacks.
    REVOKE SELECT ON hivemind_app.hive_permlink_data FROM haf_stats_owner;
    BEGIN
        PERFORM haf_stats_app.select_content_source('hivemind');
        RAISE EXCEPTION 'ci: unreadable hivemind accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%cannot read: hive_permlink_data.id, hive_permlink_data.permlink%' THEN
            RAISE;
        END IF;
    END;
    IF haf_stats_app.select_content_source('auto') <> 'internal' THEN
        RAISE EXCEPTION 'content source: auto with an unreadable hivemind_app on a new deployment must pick internal';
    END IF;
    GRANT SELECT ON hivemind_app.hive_permlink_data TO haf_stats_owner;

    BEGIN
        PERFORM haf_stats_app.select_content_source('hivemnd');
        RAISE EXCEPTION 'ci: unknown source accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%must be auto, internal or hivemind, got hivemnd%' THEN
            RAISE;
        END IF;
    END;

    RAISE NOTICE 'hivemind source: selection verified';
END
$select$;

-- ---------------------------------------------------------------------------
-- 2. Equality
-- ---------------------------------------------------------------------------

-- Votes for the engagement rollup, which the hivemind source reads from hive_votes rather than
-- from these ops: each hive_votes row below is what hivemind keeps for the ops beside it. bob's
-- and alice's single votes, carol's vote and later edit (two ops that count), dave's vote and
-- unvote (one), a vote on a comment (no post counts it), and votes on alice/p4's re-creation and
-- on grace/g1's first creation (the post it counts for keeps its first day).
INSERT INTO hafd.operations (id, op_type_id, body_value)
VALUES
    (hafd.operation_id(37500011, 2), 0, '{"voter": "bob", "author": "alice", "permlink": "p1", "weight": 10000}'),
    (hafd.operation_id(37500012, 2), 0, '{"voter": "carol", "author": "alice", "permlink": "p1", "weight": 10000}'),
    (hafd.operation_id(37500016, 2), 0, '{"voter": "alice", "author": "bob", "permlink": "p2", "weight": 10000}'),
    (hafd.operation_id(37500020, 2), 0, '{"voter": "bob", "author": "alice", "permlink": "c3", "weight": 10000}'),
    (hafd.operation_id(37500020, 3), 0, '{"voter": "carol", "author": "alice", "permlink": "p4", "weight": 10000}'),
    (hafd.operation_id(37500021, 2), 0, '{"voter": "dave", "author": "alice", "permlink": "p1", "weight": 10000}'),
    (hafd.operation_id(37500022, 2), 0, '{"voter": "carol", "author": "alice", "permlink": "p1", "weight": 5000}'),
    (hafd.operation_id(37500023, 2), 0, '{"voter": "dave", "author": "alice", "permlink": "p1", "weight": 0}'),
    (hafd.operation_id(37500036, 2), 0, '{"voter": "erin", "author": "grace", "permlink": "g1", "weight": 10000}');

INSERT INTO hivemind_app.hive_votes
    (id, post_id, voter_id, author_id, permlink_id, vote_percent, num_changes, block_num)
VALUES
    (1, 1,  47003, 47002, 1,  10000, 0, 37500011),   -- bob -> alice/p1
    (2, 1,  47004, 47002, 1,  5000,  1, 37500022),   -- carol -> alice/p1, edited
    (3, 5,  47002, 47003, 5,  10000, 0, 37500016),   -- alice -> bob/p2
    (4, 4,  47003, 47002, 4,  10000, 0, 37500020),   -- bob -> alice/c3 (a comment)
    (5, 8,  47004, 47002, 7,  10000, 0, 37500020),   -- carol -> alice/p4 (live copy)
    (6, 1,  47005, 47002, 1,  0,     1, 37500023),   -- dave -> alice/p1, unvoted
    (7, 15, 47007, 47009, 12, 10000, 0, 37500036);   -- erin -> grace/g1 (first copy)

-- Everything the two runs write for the fixture's accounts (47001-47010) and days.
CREATE FUNCTION pg_temp.ci_reset_content()
RETURNS VOID
LANGUAGE sql
AS $fn$
    DELETE FROM haf_stats_backend.network_content_daily WHERE day IN (DATE '2019-10-01', DATE '2019-10-02');
    DELETE FROM haf_stats_backend.network_author_daily WHERE day IN (DATE '2019-10-01', DATE '2019-10-02');
    DELETE FROM haf_stats_backend.account_content_daily WHERE account_id BETWEEN 47001 AND 47010;
    DELETE FROM haf_stats_backend.account_community_daily WHERE account_id BETWEEN 47001 AND 47010;
    DELETE FROM haf_stats_backend.comment_registry WHERE author_id BETWEEN 47001 AND 47010;
    DELETE FROM haf_stats_backend.post_engagement WHERE author_id BETWEEN 47001 AND 47010;
    DELETE FROM haf_stats_backend.engagement_touched_days;
    DELETE FROM haf_stats_backend.engagement_period_counts WHERE period >= DATE '2019-09-30';
    DELETE FROM haf_stats_backend.author_cohort_members WHERE account_id BETWEEN 47001 AND 47010;
$fn$;

-- The two batches tests/community_fixture.sql uses, through the block path's order.
CREATE FUNCTION pg_temp.ci_run_content()
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
BEGIN
    PERFORM haf_stats_app.process_content_stats(37500001, 37500019);
    PERFORM haf_stats_app.process_content_cohorts(37500001, 37500019);
    PERFORM haf_stats_app.process_content_stats(37500020, 37500045);
    PERFORM haf_stats_app.process_content_cohorts(37500020, 37500045);
END;
$fn$;

CREATE TEMP TABLE ci_output (source TEXT NOT NULL, tbl TEXT NOT NULL, row_text TEXT NOT NULL);

-- What the batches wrote, then -- the batches stay inside one 1200-block bucket, so the boundary
-- refresh never fires -- the engagement rollup the refresh makes of the creation-days they staged.
CREATE FUNCTION pg_temp.ci_capture(_source TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
BEGIN
    INSERT INTO ci_output (source, tbl, row_text)
    SELECT _source, 'network_content_daily', t::TEXT FROM haf_stats_backend.network_content_daily t
    WHERE t.day IN (DATE '2019-10-01', DATE '2019-10-02')
    UNION ALL
    SELECT _source, 'network_author_daily', t::TEXT FROM haf_stats_backend.network_author_daily t
    WHERE t.day IN (DATE '2019-10-01', DATE '2019-10-02')
    UNION ALL
    SELECT _source, 'account_content_daily', t::TEXT FROM haf_stats_backend.account_content_daily t
    WHERE t.account_id BETWEEN 47001 AND 47010
    UNION ALL
    SELECT _source, 'account_community_daily', t::TEXT FROM haf_stats_backend.account_community_daily t
    WHERE t.account_id BETWEEN 47001 AND 47010
    UNION ALL
    SELECT _source, 'engagement_touched_days', t::TEXT FROM haf_stats_backend.engagement_touched_days t
    UNION ALL
    SELECT _source, 'author_cohort_members', t::TEXT FROM haf_stats_backend.author_cohort_members t
    WHERE t.account_id BETWEEN 47001 AND 47010;

    PERFORM haf_stats_app.refresh_engagement_touched();
    INSERT INTO ci_output (source, tbl, row_text)
    SELECT _source, 'engagement_period_counts', t::TEXT FROM haf_stats_backend.engagement_period_counts t
    WHERE t.period >= DATE '2019-09-30';
END;
$fn$;

DELETE FROM haf_stats_app.content_source_config;
SELECT pg_temp.ci_reset_content();
SELECT pg_temp.ci_run_content();
SELECT pg_temp.ci_capture('internal');
-- Kept for the upgrade check below.
CREATE TEMP TABLE ci_internal_post_engagement AS
SELECT * FROM haf_stats_backend.post_engagement WHERE author_id BETWEEN 47001 AND 47010;

INSERT INTO haf_stats_app.content_source_config (source) VALUES ('hivemind');
SELECT pg_temp.ci_reset_content();
SELECT pg_temp.ci_run_content();
SELECT pg_temp.ci_capture('hivemind');

DO $equal$
DECLARE
    _tbl TEXT;
    _diff TEXT;
    _n INT;
BEGIN
    -- Non-vacuous: the internal run produced every output this compares.
    FOREACH _tbl IN ARRAY ARRAY['network_content_daily', 'network_author_daily', 'account_content_daily',
                                'account_community_daily', 'engagement_touched_days', 'engagement_period_counts',
                                'author_cohort_members'] LOOP
        IF NOT EXISTS (SELECT 1 FROM ci_output WHERE source = 'internal' AND tbl = _tbl) THEN
            RAISE EXCEPTION 'hivemind source: the internal run wrote no % row for the fixture; the comparison would prove nothing', _tbl;
        END IF;
    END LOOP;
    -- The edit at 37500014 must survive as an edit on both sides (posts, comments, edits).
    IF NOT EXISTS (SELECT 1 FROM ci_output WHERE source = 'internal' AND tbl = 'network_content_daily'
                   AND row_text = '(2019-10-01,6,5,1)') THEN
        RAISE EXCEPTION 'hivemind source: the internal run''s 2019-10-01 content volume is not 6 posts, 5 comments, 1 edit: %',
            (SELECT string_agg(row_text, ' ') FROM ci_output WHERE source = 'internal' AND tbl = 'network_content_daily');
    END IF;
    -- The engagement every case above adds up to (posts, votes, replies, posts with no vote, posts
    -- with no reply): 10-01 holds alice/p1 (4 counted votes, 3 replies, frank's f1 among them),
    -- bob/p2, carol/p3, alice/p4 and erin/p5 (its first day); 10-02 frank/f1 and grace/g1 (2 replies,
    -- one under each of its creations).
    SELECT string_agg(row_text, ' ' ORDER BY row_text) INTO _diff
    FROM ci_output WHERE source = 'internal' AND tbl = 'engagement_period_counts';
    IF _diff IS DISTINCT FROM '(day,2019-10-01,5,6,4,2,3) (day,2019-10-02,2,1,2,1,1) (month,2019-10-01,7,7,6,3,4) (week,2019-09-30,7,7,6,3,4)' THEN
        RAISE EXCEPTION 'hivemind source: the internal run''s engagement rollup is not the fixture''s: %', _diff;
    END IF;

    SELECT string_agg(format('%s %s: %s', d.side, d.tbl, d.row_text), E'\n  ' ORDER BY d.tbl, d.side, d.row_text), COUNT(*)
    INTO _diff, _n
    FROM (
        (SELECT 'internal only' AS side, tbl, row_text FROM ci_output WHERE source = 'internal'
         EXCEPT ALL
         SELECT 'internal only', tbl, row_text FROM ci_output WHERE source = 'hivemind')
        UNION ALL
        (SELECT 'hivemind only', tbl, row_text FROM ci_output WHERE source = 'hivemind'
         EXCEPT ALL
         SELECT 'hivemind only', tbl, row_text FROM ci_output WHERE source = 'internal')
    ) AS d;
    IF _n > 0 THEN
        RAISE EXCEPTION E'hivemind source: % row(s) differ from the internal source over the same blocks:\n  %', _n, _diff;
    END IF;

    IF EXISTS (SELECT 1 FROM haf_stats_backend.comment_registry WHERE author_id BETWEEN 47001 AND 47010) THEN
        RAISE EXCEPTION 'hivemind source: comment_registry has rows after a hivemind-sourced run; it must stay empty';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ci_internal_post_engagement) THEN
        RAISE EXCEPTION 'hivemind source: the internal run wrote no post_engagement row; the check below would prove nothing';
    END IF;
    IF EXISTS (SELECT 1 FROM haf_stats_backend.post_engagement WHERE author_id BETWEEN 47001 AND 47010) THEN
        RAISE EXCEPTION 'hivemind source: post_engagement has rows after a hivemind-sourced run; it must stay empty';
    END IF;

    RAISE NOTICE 'hivemind source: % output rows identical to the internal source (content volume, account content, community activity, author cohorts, engagement rollup); comment_registry and post_engagement untouched',
        (SELECT COUNT(*) FROM ci_output WHERE source = 'hivemind');
END
$equal$;

-- The upgrade: a hivemind deployment that still holds post_engagement (here, the internal run's
-- rows) gets the rollup rebuilt from hivemind, to the same rows, and the table emptied. On the
-- internal source, and while hivemind is not usable, it is left alone. The rollup is spoiled
-- first, so a rebuild that never ran fails.
INSERT INTO haf_stats_backend.post_engagement SELECT * FROM ci_internal_post_engagement;
UPDATE haf_stats_backend.engagement_period_counts SET sum_votes = -1 WHERE period >= DATE '2019-09-30';

DO $retire$
DECLARE
    _diff TEXT;
BEGIN
    UPDATE haf_stats_app.content_source_config SET source = 'internal';
    PERFORM haf_stats_app.retire_post_engagement();
    IF (SELECT COUNT(*) FROM haf_stats_backend.post_engagement WHERE author_id BETWEEN 47001 AND 47010)
       <> (SELECT COUNT(*) FROM ci_internal_post_engagement) THEN
        RAISE EXCEPTION 'hivemind source: retire_post_engagement emptied post_engagement on the internal source';
    END IF;

    -- hivemind behind the processed blocks: kept, without waiting.
    UPDATE haf_stats_app.content_source_config SET source = 'hivemind';
    UPDATE hafd.contexts SET current_block_num = 0 WHERE name = 'hivemind_app';
    PERFORM haf_stats_app.retire_post_engagement();
    IF NOT EXISTS (SELECT 1 FROM haf_stats_backend.post_engagement) THEN
        RAISE EXCEPTION 'hivemind source: retire_post_engagement emptied post_engagement while hivemind was not usable';
    END IF;
    IF current_setting('haf_stats.hivemind_wait_timeout', TRUE) IS DISTINCT FROM '' THEN
        RAISE EXCEPTION 'hivemind source: retire_post_engagement left haf_stats.hivemind_wait_timeout at %',
            current_setting('haf_stats.hivemind_wait_timeout', TRUE);
    END IF;
    UPDATE hafd.contexts SET current_block_num = 37500045 WHERE name = 'hivemind_app';

    PERFORM haf_stats_app.retire_post_engagement();
    IF EXISTS (SELECT 1 FROM haf_stats_backend.post_engagement) THEN
        RAISE EXCEPTION 'hivemind source: retire_post_engagement left post_engagement rows on the hivemind source';
    END IF;

    SELECT string_agg(format('%s: %s', d.side, d.row_text), ', ' ORDER BY d.side, d.row_text) INTO _diff
    FROM (
        (SELECT 'expected' AS side, row_text FROM ci_output WHERE source = 'internal' AND tbl = 'engagement_period_counts'
         EXCEPT ALL
         SELECT 'expected', t::TEXT FROM haf_stats_backend.engagement_period_counts t WHERE t.period >= DATE '2019-09-30')
        UNION ALL
        (SELECT 'got', t::TEXT FROM haf_stats_backend.engagement_period_counts t WHERE t.period >= DATE '2019-09-30'
         EXCEPT ALL
         SELECT 'got', row_text FROM ci_output WHERE source = 'internal' AND tbl = 'engagement_period_counts')
    ) AS d;
    IF _diff IS NOT NULL THEN
        RAISE EXCEPTION 'hivemind source: the rollup retire_post_engagement rebuilt differs from the internal source''s: %', _diff;
    END IF;

    RAISE NOTICE 'hivemind source: retire_post_engagement rebuilt the engagement rollup from hivemind and emptied post_engagement; a no-op on the internal source';
END
$retire$;

-- ---------------------------------------------------------------------------
-- 3. The clamp. The per-range body is replaced, for this transaction, by one that records the
--    range it was given and then lets hivemind advance by ten blocks.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE ci_ranges (first_block INT NOT NULL, last_block INT NOT NULL, hivemind_head INT NOT NULL);

CREATE OR REPLACE FUNCTION haf_stats_app.process_content_stats_range(
    _first_block INT,
    _last_block INT,
    _hivemind BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
BEGIN
    INSERT INTO ci_ranges
    SELECT _first_block, _last_block, c.current_block_num FROM hafd.contexts AS c WHERE c.name = 'hivemind_app';
    UPDATE hafd.contexts SET current_block_num = current_block_num + 10 WHERE name = 'hivemind_app';
END;
$fn$;

UPDATE hafd.contexts SET current_block_num = 37500019 WHERE name = 'hivemind_app';
SELECT haf_stats_app.process_content_stats(37500001, 37500045);

DO $clamp$
DECLARE
    _got TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM ci_ranges WHERE last_block > hivemind_head) THEN
        RAISE EXCEPTION 'hivemind source: a content-stats batch ended past hivemind''s head: %',
            (SELECT string_agg(format('%s..%s (head %s)', first_block, last_block, hivemind_head), ', ' ORDER BY first_block) FROM ci_ranges);
    END IF;
    SELECT string_agg(format('%s..%s', first_block, last_block), ', ' ORDER BY first_block) INTO _got FROM ci_ranges;
    IF _got IS DISTINCT FROM '37500001..37500019, 37500020..37500029, 37500030..37500039, 37500040..37500045' THEN
        RAISE EXCEPTION 'hivemind source: expected the range in the four pieces hivemind had reached, got %', _got;
    END IF;
    RAISE NOTICE 'hivemind source: clamp verified (%)', _got;
END
$clamp$;

-- ---------------------------------------------------------------------------
-- 4. The wait
-- ---------------------------------------------------------------------------
SET LOCAL haf_stats.hivemind_wait_timeout = '1';

DO $wait$
DECLARE
    _ranges_before CONSTANT BIGINT := (SELECT COUNT(*) FROM ci_ranges);
BEGIN
    -- hivemind below the first block: nothing to process, so it waits, and does not fall back.
    UPDATE hafd.contexts SET current_block_num = 37500000 WHERE name = 'hivemind_app';
    BEGIN
        PERFORM haf_stats_app.process_content_stats(37500001, 37500045);
        RAISE EXCEPTION 'ci: no wait';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%hivemind has not reached block 37500001 (usable through 37500000)%' THEN
            RAISE;
        END IF;
    END;
    IF (SELECT COUNT(*) FROM ci_ranges) <> _ranges_before THEN
        RAISE EXCEPTION 'hivemind source: a range was processed while hivemind was behind it';
    END IF;

    -- hivemind's completion marker caps its context head.
    UPDATE hafd.contexts SET current_block_num = 37500045 WHERE name = 'hivemind_app';
    CREATE TABLE hivemind_app.hive_state (last_completed_block_num INT NOT NULL);
    INSERT INTO hivemind_app.hive_state VALUES (37500030);
    IF haf_stats_app.wait_for_hivemind(37500001) <> 37500030 THEN
        RAISE EXCEPTION 'hivemind source: usable head % ignores hive_state.last_completed_block_num 37500030',
            haf_stats_app.wait_for_hivemind(37500001);
    END IF;

    -- Without the block_num_created index (hivemind's massive sync drops it) nothing is usable.
    DROP INDEX hivemind_app.ci_hive_posts_block_num_created;
    BEGIN
        PERFORM haf_stats_app.wait_for_hivemind(37500001);
        RAISE EXCEPTION 'ci: no wait without the index';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%hivemind has not reached block 37500001 (usable through 0)%' THEN
            RAISE;
        END IF;
    END;

    -- No context row is an error, not a wait.
    DELETE FROM hafd.contexts WHERE name = 'hivemind_app';
    BEGIN
        PERFORM haf_stats_app.wait_for_hivemind(37500001);
        RAISE EXCEPTION 'ci: no context accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%no hivemind_app context%' THEN
            RAISE;
        END IF;
    END;

    RAISE NOTICE 'hivemind source: wait verified (behind -> waits, completion marker and missing index hold it back, no context -> error)';
END
$wait$;

ROLLBACK;
