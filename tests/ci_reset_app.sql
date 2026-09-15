-- Wipe every trace of the app, so the next install takes the CREATE path. (#78)
--
-- Run TWICE: once in db-setup, once between the upgrade check and `install`.
--
-- THE SECOND CALL IS THE POINT. Without it the baseline install takes the create path and
-- `install` takes the "already exists" early return -- so every assertion about what an
-- install CREATES (the context owner, is_forking/is_attached, the three schemas,
-- swagger_base_url, db/builtin_roles.sql's CREATE ROLE arms) is satisfied by the MERGE
-- TARGET rather than by the commit under test, and passes either way.
--
-- The bystander context (ci_bystander_app) is deliberately NOT touched: it exists to
-- prove the teardown is scoped, and re-inserting it here would defeat that.

DELETE FROM hafd.contexts WHERE name = 'haf_stats';

DROP SCHEMA IF EXISTS haf_stats_app, haf_stats_backend, haf_stats_endpoints CASCADE;

-- tests/ci_setup.sql creates haf_stats_owner and haf_stats_user, makes the owner INHERIT
-- and grants it hive_applications_owner_group -- it is written for the endpoint-tests
-- lane, where it SUBSTITUTES for an install. Left in place it makes most of
-- db/builtin_roles.sql unfalsifiable: the CREATE ROLE arms never run, and the install-time
-- assertion that haf_stats_owner holds hive_applications_group is satisfied by the fixture.
--
-- DROP OWNED BY must come first: the roles hold grants and ALTER DEFAULT PRIVILEGES
-- entries that DROP ROLE alone refuses to step over. It also RAISES 42704 on a role that
-- does not exist, where DROP ROLE has an IF EXISTS -- hence the guard.
--
-- Safe here and ONLY here: roles are CLUSTER-wide. This runs against a throwaway
-- postgres:14-alpine container with nothing else in it. Never point it at a real cluster.
DO $reset$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_owner') THEN
        EXECUTE 'DROP OWNED BY haf_stats_owner CASCADE';
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_user') THEN
        EXECUTE 'DROP OWNED BY haf_stats_user CASCADE';
    END IF;
END
$reset$;

DROP ROLE IF EXISTS haf_stats_owner;
DROP ROLE IF EXISTS haf_stats_user;

DO $check$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname IN ('haf_stats_owner', 'haf_stats_user')) THEN
        RAISE EXCEPTION 'ci_reset_app: the app roles survived the reset, so db/builtin_roles.sql will take its repair arms instead of creating them';
    END IF;
    IF EXISTS (SELECT FROM pg_namespace WHERE nspname LIKE 'haf_stats%') THEN
        RAISE EXCEPTION 'ci_reset_app: a haf_stats schema survived the reset';
    END IF;
    IF EXISTS (SELECT FROM hafd.contexts WHERE name = 'haf_stats') THEN
        RAISE EXCEPTION 'ci_reset_app: the haf_stats context survived the reset';
    END IF;
    RAISE NOTICE 'ci_reset_app: schemas, roles and context gone -- the next install must create them itself';
END
$check$;

-- THE RUN COUNTER, which is what makes the second call's ABSENCE detectable.
--
-- Delete the reset-app SERVICE and every downstream assertion still passes on its own:
-- `install` just takes the "already exists" branch, and the owner, schemas and pointer
-- all still check out. So leave positive evidence that BOTH calls happened.
--
-- COUNTING, not OID ordering. An earlier attempt compared haf_stats_app's oid against
-- this table's, reasoning that a higher one meant the schema was created after the reset.
-- That was inert, because this file runs TWICE: db-setup creates the marker first, so
-- the baseline's schema already has a higher oid than it, and the comparison passed with
-- reset-app deleted. A row per run cannot be satisfied by the wrong caller.
CREATE TABLE IF NOT EXISTS public.ci_reset_marker (run_at TIMESTAMPTZ NOT NULL DEFAULT now());
INSERT INTO public.ci_reset_marker DEFAULT VALUES;
