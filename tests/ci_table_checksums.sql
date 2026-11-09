-- One line per haf_stats table, `schema.table|rows|checksum`, for comparing what two syncs of
-- the same block range wrote (tests/ci_parallel_sync_equality.sh). The checksum is over the
-- sorted md5 of each row's text, so it does not depend on the physical row order.
--
-- Left out: the two snapshot tables block processing never writes. They are refreshed by
-- install_app.sh and by cron, and stamped with now() (computed_at). Also the shared batch
-- staging of parallel sync (db/process_block_range.sql): its slots keep the last staged batches'
-- rows until a later batch replaces them, and its marker table keeps the range staged ahead of
-- the last batch (tests/ci_parallel_sync_equality.sh checks that no marker is left for a range
-- the sync committed).
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
      ('haf_stats_app', 'shared_batch_marker')
  )
  AND c.relname !~ '^shared_batch_(ops|authored_ops|exact_rc|custom_json_ops)_[01]$'
ORDER BY n.nspname, c.relname
\gexec
