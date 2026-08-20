-- Behavioural privilege and source probes for GET /sync-status (#55).
--
-- Runs LAST in the stub lane's setup chain (docker/docker-compose-ci.yml), as postgres,
-- after the endpoints and grants exist. Every check is an assertion: psql runs the chain
-- with ON_ERROR_STOP=1, so a RAISE EXCEPTION here fails the job.
--
-- These cover what no other lane does. The tavern suite talks HTTP and can only see the
-- wire shape; the real-data lane runs behind the heavy sync job; and the install-time
-- assertion in scripts/install_app.sh never executes here because the stub lane does not
-- run install_app.sh. What is under test is the chain between the anon role and the data:
-- the EXECUTE grant, the SECURITY DEFINER hop, the definer owner's group membership, and
-- HAF's RLS policy on hafd.contexts (all modelled in tests/ci_setup.sql).
--
-- The central failure mode is silent. A role outside hive_applications_group does not get
-- an error from hafd.contexts, it gets ZERO ROWS. So these assert on row counts and on the
-- reported number, never merely on "the call did not throw".

-- ---------------------------------------------------------------------------
-- (a) The definer hop works for the anon role, and returns the CONTEXT value.
-- ---------------------------------------------------------------------------
SET ROLE haf_stats_user;
DO $$
DECLARE
    _n INT;
BEGIN
    SELECT s.context_block_num INTO _n FROM haf_stats_app.sync_status() AS s;

    IF _n IS NULL THEN
        RAISE EXCEPTION 'haf_stats_app.sync_status() returned no row as haf_stats_user. Expect haf_stats_owner (the definer owner) to be missing hive_applications_group, so RLS on hafd.contexts hides every row with no error (db/builtin_roles.sql; pg_auth_members.inherit_option).';
    END IF;

    IF _n <> 6000 THEN
        RAISE EXCEPTION 'sync_status().context_block_num = %, expected the fixture context head 6000', _n;
    END IF;
END
$$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- (b) SOURCE DISCRIMINATION — the assertion that fails if anyone reverts
--     /sync-status to haf_stats_app.app_status.
--
-- The fixture already discriminates on its own: the context sits at 6000 while app_status
-- carries a far higher head by the time this file runs (tests/ci_setup.sql seeds it at 0,
-- then tests/mainnet_community_fixture.sql raises it past 37.5M for the community oracle),
-- so a reverted endpoint reports that head here instead. Mutating both makes the intent
-- explicit and pins which number came from which table.
-- ---------------------------------------------------------------------------
BEGIN;
UPDATE hafd.contexts SET current_block_num = 5999 WHERE name = 'haf_stats';
UPDATE haf_stats_app.app_status SET last_processed_block = 123;
SET ROLE haf_stats_user;
DO $$
DECLARE
    _j JSON;
BEGIN
    _j := haf_stats_endpoints.get_sync_status();

    IF (_j ->> 'last_block_num')::INT <> 5999 THEN
        RAISE EXCEPTION 'get_sync_status().last_block_num = %, expected the CONTEXT value 5999 (issue #55). It is reading haf_stats_app.app_status (123).', _j ->> 'last_block_num';
    END IF;

    -- The wire shape stays byte-compatible with hafbe and haf_fyp: exactly two keys.
    -- (json_object_keys rather than the ? operator, which only exists for jsonb.)
    IF (SELECT array_agg(k ORDER BY k) FROM json_object_keys(_j) AS k)
       <> ARRAY['last_block_num', 'last_block_time'] THEN
        RAISE EXCEPTION 'get_sync_status() returned keys %, expected exactly last_block_num and last_block_time', (SELECT array_agg(k ORDER BY k) FROM json_object_keys(_j) AS k);
    END IF;
END
$$;
RESET ROLE;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (c) An invisible context must raise 53000 (-> HTTP 503), never 200 with a
--     body of `null`. Renaming models exactly what the function sees when the
--     context is absent OR filtered away by RLS.
-- ---------------------------------------------------------------------------
BEGIN;
UPDATE hafd.contexts SET name = 'haf_stats_gone' WHERE name = 'haf_stats';
SET ROLE haf_stats_user;
DO $$
BEGIN
    PERFORM haf_stats_endpoints.get_sync_status();
    RAISE EXCEPTION 'get_sync_status() returned a body with no context row: PostgREST would serve HTTP 200 with `null`, hiding a privilege misconfiguration behind a healthy-looking response.';
EXCEPTION WHEN SQLSTATE '53000' THEN
    NULL;  -- expected
END
$$;
RESET ROLE;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (d) The massive-sync guard is executed, not dead code. It fires in no other
--     lane, so without this it could rot unnoticed.
-- ---------------------------------------------------------------------------
BEGIN;
UPDATE hive.ci_instance_state SET is_ready = FALSE;
SET ROLE haf_stats_user;
DO $$
BEGIN
    PERFORM haf_stats_endpoints.get_sync_status();
    RAISE EXCEPTION 'get_sync_status() answered while the HAF instance reports not-ready; the massive-sync guard did not fire.';
EXCEPTION WHEN SQLSTATE '53000' THEN
    NULL;  -- expected
END
$$;
RESET ROLE;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (e) row_security is USERSET, so a caller can turn it off. The definer pins it;
--     without that pin this call fails with "query would be affected by
--     row-level security policy for table contexts".
-- ---------------------------------------------------------------------------
SET ROLE haf_stats_user;
SET row_security = off;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM haf_stats_app.sync_status()) THEN
        RAISE EXCEPTION 'sync_status() lost its rows under row_security = off; add SET row_security = on to db/sync_status.sql';
    END IF;
END
$$;
RESET row_security;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- (f) Negative: the anon role still cannot reach hafd.contexts directly, and the
--     definer is neither superuser-owned nor PUBLIC-callable.
-- ---------------------------------------------------------------------------
SET ROLE haf_stats_user;
DO $$
DECLARE
    _direct INT;
BEGIN
    SELECT count(*) INTO _direct FROM hafd.contexts;
    IF _direct <> 0 THEN
        RAISE EXCEPTION 'haf_stats_user can read % row(s) of hafd.contexts directly; the SECURITY DEFINER exists precisely so it does not need to, and table-level access here means the RLS model has drifted.', _direct;
    END IF;
END
$$;
RESET ROLE;

DO $$
BEGIN
    -- MEMBER, not USAGE: haf_stats_user is NOINHERIT, and USAGE asks whether privileges
    -- arrive by inheritance - which is false for a NOINHERIT member even though it can
    -- SET ROLE into the group and take them all. Measured on the live node: after
    -- GRANT hive_applications_group TO haf_stats_user, USAGE is false and
    -- has_table_privilege(...,'TRUNCATE') is false, while MEMBER is true. A USAGE probe
    -- therefore passes on precisely the leak it exists to catch, which is why this
    -- assertion could be granted away without going red.
    IF pg_has_role('haf_stats_user', 'hive_applications_group', 'MEMBER') THEN
        RAISE EXCEPTION 'haf_stats_user is a member of hive_applications_group, which on a real node grants TRUNCATE on hafd.contexts (not gated by RLS) and CREATE on schema hafd to the unauthenticated PostgREST role. NOINHERIT does not contain this: the role can SET ROLE into the group and take every privilege.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'haf_stats_app'
          AND p.proname = 'sync_status'
          AND p.prosecdef
          AND p.proowner = 'haf_stats_owner'::regrole
          AND p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp']
          AND p.proconfig @> ARRAY['row_security=on']
    ) THEN
        RAISE EXCEPTION 'haf_stats_app.sync_status() is not a SECURITY DEFINER owned by haf_stats_owner with a pinned search_path and row_security. Installed as a superuser without the ALTER FUNCTION ... OWNER TO in db/sync_status.sql, it would execute as that superuser.';
    END IF;

    IF has_function_privilege('public', 'haf_stats_app.sync_status()', 'EXECUTE') THEN
        RAISE EXCEPTION 'PUBLIC can EXECUTE haf_stats_app.sync_status(); the REVOKE in db/sync_status.sql was lost (a DROP FUNCTION restores the default PUBLIC grant).';
    END IF;
END
$$;
