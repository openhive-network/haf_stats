-- The processor sessions' half of HAF's application lock (#157): the legacy CALL
-- haf_stats_app.main() loop's session, and each worker connection the parallel massive sync
-- (scripts/haf_stats_parallel.py) opens. Run by scripts/process_blocks.sh in the SAME psql
-- session as the CALL, before it, so the session holds the lock for as long as the loop runs.
-- Each statement is its own transaction there (psql autocommit); a worker sends the file as
-- one query string. Either way the setting and the advisory lock are session-level and
-- outlive the transaction. The install-test lane runs this file against a real server, with
-- and without HAF's lock functions.

-- bash is PID 1 in the processor container and ignores SIGTERM, so `docker stop` ends in
-- SIGKILL, and a backend busy in main() does not notice its client is gone: it would keep
-- the lock, and every later install would skip, exit 0 and apply nothing. With this the
-- backend ends within seconds of its client. PostgreSQL 14+ only, hence the guard. PERFORM, in
-- a DO block, so the processor's log gets no result table; not psql's \o, which a worker's
-- single query string cannot carry.
DO $$
BEGIN
    IF CURRENT_SETTING('server_version_num')::INT >= 140000 THEN
        PERFORM SET_CONFIG('client_connection_check_interval', '10s', FALSE);
    END IF;
END
$$;

-- The shared lock install_app.sh takes exclusively, the same as the driver's --lock. Waits
-- while an install holds it. HAF before 1.28.8 has no lock functions: there the loop runs
-- unlocked, as it always has.
DO $$
BEGIN
    IF TO_REGPROCEDURE('hive.acquire_app_block_processor_locks(text[])') IS NOT NULL THEN
        PERFORM hive.acquire_app_block_processor_locks(ARRAY['haf_stats']);
    END IF;
END
$$;
