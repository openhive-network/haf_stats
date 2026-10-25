-- After the first batch outside massive sync has run the deferred rollup refreshes
-- (haf_stats_app.prepare_rollup_refreshes(FALSE)): the record is cleared, and every rollup
-- holds exactly the rows a from-genesis rebuild of it gives. A record dirty from too late
-- a day, or a refresh it missed, shows here as rows the rebuild has and the refresh lacks.
--
-- The rebuild runs in a transaction that is rolled back, so the rollups are left as the
-- deferred refresh wrote them for the steps after this one.

SET ROLE haf_stats_owner;

DO $cleared$
BEGIN
    IF EXISTS (SELECT 1 FROM haf_stats_app.deferred_rollup_refreshes) THEN
        RAISE EXCEPTION 'deferred_rollup_refreshes still holds % after the deferred refreshes ran',
            (SELECT string_agg(processor, ',' ORDER BY processor) FROM haf_stats_app.deferred_rollup_refreshes);
    END IF;
    IF EXISTS (SELECT 1 FROM haf_stats_backend.engagement_touched_days) THEN
        RAISE EXCEPTION 'engagement_touched_days was not drained';
    END IF;
END
$cleared$;

CREATE TEMP TABLE deferred_rollup_md5 (
    rollup TEXT PRIMARY KEY,
    row_count BIGINT NOT NULL,
    md5 TEXT
);

CREATE FUNCTION pg_temp.rollup_md5(_rollup TEXT, OUT row_count BIGINT, OUT md5 TEXT)
LANGUAGE plpgsql
AS $fn$
BEGIN
    EXECUTE format('SELECT count(*), md5(string_agg(t::TEXT, ''|'' ORDER BY t::TEXT)) FROM %s AS t', _rollup)
        INTO row_count, md5;
END
$fn$;

INSERT INTO deferred_rollup_md5 (rollup, row_count, md5)
SELECT r.rollup, m.row_count, m.md5
FROM unnest(ARRAY[
    'haf_stats_backend.account_financial_monthly',
    'haf_stats_backend.account_cohort_retention',
    'haf_stats_backend.active_users_period_counts',
    'haf_stats_backend.active_users_account_monthly',
    'haf_stats_backend.network_vote_period_counts',
    'haf_stats_backend.network_content_period_counts',
    'haf_stats_backend.engagement_period_counts',
    'haf_stats_backend.author_cohort_retention'
]) AS r (rollup)
CROSS JOIN LATERAL pg_temp.rollup_md5(r.rollup) AS m;

BEGIN;

TRUNCATE haf_stats_backend.account_financial_monthly,
    haf_stats_backend.account_cohort_retention,
    haf_stats_backend.active_users_period_counts,
    haf_stats_backend.active_users_account_monthly,
    haf_stats_backend.network_vote_period_counts,
    haf_stats_backend.network_content_period_counts,
    haf_stats_backend.author_cohort_retention;

DO $rebuild$
DECLARE
    _genesis DATE := (SELECT b.created_at::DATE FROM hafd.blocks AS b WHERE b.num = 1);
    _as_of TIMESTAMP := (
        SELECT b.created_at FROM hafd.blocks AS b
        WHERE b.num = (SELECT MAX(s.last_processed_block) FROM haf_stats_app.app_status AS s)
    );
    _r RECORD;
BEGIN
    PERFORM haf_stats_app.refresh_financial_monthly(_genesis);
    PERFORM haf_stats_app.refresh_account_cohort_retention(_as_of);
    PERFORM haf_stats_app.refresh_active_users_periods(_genesis);
    PERFORM haf_stats_app.refresh_active_users_account_monthly(_genesis);
    PERFORM haf_stats_app.refresh_network_vote_periods(_genesis);
    PERFORM haf_stats_app.refresh_network_content_periods(_genesis);
    PERFORM haf_stats_app.refresh_engagement_full();
    PERFORM haf_stats_app.refresh_author_cohort_retention(_as_of);

    FOR _r IN
        SELECT d.rollup, d.row_count, d.md5, m.row_count AS rebuilt_count, m.md5 AS rebuilt_md5
        FROM deferred_rollup_md5 AS d
        CROSS JOIN LATERAL pg_temp.rollup_md5(d.rollup) AS m
        ORDER BY d.rollup
    LOOP
        IF _r.row_count = 0 THEN
            RAISE EXCEPTION '% is empty after the deferred refreshes', _r.rollup;
        END IF;
        IF (_r.row_count, _r.md5) IS DISTINCT FROM (_r.rebuilt_count, _r.rebuilt_md5) THEN
            RAISE EXCEPTION '%: the deferred refresh wrote % rows (md5 %), a from-genesis rebuild % rows (md5 %)',
                _r.rollup, _r.row_count, _r.md5, _r.rebuilt_count, _r.rebuilt_md5;
        END IF;
        RAISE NOTICE '%: % rows, as rebuilt from genesis', _r.rollup, _r.row_count;
    END LOOP;
END
$rebuild$;

ROLLBACK;
