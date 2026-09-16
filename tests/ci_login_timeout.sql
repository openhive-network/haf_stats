-- What a fresh LOGIN gets, for the API role and for the owner. (#94)
--
-- Run twice by docker/docker-compose-ci-install.yml's verify service: once connected AS
-- haf_stats_user, once AS haf_stats_owner -- never as the superuser. PostgreSQL applies
-- a role's settings at LOGIN only, not on SET ROLE and not on SET SESSION AUTHORIZATION,
-- so a superuser session that "becomes" either role proves nothing.
--
-- Who connected is read from pg_stat_activity, NOT session_user: SET SESSION
-- AUTHORIZATION changes session_user but not the authenticated user pg_stat_activity
-- records, so a superuser run with that plus PGOPTIONS='-c statement_timeout=30s' would
-- otherwise pass the API-role branch -- measured.
--
--   haf_stats_user   must get 30s. db/builtin_roles.sql sets it; this is the budget
--                    wherever PostgREST logs in as, or switches to, this role.
--   haf_stats_owner  must get 0. The block processor logs in as the owner and its batches
--                    legitimately run long. Asserting the EFFECTIVE value catches a
--                    timeout that reaches the owner by any route -- a role setting, a
--                    database-wide ALTER DATABASE, ALTER ROLE ALL, or ALTER SYSTEM --
--                    where a catalog check on the owner's own row saw only the first.
--
-- tests/ci_install_verify.sql gives both roles the CI-only passwords these connections use.
DO $probe$
DECLARE
    _authenticated TEXT;
    _timeout       TEXT := current_setting('statement_timeout');
BEGIN
    SELECT a.usename INTO _authenticated
      FROM pg_stat_activity AS a
     WHERE a.pid = pg_backend_pid();

    IF _authenticated = 'haf_stats_user' THEN
        IF _timeout <> '30s' THEN
            RAISE EXCEPTION 'login probe: a fresh haf_stats_user login has statement_timeout = %, '
                            'expected 30s. db/builtin_roles.sql sets it with ALTER ROLE; without '
                            'it the API runs uncapped wherever PostgREST logs in as this role '
                            '(the haf_api_node stack, and side-loaded nodes).', _timeout;
        END IF;
        RAISE NOTICE 'login probe: haf_stats_user logs in with statement_timeout = 30s';

    ELSIF _authenticated = 'haf_stats_owner' THEN
        IF _timeout <> '0' THEN
            RAISE EXCEPTION 'login probe: a fresh haf_stats_owner login has statement_timeout = %, '
                            'expected 0. The block processor logs in as the owner and its batches '
                            'legitimately run long; the API budget belongs on haf_stats_user only. '
                            'Look for a role, database-wide, ALL-roles or system setting.', _timeout;
        END IF;
        RAISE NOTICE 'login probe: haf_stats_owner logs in with statement_timeout = 0';

    ELSE
        RAISE EXCEPTION 'login probe: this connection authenticated as %, not haf_stats_user or '
                        'haf_stats_owner. It must LOG IN as one of them: role settings are not '
                        'applied on SET ROLE or SET SESSION AUTHORIZATION, so any other session '
                        'proves nothing about what PostgREST or the block processor gets.',
                        _authenticated;
    END IF;
END
$probe$;
