-- After a massive-sync run has stopped, and before anything leaves massive sync: the
-- rollup refreshes were recorded instead of run, and the record outlived the processor.
--
-- .aidev/run-checks.sh runs this in a new connection once haf_app_driver.py has exited
-- between two batches, which is what a crash after a massive batch leaves behind: only
-- what the committed batches wrote. Paired with tests/ci_deferred_refresh_complete.sql,
-- which checks what the first batch outside massive sync makes of it.

SET ROLE haf_stats_owner;

DO $recorded$
DECLARE
    _first_day DATE := (SELECT b.created_at::DATE FROM hafd.blocks AS b WHERE b.num = 1);
    _recorded TEXT;
    _content_from DATE;
    _rollup TEXT;
    _rows BIGINT;
BEGIN
    SELECT string_agg(d.processor, ',' ORDER BY d.processor) INTO _recorded
    FROM haf_stats_app.deferred_rollup_refreshes AS d;
    IF _recorded IS DISTINCT FROM
       'process_account_cohorts,process_active_users,process_content_cohorts,process_content_stats,process_financial' THEN
        RAISE EXCEPTION 'deferred_rollup_refreshes records %, not the five processors whose refreshes massive sync defers', _recorded;
    END IF;

    -- The first massive batch starts at block 1, so every day-keyed refresh is dirty from
    -- the chain's first day; a later day would leave the days before it unrefreshed.
    -- process_content_stats is the exception: once a month of chain time it restates the
    -- periods that can no longer change and moves its record up, so its presence sets can be
    -- pruned during the sync (prune_content_presence, db/process_content_stats.sql).
    IF EXISTS (
        SELECT 1 FROM haf_stats_app.deferred_rollup_refreshes AS d
        WHERE d.processor NOT IN ('process_account_cohorts', 'process_content_cohorts', 'process_content_stats')
          AND d.dirty_from <> _first_day
    ) THEN
        RAISE EXCEPTION 'a day-keyed deferred refresh is dirty from a day after block 1''s (%)', _first_day;
    END IF;
    SELECT d.dirty_from INTO _content_from FROM haf_stats_app.deferred_rollup_refreshes AS d
    WHERE d.processor = 'process_content_stats';
    IF _content_from = _first_day THEN
        RAISE EXCEPTION 'process_content_stats'' deferred refresh is still dirty from block 1''s day (%): it never restated a finished month, so its presence sets kept the whole sync', _first_day;
    END IF;
    -- Restated: every day before the record, and nothing from it on.
    FOREACH _rollup IN ARRAY ARRAY['haf_stats_backend.network_vote_period_counts',
                                   'haf_stats_backend.network_content_period_counts'] LOOP
        EXECUTE format('SELECT count(*) FROM %s WHERE period >= %L', _rollup, _content_from) INTO _rows;
        IF _rows <> 0 THEN
            RAISE EXCEPTION '% holds % rows from % on, which the deferred refresh is still to restate', _rollup, _rows, _content_from;
        END IF;
        EXECUTE format('SELECT count(*) FROM %s WHERE period_type = ''day'' AND period = %L', _rollup, _content_from - 1) INTO _rows;
        IF _rows <> 1 THEN
            RAISE EXCEPTION '% has no day row for %, the day before the deferred record: the restated months were not written', _rollup, _content_from - 1;
        END IF;
    END LOOP;

    -- The cohort refreshes are dirty from a month at or before every cohort's.
    IF (SELECT d.dirty_from FROM haf_stats_app.deferred_rollup_refreshes AS d
        WHERE d.processor = 'process_account_cohorts')
       > (SELECT MIN(m.cohort_month) FROM haf_stats_backend.account_cohort_members AS m) THEN
        RAISE EXCEPTION 'the account cohort refresh is dirty from a month after the first cohort';
    END IF;
    IF (SELECT d.dirty_from FROM haf_stats_app.deferred_rollup_refreshes AS d
        WHERE d.processor = 'process_content_cohorts')
       > (SELECT MIN(m.cohort_month) FROM haf_stats_backend.author_cohort_members AS m) THEN
        RAISE EXCEPTION 'the author cohort refresh is dirty from a month after the first cohort';
    END IF;

    -- Nothing else was refreshed while in massive sync.
    FOREACH _rollup IN ARRAY ARRAY[
        'haf_stats_backend.account_financial_monthly',
        'haf_stats_backend.account_cohort_retention',
        'haf_stats_backend.active_users_period_counts',
        'haf_stats_backend.active_users_account_monthly',
        'haf_stats_backend.engagement_period_counts',
        'haf_stats_backend.author_cohort_retention'
    ] LOOP
        EXECUTE format('SELECT count(*) FROM %s', _rollup) INTO _rows;
        IF _rows <> 0 THEN
            RAISE EXCEPTION '% holds % rows: a refresh ran during massive sync', _rollup, _rows;
        END IF;
    END LOOP;

    -- The engagement drain's own record is its staging set.
    IF NOT EXISTS (SELECT 1 FROM haf_stats_backend.engagement_touched_days) THEN
        RAISE EXCEPTION 'engagement_touched_days is empty: the deferred engagement drain has nothing to drain';
    END IF;

    RAISE NOTICE 'deferred rollup refreshes recorded: %', _recorded;
END
$recorded$;
