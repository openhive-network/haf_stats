-- Owner, SECURITY DEFINER flag and ACL of every haf_stats function, one line each,
-- for the reinstall-test lane to compare against tests/expected_function_acls.txt (#82).
--
-- Why a pinned list: a DROP FUNCTION discards the function's ACL (CREATE OR REPLACE keeps
-- it), and ~40 haf_stats functions are dropped and recreated on every install. A GRANT
-- that runs before its DROP, or a REVOKE ... FROM PUBLIC above a DROP, is then lost on
-- EVERY install - identically on both installs, so the lane's before/after schema diff
-- cannot see it. Expectations derived from the GRANT statements at test time would shrink
-- along with a deleted GRANT; a committed list cannot.
--
-- The grantor is left out (aclexplode's grantee and privilege only): it depends on which
-- role ran the installer, not on what the installer granted. A function with no explicit
-- ACL prints <default> (owner + PUBLIC EXECUTE, PostgreSQL's built-in default).
SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
       || ' | owner=' || pg_get_userbyid(p.proowner)
       || ' | secdef=' || p.prosecdef
       || ' | acl=' || COALESCE(
            (SELECT string_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END
                               || ':' || a.privilege_type, ',' ORDER BY 1)
             FROM aclexplode(p.proacl) AS a),
            '<default>')
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
ORDER BY 1;
