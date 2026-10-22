-- Sync-status reader for GET /sync-status (#55).
--
-- WHY SECURITY DEFINER, rather than letting the API role read hafd directly.
-- hafd.contexts has ROW LEVEL SECURITY enabled, and its only application SELECT policy
-- (sp_applications_hive_context) is granted TO hive_applications_group. A direct read
-- therefore requires putting the caller in that group - and that group is far more than
-- a read grant. Measured on a live HAF node:
--     has_table_privilege('hive_applications_group','hafd.contexts','TRUNCATE') = t
--     has_schema_privilege('hive_applications_group','hafd','CREATE')           = t
--     has_function_privilege(...,'hive.disable_indexes_of_irreversible()', ...) = t
-- TRUNCATE is not gated by row-level security at all, so a member can wipe every HAF
-- app's context registration on the node regardless of the policies. And that group is
-- reachable without a credential on a typical deployment: HAF's docker_entrypoint.sh
-- overwrites pg_hba.conf with the deployment's own $PG_ACCESS (commonly
-- `host haf_block_log all 0.0.0.0/0 trust`) and only appends the image's narrower default
-- as a fallback - so the trust rule is the deployment's choice, not a HAF image default.
-- haf_stats_user is the unauthenticated role PostgREST connects as, so it stays out of
-- that group: db/builtin_roles.sql never grants it, and removes it where an earlier
-- install left it -- an unmerged revision (9a77508) created the role IN that group, and
-- testapi keeps the edge until an installer carrying #88 runs there. The table grant that makes the group dangerous is
-- HAF's, and closing it there is hive/haf#348.
--
-- Membership is checked there with pg_has_role(..., 'MEMBER'), not 'USAGE': where this
-- installer created haf_stats_user it is NOINHERIT, and a NOINHERIT member reports USAGE
-- false while still being able to SET ROLE into the group and take every privilege above.
--
-- The failure mode this protects against is silent: a non-member does not get an error
-- from hafd.contexts, it gets ZERO ROWS. Confirmed as haf_stats_user outside the group -
-- SELECT count(*) FROM hafd.contexts returns 0, and hive.app_get_current_block_num()
-- (SECURITY INVOKER) fails with "Contexts {haf_stats} are not synchronized".
--
-- The read instead runs as haf_stats_owner, which is already an INHERIT member of
-- hive_applications_owner_group -> hive_applications_group because the block processor
-- must UPDATE hafd.contexts anyway; haf_stats_user gets EXECUTE on this one function.
--
-- Deliberately NOT wrapped in this repo's usual "SET ROLE haf_stats_owner; ... RESET
-- ROLE;" pattern. SET ROLE gets ownership right only on a fresh node: where an earlier
-- install left this function owned by the installing superuser, ALTER FUNCTION under
-- SET ROLE fails with "must be owner of function". Installing as the installer and
-- fixing ownership explicitly below both installs and repairs.
--
-- LANGUAGE plpgsql, not sql: an SQL body is validated at CREATE time under this
-- function's own pinned search_path, so it could not be loaded before hafd exists.
--
-- DROP + CREATE rather than CREATE OR REPLACE, because CREATE OR REPLACE cannot change
-- a RETURNS TABLE column set ("cannot change return type of existing function") and a
-- future signature change would otherwise wedge the upgrade. The DROP resets the owner
-- to the creator and restores EXECUTE to PUBLIC, which is why the ALTER/REVOKE/GRANT
-- trio below is unconditional and why the whole file is one transaction: a mid-file
-- abort must never leave a superuser-owned SECURITY DEFINER that PUBLIC can call.
BEGIN;

DROP FUNCTION IF EXISTS haf_stats_app.sync_status();

CREATE FUNCTION haf_stats_app.sync_status()
RETURNS TABLE (
    context_block_num INT,
    app_block_num INT,
    last_block_time TIMESTAMP,
    context_irreversible_block_num INT,
    haf_consistent_block_num INT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
-- Every identifier in the body is schema-qualified because this path is pinned: an
-- unqualified hafd/hive/haf_stats_app reference would resolve to nothing at RUNTIME,
-- and plpgsql does not catch that at CREATE time. pg_temp goes LAST so a caller cannot
-- shadow a function this body calls by creating pg_temp.<name>.
SET search_path = pg_catalog, pg_temp
-- row_security is USERSET. Without pinning it, any caller doing SET row_security = off
-- turns this function into "ERROR: query would be affected by row-level security policy
-- for table contexts" - a definer cannot bypass RLS, so it must forbid the override.
SET row_security = on
AS $$
BEGIN
    -- Fail fast during HAF massive sync: hafd.blocks' primary key is dropped for the
    -- duration (hive.disable_indexes_of_irreversible), so the join below would
    -- sequentially scan the largest table in the database.
    --
    -- CAVEAT, inherited from hafbe's and haf_fyp's identical guard and deliberately not
    -- papered over: hive.is_instance_ready() returns TRUE unconditionally on a
    -- pruning-enabled node, so there it never fires; pruning also deletes old
    -- hafd.blocks rows, so a context behind the prune tail produces a LEFT JOIN miss.
    IF NOT hive.is_instance_ready() THEN
        RAISE EXCEPTION 'HAF instance is not ready (massive sync in progress)'
            USING ERRCODE = '53000';
    END IF;

    -- LEFT JOIN, not inner: a context at block 0 has no hafd.blocks row (there is no
    -- block 0), so this yields ONE row with a NULL time rather than no row at all. The
    -- caller must be able to tell "healthy but at 0" (one row) from "context missing or
    -- RLS-invisible" (zero rows) - those are different HTTP statuses.
    --
    -- The OUT column names deliberately differ from the underlying ones
    -- (context_block_num vs contexts.current_block_num) and every reference below is
    -- alias-qualified, so an OUT parameter can never capture a column reference.
    --
    -- The last three columns are diagnostics; the endpoint serves only the
    -- ecosystem-uniform two keys. app_block_num is read by
    -- tests/parity/context_vs_app_status.sql - a divergence from the context pointer is
    -- the first thing to look at on a suspect node. The other two are named for what they
    -- actually hold, which is not what a caller might assume:
    --   context_irreversible_block_num = hafd.contexts.irreversible_block, this CONTEXT's
    --     own irreversible marker, which lags the node's;
    --   haf_consistent_block_num = hafd.hive_state.consistent_block, the last block HAF
    --     itself has written - NOT the chain head that hived is on. On a node whose HAF is
    --     behind, lag computed against this reads 0 while the node is millions of blocks
    --     behind the network, so it is not a substitute for a head reference.
    RETURN QUERY
    SELECT c.current_block_num,
           (SELECT COALESCE(MAX(s.last_processed_block), 0)::INT
              FROM haf_stats_app.app_status AS s),
           b.created_at,
           c.irreversible_block,
           -- MAX(), not a bare scalar subquery: as an expression the latter raises 21000
           -- if hafd.hive_state ever holds more than one row, turning GET /sync-status into a
           -- PostgREST 500. NULL is a legitimate value here (no irreversible block yet).
           (SELECT MAX(hs.consistent_block) FROM hafd.hive_state AS hs)
    FROM hafd.contexts AS c
    LEFT JOIN hafd.blocks AS b ON b.num = c.current_block_num
    WHERE c.name = 'haf_stats';
END;
$$;

-- The owner must be haf_stats_owner, never the installing superuser: install runs as
-- haf_admin (docker/docker-compose.yml) and the stub gate as postgres, so without this
-- the function would execute as a SUPERUSER and any future bug in it is a full
-- compromise. Must precede the REVOKE/GRANT so their ACL entries carry the right
-- grantor.
ALTER FUNCTION haf_stats_app.sync_status() OWNER TO haf_stats_owner;

-- PostgreSQL grants EXECUTE to PUBLIC on creation and schema haf_stats_app has no
-- ALTER DEFAULT PRIVILEGES entry, so both statements are needed. haf_stats_app is not
-- PostgREST-exposed (PGRST_DB_SCHEMA=haf_stats_endpoints), so this is not itself an RPC.
-- NEGATIVE CONTROL (#82): line removed
GRANT EXECUTE ON FUNCTION haf_stats_app.sync_status() TO haf_stats_user;

COMMIT;
