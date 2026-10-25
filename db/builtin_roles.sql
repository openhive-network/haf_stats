DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_owner') THEN
    -- INHERIT (like btracker_owner) so that, as a member of
    -- hive_applications_owner_group, the owner can INSERT/UPDATE hafd.contexts
    -- when creating the HAF context and advancing the block pointer in main().
    -- A NOINHERIT owner fails context creation with "permission denied for table contexts".
    CREATE ROLE haf_stats_owner LOGIN INHERIT;
  ELSIF NOT (SELECT rolinherit FROM pg_roles WHERE rolname = 'haf_stats_owner') THEN
    -- Repair an earlier install that created the role as NOINHERIT. Only then: an
    -- installer that is a member of the app roles but not their admin (no CREATEROLE)
    -- may not ALTER the role, and has nothing to repair when it is already INHERIT.
    ALTER ROLE haf_stats_owner INHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_user') THEN
    CREATE ROLE haf_stats_user LOGIN NOINHERIT;
  END IF;
END
$$;

-- Memberships, applied atomically.
--
-- haf_stats_owner joins the HAF app group so it can read hafd.* and write hafd.contexts
-- (same pattern as btracker_owner); a NOINHERIT owner here fails context creation with
-- "permission denied for table contexts". REVOKE+GRANT rather than a bare GRANT
-- refreshes the membership's inherit flag from the now-INHERIT role: PG16+ freezes that
-- flag at GRANT time, so a membership first created while the role was NOINHERIT would
-- otherwise stay non-inheriting on re-install. On a fresh install the REVOKE is a no-op.
--
-- Each edge is touched only when it is missing or does not inherit. An installer that is a
-- member of the app roles but not their admin (no ADMIN option on the group, no CREATEROLE)
-- may neither REVOKE nor GRANT them, and where the shared HAF provisioned the roles there is
-- nothing to repair. pg_auth_members.inherit_option is PostgreSQL 16+; it is read through
-- to_jsonb() so the block also runs on 14/15, where a membership inherits by the member's
-- rolinherit, which the block above has just made INHERIT.
--
-- The whole set lives in one DO block because a DO block is a single statement, hence a
-- single transaction, and scripts/common.sh runs psql without --single-transaction. As
-- separate top-level statements the REVOKE committed on its own, leaving a window in
-- which haf_stats_owner was outside hive_applications_group. That window is not benign:
-- the owner keeps its direct hafd grants (below), so a read of hafd.contexts inside it
-- raises no error - RLS simply returns zero rows - and any PostgREST connection that
-- planned haf_stats_app.sync_status()'s query there caches a zero-row plan and keeps
-- serving it after the membership is restored. Role changes do not invalidate cached
-- plans; only DISCARD PLANS or a pool recycle recovers. haf-stats-setup re-runs
-- install_app.sh on every stack start. On a COLD `compose up` the API is transitively
-- gated on setup (haf-stats-process depends_on haf-stats-setup
-- service_completed_successfully, and haf-stats-api in turn depends_on
-- haf-stats-process), so the window is not reachable there - but `compose up -d` against a
-- running stack does NOT restart an already-up haf-stats-api, and that container keeps
-- serving from its existing pool across the re-install. That is the reachable case.
DO $$
BEGIN
    -- Guarded for the same reason the assertions below are: pg_has_role()/REVOKE/GRANT all
    -- raise 42704 on an unknown role. Without this the REVOKE aborts step 1 of the install
    -- on a non-HAF database with a bare 'role does not exist', and the deliberately-worded
    -- diagnostic further down never gets the chance to run - making that branch dead code.
    IF to_regrole('hive_applications_owner_group') IS NULL THEN
        RAISE WARNING 'hive_applications_owner_group does not exist - skipping the haf_stats_owner group membership. The block processor cannot write hafd.contexts and GET /sync-status will answer 503 until HAF is installed.';
    ELSIF NOT EXISTS (
        SELECT FROM pg_auth_members AS a
        WHERE a.roleid = 'hive_applications_owner_group'::regrole
          AND a.member = 'haf_stats_owner'::regrole
          AND COALESCE((to_jsonb(a) ->> 'inherit_option')::boolean, TRUE)
    ) THEN
        EXECUTE 'REVOKE hive_applications_owner_group FROM haf_stats_owner';
        EXECUTE 'GRANT hive_applications_owner_group TO haf_stats_owner';
    END IF;

    -- haf_stats_user is readable by haf_stats_owner (owner inherits user perms). Same
    -- PG16+ inherit-flag freeze applies, so refresh this one too.
    IF NOT EXISTS (
        SELECT FROM pg_auth_members AS a
        WHERE a.roleid = 'haf_stats_user'::regrole
          AND a.member = 'haf_stats_owner'::regrole
          AND COALESCE((to_jsonb(a) ->> 'inherit_option')::boolean, TRUE)
    ) THEN
        REVOKE haf_stats_user FROM haf_stats_owner;
        GRANT haf_stats_user TO haf_stats_owner;
    END IF;

    -- haf_admin (HAF superrole) owns haf_stats_owner
    IF NOT EXISTS (
        SELECT FROM pg_auth_members AS a
        WHERE a.roleid = 'haf_stats_owner'::regrole
          AND a.member = 'haf_admin'::regrole
    ) THEN
        GRANT haf_stats_owner TO haf_admin;
    END IF;
END
$$;

-- Direct schema access for the API role, which cannot rely on group-inherited
-- privileges. Do NOT restate this node's role flags as a property of haf_stats: the
-- CREATE ROLE above is guarded by IF NOT EXISTS and has no repair branch, so whoever
-- created the role first decided its flags. Where this file created it, haf_stats_user
-- is NOINHERIT. testapi's was created INHERIT, and IN hive_applications_group, by an
-- unmerged revision of this file (9a77508); the block after these grants takes it out of
-- that group again (#88), and leaves the flag as found. These direct grants hold either
-- way, which is the point of stating them explicitly; granted to the owner too. (HAF's
-- own create_haf_app_role.sh does not grant that edge: its default group is
-- hive_applications_owner_group, the OWNER's. An earlier revision said otherwise.)
--
-- Granted only by an installer that holds the schema's USAGE WITH GRANT OPTION: HAF's
-- owner (haf_admin) or a superuser, as docker/docker-compose.yml's haf-stats-setup and
-- every CI lane install. Any other installer can grant none of it -- PostgreSQL only warns for the
-- objects it can read, and refuses outright (42501) the first hive function it cannot
-- execute -- so it skips the grants and warns for each role left unable to read the
-- schema. In a clone of the shared HAF the consumer installs; haf_stats_owner reads
-- through hive_applications_owner_group there, haf_stats_user does not.
DO $$
DECLARE
    _role text;
    _schema text;
    _unreadable bigint;
BEGIN
    IF has_schema_privilege('hafd', 'USAGE WITH GRANT OPTION') THEN
        GRANT USAGE ON SCHEMA hafd TO haf_stats_owner;
        GRANT SELECT ON ALL TABLES IN SCHEMA hafd TO haf_stats_owner;
        GRANT USAGE ON SCHEMA hafd TO haf_stats_user;
        GRANT SELECT ON ALL TABLES IN SCHEMA hafd TO haf_stats_user;
    END IF;
    IF has_schema_privilege('hive', 'USAGE WITH GRANT OPTION') THEN
        GRANT USAGE ON SCHEMA hive TO haf_stats_owner;
        GRANT SELECT ON ALL TABLES IN SCHEMA hive TO haf_stats_owner;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA hive TO haf_stats_owner;
        GRANT USAGE ON SCHEMA hive TO haf_stats_user;
        GRANT SELECT ON ALL TABLES IN SCHEMA hive TO haf_stats_user;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA hive TO haf_stats_user;
    END IF;

    FOREACH _schema IN ARRAY ARRAY['hafd', 'hive'] LOOP
        CONTINUE WHEN has_schema_privilege(_schema, 'USAGE WITH GRANT OPTION');
        FOREACH _role IN ARRAY ARRAY['haf_stats_owner', 'haf_stats_user'] LOOP
            SELECT count(*) INTO _unreadable
            FROM pg_class AS c
            WHERE c.relnamespace = _schema::regnamespace
              AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND NOT has_table_privilege(_role, c.oid, 'SELECT');
            IF NOT has_schema_privilege(_role, _schema, 'USAGE') OR _unreadable > 0 THEN
                RAISE WARNING '% cannot read schema % (USAGE: %, tables without SELECT: %), and % (the installing role) may not grant it: run db/builtin_roles.sql as the schema''s owner or a superuser.',
                    _role, _schema, has_schema_privilege(_role, _schema, 'USAGE'), _unreadable, current_user;
            END IF;
        END LOOP;
    END LOOP;
END
$$;

-- Take the API role OUT of the HAF application groups. (#88)
--
-- haf_stats_user is the role PostgREST connects as for unauthenticated requests, and
-- hive_applications_group carries TRUNCATE on hafd.contexts -- which row-level security
-- does not cover -- plus CREATE on schema hafd. Nothing haf_stats serves needs it: every
-- read the API role makes is granted directly above, and GET /sync-status goes through the
-- SECURITY DEFINER haf_stats_app.sync_status().
--
-- This file has never granted that membership -- except once. 9a77508 (2026-05-30, on the
-- unmerged ci/endpoint-tests branch) created the role "LOGIN INHERIT IN ROLE
-- hive_applications_group", and because the CREATE is IF NOT EXISTS with no repair branch,
-- a node that ran it kept the edge. testapi's role matches it exactly -- INHERIT, with that
-- direct edge -- and nothing else creates the role that way (develop's CREATE is NOINHERIT,
-- HAF's create_haf_app_role.sh defaults to the owner group), so that is almost certainly
-- where testapi's edge came from; the grantor alone cannot tell. Other apps put their own API roles in this
-- group on purpose (balance_tracker's btracker_user, for one); the TABLE grant that makes
-- the group dangerous is HAF's, and closing it there is hive/haf#348.
--
-- Removes a DIRECT edge to either group, whoever granted it. GRANTED BY the recorded
-- grantor because on PostgreSQL 16+ a REVOKE removes only the grant made by the named
-- grantor, and refuses (with a warning) one that does not match; PostgreSQL 14/15 parse
-- the clause, ignore it, and remove the edge regardless. CI runs 14, so the 16+ grantor
-- path is exercised on nodes (testapi runs 17), not in the install lane. Idempotent: with
-- no edge the loop does nothing. Never fatal: a REVOKE this login may not make becomes a
-- WARNING, and the probe below still reports whatever is left.
--
-- testapi's haf_stats health check had to stop connecting as haf_stats_user first:
-- hive.get_app_current_block_age() is SECURITY INVOKER, and outside the group RLS hides the
-- context row -- measured, the check's own query then returned 1790500864 s. It connects as
-- haf_stats_owner now, which is what haf_fyp's check already did after haf_fyp!41.
DO $$
DECLARE
    _edge record;
BEGIN
    IF to_regrole('hive_applications_group') IS NULL THEN
        RETURN;
    END IF;
    FOR _edge IN
        SELECT g.rolname AS grp, gr.rolname AS grantor
        FROM pg_auth_members AS a
        INNER JOIN pg_roles AS g ON a.roleid = g.oid
        INNER JOIN pg_roles AS gr ON a.grantor = gr.oid
        WHERE a.member = 'haf_stats_user'::regrole
          AND g.rolname IN ('hive_applications_group', 'hive_applications_owner_group')
    LOOP
        BEGIN
            EXECUTE format('REVOKE %I FROM haf_stats_user GRANTED BY %I', _edge.grp, _edge.grantor);
            RAISE NOTICE 'haf_stats_user removed from % (granted by %): the PostgREST anon role does not need it', _edge.grp, _edge.grantor;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'could not remove haf_stats_user from % (granted by %): %', _edge.grp, _edge.grantor, SQLERRM;
        END;
    END LOOP;
END
$$;

-- Install-time assertions for GET /sync-status (#55).
--
-- The asymmetry is deliberate. The owner side is a hard failure: without that
-- membership, RLS on hafd.contexts hides every row from haf_stats_app.sync_status()
-- with no error at all, so /sync-status answers 503 on a healthy node and the block
-- processor cannot advance the context. The user side is a warning: the block above has
-- just removed any direct membership, so reaching it means a REVOKE was refused or the
-- privilege arrives some other way -- and the SECURITY DEFINER is correct either way, so
-- this is a security-posture problem, not a correctness one, and must not stop an install.
DO $$
BEGIN
    -- to_regrole() first: pg_has_role() RAISES 42704 on an unknown role, which would abort
    -- step 1 of the install with a bare 'role does not exist' instead of the message below.
    IF to_regrole('hive_applications_group') IS NULL THEN
        RAISE WARNING 'hive_applications_group does not exist on this database - skipping the haf_stats_owner membership check. This is not a HAF database, or HAF renamed the group.';
    ELSIF NOT pg_has_role('haf_stats_owner', 'hive_applications_group', 'USAGE') THEN
        RAISE EXCEPTION 'haf_stats_owner does not INHERIT hive_applications_group. Row-level security on hafd.contexts will silently hide every row from haf_stats_app.sync_status() (GET /sync-status answers 503 on a healthy node), and the block processor cannot UPDATE the context. Check pg_auth_members.inherit_option for haf_stats_owner -> hive_applications_owner_group.';
    END IF;

    -- MEMBER, not USAGE. Both are transitive, but USAGE asks "do the privileges arrive by
    -- inheritance", and for a NOINHERIT role -- which is what this file creates -- the
    -- answer is no even when it IS a member. Measured with a NOINHERIT haf_stats_user after
    -- granting it the group directly: USAGE false, has_table_privilege(...,'TRUNCATE')
    -- false, MEMBER true. The role can still SET ROLE into the group and take every privilege,
    -- so the USAGE form reported "contained" for exactly the leak it exists to find.
    -- (Same trap found independently in haf_fyp!42, measured on PG14.) has_table_privilege
    -- is kept as a second, independent probe: it catches a direct grant on the table that
    -- bypasses the group entirely, which no membership check would see.
    --
    -- This fires only if the block above could not do its job: a REVOKE was refused (it
    -- warned), or the privilege arrives some other way -- a direct grant on the table, or a
    -- group other than the two it removes. (#88) An earlier revision of this comment called
    -- REVOKE hive_applications_group "a measured no-op ... because the real edge is the
    -- owner_group one", and told operators to revoke hive_applications_owner_group instead.
    -- On testapi it was the other way round, and the edge came from this repo, not from HAF.
    -- Same guard on both probes: has_table_privilege() RAISES on an absent relation, which
    -- would turn this deliberately-a-warning branch into a hard install failure.
    IF to_regrole('hive_applications_group') IS NOT NULL
       AND (pg_has_role('haf_stats_user', 'hive_applications_group', 'MEMBER')
            OR (to_regclass('hafd.contexts') IS NOT NULL
                AND has_table_privilege('haf_stats_user', 'hafd.contexts', 'TRUNCATE'))) THEN
        RAISE WARNING 'haf_stats_user (the PostgREST anon role) can still reach hive_applications_group, or TRUNCATE hafd.contexts directly, after the installer removed its direct memberships of the HAF application groups. Row-level security does not cover TRUNCATE, so that is enough to wipe every co-located HAF app''s context registration. Check pg_auth_members for a remaining path to the group, and has_table_privilege for a direct grant on the table: haf_stats needs neither, because GET /sync-status goes through the SECURITY DEFINER haf_stats_app.sync_status(). The group''s TRUNCATE grant itself is HAF''s: hive/haf#348.';
    END IF;
END
$$;

-- The API's 30 s statement budget. (#94)
--
-- This role setting caps API queries in every deployment -- measured on PostgREST v12.2.3:
--
--   PostgREST logs in AS haf_stats_user    applied at login. That is the haf_api_node stack,
--                                          whose PgBouncer rejects options=statement_timeout
--                                          (hive/haf_api_node!244), and testapi, whose URI
--                                          carries none.
--   PostgREST logs in as haf_stats_owner   this repo's docker-compose.yml. PostgREST applies
--   and switches roles                     the settings of every role its login role is a
--                                          member of to each request, so this OVERRIDES the
--                                          options= on PGRST_DB_URI there, in both directions.
--
-- The sibling apps do the same (on testapi: btracker_user and hafbe_user 10s, hafah_user
-- 15s, hivemind_user 5000 ms); haf_stats' endpoints are heavier, hence 30 s.
--
-- NOT on haf_stats_owner: the block processor logs in as the owner and its batches
-- legitimately run long. install-test asserts the owner LOGS IN with 0.
--
-- Headroom, from testapi's PostgreSQL log (2026-07-14 .. 09-16, every call of >= 1 s):
-- the slowest PostgREST calls into haf_stats_endpoints took 21.9 s, 21.7 s and 21.5 s.
-- The one call of 30 s or more took 48.8 s, 48.4 s of it waiting for the lock the 03:30 UTC
-- refresh_top_accounts_alltime() held while it used TRUNCATE. It no longer takes a lock
-- a reader waits for (#95).
--
-- Set on every install unless the role already carries it, so a reinstall restores the
-- shipped budget, and an installer without CREATEROLE (which may not ALTER the role) passes
-- where it is already in place. Where PostgREST logs in as haf_stats_user, ALTER ROLE
-- haf_stats_user IN DATABASE <db> SET statement_timeout = ... takes precedence over this
-- and survives reinstall.
--
-- Kept at the END of the file on purpose: tests/ci_install_verify.sql,
-- tests/ci_haf_stub.sql and scripts/check_haf_drift.sh cite lines of this file by NUMBER,
-- and inserting this beside the CREATE ROLE would re-point most of them.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_roles
        WHERE rolname = 'haf_stats_user' AND 'statement_timeout=30s' = ANY(rolconfig)
    ) THEN
        ALTER ROLE haf_stats_user SET statement_timeout = '30s';
    END IF;
END
$$;
