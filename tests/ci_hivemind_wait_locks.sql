-- While the hivemind content source waits for hivemind, it must hold no lock on hivemind's
-- tables, and it must stop waiting once hivemind has caught up. (#118)
--
-- The wait (wait_for_hivemind) sleeps inside the block driver's transaction. Since #123 the
-- drivers check hivemind before the batch and retry it later, so the block path reaches this
-- wait only when hivemind goes back after that check (tests/ci_driver_hivemind_retry.py covers
-- the check). Any lock that transaction took on a hivemind table before the wait is held
-- through the sleep. hivemind
-- drops hive_posts' foreign keys (ACCESS EXCLUSIVE, no lock_timeout) whenever it enters
-- massive sync, which is exactly when haf_stats waits for it, so such a lock means both wait
-- on each other forever, and every hive_posts reader (hivemind's API included) queues behind
-- hivemind's pending request.
--
-- A second connection runs process_content_stats over a range hivemind has only partly
-- reached. Once it sleeps, this session checks pg_locks for any lock it holds on a
-- hivemind_app relation, and a third connection must get ACCESS EXCLUSIVE on hive_posts within
-- lock_timeout, as hivemind's ALTER TABLE would. Then hivemind's completion marker is moved
-- past the range, and the second connection's call must return without an error.
-- (That the range is then processed, and as one, is ci_hivemind_source.sql section 3.)
--
-- Twice: once for process_content_stats alone, and once for the first batch outside massive
-- sync with deferred refreshes recorded (#126). That batch starts as main() and process_blocks()
-- start it, with prepare_rollup_refreshes(FALSE), in the same transaction and before the range,
-- and the content refresh massive sync deferred includes the engagement drain, which on this
-- source reads hivemind; so that drain, too, must wait for the range's hivemind wait. After the
-- batch the deferral record and the staged creation-days must be gone: the drain ran in it.
--
-- The other connections must see the fixture, so the setup is committed and undone at the
-- end; the result is recorded and raised only after the cleanup. dblink connects over the
-- server's local socket (see tests/ci_alltime_refresh.sql), and is dropped again only if this
-- file created it.
\set ON_ERROR_STOP on

CREATE TABLE public.ci118_saved AS
SELECT
    (SELECT COALESCE(MAX(last_processed_block), 0) FROM haf_stats_app.app_status) AS last_processed_block,
    (SELECT array_agg(source) FROM haf_stats_app.content_source_config) AS sources,
    EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') AS had_dblink;
CREATE TABLE public.ci118_result (failure TEXT);
CREATE TABLE public.ci118_saved_deferred AS SELECT * FROM haf_stats_app.deferred_rollup_refreshes;
CREATE TABLE public.ci118_saved_touched AS SELECT * FROM haf_stats_backend.engagement_touched_days;

CREATE EXTENSION IF NOT EXISTS dblink;

-- hivemind as far as block 37500030 of the 37500001..37500045 range below: its context is at
-- the range's end, but its completion marker (hive_state, which the wait reads on every pass)
-- is at 37500030. The index the source reads hive_posts by; the source recorded as hivemind;
-- nothing processed yet. The stub has no hive_state, so creating it fails loudly if one exists.
CREATE INDEX ci118_hive_posts_block_num_created ON hivemind_app.hive_posts (block_num_created);
CREATE TABLE hivemind_app.hive_state (last_completed_block_num INT NOT NULL);
INSERT INTO hivemind_app.hive_state VALUES (37500030);
INSERT INTO hafd.contexts (name, current_block_num, irreversible_block)
VALUES ('hivemind_app', 37500045, 37500045);
DELETE FROM haf_stats_app.content_source_config;
INSERT INTO haf_stats_app.content_source_config (source) VALUES ('hivemind');
UPDATE haf_stats_app.app_status SET last_processed_block = 0;

-- One batch in the waiter connection: _start (synchronously, if not NULL), then the range,
-- which must wait for hivemind holding no hivemind_app lock; once hivemind completes the range,
-- _after (if not NULL) runs in the same transaction and returns the failure it finds, or NULL.
-- Records the first failure under _scenario. The waiter's transaction is never committed.
CREATE FUNCTION pg_temp.ci118_batch(_scenario TEXT, _start TEXT, _after TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $locks$
DECLARE
    _pid INT;
    _event TEXT;
    _held TEXT;
    _ddl TEXT;
    _found TEXT;
    _samples INT := 0;
    _deadline TIMESTAMPTZ := clock_timestamp() + INTERVAL '60 seconds';
BEGIN
    PERFORM dblink_connect('ci118_waiter', 'dbname=haf_block_log user=postgres application_name=ci118_waiter');
    SELECT r.pid INTO _pid FROM dblink('ci118_waiter', 'SELECT pg_backend_pid()') AS r(pid INT);
    -- One transaction, as the block driver runs it; the timeout only bounds a broken run.
    PERFORM dblink_exec('ci118_waiter', 'BEGIN');
    PERFORM dblink_exec('ci118_waiter', 'SET LOCAL haf_stats.hivemind_wait_timeout = ''120''');

    BEGIN
        IF _start IS NOT NULL THEN
            PERFORM r.v FROM dblink('ci118_waiter', _start) AS r(v TEXT);
        END IF;
        PERFORM dblink_send_query('ci118_waiter', 'SELECT haf_stats_app.process_content_stats(37500001, 37500045)');

        -- Sample the waiter's locks while it sleeps. It wakes once a second to read hivemind's
        -- progress, so a sample is kept only if it is still asleep after it.
        LOOP
            LOOP
                PERFORM pg_stat_clear_snapshot();
                SELECT a.wait_event INTO _event FROM pg_stat_activity AS a WHERE a.pid = _pid;
                EXIT WHEN _event = 'PgSleep';
                IF dblink_is_busy('ci118_waiter') = 0 THEN
                    RAISE EXCEPTION 'process_content_stats returned instead of waiting for hivemind (usable through 37500030): %',
                        COALESCE(dblink_error_message('ci118_waiter'), 'no error');
                END IF;
                IF clock_timestamp() > _deadline THEN
                    RAISE EXCEPTION 'process_content_stats did not start waiting for hivemind within 60 s (wait_event %)', _event;
                END IF;
                PERFORM pg_sleep(0.2);
            END LOOP;

            SELECT string_agg(format('%s %s%s', c.relname, l.mode, CASE WHEN l.granted THEN '' ELSE ' (waiting)' END), ', ' ORDER BY c.relname)
            INTO _held
            FROM pg_locks AS l
            JOIN pg_class AS c ON c.oid = l.relation
            JOIN pg_namespace AS n ON n.oid = c.relnamespace
            WHERE l.pid = _pid AND n.nspname = 'hivemind_app';

            PERFORM pg_stat_clear_snapshot();
            SELECT a.wait_event INTO _event FROM pg_stat_activity AS a WHERE a.pid = _pid;
            _samples := _samples + 1;
            EXIT WHEN _event = 'PgSleep' OR _samples >= 5;
        END LOOP;
        IF _held IS NOT NULL THEN
            RAISE EXCEPTION 'while waiting for hivemind, process_content_stats holds locks on hivemind_app: %', _held;
        END IF;

        -- What hivemind's massive sync does to hive_posts, under a lock_timeout it does not have.
        PERFORM dblink_connect('ci118_ddl', 'dbname=haf_block_log user=postgres application_name=ci118_ddl');
        PERFORM dblink_exec('ci118_ddl', 'SET lock_timeout = ''3s''');
        IF dblink_exec('ci118_ddl', 'ALTER TABLE hivemind_app.hive_posts DROP CONSTRAINT IF EXISTS ci118_none', FALSE) = 'ERROR' THEN
            _ddl := dblink_error_message('ci118_ddl');
        END IF;
        IF _ddl IS NOT NULL THEN
            RAISE EXCEPTION 'while process_content_stats waits for hivemind, ALTER TABLE hivemind_app.hive_posts cannot get its lock: %', _ddl;
        END IF;

        IF dblink_is_busy('ci118_waiter') = 0 THEN
            RAISE EXCEPTION 'process_content_stats stopped waiting while hivemind was still behind the range';
        END IF;

        -- hivemind completes the range: the wait must notice and the range be processed.
        PERFORM dblink_exec('ci118_ddl', 'UPDATE hivemind_app.hive_state SET last_completed_block_num = 37500045');
        PERFORM dblink_disconnect('ci118_ddl');
        _deadline := clock_timestamp() + INTERVAL '60 seconds';
        WHILE dblink_is_busy('ci118_waiter') = 1 LOOP
            IF clock_timestamp() > _deadline THEN
                RAISE EXCEPTION 'process_content_stats kept waiting for 60 s after hivemind completed the range';
            END IF;
            PERFORM pg_sleep(0.2);
        END LOOP;
        -- Raises the waiter's error, if it failed.
        PERFORM r.v FROM dblink_get_result('ci118_waiter') AS r(v TEXT);
        IF _after IS NOT NULL THEN
            -- The async call's end of results, so the connection takes another query.
            PERFORM r.v FROM dblink_get_result('ci118_waiter') AS r(v TEXT);
            SELECT r.v INTO _found FROM dblink('ci118_waiter', _after) AS r(v TEXT);
            IF _found IS NOT NULL THEN
                RAISE EXCEPTION '%', _found;
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.ci118_result VALUES (_scenario || ': ' || SQLERRM);
    END;

    -- Stop the waiter if it is still running; its transaction goes with the connection.
    IF dblink_is_busy('ci118_waiter') = 1 THEN
        PERFORM dblink_cancel_query('ci118_waiter');
    END IF;
    PERFORM dblink_disconnect('ci118_waiter');
    IF 'ci118_ddl' = ANY (dblink_get_connections()) THEN
        PERFORM dblink_disconnect('ci118_ddl');
    END IF;
END
$locks$;

SELECT pg_temp.ci118_batch('process_content_stats', NULL, NULL);

-- The first batch outside massive sync: block 37500000 processed, the content refreshes recorded
-- from its day, and a creation-day staged for the engagement drain, as massive sync leaves them;
-- hivemind again only through block 37500030.
UPDATE hivemind_app.hive_state SET last_completed_block_num = 37500030;
UPDATE haf_stats_app.app_status SET last_processed_block = 37500000;
DELETE FROM haf_stats_app.deferred_rollup_refreshes;
INSERT INTO haf_stats_app.deferred_rollup_refreshes (processor, dirty_from)
SELECT 'process_content_stats', b.created_at::DATE FROM hafd.blocks AS b WHERE b.num = 37500000;
INSERT INTO haf_stats_backend.engagement_touched_days (day)
SELECT b.created_at::DATE FROM hafd.blocks AS b WHERE b.num = 37500001
ON CONFLICT (day) DO NOTHING;

SELECT pg_temp.ci118_batch(
    'the first batch outside massive sync',
    'SELECT haf_stats_app.prepare_rollup_refreshes(FALSE)::TEXT',
    $after$
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM haf_stats_app.deferred_rollup_refreshes)
            THEN 'the batch left deferred refreshes recorded: '
                 || (SELECT string_agg(d.processor, ', ' ORDER BY d.processor) FROM haf_stats_app.deferred_rollup_refreshes AS d)
        WHEN EXISTS (SELECT 1 FROM haf_stats_backend.engagement_touched_days)
            THEN 'the batch did not drain engagement_touched_days'
    END
    $after$);

UPDATE haf_stats_app.app_status SET last_processed_block = (SELECT last_processed_block FROM public.ci118_saved);
DELETE FROM haf_stats_app.deferred_rollup_refreshes;
INSERT INTO haf_stats_app.deferred_rollup_refreshes SELECT * FROM public.ci118_saved_deferred;
DELETE FROM haf_stats_backend.engagement_touched_days;
INSERT INTO haf_stats_backend.engagement_touched_days SELECT * FROM public.ci118_saved_touched;
DELETE FROM haf_stats_app.content_source_config;
INSERT INTO haf_stats_app.content_source_config (source)
SELECT unnest(sources) FROM public.ci118_saved WHERE sources IS NOT NULL;
DELETE FROM hafd.contexts WHERE name = 'hivemind_app';
DROP INDEX hivemind_app.ci118_hive_posts_block_num_created;
DROP TABLE hivemind_app.hive_state;
DO $dblink$
BEGIN
    IF NOT (SELECT had_dblink FROM public.ci118_saved) THEN
        DROP EXTENSION dblink;
    END IF;
END
$dblink$;

DO $report$
DECLARE
    _failure TEXT := (SELECT string_agg(failure, '; ') FROM public.ci118_result);
BEGIN
    DROP TABLE public.ci118_saved;
    DROP TABLE public.ci118_saved_deferred;
    DROP TABLE public.ci118_saved_touched;
    DROP TABLE public.ci118_result;
    IF _failure IS NOT NULL THEN
        RAISE EXCEPTION 'hivemind source (#118): %', _failure;
    END IF;
    RAISE NOTICE 'hivemind source: waiting for hivemind holds no lock on hivemind_app, in process_content_stats and in the first batch outside massive sync; hive_posts DDL is not blocked; the wait ends without an error once hivemind completes the range, and that batch then runs its deferred engagement drain';
END
$report$;
