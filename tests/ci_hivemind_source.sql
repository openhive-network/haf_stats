-- The hivemind content source (db/process_content_stats.sql, "Content source"), run for real in
-- the stub lane over tests/community_fixture.sql's synthetic content and the hivemind_app double
-- tests/hivemind_oracle_fixture.sql holds for it (one hive_posts row per creation, deletes and
-- re-creations included).
--
--   1. select_content_source: auto picks a readable hivemind, keeps a recorded source, treats a
--      deployment that processed blocks without a record as internal, refuses a switch on one
--      that has processed blocks unless asked to, and refuses hivemind it cannot read.
--   2. Equality: the content processors over the same blocks produce the same content volume,
--      account content, community activity, author cohorts and engagement from either source,
--      and the hivemind source writes no comment_registry row.
--   3. The clamp: while hivemind has reached only part of a range, none of it is processed;
--      once hivemind has reached all of it, it is processed as one range. Waiting first and
--      reading after is what keeps the wait from holding locks on hivemind's tables (#118;
--      tests/ci_hivemind_wait_locks.sql checks the locks themselves).
--   4. The wait: below hivemind's head nothing is processed and nothing falls back; it waits
--      (here bounded by haf_stats.hivemind_wait_timeout into an error). hivemind's completion
--      marker and a missing block_num_created index hold it back too; an error reading the
--      marker is raised, not taken for "no marker".
--   5. The block drivers' check (#123): while hivemind is behind a range, require_content_source
--      raises 55H18 at once and hivemind_behind says how far hivemind is usable; neither waits.
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

CREATE FUNCTION pg_temp.ci_capture(_source TEXT)
RETURNS VOID
LANGUAGE sql
AS $fn$
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
    SELECT _source, 'post_engagement', t::TEXT FROM haf_stats_backend.post_engagement t
    WHERE t.author_id BETWEEN 47001 AND 47010
    UNION ALL
    SELECT _source, 'engagement_touched_days', t::TEXT FROM haf_stats_backend.engagement_touched_days t
    UNION ALL
    SELECT _source, 'author_cohort_members', t::TEXT FROM haf_stats_backend.author_cohort_members t
    WHERE t.account_id BETWEEN 47001 AND 47010;
$fn$;

DELETE FROM haf_stats_app.content_source_config;
SELECT pg_temp.ci_reset_content();
SELECT pg_temp.ci_run_content();
SELECT pg_temp.ci_capture('internal');

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
                                'account_community_daily', 'post_engagement', 'engagement_touched_days',
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

    RAISE NOTICE 'hivemind source: % output rows identical to the internal source (content volume, account content, community activity, author cohorts, engagement); comment_registry untouched',
        (SELECT COUNT(*) FROM ci_output WHERE source = 'hivemind');
END
$equal$;

-- ---------------------------------------------------------------------------
-- 3. The clamp. The per-range body is replaced, for this transaction, by one that records the
--    range it was given and hivemind's head at that moment. It also counts its calls on a
--    sequence: a call made before a wait times out is rolled back with the error, rows and
--    all, but a sequence does not roll back.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE ci_ranges (first_block INT NOT NULL, last_block INT NOT NULL, hivemind_head INT NOT NULL);
CREATE TEMP SEQUENCE ci_range_calls;

CREATE FUNCTION pg_temp.ci_range_calls()
RETURNS BIGINT
LANGUAGE sql
AS $fn$
    SELECT CASE WHEN s.is_called THEN s.last_value ELSE 0 END FROM ci_range_calls AS s;
$fn$;

CREATE OR REPLACE FUNCTION haf_stats_app.process_content_stats_range(
    _first_block INT,
    _last_block INT,
    _hivemind BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
BEGIN
    PERFORM nextval('ci_range_calls');
    INSERT INTO ci_ranges
    SELECT _first_block, _last_block, c.current_block_num FROM hafd.contexts AS c WHERE c.name = 'hivemind_app';
END;
$fn$;

SET LOCAL haf_stats.hivemind_wait_timeout = '1';

DO $clamp$
DECLARE
    _got TEXT;
BEGIN
    -- hivemind through 37500019 of 37500001..37500045: it waits for the rest, and processes
    -- nothing meanwhile, not even the part hivemind has reached.
    UPDATE hafd.contexts SET current_block_num = 37500019 WHERE name = 'hivemind_app';
    BEGIN
        PERFORM haf_stats_app.process_content_stats(37500001, 37500045);
        RAISE EXCEPTION 'ci: no wait';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%hivemind has not reached block 37500045 (usable through 37500019)%' THEN
            RAISE;
        END IF;
    END;
    IF pg_temp.ci_range_calls() <> 0 THEN
        RAISE EXCEPTION 'hivemind source: % range(s) processed while hivemind was only through 37500019; nothing may be read before hivemind has the whole range',
            pg_temp.ci_range_calls();
    END IF;

    -- hivemind past the whole range: the range as one, ending at its own last block, not at
    -- hivemind's head.
    UPDATE hafd.contexts SET current_block_num = 37500050 WHERE name = 'hivemind_app';
    PERFORM haf_stats_app.process_content_stats(37500001, 37500045);
    IF EXISTS (SELECT 1 FROM ci_ranges WHERE last_block > hivemind_head) THEN
        RAISE EXCEPTION 'hivemind source: a content-stats batch ended past hivemind''s head: %',
            (SELECT string_agg(format('%s..%s (head %s)', first_block, last_block, hivemind_head), ', ' ORDER BY first_block) FROM ci_ranges);
    END IF;
    SELECT string_agg(format('%s..%s', first_block, last_block), ', ' ORDER BY first_block) INTO _got FROM ci_ranges;
    IF _got IS DISTINCT FROM '37500001..37500045' THEN
        RAISE EXCEPTION 'hivemind source: expected the range as one, once hivemind had reached all of it, got %', _got;
    END IF;
    RAISE NOTICE 'hivemind source: clamp verified (nothing while hivemind was partway; then %)', _got;
END
$clamp$;

-- ---------------------------------------------------------------------------
-- 4. The wait
-- ---------------------------------------------------------------------------

DO $wait$
DECLARE
    _calls_before CONSTANT BIGINT := pg_temp.ci_range_calls();
BEGIN
    -- hivemind below the first block: nothing to process, so it waits, and does not fall back.
    UPDATE hafd.contexts SET current_block_num = 37500000 WHERE name = 'hivemind_app';
    BEGIN
        PERFORM haf_stats_app.process_content_stats(37500001, 37500045);
        RAISE EXCEPTION 'ci: no wait';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%hivemind has not reached block 37500045 (usable through 37500000)%' THEN
            RAISE;
        END IF;
    END;
    IF pg_temp.ci_range_calls() <> _calls_before THEN
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

    -- An error reading hive_state is raised, not taken for "no marker": swallowed, the head
    -- would go uncapped and the source would read rows hivemind has not finished writing.
    ALTER TABLE hivemind_app.hive_state RENAME COLUMN last_completed_block_num TO ci_renamed;
    BEGIN
        PERFORM haf_stats_app.wait_for_hivemind(37500001);
        RAISE EXCEPTION 'ci: a failed hive_state read was swallowed';
    EXCEPTION WHEN undefined_column THEN
        NULL;
    END;
    ALTER TABLE hivemind_app.hive_state RENAME COLUMN ci_renamed TO last_completed_block_num;

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

    RAISE NOTICE 'hivemind source: wait verified (behind -> waits, completion marker and missing index hold it back, a hive_state read error and no context -> errors)';
END
$wait$;

-- ---------------------------------------------------------------------------
-- 5. The block drivers' check (#123): require_content_source, which process_blocks calls
--    first, and hivemind_behind, which main() calls. Neither waits: while hivemind is behind
--    the range they report it at once -- require_content_source as SQLSTATE 55H18, the code
--    haf_app_driver.py retries (tests/ci_driver_hivemind_retry.py) -- and once hivemind has
--    reached it they let it through. The timeout is long, so a check that waited would be
--    seen taking seconds and then raising the wait's own error.
-- ---------------------------------------------------------------------------

DO $gate$
DECLARE
    _started TIMESTAMPTZ;
    _state TEXT;
    _message TEXT;
BEGIN
    SET LOCAL haf_stats.hivemind_wait_timeout = '30';

    -- The internal source never reads hivemind, so it is never behind -- even with no hivemind
    -- context at all (section 4 deleted it).
    DELETE FROM haf_stats_app.content_source_config;
    INSERT INTO haf_stats_app.content_source_config (source) VALUES ('internal');
    IF haf_stats_app.hivemind_behind(37500045) IS NOT NULL THEN
        RAISE EXCEPTION 'hivemind check: the internal source reported hivemind behind (%)', haf_stats_app.hivemind_behind(37500045);
    END IF;
    PERFORM haf_stats_app.require_content_source(37500001, 37500045);

    -- hivemind's context at the range's end, its completion marker at 37500030.
    DELETE FROM haf_stats_app.content_source_config;
    INSERT INTO haf_stats_app.content_source_config (source) VALUES ('hivemind');
    INSERT INTO hafd.contexts (name, current_block_num, irreversible_block)
    VALUES ('hivemind_app', 37500045, 37500045);
    CREATE INDEX ci_hive_posts_block_num_created ON hivemind_app.hive_posts (block_num_created);
    UPDATE hivemind_app.hive_state SET last_completed_block_num = 37500030;

    _started := clock_timestamp();
    BEGIN
        PERFORM haf_stats_app.require_content_source(37500001, 37500045);
        _state := 'none';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS _state = RETURNED_SQLSTATE, _message = MESSAGE_TEXT;
    END;
    IF _state IS DISTINCT FROM '55H18'
       OR _message NOT LIKE '%hivemind has not reached block 37500045 (usable through 37500030); blocks 37500001..37500045 are left for a retry%' THEN
        RAISE EXCEPTION 'hivemind check: hivemind behind the range must raise 55H18 naming the range and 37500030, got % (%)', _state, _message;
    END IF;
    IF clock_timestamp() - _started > INTERVAL '2 seconds' THEN
        RAISE EXCEPTION 'hivemind check: require_content_source took % to report hivemind behind; it must not wait', clock_timestamp() - _started;
    END IF;
    IF haf_stats_app.hivemind_behind(37500045) IS DISTINCT FROM 37500030 THEN
        RAISE EXCEPTION 'hivemind check: hivemind_behind(37500045) must be 37500030, got %', haf_stats_app.hivemind_behind(37500045);
    END IF;

    -- Without the block_num_created index nothing is usable.
    DROP INDEX hivemind_app.ci_hive_posts_block_num_created;
    IF haf_stats_app.hivemind_behind(37500001) IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'hivemind check: without the block_num_created index hivemind_behind(37500001) must be 0, got %', haf_stats_app.hivemind_behind(37500001);
    END IF;
    CREATE INDEX ci_hive_posts_block_num_created ON hivemind_app.hive_posts (block_num_created);

    -- One block short is still behind; the range's last block is through, from both.
    UPDATE hivemind_app.hive_state SET last_completed_block_num = 37500044;
    IF haf_stats_app.hivemind_behind(37500045) IS DISTINCT FROM 37500044 THEN
        RAISE EXCEPTION 'hivemind check: hivemind one block short must be behind at 37500044, got %', haf_stats_app.hivemind_behind(37500045);
    END IF;
    UPDATE hivemind_app.hive_state SET last_completed_block_num = 37500045;
    IF haf_stats_app.hivemind_behind(37500045) IS NOT NULL THEN
        RAISE EXCEPTION 'hivemind check: hivemind at the range''s end still reported behind (%)', haf_stats_app.hivemind_behind(37500045);
    END IF;
    PERFORM haf_stats_app.require_content_source(37500001, 37500045);

    -- No hivemind context is a configuration error, not something to retry: not 55H18.
    DELETE FROM hafd.contexts WHERE name = 'hivemind_app';
    BEGIN
        PERFORM haf_stats_app.require_content_source(37500001, 37500045);
        _state := 'none';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS _state = RETURNED_SQLSTATE, _message = MESSAGE_TEXT;
    END;
    IF _state IS DISTINCT FROM 'P0001' OR _message NOT LIKE '%no hivemind_app context%' THEN
        RAISE EXCEPTION 'hivemind check: no hivemind context must raise P0001 "no hivemind_app context", got % (%)', _state, _message;
    END IF;

    RAISE NOTICE 'hivemind source: block-driver check verified (internal -> through; behind -> 55H18 at once; missing index -> 0; reached -> through; no context -> P0001)';
END
$gate$;

ROLLBACK;
