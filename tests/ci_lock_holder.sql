-- An install must not queue readers behind an ACCESS EXCLUSIVE lock. (#96)
--
-- Runs in install-test beside `install-under-lock`: this session holds ACCESS SHARE -- what a
-- get_network_top_accounts request holds while it reads -- on every table a db/ migration touches,
-- and watches pg_locks until that install is past every migrating file.
--
-- The guarded migrations (db/schema_migration.sql) ask the catalog first and run no DDL when the
-- upgrade is already applied, so nothing requests a conflicting lock. An unguarded
-- `ALTER TABLE ... IF [NOT] EXISTS` requests ACCESS EXCLUSIVE before it evaluates that clause, so
-- it appears here as an ungranted request -- and readers arriving after it queue behind it (#95).
-- ACCESS EXCLUSIVE is the only mode that conflicts with ACCESS SHARE, so it is the only mode that
-- can wait behind this session, and the only one that makes readers queue.
--
-- WHEN TO STOP is decided by a marker, not by watching for activity. install_app.sh runs
-- db/process_top_accounts_alltime.sql after every file that calls apply_schema_migration, and that
-- file drops and recreates haf_stats_app.refresh_top_accounts_alltime(), so the function's OID
-- changes exactly when the install is past the last migration (tests/unit/test_ddl_lock_guard.py
-- pins that ordering). An earlier version sampled pg_stat_activity instead; an install under lock
-- runs in well under a second, so four polls a second could miss it entirely and fail the lane
-- for nothing.
--
-- It fails if a reader-blocking request appears, or if the marker has not changed by the deadline
-- (no install ran, or it is stuck). It cannot pass while an install is still stuck, because a
-- stuck install never reaches the marker.
--
-- The tables are listed twice -- the LOCK below and the compose healthcheck -- and
-- tests/unit/test_ddl_lock_guard.py asserts both equal the set of tables the guarded DDL actually
-- names, so a migration on a seventh table cannot slip past unwatched. The watch list inside the
-- DO block is read back from this session's own locks rather than written a third time.
--
-- Held in one transaction and rolled back.

\set ON_ERROR_STOP on

BEGIN;

-- The marker's OID is taken BEFORE the locks exist, so before the healthcheck can pass and
-- install-under-lock can start: the install cannot move it first.
DO $marker$
DECLARE
    _oid OID;
BEGIN
    SELECT p.oid INTO _oid
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'haf_stats_app' AND p.proname = 'refresh_top_accounts_alltime' AND p.pronargs = 0;
    IF _oid IS NULL THEN
        RAISE EXCEPTION 'LOCK: marker haf_stats_app.refresh_top_accounts_alltime() is missing before the install - the lane order is wrong';
    END IF;
    PERFORM set_config('ci_lock_holder.marker', _oid::TEXT, TRUE);
END;
$marker$;

LOCK TABLE
    haf_stats_backend.account_financial_daily,
    haf_stats_backend.active_users_daily,
    haf_stats_backend.comment_registry,
    haf_stats_backend.account_custom_json_daily,
    haf_stats_backend.account_cohort_retention,
    haf_stats_backend.author_cohort_retention,
    haf_stats_backend.network_op_daily,
    haf_stats_backend.network_custom_json_daily,
    haf_stats_app.app_config
IN ACCESS SHARE MODE;

DO $watch$
DECLARE
    _marker_before CONSTANT OID := current_setting('ci_lock_holder.marker')::OID;
    _deadline CONSTANT TIMESTAMPTZ := clock_timestamp() + INTERVAL '90 seconds';
    _db CONSTANT OID := (SELECT d.oid FROM pg_database AS d WHERE d.datname = current_database());
    _watched OID[];
    _marker_now OID;
    _blocked TEXT;
BEGIN
    -- What the LOCK above took: every haf_stats_backend table this session holds ACCESS SHARE on.
    SELECT array_agg(l.relation) INTO _watched
    FROM pg_locks AS l
    JOIN pg_class AS c ON c.oid = l.relation
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE l.pid = pg_backend_pid() AND l.locktype = 'relation' AND l.mode = 'AccessShareLock'
      AND l.granted AND n.nspname = 'haf_stats_backend' AND c.relkind IN ('r', 'p');
    IF _watched IS NULL THEN
        RAISE EXCEPTION 'LOCK: this session holds no lock on a haf_stats_backend table, so it watches nothing';
    END IF;

    LOOP
        SELECT string_agg(DISTINCT l.relation::REGCLASS::TEXT, ', ') INTO _blocked
        FROM pg_locks AS l
        WHERE NOT l.granted
          AND l.locktype = 'relation'
          AND l.mode = 'AccessExclusiveLock'
          AND l.database = _db
          AND l.relation = ANY (_watched);
        IF _blocked IS NOT NULL THEN
            RAISE EXCEPTION 'LOCK: an install queued READERS behind it: AccessExclusiveLock on % waiting', _blocked
                USING HINT = 'A db/ migration asked for ACCESS EXCLUSIVE. Guard it with haf_stats_app.apply_schema_migration so it takes no lock when the upgrade is already applied.';
        END IF;

        -- A fresh statement, so a fresh snapshot of pg_proc (this block is VOLATILE, READ COMMITTED).
        SELECT p.oid INTO _marker_now
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'haf_stats_app' AND p.proname = 'refresh_top_accounts_alltime' AND p.pronargs = 0;
        EXIT WHEN _marker_now IS DISTINCT FROM _marker_before;

        IF clock_timestamp() > _deadline THEN
            RAISE EXCEPTION 'LOCK: no install got past the migrating files within 90 s'
                USING HINT = 'Either install-under-lock never ran an install, or the install is stuck (its log says where), or db/process_top_accounts_alltime.sql no longer DROPs the function before re-creating it, so its OID no longer changes.';
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;

    RAISE NOTICE 'lock holder: held ACCESS SHARE on % migrated tables until the install was past every migration; nothing requested a lock that queues readers', cardinality(_watched);
END;
$watch$;

ROLLBACK;
