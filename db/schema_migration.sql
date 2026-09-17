-- Shared helper for the one-time schema upgrades the db/ processors carry. (#96)
--
-- Its own file because TWO chains load db/ files and they load different sets: install_app.sh
-- runs db/haf_stats_app.sql and then every processor, while the endpoint-tests stub lane
-- (docker/docker-compose-ci.yml) psql's the processor files DIRECTLY without the app file.
-- Defining it inside db/haf_stats_app.sql broke that lane with
-- `function haf_stats_app.apply_schema_migration(boolean, unknown, unknown) does not exist`.
-- Both chains load this file before the first caller, and
-- tests/unit/test_ddl_lock_guard.py asserts that for each of them.

SET ROLE haf_stats_owner;

-- ---------------------------------------------------------------------------
-- One-time schema upgrades, without an ACCESS EXCLUSIVE lock on the normal path. (#96)
--
-- The db/ files carry one-time schema upgrades for deployments that predate a column or a
-- constraint (one of them, comment_registry.community, is also how every FRESH install gets that
-- column: its CREATE TABLE does not have it). The column upgrades are ALTER TABLE ... IF [NOT]
-- EXISTS, which change nothing on a node that already has them -- but PostgreSQL takes the
-- table's ACCESS EXCLUSIVE lock BEFORE it evaluates that clause, and install_app.sh sets no
-- lock_timeout. The direction-CHECK swap in process_financial.sql was worse: its DROP CONSTRAINT
-- IF EXISTS found the canonical constraint, and ADD CONSTRAINT and VALIDATE have no IF clause, so
-- every install dropped it, re-added it and re-validated it with a full scan.
--
-- ACCESS EXCLUSIVE conflicts with a plain SELECT, so an install that runs while a slow request
-- or a processor batch holds the table waits for it, and every reader arriving after that
-- queues behind the waiting ALTER. With #94's 30 s statement_timeout on haf_stats_user that
-- surfaces as HTTP 500s -- #95's failure mode from a different statement.
-- account_financial_daily is named by the four reward and transfer metrics of
-- get_network_top_accounts (bounded ranges and the all-time default alike, since a skipped
-- UNION arm is still locked); transaction_count names active_users_daily the same way.
-- hp_balance is the only metric that names none of the six tables migrated here.
--
-- So call sites pass a catalog test with the DDL, as a SELECT (a CALL argument may not
-- contain a subquery -- SQLSTATE 0A000, measured). _needed is evaluated by the CALLER and
-- reads catalogs (pg_attribute, pg_constraint, and the relation-name lookup behind ::REGCLASS).
-- The one table lock it can take is pg_get_constraintdef() in process_financial.sql's DROP
-- guard, which opens the table with ACCESS SHARE for an instant: a reader's own lock, which
-- queues no reader (though, like any reader, it waits behind an ACCESS EXCLUSIVE holder --
-- measured: under lock_timeout 1s it times out there, while the same catalog read without it
-- returns at once).
--
--   SELECT haf_stats_app.apply_schema_migration(
--       NOT EXISTS (SELECT 1 FROM pg_attribute WHERE ...),   -- upgrade still to do?
--       'ALTER TABLE ... ADD COLUMN IF NOT EXISTS ...',      -- how to do it
--       'active_users_daily.ops');                           -- what to say in the log
--
-- Where the upgrade IS still needed the DDL runs under lock_timeout and is retried, so a busy
-- table delays the install instead of stalling readers behind it indefinitely; after the last
-- attempt it fails the install with a message naming the table.
--
-- 3 s x 10, not 30 s x 3, ON PURPOSE. Each attempt parks a conflicting request in front of the
-- table, and readers arriving behind it wait for the attempt to end. haf_stats_user's own budget
-- is 30 s (db/builtin_roles.sql), so a 30 s attempt can burn a reader's entire budget by itself.
-- Ten short attempts give ~30 s of total patience -- one reader's budget -- while capping what
-- any one reader waits at ~3 s.
--
-- lock_timeout is consulted when a lock wait BEGINS, so setting it here does bound a wait
-- started inside this call. On success the caller's value is put back, so a caller inside a
-- larger transaction does not keep 3 s for the rest of it. statement_timeout is NOT touched: it
-- is armed when the top-level statement starts, and a SET inside the function cannot disarm it.
-- The installer's logins carry none (on testapi only the API reader roles, *_user, have one);
-- a caller that does carry one sees a slow attempt cancelled (57014) rather than retried.
--
-- Where the DDL has an IF [NOT] EXISTS clause it keeps it: the catalog test is what avoids the
-- lock, the clause keeps the statement idempotent if the two ever disagree. ADD CONSTRAINT and
-- VALIDATE have no such clause, so for them the catalog test is the only thing that does.
--
-- NOT for CREATE/DROP INDEX CONCURRENTLY: EXECUTE inside a function always runs in a
-- transaction block, which CONCURRENTLY forbids. Those are already reader-safe anyway.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.apply_schema_migration;
CREATE OR REPLACE FUNCTION haf_stats_app.apply_schema_migration(
    _needed BOOLEAN,
    _ddl TEXT,
    _what TEXT,
    _lock_timeout TEXT DEFAULT '3s',
    _attempts INT DEFAULT 10
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _caller_lock_timeout CONSTANT TEXT := current_setting('lock_timeout');
BEGIN
    IF NOT _needed THEN
        RETURN;  -- already applied on this node: no DDL, no lock on the table
    END IF;

    IF _attempts IS NULL OR _attempts < 1 THEN
        RAISE EXCEPTION 'haf_stats: apply_schema_migration(%) needs _attempts >= 1, got %', _what, _attempts;
    END IF;

    FOR _try IN 1.._attempts LOOP
        BEGIN
            -- Re-issued every attempt: a failed attempt's subtransaction rolls it back with it.
            PERFORM set_config('lock_timeout', _lock_timeout, TRUE);
            EXECUTE _ddl;
            PERFORM set_config('lock_timeout', _caller_lock_timeout, TRUE);
            RAISE NOTICE 'haf_stats: schema upgrade applied: % (attempt %)', _what, _try;
            RETURN;
        EXCEPTION WHEN lock_not_available THEN
            RAISE NOTICE 'haf_stats: schema upgrade % waited % for its lock (attempt % of %)',
                _what, _lock_timeout, _try, _attempts;
        END;
    END LOOP;

    RAISE EXCEPTION 'haf_stats: schema upgrade % could not get its lock within % x %', _what, _attempts, _lock_timeout
        USING HINT = 'A long-running reader or the block processor is holding that table. Re-run the install when it is idle, or apply the statement by hand during a quiet window: ' || _ddl;
END;
$$;

-- It EXECUTEs an arbitrary SQL string, so do not leave it callable by PUBLIC (which
-- CREATE FUNCTION grants by default, and the DROP above resets). Only the owner and
-- superusers run installs; haf_stats_user must not reach it.
REVOKE EXECUTE ON FUNCTION haf_stats_app.apply_schema_migration(BOOLEAN, TEXT, TEXT, TEXT, INT) FROM public;

RESET ROLE;
