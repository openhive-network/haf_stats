-- #44 part 2: the REAL rollup processors and the rc_exact backfill, over the rcexact fixture
-- (tests/ci_setup.sql, blocks 6500-6503), inside a transaction that is rolled back.
--
-- The endpoint tests read rollup rows the fixture writes by hand, so without this nothing in the
-- fast lane runs process_network_ops / process_network_custom_json / process_custom_json with
-- their rc_exact arm, or backfill_rc_exact. The blocks are processed in TWO batches (6500-6501,
-- 6502-6503), so a day touched by two batches exercises the accumulation rule too.
--
-- Expected, from the fixture's shares (see the rcexact comment in tests/ci_setup.sql):
--   network_op_daily      2021-03-20 op 1   5 ops, NULL: 6502000001's transaction has no rc_cost
--                         2021-03-20 op 18  3 ops, 155060730 + 155060730 + 126611573 = 436733033
--                         2021-03-21 op 1   1 op,  384756778
--                         2021-03-21 op 18  1 op,  215243222
--                         2021-03-21 op 2   2 ops, 500000 + 500001 = 1000001
--   network_custom_json   2021-03-20 sm_claim_daily 2 ops 310121460; follow 1 op 126611573
--                         2021-03-21 sm_claim_daily 1 op 215243222
--   account_custom_json   rcexact 2021-03-20 sm_claim_daily 2 ops 310121460
--                         rcother 2021-03-20 follow 1 op 126611573
--                         rcexact 2021-03-21 sm_claim_daily 1 op 215243222

-- exact_rc_for_range itself, over block 6502: the vote of tx 1 shares its transaction with a
-- VIRTUAL op, which takes no share, so the vote gets all 50,000,000; tx 0's vote has no recorded
-- cost and gets no row. (The rollup rows below cannot show this: that day's vote row is NULL.)
DO $range$
DECLARE
    _got TEXT;
BEGIN
    SELECT string_agg(e.operation_id || '=' || e.rc_exact, ',' ORDER BY e.operation_id) INTO _got
    FROM haf_stats_app.exact_rc_for_range(6502, 6502) AS e;
    IF _got IS DISTINCT FROM '6502000011=50000000' THEN
        RAISE EXCEPTION 'FAIL (#44): exact_rc_for_range(6502, 6502) gave %, expected 6502000011=50000000', _got;
    END IF;
    RAISE NOTICE 'exact_rc_for_range: a virtual op takes no share, an op without a recorded cost gets no row';
END
$range$;

BEGIN;

-- Start from empty rows for these days and accounts: the fixture's hand-written rcexact row would
-- otherwise be added to, and its NULL rc_exact would (correctly) make the sum NULL.
DELETE FROM haf_stats_backend.account_custom_json_daily WHERE account_id IN (3101, 3102);
DELETE FROM haf_stats_backend.network_op_daily WHERE day IN ('2021-03-20', '2021-03-21');
DELETE FROM haf_stats_backend.network_custom_json_daily WHERE day IN ('2021-03-20', '2021-03-21');

SELECT haf_stats_app.process_network_ops(6500, 6501);
SELECT haf_stats_app.process_network_custom_json(6500, 6501);
SELECT haf_stats_app.process_custom_json(6500, 6501);
SELECT haf_stats_app.process_network_ops(6502, 6503);
SELECT haf_stats_app.process_network_custom_json(6502, 6503);
SELECT haf_stats_app.process_custom_json(6502, 6503);

CREATE TEMP TABLE expected_rc (rollup TEXT, k TEXT, op_count BIGINT, rc_exact BIGINT) ON COMMIT DROP;
INSERT INTO expected_rc VALUES
('nod', '2021-03-20/1', 5, NULL),
('nod', '2021-03-20/18', 3, 436733033),
('nod', '2021-03-21/1', 1, 384756778),
('nod', '2021-03-21/18', 1, 215243222),
('nod', '2021-03-21/2', 2, 1000001),
('ncj', '2021-03-20/sm_claim_daily', 2, 310121460),
('ncj', '2021-03-20/follow', 1, 126611573),
('ncj', '2021-03-21/sm_claim_daily', 1, 215243222),
('acj', '3101/2021-03-20/sm_claim_daily', 2, 310121460),
('acj', '3102/2021-03-20/follow', 1, 126611573),
('acj', '3101/2021-03-21/sm_claim_daily', 1, 215243222);

CREATE TEMP VIEW actual_rc AS
SELECT 'nod' AS rollup, day::TEXT || '/' || op_type_id AS k, op_count::BIGINT, rc_exact
FROM haf_stats_backend.network_op_daily WHERE day IN ('2021-03-20', '2021-03-21')
UNION ALL
SELECT 'ncj', day::TEXT || '/' || json_id, op_count::BIGINT, rc_exact
FROM haf_stats_backend.network_custom_json_daily WHERE day IN ('2021-03-20', '2021-03-21')
UNION ALL
SELECT 'acj', account_id::TEXT || '/' || day::TEXT || '/' || json_id, op_count::BIGINT, rc_exact
FROM haf_stats_backend.account_custom_json_daily WHERE account_id IN (3101, 3102);

DO $rollups$
DECLARE
    _diff TEXT;
BEGIN
    SELECT string_agg(format('%s %s: expected %s ops / %s, got %s ops / %s',
                             coalesce(e.rollup, a.rollup), coalesce(e.k, a.k),
                             e.op_count, coalesce(e.rc_exact::TEXT, 'NULL'),
                             a.op_count, coalesce(a.rc_exact::TEXT, 'NULL')), '; ')
    INTO _diff
    FROM expected_rc AS e
    FULL JOIN actual_rc AS a ON a.rollup = e.rollup AND a.k = e.k
    WHERE e.op_count IS DISTINCT FROM a.op_count OR e.rc_exact IS DISTINCT FROM a.rc_exact;
    IF _diff IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL (#44): processors wrote the wrong rollups: %', _diff;
    END IF;
    RAISE NOTICE 'exact rollups: the processors wrote every expected row and rc_exact';
END
$rollups$;

-- The endpoints that read these rollups now report rc_exact where a row has it, and the estimate
-- for a row without it, in the same response:
--   network rc-utilization 2021-03-21: 384756778 + 215243222 + 1000001 = 601000001, all exact;
--     2021-03-20: custom_json exact 436733033 + votes ESTIMATED (op 1 has a NULL row): at the
--     2020-06-08 rate, 5 ops * 500 + 10 bytes * 50 = 3000 (each vote body is '{}', 2 bytes).
--   network custom-json-usage sm_claim_daily: 310121460 on 2021-03-20, 215243222 on 2021-03-21.
--   network top-custom-json over both days: sm_claim_daily 3 ops 525364682, follow 1 op 126611573.
--   account dapp-footprint rcexact 2021-03-21: total 215243222.
--   account rc-footprint group_by=app rcexact 2021-03-21: Splinterlands 215243222 (the rollup's
--     exact figure), non-custom_json 384756778 + 1000001 = 385756779.
DO $endpoints$
DECLARE
    _bad TEXT := '';
    _v NUMERIC;
    _j JSONB;
BEGIN
    SELECT u.rc_total INTO _v FROM haf_stats_endpoints.get_network_rc_utilization('2021-03-21', '2021-03-21', 'day') AS u;
    IF _v IS DISTINCT FROM 601000001 THEN _bad := _bad || format(' rc-utilization 03-21=%s;', _v); END IF;
    SELECT u.rc_total INTO _v FROM haf_stats_endpoints.get_network_rc_utilization('2021-03-20', '2021-03-20', 'day') AS u;
    IF _v IS DISTINCT FROM 436736033 THEN _bad := _bad || format(' rc-utilization 03-20=%s;', _v); END IF;

    IF (SELECT string_agg(u.period || '=' || u.rc_estimate, ',' ORDER BY u.period)
        FROM haf_stats_endpoints.get_network_custom_json_usage('sm_claim_daily', '2021-03-20', '2021-03-21', 'day') AS u)
       IS DISTINCT FROM '2021-03-20=310121460,2021-03-21=215243222' THEN
        _bad := _bad || ' custom-json-usage;';
    END IF;

    IF (SELECT string_agg(t.json_id || '=' || t.op_count || '/' || t.rc_estimate, ',' ORDER BY t.json_id)
        FROM haf_stats_endpoints.get_network_top_custom_json('2021-03-20', '2021-03-21', 25, 'id', 'op_count') AS t)
       IS DISTINCT FROM 'follow=1/126611573,sm_claim_daily=3/525364682' THEN
        _bad := _bad || ' top-custom-json;';
    END IF;

    _j := haf_stats_endpoints.get_account_dapp_footprint('rcexact', '2021-03-21', '2021-03-21');
    IF (_j ->> 'total_rc_estimated')::NUMERIC IS DISTINCT FROM 215243222 THEN
        _bad := _bad || format(' dapp-footprint total=%s;', _j ->> 'total_rc_estimated');
    END IF;

    IF (SELECT string_agg(f.label || '=' || f.rc_consumed, ',' ORDER BY f.label)
        FROM haf_stats_endpoints.get_account_rc_footprint('rcexact', '2021-03-21', '2021-03-21', 'app') AS f)
       IS DISTINCT FROM 'Splinterlands=215243222,non-custom_json=385756779' THEN
        _bad := _bad || ' rc-footprint app;';
    END IF;

    IF _bad <> '' THEN
        RAISE EXCEPTION 'FAIL (#44): endpoints over the processed rollups:%', _bad;
    END IF;
    RAISE NOTICE 'exact rollups: every rollup-reading endpoint reports rc_exact where set and the estimate where not';
END
$endpoints$;

-- The backfill: make the rows look built before the column existed, put the processor on
-- 2021-03-21 (so 2021-03-20 is finished and 2021-03-21 is not), and backfill 2021-03-20.
UPDATE haf_stats_backend.network_op_daily SET rc_exact = NULL WHERE day IN ('2021-03-20', '2021-03-21');
UPDATE haf_stats_backend.network_custom_json_daily SET rc_exact = NULL WHERE day IN ('2021-03-20', '2021-03-21');
UPDATE haf_stats_backend.account_custom_json_daily SET rc_exact = NULL WHERE account_id IN (3101, 3102);
-- One row whose counts no longer match the chain: the backfill must leave it NULL.
UPDATE haf_stats_backend.account_custom_json_daily SET op_count = op_count + 1
WHERE account_id = 3102 AND day = '2021-03-20' AND json_id = 'follow';
UPDATE haf_stats_app.app_status SET last_processed_block = 6503;

DO $backfill$
DECLARE
    _set TEXT;
    _diff TEXT;
    _refused BOOLEAN := FALSE;
BEGIN
    SELECT string_agg(b.rollup || '=' || b.rows_set, ' ' ORDER BY b.rollup) INTO _set
    FROM haf_stats_app.backfill_rc_exact('2021-03-20') AS b;
    IF _set IS DISTINCT FROM 'account_custom_json_daily=1 network_custom_json_daily=2 network_op_daily=1' THEN
        RAISE EXCEPTION 'FAIL (#44): backfill of 2021-03-20 set %, expected acj 1 (rcother''s row has a wrong count), ncj 2, nod 1 (op 1 stays NULL)', _set;
    END IF;

    SELECT string_agg(a.rollup || ' ' || a.k || '=' || coalesce(a.rc_exact::TEXT, 'NULL'), '; ') INTO _diff
    FROM actual_rc AS a
    JOIN expected_rc AS e ON e.rollup = a.rollup AND e.k = a.k
    WHERE a.k LIKE '%2021-03-20%'
      AND a.rc_exact IS DISTINCT FROM CASE WHEN a.k = '3102/2021-03-20/follow' THEN NULL ELSE e.rc_exact END;
    IF _diff IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL (#44): backfill wrote the wrong rc_exact: %', _diff;
    END IF;

    IF EXISTS (SELECT 1 FROM actual_rc AS a WHERE a.k LIKE '%2021-03-21%' AND a.rc_exact IS NOT NULL) THEN
        RAISE EXCEPTION 'FAIL (#44): backfill of 2021-03-20 touched 2021-03-21';
    END IF;

    BEGIN
        PERFORM haf_stats_app.backfill_rc_exact('2021-03-21');
    EXCEPTION WHEN OTHERS THEN
        _refused := SQLERRM LIKE 'backfill_rc_exact:%';
    END;
    IF NOT _refused THEN
        RAISE EXCEPTION 'FAIL (#44): backfill_rc_exact accepted 2021-03-21, the day the processor is still on';
    END IF;
    RAISE NOTICE 'exact rollups: the backfill filled the finished day, skipped a row with other counts, and refused the unfinished day';
END
$backfill$;

ROLLBACK;
