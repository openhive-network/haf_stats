-- The retention window of the per-account daily rows (#124, db/daily_retention.sql) against the
-- logic it replaced, on the CI sync, after the deferred rollup refreshes have run
-- (tests/ci_deferred_refresh_complete.sql).
--
-- The sync pruned active_users_daily and account_custom_json_daily as it went: they hold their
-- rows from the floor in daily_retention_floor on, account_custom_json_monthly the months before
-- it, and the active-user rollups were restated before each prune. This puts the pruned rows back
-- - recomputed from the chain with the processors' own row statements, as the sync first wrote
-- them - removes the floor and the monthly rows, and rebuilds every rollup from genesis: the
-- history as the code before #124 kept and served it. Then:
--   * active_users_period_counts, active_users_account_monthly and account_txn_alltime equal the
--     ones the pruning sync made;
--   * get_daily_active_users, get_network_top_accounts transaction_count (its fast and ordered
--     paths), get_account_dapp_footprint, get_account_rc_footprint (group_by=app and category)
--     and get_account_rc_footprint_timeline (app_filter) answer as they did pruned, for ranges in
--     the window and month-aligned ones before it; a range starting before the window answered,
--     pruned, as its month-aligned widening does here.
--
-- In one transaction that is rolled back, so the synced database is left as it was.

SET ROLE haf_stats_owner;

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE retention_floor AS
SELECT
    (SELECT f.kept_from FROM haf_stats_app.daily_retention_floor AS f WHERE f.daily_table = 'active_users_daily') AS users,
    (SELECT f.kept_from FROM haf_stats_app.daily_retention_floor AS f WHERE f.daily_table = 'account_custom_json_daily') AS custom_json;

DO $floor$
DECLARE
    _f retention_floor%ROWTYPE;
BEGIN
    SELECT * INTO _f FROM retention_floor;
    -- The 5M-block replay ends in September 2016, so both tables were pruned to its August.
    IF _f.users IS NULL OR _f.custom_json IS NULL OR _f.users <> _f.custom_json
       OR _f.users <= DATE '2016-05-01' THEN
        RAISE EXCEPTION 'the sync did not prune the daily tables to a floor months after genesis: active users %, custom_json %',
            _f.users, _f.custom_json;
    END IF;
    IF (SELECT MIN(au.day) FROM haf_stats_backend.active_users_daily AS au) < _f.users
       OR NOT EXISTS (SELECT 1 FROM haf_stats_backend.account_custom_json_monthly) THEN
        RAISE EXCEPTION 'the daily tables were not pruned to their floor %', _f.users;
    END IF;
    RAISE NOTICE 'daily rows kept from %', _f.users;
END
$floor$;

-- The month starts and the cases, relative to the floor F: two months before it, the month
-- before it, and the floor's month.
CREATE TEMP TABLE retention_case (name TEXT PRIMARY KEY, from_day DATE, to_day DATE, twin TEXT);
INSERT INTO retention_case (name, from_day, to_day, twin)
SELECT c.name, c.from_day, c.to_day, c.twin
FROM retention_floor AS f
CROSS JOIN LATERAL (VALUES
    -- Before the window, month-aligned.
    ('aligned_two_months', (f.users - INTERVAL '3 months')::DATE, (f.users - INTERVAL '1 month' - INTERVAL '1 day')::DATE, NULL),
    ('aligned_month', (f.users - INTERVAL '1 month')::DATE, f.users - 1, NULL),
    ('aligned_history', DATE '2016-04-01', f.users - 1, NULL),
    -- Month-aligned start before the window, end inside it.
    ('aligned_into_window', (f.users - INTERVAL '2 months')::DATE, f.users + 9, NULL),
    -- In the window.
    ('window', f.users + 2, f.users + 20, NULL),
    ('window_month', f.users, (f.users + INTERVAL '1 month' - INTERVAL '1 day')::DATE, NULL),
    -- Before the window, not aligned: widened to the aligned ranges above.
    ('rounded_two_months', (f.users - INTERVAL '3 months')::DATE + 9, (f.users - INTERVAL '1 month')::DATE - 5, 'aligned_two_months'),
    ('rounded_into_window', (f.users - INTERVAL '2 months')::DATE + 11, f.users + 9, 'aligned_into_window')
) AS c (name, from_day, to_day, twin);

-- The custom_json accounts: the three with the most ops before the window and the one with the
-- most in it.
CREATE TEMP TABLE retention_account AS
(SELECT a.name FROM haf_stats_backend.account_custom_json_monthly AS m JOIN hafd.accounts AS a ON a.id = m.account_id
 GROUP BY a.name ORDER BY SUM(m.op_count) DESC, a.name LIMIT 3)
UNION
(SELECT a.name FROM haf_stats_backend.account_custom_json_daily AS d JOIN hafd.accounts AS a ON a.id = d.account_id
 GROUP BY a.name ORDER BY SUM(d.op_count) DESC, a.name LIMIT 1);

-- Each account's most used DApp before the window, for the timeline's app_filter.
CREATE TEMP TABLE retention_app AS
SELECT DISTINCT ON (ra.name) ra.name, haf_stats_app.resolve_dapp_name(cjt.custom_json_id) AS app
FROM retention_account AS ra
JOIN hafd.accounts AS a ON a.name = ra.name
JOIN haf_stats_backend.account_custom_json_monthly AS m ON m.account_id = a.id
JOIN hafd.custom_json_types AS cjt ON cjt.id = m.custom_json_type_id
ORDER BY ra.name, m.op_count DESC, cjt.custom_json_id;

CREATE FUNCTION pg_temp.answers() RETURNS TABLE (name TEXT, answer TEXT) LANGUAGE plpgsql AS $fn$
BEGIN
    RETURN QUERY
    SELECT 'top/' || c.name || CASE WHEN o.ob IS NULL THEN '' ELSE '/' || o.ob || '_' || o.dir END,
           (SELECT string_agg(r::TEXT, '|' ORDER BY r.rank)
            FROM haf_stats_endpoints.get_network_top_accounts('transaction_count', c.from_day::TEXT, c.to_day::TEXT,
                                                              25, o.ob, o.dir) AS r)
    FROM retention_case AS c
    CROSS JOIN (VALUES (NULL::TEXT, 'desc'), ('account', 'asc'), ('op_count', 'asc')) AS o (ob, dir);

    RETURN QUERY
    SELECT 'dapp/' || c.name || '/' || a.name,
           haf_stats_endpoints.get_account_dapp_footprint(a.name, c.from_day::TEXT, c.to_day::TEXT)::TEXT
    FROM retention_case AS c CROSS JOIN retention_account AS a;

    RETURN QUERY
    SELECT 'rc/' || c.name || '/' || a.name || '/' || g.by,
           (SELECT string_agg(r::TEXT, '|' ORDER BY r.label)
            FROM haf_stats_endpoints.get_account_rc_footprint(a.name, c.from_day::TEXT, c.to_day::TEXT, g.by) AS r)
    FROM retention_case AS c CROSS JOIN retention_account AS a
    CROSS JOIN (VALUES ('app'), ('category')) AS g (by);

    -- Never widened: a rounded range answers as itself, so it has no twin here.
    RETURN QUERY
    SELECT 'timeline/' || c.name || '/' || a.name,
           (SELECT string_agg(r::TEXT, '|' ORDER BY r.op_seq DESC)
            FROM haf_stats_endpoints.get_account_rc_footprint_timeline(a.name, c.from_day::TEXT, c.to_day::TEXT,
                                                                       NULL, a.app, NULL, 50) AS r)
    FROM retention_case AS c CROSS JOIN retention_app AS a;

    RETURN QUERY
    SELECT 'dau/' || g.granularity || '/' || o.ot,
           (SELECT string_agg(r::TEXT, '|' ORDER BY r.period)
            FROM haf_stats_endpoints.get_daily_active_users(NULL, NULL, g.granularity, o.ot) AS r)
    FROM (VALUES ('day'), ('week'), ('month')) AS g (granularity)
    CROSS JOIN (VALUES ('all'), ('post'), ('comment'), ('vote'), ('transfer'), ('custom_json')) AS o (ot);
END;
$fn$;

CREATE FUNCTION pg_temp.rollups() RETURNS TABLE (rollup TEXT, row_count BIGINT, md5 TEXT) LANGUAGE sql AS $fn$
    SELECT 'active_users_period_counts', count(*), md5(string_agg(t::TEXT, '|' ORDER BY t::TEXT))
    FROM haf_stats_backend.active_users_period_counts AS t
    UNION ALL
    SELECT 'active_users_account_monthly', count(*), md5(string_agg(t::TEXT, '|' ORDER BY t::TEXT))
    FROM haf_stats_backend.active_users_account_monthly AS t
    UNION ALL
    SELECT 'account_txn_alltime', count(*), md5(string_agg(t::TEXT, '|' ORDER BY t::TEXT))
    FROM haf_stats_backend.account_txn_alltime AS t
$fn$;

-- The tables' sizes pruned and, after the restore below, as the code before #124 kept them, each
-- measured on a freshly written copy so that neither carries the other's dead rows.
CREATE TEMP TABLE retention_size (stage TEXT, rel TEXT, row_count BIGINT, heap BIGINT, indexes BIGINT);
CREATE FUNCTION pg_temp.measure(_stage TEXT, _rel TEXT, _copy REGCLASS) RETURNS VOID LANGUAGE plpgsql AS $fn$
BEGIN
    EXECUTE format('ANALYZE %s', _copy);
    INSERT INTO retention_size
    SELECT _stage, _rel, (SELECT c.reltuples::BIGINT FROM pg_class AS c WHERE c.oid = _copy),
           pg_relation_size(_copy), pg_indexes_size(_copy);
END;
$fn$;
CREATE TEMP TABLE size_aud (LIKE haf_stats_backend.active_users_daily INCLUDING ALL);
INSERT INTO size_aud SELECT * FROM haf_stats_backend.active_users_daily ORDER BY op_class, day, account_id;
CREATE TEMP TABLE size_acj (LIKE haf_stats_backend.account_custom_json_daily INCLUDING ALL);
INSERT INTO size_acj SELECT * FROM haf_stats_backend.account_custom_json_daily ORDER BY account_id, day, custom_json_type_id;
CREATE TEMP TABLE size_acjm (LIKE haf_stats_backend.account_custom_json_monthly INCLUDING ALL);
INSERT INTO size_acjm SELECT * FROM haf_stats_backend.account_custom_json_monthly ORDER BY account_id, month, custom_json_type_id;
SELECT pg_temp.measure('pruned', 'active_users_daily', 'size_aud');
SELECT pg_temp.measure('pruned', 'account_custom_json_daily', 'size_acj');
SELECT pg_temp.measure('pruned', 'account_custom_json_monthly', 'size_acjm');
DROP TABLE size_aud, size_acj, size_acjm;

-- Pruned, as the sync left it.
SELECT haf_stats_app.refresh_top_accounts_alltime();
CREATE TEMP TABLE retention_pruned_rollups AS SELECT * FROM pg_temp.rollups();
CREATE TEMP TABLE retention_pruned AS SELECT * FROM pg_temp.answers();

-- The pruned rows, recomputed from the chain over the blocks of the days before the floor, in
-- steps of 100,000 blocks: process_active_users' membership statement and process_custom_json's
-- rows (haf_stats_app.account_custom_json_rows), merged as those processors merge them.
DO $restore$
DECLARE
    _floor CONSTANT DATE := (SELECT f.users FROM retention_floor AS f);
    _last INT;
    _lo INT := 1;
    _hi INT;
BEGIN
    SELECT r.to_block INTO _last FROM haf_stats_app.block_range_for_dates(DATE '2016-03-24', _floor - 1) AS r;
    WHILE _lo <= _last LOOP
        _hi := LEAST(_lo + 99999, _last);
        PERFORM haf_stats_app.prepare_batch_authored_ops(_lo, _hi);
        INSERT INTO haf_stats_backend.active_users_daily AS aud (day, op_class, account_id, ops)
        SELECT m.day, m.op_class, m.account_id, m.ops
        FROM (
            SELECT day, op_class, account_id, COUNT(*) AS ops
            FROM haf_stats_batch_authored_ops
            WHERE op_class IS NOT NULL
            GROUP BY day, op_class, account_id
            UNION ALL
            SELECT day, -1::SMALLINT, account_id, COUNT(*)
            FROM haf_stats_batch_authored_ops
            GROUP BY day, account_id
        ) AS m
        ON CONFLICT (op_class, day, account_id) DO UPDATE SET ops = aud.ops + EXCLUDED.ops;

        INSERT INTO haf_stats_backend.account_custom_json_daily AS acj
            (account_id, day, custom_json_type_id, op_count, op_bytes, rc_exact)
        SELECT r.account_id, r.day, r.custom_json_type_id, r.op_count, r.op_bytes, r.rc_exact
        FROM haf_stats_app.account_custom_json_rows(_lo, _hi) AS r
        ON CONFLICT (account_id, day, custom_json_type_id) DO UPDATE SET
            op_count = acj.op_count + EXCLUDED.op_count,
            op_bytes = acj.op_bytes + EXCLUDED.op_bytes,
            rc_exact = acj.rc_exact + EXCLUDED.rc_exact;
        _lo := _hi + 1;
    END LOOP;

    -- The restored rows are exactly the pruned ones: they sum to the monthly rows.
    CREATE TEMP TABLE retention_restored_months AS
    SELECT d.account_id, DATE_TRUNC('month', d.day)::DATE AS month, d.custom_json_type_id,
           SUM(d.op_count)::BIGINT AS op_count, SUM(d.op_bytes)::BIGINT AS op_bytes
    FROM haf_stats_backend.account_custom_json_daily AS d
    WHERE d.day < _floor
    GROUP BY 1, 2, 3;
    IF EXISTS (
        SELECT m.account_id, m.month, m.custom_json_type_id, m.op_count, m.op_bytes
        FROM haf_stats_backend.account_custom_json_monthly AS m
        EXCEPT SELECT * FROM retention_restored_months
    ) OR EXISTS (
        SELECT * FROM retention_restored_months
        EXCEPT
        SELECT m.account_id, m.month, m.custom_json_type_id, m.op_count, m.op_bytes
        FROM haf_stats_backend.account_custom_json_monthly AS m
    ) THEN
        RAISE EXCEPTION 'the custom_json rows recomputed from the chain before % do not add up to account_custom_json_monthly', _floor;
    END IF;
    RAISE NOTICE 'restored the daily rows of blocks 1..% (the days before %)', _last, _floor;
END
$restore$;

-- The restored tables in the shape before #124: active_users_daily keyed (day, op_class,
-- account_id) with idx_aud_opclass_day beside it.
CREATE TEMP TABLE size_aud (
    day DATE NOT NULL, op_class SMALLINT NOT NULL, account_id INT NOT NULL, ops INT NOT NULL,
    PRIMARY KEY (day, op_class, account_id)
);
INSERT INTO size_aud SELECT au.day, au.op_class, au.account_id, au.ops
FROM haf_stats_backend.active_users_daily AS au ORDER BY au.day, au.op_class, au.account_id;
CREATE INDEX ON size_aud (op_class, day) INCLUDE (account_id, ops);
CREATE TEMP TABLE size_acj (LIKE haf_stats_backend.account_custom_json_daily INCLUDING ALL);
INSERT INTO size_acj SELECT * FROM haf_stats_backend.account_custom_json_daily ORDER BY account_id, day, custom_json_type_id;
SELECT pg_temp.measure('whole history', 'active_users_daily', 'size_aud');
SELECT pg_temp.measure('whole history', 'account_custom_json_daily', 'size_acj');
DROP TABLE size_aud, size_acj;
DO $sizes$
DECLARE
    _r RECORD;
BEGIN
    FOR _r IN SELECT * FROM retention_size ORDER BY rel, stage DESC LOOP
        RAISE NOTICE 'size: % %: % rows, heap %, indexes %', _r.stage, _r.rel, _r.row_count,
            pg_size_pretty(_r.heap), pg_size_pretty(_r.indexes);
    END LOOP;
END
$sizes$;

-- The history as the code before #124 kept it: no floor, no monthly rows, every rollup rebuilt
-- from genesis.
DELETE FROM haf_stats_app.daily_retention_floor;
TRUNCATE haf_stats_backend.account_custom_json_monthly,
    haf_stats_backend.active_users_period_counts,
    haf_stats_backend.active_users_account_monthly;
SELECT haf_stats_app.refresh_active_users_periods('2016-03-24');
SELECT haf_stats_app.refresh_active_users_account_monthly('2016-03-24');
SELECT haf_stats_app.refresh_top_accounts_alltime();

DO $compare$
DECLARE
    _r RECORD;
    _bad TEXT;
    _n INT;
BEGIN
    FOR _r IN
        SELECT p.rollup, p.row_count, p.md5, u.row_count AS full_count, u.md5 AS full_md5
        FROM retention_pruned_rollups AS p JOIN pg_temp.rollups() AS u USING (rollup)
        ORDER BY p.rollup
    LOOP
        IF _r.row_count = 0 OR (_r.row_count, _r.md5) IS DISTINCT FROM (_r.full_count, _r.full_md5) THEN
            RAISE EXCEPTION '%: % rows (md5 %) pruned, % rows (md5 %) over the whole history',
                _r.rollup, _r.row_count, _r.md5, _r.full_count, _r.full_md5;
        END IF;
        RAISE NOTICE '%: % rows, as over the whole history', _r.rollup, _r.row_count;
    END LOOP;

    SELECT count(*) INTO _n FROM retention_pruned AS p WHERE p.answer IS NOT NULL;
    IF _n < 40 THEN
        RAISE EXCEPTION 'only % endpoint cases answered anything, too few to compare', _n;
    END IF;
    SELECT string_agg(p.name, ', ' ORDER BY p.name) INTO _bad
    FROM retention_pruned AS p
    JOIN pg_temp.answers() AS u
      ON u.name = COALESCE(
             (SELECT replace(p.name, c.name, c.twin) FROM retention_case AS c
              WHERE c.twin IS NOT NULL AND p.name NOT LIKE 'timeline/%' AND p.name LIKE '%/' || c.name || '%'),
             p.name)
    WHERE p.answer IS DISTINCT FROM u.answer;
    IF _bad IS NOT NULL THEN
        RAISE EXCEPTION 'these endpoint answers differ from the whole history''s: %', _bad;
    END IF;
    RAISE NOTICE '% endpoint answers (% non-empty) as over the whole history', (SELECT count(*) FROM retention_pruned), _n;
END
$compare$;

ROLLBACK;
