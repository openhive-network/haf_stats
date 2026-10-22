-- Every haf_stats privilege that the installer sets, one line per object, for the
-- reinstall-test lane to compare against tests/expected_privileges.txt (#82).
--
-- Why a committed list. ~40 haf_stats functions are dropped and recreated on every
-- install, and DROP FUNCTION discards the ACL where CREATE OR REPLACE keeps it. A GRANT
-- that runs before its DROP, or a REVOKE ... FROM PUBLIC above a DROP, is then lost on
-- EVERY install -- identically on both installs, so the lane's before/after schema diff
-- cannot see it. tests/unit/test_privileges_pinned.py checks the other direction: every
-- GRANT/REVOKE in the install sources is reflected in the committed list, so the list
-- cannot quietly absorb a privilege the sources say should not exist.
--
-- Covered: functions (owner, SECURITY DEFINER, ACL), tables / partitioned tables /
-- sequences / materialized views (owner, ACL), the three schemas (owner, ACL), haf_stats'
-- default privileges, and role memberships involving a haf_stats role. Left out: views --
-- haf_stats creates none; the ones in haf_stats_app are HAF's context views, which follow
-- the HAF version, not this repo. There are no column grants.
--
-- ACL entries are grantee:privilege, with * for WITH GRANT OPTION, sorted by grantee and
-- privilege. Left out: the grantor (it depends on which role ran the installer, not on
-- what the installer granted) and the owner's own entries (implicit, and their privilege
-- list varies with the PostgreSQL version), so a REVOKE from an object's own owner is not
-- seen. <default> means no explicit ACL (PostgreSQL's default: the owner, plus PUBLIC
-- EXECUTE for a function); <owner only> means an explicit ACL granting nobody else.
--
-- To regenerate the list after an intended change (it is then a reviewed diff):
--   psql -X -At -v ON_ERROR_STOP=1 -d haf_block_log -f tests/privileges.sql > tests/expected_privileges.txt
-- or take docker/privileges-actual.txt from a failed reinstall-test job's artifacts.
WITH acl AS (
    -- One row per object that has an explicit ACL. The owner's own entries are left out:
    -- they are implicit, and their privilege list varies with the PostgreSQL version
    -- (MAINTAIN on tables since 17). txt is NULL when the explicit ACL holds only the owner.
    SELECT o.kind, o.objid,
           string_agg(e.who || ':' || e.privilege_type || CASE WHEN e.is_grantable THEN '*' ELSE '' END,
                      ',' ORDER BY e.who COLLATE "C", e.privilege_type COLLATE "C")
               FILTER (WHERE e.grantee <> o.owner) AS txt
    FROM (
        SELECT 'f' AS kind, p.oid AS objid, p.proowner AS owner, p.proacl AS acl FROM pg_proc AS p
        UNION ALL SELECT 'c', c.oid, c.relowner, c.relacl FROM pg_class AS c
        UNION ALL SELECT 'n', n.oid, n.nspowner, n.nspacl FROM pg_namespace AS n
        UNION ALL SELECT 'd', d.oid, d.defaclrole, d.defaclacl FROM pg_default_acl AS d
    ) AS o
    CROSS JOIN LATERAL (
        SELECT x.grantee,
               CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END AS who,
               x.privilege_type, x.is_grantable
        FROM aclexplode(o.acl) AS x
    ) AS e
    GROUP BY o.kind, o.objid
)
SELECT line FROM (
    SELECT 'function ' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
           || ' | owner=' || pg_get_userbyid(p.proowner)
           || ' | secdef=' || p.prosecdef
           || ' | acl=' || CASE WHEN a.objid IS NULL THEN '<default>' ELSE COALESCE(a.txt, '<owner only>') END AS line
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    LEFT JOIN acl AS a ON a.kind = 'f' AND a.objid = p.oid
    WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
    UNION ALL
    SELECT CASE c.relkind WHEN 'S' THEN 'sequence ' WHEN 'm' THEN 'matview ' ELSE 'table ' END
           || n.nspname || '.' || c.relname
           || ' | owner=' || pg_get_userbyid(c.relowner)
           || ' | acl=' || CASE WHEN a.objid IS NULL THEN '<default>' ELSE COALESCE(a.txt, '<owner only>') END
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    LEFT JOIN acl AS a ON a.kind = 'c' AND a.objid = c.oid
    WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
      AND c.relkind IN ('r', 'p', 'S', 'm')
    UNION ALL
    SELECT 'schema ' || n.nspname || ' | owner=' || pg_get_userbyid(n.nspowner)
           || ' | acl=' || CASE WHEN a.objid IS NULL THEN '<default>' ELSE COALESCE(a.txt, '<owner only>') END
    FROM pg_namespace AS n
    LEFT JOIN acl AS a ON a.kind = 'n' AND a.objid = n.oid
    WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
    UNION ALL
    SELECT 'default-privileges for=' || pg_get_userbyid(d.defaclrole)
           || ' in=' || COALESCE(d.defaclnamespace::REGNAMESPACE::TEXT, '<all schemas>')
           || ' on=' || d.defaclobjtype::TEXT
           || ' | acl=' || COALESCE(a.txt, '<owner only>')
    FROM pg_default_acl AS d
    LEFT JOIN acl AS a ON a.kind = 'd' AND a.objid = d.oid
    WHERE pg_get_userbyid(d.defaclrole) LIKE 'haf\_stats\_%'
    UNION ALL
    SELECT 'membership ' || m.rolname || ' in ' || r.rolname || ' | admin=' || am.admin_option
    FROM pg_auth_members AS am
    JOIN pg_roles AS r ON r.oid = am.roleid
    JOIN pg_roles AS m ON m.oid = am.member
    WHERE r.rolname LIKE 'haf\_stats\_%' OR m.rolname LIKE 'haf\_stats\_%'
) AS z
ORDER BY line COLLATE "C";
