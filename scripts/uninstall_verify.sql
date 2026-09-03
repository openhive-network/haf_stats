-- Post-teardown verification for scripts/uninstall_app.sh (#57).
--
-- Names whatever the teardown failed to remove, as a single comma-separated string
-- (empty when nothing survives). This is what lets the destructive steps run
-- permissively and push past an error the way upstream's uninstall scripts do, without
-- a partial teardown passing silently.
--
-- ONLY catalog tables that always exist. hafd.contexts is deliberately absent: a WHERE
-- clause cannot protect a FROM clause, because PostgreSQL resolves relation names during
-- parse analysis before any predicate runs. The caller checks for the context
-- separately, and only when to_regclass says hafd.contexts is there.
--
-- In a file rather than inline so the tests can compare the whole query against an
-- expected one. Inline, the only thing a test could do was grep the assembled string for
-- substrings, and that cannot distinguish this from a version whose branches return
-- nothing.

SELECT
    string_agg(
        item,
        ', '
        ORDER BY item
    )
FROM (
    SELECT 'schema ' || n.nspname AS item
    FROM pg_namespace AS n
    WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')

    UNION ALL

    SELECT 'role ' || r.rolname AS item
    FROM pg_roles AS r
    WHERE r.rolname IN ('haf_stats_owner', 'haf_stats_user')
) AS s;
