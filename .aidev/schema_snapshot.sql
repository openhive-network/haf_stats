-- The definitions in haf_stats' three schemas, one sorted line per object, for the
-- `reinstall` step of .aidev/run-checks.sh: what CI's reinstall-test compares with
-- `pg_dump --schema-only`, read from the catalogs instead, because the runtime's
-- pg_dump (17) refuses the shared HAF's newer server. Privileges are compared
-- separately, through tests/privileges.sql.
--
--   psql -X -At -v ON_ERROR_STOP=1 -f .aidev/schema_snapshot.sql
SELECT line FROM (
    SELECT 'schema ' || n.nspname || ' owner=' || pg_get_userbyid(n.nspowner) AS line
    FROM pg_namespace AS n
    WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
    UNION ALL
    SELECT 'function ' || p.oid::regprocedure::text || ' owner=' || pg_get_userbyid(p.proowner)
           || E'\n' || pg_get_functiondef(p.oid)
    FROM pg_proc AS p
    WHERE p.pronamespace::regnamespace::text IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
      AND p.prokind IN ('f', 'p', 'w')
    UNION ALL
    SELECT 'aggregate ' || p.oid::regprocedure::text || ' owner=' || pg_get_userbyid(p.proowner)
    FROM pg_proc AS p
    WHERE p.pronamespace::regnamespace::text IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
      AND p.prokind = 'a'
    UNION ALL
    SELECT 'relation ' || c.oid::regclass::text || ' kind=' || c.relkind::text
           || ' owner=' || pg_get_userbyid(c.relowner)
           || ' options=' || coalesce(array_to_string(c.reloptions, ','), '-')
           || CASE WHEN c.relkind IN ('v', 'm') THEN E'\n' || pg_get_viewdef(c.oid) ELSE '' END
    FROM pg_class AS c
    WHERE c.relnamespace::regnamespace::text IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
      AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
    UNION ALL
    SELECT 'column ' || a.attrelid::regclass::text || '.' || a.attname
           || ' ' || format_type(a.atttypid, a.atttypmod)
           || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END
           || coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), '')
           || CASE WHEN a.attgenerated <> '' THEN ' generated ' || a.attgenerated::text ELSE '' END
    FROM pg_attribute AS a
    INNER JOIN pg_class AS c ON a.attrelid = c.oid
    LEFT JOIN pg_attrdef AS d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    WHERE c.relnamespace::regnamespace::text IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND a.attnum > 0 AND NOT a.attisdropped
    UNION ALL
    SELECT 'constraint ' || r.conrelid::regclass::text || ' ' || r.conname || ' ' || pg_get_constraintdef(r.oid)
    FROM pg_constraint AS r
    WHERE r.connamespace::regnamespace::text IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
    UNION ALL
    SELECT 'index ' || pg_get_indexdef(i.indexrelid)
    FROM pg_index AS i
    INNER JOIN pg_class AS c ON i.indexrelid = c.oid
    WHERE c.relnamespace::regnamespace::text IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
    UNION ALL
    SELECT 'trigger ' || pg_get_triggerdef(t.oid)
    FROM pg_trigger AS t
    INNER JOIN pg_class AS c ON t.tgrelid = c.oid
    WHERE c.relnamespace::regnamespace::text IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
      AND NOT t.tgisinternal
    UNION ALL
    SELECT 'type ' || t.oid::regtype::text || ' kind=' || t.typtype::text || ' owner=' || pg_get_userbyid(t.typowner)
           || coalesce(' labels=' || (SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
                                      FROM pg_enum AS e WHERE e.enumtypid = t.oid), '')
    FROM pg_type AS t
    WHERE t.typnamespace::regnamespace::text IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
      AND t.typtype IN ('c', 'd', 'e')
      AND NOT EXISTS (SELECT FROM pg_class AS c WHERE c.oid = t.typrelid AND c.relkind <> 'c')
) AS z
ORDER BY line COLLATE "C";
