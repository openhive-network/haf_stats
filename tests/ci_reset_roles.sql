-- Reset the two app roles between the fixture and the install. (#84)
--
-- tests/ci_setup.sql creates haf_stats_owner and haf_stats_user, makes the owner INHERIT
-- and grants it hive_applications_owner_group. That is written for the endpoint-tests
-- lane, where it SUBSTITUTES for an install. Here it made most of db/builtin_roles.sql
-- unfalsifiable: its CREATE ROLE arms never ran, and its hard install-time assertion that
-- haf_stats_owner holds hive_applications_group was satisfied by the fixture no matter
-- what the installer did. The group grant could be deleted from db/builtin_roles.sql and
-- this lane stayed green, while /sync-status answers 503 on a healthy node.
--
-- DROP OWNED BY must come first: the roles hold grants and ALTER DEFAULT PRIVILEGES
-- entries that DROP ROLE alone refuses to step over. It also RAISES 42704 on a role that
-- does not exist, where DROP ROLE has an IF EXISTS -- hence the guard. An earlier
-- revision ran both inline in a two-statement `psql -c`, which reports only the last
-- command tag, so the DROP OWNED was invisible in the job log.
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
        RAISE EXCEPTION 'db-setup: the app roles survived the reset, so db/builtin_roles.sql will take its repair arms instead of creating them';
    END IF;
    RAISE NOTICE 'db-setup: app roles reset -- db/builtin_roles.sql must now create them itself';
END
$check$;
