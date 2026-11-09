-- db/register_app.sql registers haf_stats under each hive.app_register signature it
-- accepts, and only under those. (#151)
--
-- Runs in install-test's verify service, as postgres, after the REAL installer has created
-- the haf_stats context and haf_stats_app.process_blocks(hive.blocks_range). The stub HAF
-- (tests/ci_haf_stub.sql) has no application registry, so every install in this lane takes
-- register_app.sql's warning path; this file supplies one per arm, runs the shipped
-- db/register_app.sql against it, and ROLLBACKs, so uninstall and verify-gone see the install
-- exactly as it was.
--
-- Arms:
--   (a) haf#454's five-parameter app_register  -> registered, and the driver path is taken
--   (b) haf#341's four-parameter app_register  -> registered, and the driver path is taken
--   (c) a three-parameter app_register         -> not registered, and the install continues
--
-- (a) is the one that fails when the probe pins only the four-parameter signature: the
-- registry is then reported unusable and no row appears. (c) is what keeps the probe exact:
-- a bare name lookup would accept it and fail the PERFORM.
--
-- The stub registry is a transcription of the parts of HAF develop's app_registry.sql that
-- decide whether a row is written (context exists, process procedure resolves), not of
-- ownership policy, which this file does not test.
--
-- psql -v register_app_file=<db/register_app.sql>: a variable rather than a literal path in
-- the \i, so the compose replay can rewrite it as it does every other mounted path.

\set ON_ERROR_STOP on

-- Created outside the arms' transactions so they survive each ROLLBACK.
CREATE FUNCTION pg_temp.stub_registry(_params TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
BEGIN
    CREATE TABLE hafd.applications (
        name TEXT PRIMARY KEY,
        contexts TEXT[] NOT NULL,
        process_procedure TEXT,
        owner NAME NOT NULL
    );
    GRANT SELECT, INSERT, UPDATE ON hafd.applications TO haf_stats_owner;

    -- The first three parameters are named and ordered as HAF's; the call under test uses
    -- only those three.
    EXECUTE FORMAT($ddl$
        CREATE FUNCTION hive.app_register(%s)
        RETURNS VOID
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            IF EXISTS (SELECT 1 FROM unnest(_contexts) AS c
                        WHERE NOT EXISTS (SELECT 1 FROM hafd.contexts hc WHERE hc.name = c)) THEN
                RAISE EXCEPTION 'Cannot register application %%: a context does not exist', _name;
            END IF;
            IF _process_procedure IS NOT NULL
               AND to_regprocedure(_process_procedure || '( hive.blocks_range )') IS NULL THEN
                RAISE EXCEPTION 'Cannot register application %%: procedure %%( hive.blocks_range ) does not exist',
                    _name, _process_procedure;
            END IF;
            INSERT INTO hafd.applications (name, contexts, process_procedure, owner)
            VALUES (_name, _contexts::TEXT[], _process_procedure, current_user)
            ON CONFLICT (name) DO UPDATE
            SET contexts = EXCLUDED.contexts, process_procedure = EXCLUDED.process_procedure;
        END;
        $body$
    $ddl$, _params);
END;
$fn$;

-- What a registered install must show: the row register_app.sql writes, owned by the role
-- that owns the context, AND scripts/process_blocks.sh's registry_has_haf_stats() answer
-- for it -- its second query, verbatim -- so "registered" means "the driver path is taken".
CREATE FUNCTION pg_temp.assert_registered(_arm TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    _proc  TEXT;
    _owner NAME;
BEGIN
    SELECT process_procedure, owner INTO _proc, _owner
      FROM hafd.applications WHERE name = 'haf_stats';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'register_app (%): no haf_stats row in hafd.applications -- db/register_app.sql judged this hive.app_register signature unusable', _arm;
    END IF;
    IF _proc IS DISTINCT FROM 'haf_stats_app.process_blocks' THEN
        RAISE EXCEPTION 'register_app (%): entry procedure is %, expected haf_stats_app.process_blocks', _arm, _proc;
    END IF;
    IF _owner <> 'haf_stats_owner' THEN
        RAISE EXCEPTION 'register_app (%): row owned by %, expected haf_stats_owner', _arm, _owner;
    END IF;
    IF NOT (SELECT EXISTS (SELECT 1 FROM hafd.applications WHERE name = 'haf_stats' AND process_procedure IS NOT NULL AND to_regprocedure(process_procedure || '( hive.blocks_range )') IS NOT NULL)) THEN
        RAISE EXCEPTION 'register_app (%): scripts/process_blocks.sh would not take the driver path for this row', _arm;
    END IF;
    RAISE NOTICE 'register_app (%): registered, driver path taken', _arm;
END;
$fn$;

-- ------------------------------------------------- (a) haf#454: five parameters
BEGIN;
SELECT pg_temp.stub_registry('_name TEXT, _contexts hive.contexts_group, _process_procedure TEXT = NULL, _completed_block_function TEXT = NULL, _health_function TEXT = NULL');
\i :register_app_file
SELECT pg_temp.assert_registered('five-parameter app_register');
ROLLBACK;

-- ------------------------------------------------- (b) haf#341: four parameters
BEGIN;
SELECT pg_temp.stub_registry('_name TEXT, _contexts hive.contexts_group, _process_procedure TEXT = NULL, _completed_block_function TEXT = NULL');
\i :register_app_file
SELECT pg_temp.assert_registered('four-parameter app_register');
ROLLBACK;

-- ------------------------------------------------- (c) any other signature
-- The three-argument call would succeed against this one, which is the point: only the
-- exact probe refuses it, and that refusal must be the warning, not an aborted install.
BEGIN;
SELECT pg_temp.stub_registry('_name TEXT, _contexts hive.contexts_group, _process_procedure TEXT = NULL');
\i :register_app_file
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM hafd.applications) THEN
        RAISE EXCEPTION 'register_app (other signature): haf_stats was registered through an app_register signature the probe does not pin';
    END IF;
    RAISE NOTICE 'register_app (other signature): not registered, install continued';
END;
$$;
ROLLBACK;
