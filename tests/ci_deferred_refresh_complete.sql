-- After the first batch outside massive sync has run the deferred rollup refreshes
-- (haf_stats_app.prepare_rollup_refreshes(FALSE)): the record is cleared, and every rollup
-- holds exactly the rows a from-genesis rebuild of it gives. A record dirty from too late
-- a day, or a refresh it missed, shows here as rows the rebuild has and the refresh lacks.
--
-- The rebuild runs in a transaction that is rolled back, so the rollups are left as the
-- deferred refresh wrote them for the steps after this one.
--
-- The deferred refresh also pruned the presence sets it was the last to need
-- (prune_content_presence, db/process_content_stats.sql): network_voter_daily keeps the oldest
-- week or month the next batch's refresh can touch, network_author_daily that or the 181-day
-- cohort window, whichever is older. That is checked first. A from-genesis rebuild can then
-- restate unique voters/authors only for the periods those sets still cover in full, so the two
-- rollups that count them have their unique counts compared from the voter floor on (the
-- months before it were restated during the sync, as the sets were pruned).

SET ROLE haf_stats_owner;

CREATE TEMP TABLE presence_floor AS
SELECT
    LEAST(DATE_TRUNC('week', lo.day), DATE_TRUNC('month', lo.day))::DATE AS voters,
    LEAST(LEAST(DATE_TRUNC('week', lo.day), DATE_TRUNC('month', lo.day))::DATE, head.day - 181) AS authors
FROM (SELECT MAX(s.last_processed_block) AS block FROM haf_stats_app.app_status AS s) AS last
CROSS JOIN LATERAL (
    SELECT b.created_at::DATE AS day FROM hafd.blocks AS b WHERE b.num = GREATEST((last.block / 1200) * 1200, 1)
) AS lo
CROSS JOIN LATERAL (
    SELECT b.created_at::DATE AS day FROM hafd.blocks AS b WHERE b.num = last.block
) AS head;

DO $pruned$
DECLARE
    _f presence_floor%ROWTYPE;
BEGIN
    SELECT * INTO _f FROM presence_floor;
    IF _f.voters IS NULL THEN
        RAISE EXCEPTION 'cannot compute the presence-set floors from the last processed block';
    END IF;
    IF EXISTS (SELECT 1 FROM haf_stats_backend.network_voter_daily WHERE day < _f.voters) THEN
        RAISE EXCEPTION 'network_voter_daily still holds rows before % (oldest %): the deferred refresh did not prune it',
            _f.voters, (SELECT MIN(day) FROM haf_stats_backend.network_voter_daily);
    END IF;
    IF EXISTS (SELECT 1 FROM haf_stats_backend.network_author_daily WHERE day < _f.authors) THEN
        RAISE EXCEPTION 'network_author_daily still holds rows before % (oldest %): the deferred refresh did not prune it',
            _f.authors, (SELECT MIN(day) FROM haf_stats_backend.network_author_daily);
    END IF;
    -- The author floor may predate the chain (it does at 5M blocks), so its kept rows are
    -- looked for up to the voter floor rather than on the floor itself.
    IF NOT EXISTS (SELECT 1 FROM haf_stats_backend.network_voter_daily WHERE day = _f.voters)
       OR NOT EXISTS (SELECT 1 FROM haf_stats_backend.network_author_daily WHERE day BETWEEN _f.authors AND _f.voters) THEN
        RAISE EXCEPTION 'the presence sets lost rows at or after their floors (voters from %, authors from %): pruned too far',
            _f.voters, _f.authors;
    END IF;
    RAISE NOTICE 'presence sets pruned: network_voter_daily from %, network_author_daily from %', _f.voters, _f.authors;
END
$pruned$;

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

-- Whole rows, except the unique counts of the periods before the voter floor (see the header):
-- those rows are compared on their additive columns only.
CREATE FUNCTION pg_temp.rollup_md5(_rollup TEXT, OUT row_count BIGINT, OUT md5 TEXT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    _floor CONSTANT DATE := (SELECT f.voters FROM presence_floor AS f);
    _row TEXT := CASE _rollup
        WHEN 'haf_stats_backend.network_vote_period_counts' THEN format(
            'CASE WHEN t.period >= %L THEN t::TEXT ELSE ROW(t.period_type, t.period, t.upvotes, t.downvotes, t.unvotes, t.self_votes)::TEXT END', _floor)
        WHEN 'haf_stats_backend.network_content_period_counts' THEN format(
            'CASE WHEN t.period >= %L THEN t::TEXT ELSE ROW(t.period_type, t.period, t.posts, t.comments)::TEXT END', _floor)
        ELSE 't::TEXT'
    END;
BEGIN
    EXECUTE format('SELECT count(*), md5(string_agg(r, ''|'' ORDER BY r)) FROM (SELECT %s AS r FROM %s AS t) AS x',
                   _row, _rollup)
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
