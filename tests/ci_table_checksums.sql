-- One line per haf_stats table, `schema.table|rows|checksum`, for comparing what two syncs of
-- the same block range wrote (tests/ci_parallel_sync_equality.sh). The checksum is over the
-- sorted md5 of each row's text, so it does not depend on the physical row order.
--
-- Left out: the two snapshot tables block processing never writes. They are refreshed by
-- install_app.sh and by cron, and stamped with now() (computed_at). Also the shared batch
-- staging of parallel sync, which keeps the last staged batch's rows until the next batch
-- replaces them (db/process_block_range.sql); its marker table, empty once a batch commits, is
-- compared.
--
--   psql -X -At -v ON_ERROR_STOP=1 -f tests/ci_table_checksums.sql
SELECT format(
    'SELECT %L, COUNT(*), md5(COALESCE(string_agg(h, '''' ORDER BY h), '''')) FROM (SELECT md5(t::TEXT) AS h FROM %I.%I AS t) AS r',
    n.nspname || '.' || c.relname, n.nspname, c.relname
)
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend')
  AND c.relkind IN ('r', 'p')
  AND NOT c.relispartition
  AND (n.nspname, c.relname) NOT IN (
      ('haf_stats_backend', 'governance_concentration_snapshot'),
      ('haf_stats_backend', 'hp_distribution_snapshot'),
      ('haf_stats_app', 'shared_batch_ops'),
      ('haf_stats_app', 'shared_batch_authored_ops'),
      ('haf_stats_app', 'shared_batch_exact_rc'),
      ('haf_stats_app', 'shared_batch_custom_json_ops')
  )
ORDER BY n.nspname, c.relname
\gexec
