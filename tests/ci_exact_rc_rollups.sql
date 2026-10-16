-- #44 part 2: the REAL rollup processors and the rc_exact backfill, over the rcexact fixture
-- (tests/ci_setup.sql, blocks 6500-6503), inside a transaction that is rolled back.
--
-- The endpoint tests read rollup rows the fixture writes by hand, so without this nothing in the
-- fast lane runs process_network_ops / process_network_custom_json / process_custom_json with
-- their rc_exact arm, or backfill_rc_exact. The blocks are processed in TWO batches (6500-6501,
-- 6502-6503), so a day touched by two batches exercises the accumulation rule too.
--
-- Expected, from the fixture's shares (see the rcexact comment in tests/ci_setup.sql). The second
-- batch adds 6502000021 (an sm_claim_daily with its own 30,000,000, signed by rcexact AND rcother)
-- to 2021-03-20 rows the first batch made exact, so exact + exact is accumulated in all three:
--   network_op_daily      2021-03-20 op 1   5 ops, NULL: 6502000001's transaction has no rc_cost
--                         2021-03-20 op 18  4 ops, 155060730 + 155060730 + 126611573 + 30000000
--                                           = 466733033
--                         2021-03-21 op 1   1 op,  384756778
--                         2021-03-21 op 18  1 op,  215243222
--                         2021-03-21 op 2   2 ops, 500000 + 500001 = 1000001
--   network_custom_json   2021-03-20 sm_claim_daily 3 ops 340121460; follow 1 op 126611573
--                         2021-03-21 sm_claim_daily 1 op 215243222
--   account_custom_json   rcexact 2021-03-20 sm_claim_daily 3 ops 340121460
--                         rcother 2021-03-20 sm_claim_daily 1 op 30000000 (each signer: whole RC)
--                         rcother 2021-03-20 follow 1 op 126611573
--                         rcexact 2021-03-21 sm_claim_daily 1 op 215243222

-- exact_rc_for_range itself, over block 6502: the vote of tx 1 shares its transaction with a
-- VIRTUAL op, which takes no share, so the vote gets all 50,000,000; tx 0's vote has no recorded
-- cost and gets no row; tx 2's single custom_json gets its 30,000,000. (The rollup rows below
-- cannot show the virtual op: that day's vote row is NULL.)
DO $range$
DECLARE
    _got TEXT;
BEGIN
    SELECT string_agg(e.operation_id || '=' || e.rc_exact, ',' ORDER BY e.operation_id) INTO _got
    FROM haf_stats_app.exact_rc_for_range(6502, 6502) AS e;
    IF _got IS DISTINCT FROM '6502000011=50000000,6502000021=30000000' THEN
        RAISE EXCEPTION 'FAIL (#44): exact_rc_for_range(6502, 6502) gave %, expected 6502000011=50000000,6502000021=30000000', _got;
    END IF;
    RAISE NOTICE 'exact_rc_for_range: a virtual op takes no share, an op without a recorded cost gets no row';

    -- The cutoff: a range of exactly 100,000 blocks around the fixture is split, one more block
    -- and nothing is.
    IF NOT EXISTS (SELECT 1 FROM haf_stats_app.exact_rc_for_range(6403, 106402)) THEN
        RAISE EXCEPTION 'FAIL (#44): exact_rc_for_range declined a range of 100,000 blocks';
    END IF;
    IF EXISTS (SELECT 1 FROM haf_stats_app.exact_rc_for_range(6403, 106403)) THEN
        RAISE EXCEPTION 'FAIL (#44): exact_rc_for_range split a range of 100,001 blocks';
    END IF;
    RAISE NOTICE 'exact_rc_for_range: splits 100,000 blocks, declines 100,001';
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
('nod', '2021-03-20/18', 4, 466733033),
('nod', '2021-03-21/1', 1, 384756778),
('nod', '2021-03-21/18', 1, 215243222),
('nod', '2021-03-21/2', 2, 1000001),
('ncj', '2021-03-20/sm_claim_daily', 3, 340121460),
('ncj', '2021-03-20/follow', 1, 126611573),
('ncj', '2021-03-21/sm_claim_daily', 1, 215243222),
('acj', '3101/2021-03-20/sm_claim_daily', 3, 340121460),
('acj', '3102/2021-03-20/sm_claim_daily', 1, 30000000),
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
--     2021-03-20: custom_json exact 466733033 + votes ESTIMATED (op 1 has a NULL row): at the
--     2020-06-08 rate, 5 ops * 500 + 10 bytes * 50 = 3000 (each vote body is '{}', 2 bytes).
--   network custom-json-usage sm_claim_daily: 340121460 on 2021-03-20, 215243222 on 2021-03-21.
--   network top-custom-json over both days: sm_claim_daily 4 ops 555364682, follow 1 op 126611573.
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
    IF _v IS DISTINCT FROM 466736033 THEN _bad := _bad || format(' rc-utilization 03-20=%s;', _v); END IF;

    IF (SELECT string_agg(u.period || '=' || u.rc_estimate, ',' ORDER BY u.period)
        FROM haf_stats_endpoints.get_network_custom_json_usage('sm_claim_daily', '2021-03-20', '2021-03-21', 'day') AS u)
       IS DISTINCT FROM '2021-03-20=340121460,2021-03-21=215243222' THEN
        _bad := _bad || ' custom-json-usage;';
    END IF;

    IF (SELECT string_agg(t.json_id || '=' || t.op_count || '/' || t.rc_estimate, ',' ORDER BY t.json_id)
        FROM haf_stats_endpoints.get_network_top_custom_json('2021-03-20', '2021-03-21', 25, 'id', 'op_count') AS t)
       IS DISTINCT FROM 'follow=1/126611573,sm_claim_daily=4/555364682' THEN
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

-- A batch WITHOUT a full recorded cost onto rows that are exact: block 6504, written here (and
-- rolled back), holds two more sm_claim_daily by rcexact on 2021-03-21 - one in a transaction with
-- no rc_cost, one in a transaction with 7,000,000. In that batch the group has a priced and an
-- unpriced op, so its own figure is NULL (not 7,000,000), and NULL + exact is NULL: every
-- 2021-03-21 sm_claim_daily row - the network op-18 row, the network custom_json row and
-- rcexact's row - ends NULL with 3 ops. A row is exact only while every batch that touched it was.
INSERT INTO hafd.blocks (num, created_at, total_vesting_shares, total_vesting_fund_hive)
VALUES (6504, '2021-03-21 00:00:09', 1000000000, 1000000000);
INSERT INTO hafd.transactions (block_num, trx_in_block, rc_cost) VALUES (6504, 0, NULL), (6504, 1, 7000000);
INSERT INTO hafd.operations (id, op_type_id, body_value, trx_in_block) VALUES
(6504000001, 18, '{"id": "sm_claim_daily", "required_posting_auths": ["rcexact"]}', 0),
(6504000002, 18, '{"id": "sm_claim_daily", "required_posting_auths": ["rcexact"]}', 1);
SELECT haf_stats_app.process_network_ops(6504, 6504);
SELECT haf_stats_app.process_network_custom_json(6504, 6504);
SELECT haf_stats_app.process_custom_json(6504, 6504);

DO $nulled$
DECLARE
    _bad TEXT;
BEGIN
    SELECT string_agg(a.rollup || ' ' || a.k || ' ' || a.op_count || '/' || coalesce(a.rc_exact::TEXT, 'NULL'), '; ') INTO _bad
    FROM actual_rc AS a
    WHERE a.k IN ('2021-03-21/18', '2021-03-21/sm_claim_daily', '3101/2021-03-21/sm_claim_daily')
      AND (a.rc_exact IS NOT NULL OR a.op_count <> 3);
    IF _bad IS NOT NULL OR (SELECT count(*) FROM actual_rc AS a
                            WHERE a.k IN ('2021-03-21/18', '2021-03-21/sm_claim_daily', '3101/2021-03-21/sm_claim_daily')) <> 3 THEN
        RAISE EXCEPTION 'FAIL (#44): a partly priced batch onto exact rows should leave 3 ops and NULL in each: %', _bad;
    END IF;
    RAISE NOTICE 'exact rollups: an unpriced batch turns the rows it touches NULL, in all three rollups';
END
$nulled$;

-- The other direction - the day an upgrade lands in: a FULLY priced batch onto rows that are now
-- NULL must leave them NULL (with 4 ops), not make them exact with only that batch's part. Block
-- 6505 holds one more sm_claim_daily by rcexact on 2021-03-21, alone in a transaction with
-- 9,000,000.
INSERT INTO hafd.blocks (num, created_at, total_vesting_shares, total_vesting_fund_hive)
VALUES (6505, '2021-03-21 00:00:12', 1000000000, 1000000000);
INSERT INTO hafd.transactions (block_num, trx_in_block, rc_cost) VALUES (6505, 0, 9000000);
INSERT INTO hafd.operations (id, op_type_id, body_value, trx_in_block) VALUES
(6505000001, 18, '{"id": "sm_claim_daily", "required_posting_auths": ["rcexact"]}', 0);
SELECT haf_stats_app.process_network_ops(6505, 6505);
SELECT haf_stats_app.process_network_custom_json(6505, 6505);
SELECT haf_stats_app.process_custom_json(6505, 6505);

DO $upgrade_day$
DECLARE
    _bad TEXT;
BEGIN
    IF (SELECT string_agg(e.operation_id || '=' || e.rc_exact, ',')
        FROM haf_stats_app.exact_rc_for_range(6505, 6505) AS e) IS DISTINCT FROM '6505000001=9000000' THEN
        RAISE EXCEPTION 'FAIL (#44): block 6505 should be fully priced';
    END IF;
    SELECT string_agg(a.rollup || ' ' || a.k || ' ' || a.op_count || '/' || coalesce(a.rc_exact::TEXT, 'NULL'), '; ') INTO _bad
    FROM actual_rc AS a
    WHERE a.k IN ('2021-03-21/18', '2021-03-21/sm_claim_daily', '3101/2021-03-21/sm_claim_daily')
      AND (a.rc_exact IS NOT NULL OR a.op_count <> 4);
    IF _bad IS NOT NULL OR (SELECT count(*) FROM actual_rc AS a
                            WHERE a.k IN ('2021-03-21/18', '2021-03-21/sm_claim_daily', '3101/2021-03-21/sm_claim_daily')) <> 3 THEN
        RAISE EXCEPTION 'FAIL (#44): a priced batch onto NULL rows should leave 4 ops and NULL in each: %', _bad;
    END IF;
    RAISE NOTICE 'exact rollups: a priced batch onto a NULL row leaves it NULL, in all three rollups';
END
$upgrade_day$;

-- Put 2021-03-21 back as the first two batches left it, for the checks below.
DELETE FROM haf_stats_backend.network_op_daily WHERE day = '2021-03-21' AND op_type_id = 18;
DELETE FROM haf_stats_backend.network_custom_json_daily WHERE day = '2021-03-21';
DELETE FROM haf_stats_backend.account_custom_json_daily WHERE account_id = 3101 AND day = '2021-03-21';
DELETE FROM hafd.operations WHERE id IN (6504000001, 6504000002, 6505000001);
DELETE FROM hafd.transactions WHERE block_num IN (6504, 6505);
DELETE FROM hafd.blocks WHERE num IN (6504, 6505);
INSERT INTO haf_stats_backend.network_op_daily (day, op_type_id, op_count, op_bytes, rc_exact)
SELECT r.day, r.op_type_id, r.op_count, r.op_bytes, r.rc_exact
FROM haf_stats_app.network_op_rows(6503, 6503) AS r WHERE r.op_type_id = 18;
INSERT INTO haf_stats_backend.network_custom_json_daily (day, json_id, op_count, op_bytes, rc_exact)
SELECT r.day, r.json_id, r.op_count, r.op_bytes, r.rc_exact
FROM haf_stats_app.network_custom_json_rows(6503, 6503) AS r;
INSERT INTO haf_stats_backend.account_custom_json_daily (account_id, day, json_id, op_count, op_bytes, rc_exact)
SELECT r.account_id, r.day, r.json_id, r.op_count, r.op_bytes, r.rc_exact
FROM haf_stats_app.account_custom_json_rows(6503, 6503) AS r;

-- A window that mixes an exact row and a NULL one, per row, in the endpoints that sum rollup rows:
-- the 2021-03-21 sm_claim_daily rows are made NULL, so they fall back to the op-18 estimate at that
-- day's rate (1000 + 100 per byte; the 2021-03-21 body, {"id": "sm_claim_daily",
-- "required_posting_auths": ["rcexact"]}, is 63 bytes: 1000 + 6300 = 7300), while 2021-03-20 stays
-- exact. Per-row COALESCE gives 340121460 + 7300 = 340128760; a COALESCE of the SUM would give NULL
-- and price both days with the estimate.
UPDATE haf_stats_backend.account_custom_json_daily SET rc_exact = NULL
WHERE account_id = 3101 AND day = '2021-03-21';
UPDATE haf_stats_backend.network_custom_json_daily SET rc_exact = NULL
WHERE day = '2021-03-21' AND json_id = 'sm_claim_daily';

DO $mixed$
DECLARE
    _bad TEXT := '';
    _j JSONB;
    _v NUMERIC;
BEGIN
    _j := haf_stats_endpoints.get_account_dapp_footprint('rcexact', '2021-03-20', '2021-03-21');
    IF (_j ->> 'total_rc_estimated')::NUMERIC IS DISTINCT FROM 340128760 THEN
        _bad := _bad || format(' dapp-footprint total=%s;', _j ->> 'total_rc_estimated');
    END IF;
    SELECT f.rc_consumed INTO _v
    FROM haf_stats_endpoints.get_account_rc_footprint('rcexact', '2021-03-20', '2021-03-21', 'app') AS f
    WHERE f.label = 'Splinterlands';
    IF _v IS DISTINCT FROM 340128760 THEN _bad := _bad || format(' rc-footprint app Splinterlands=%s;', _v); END IF;
    SELECT t.rc_estimate INTO _v
    FROM haf_stats_endpoints.get_network_top_custom_json('2021-03-20', '2021-03-21', 25, 'app', 'op_count') AS t
    WHERE t.app_name = 'Splinterlands';
    IF _v IS DISTINCT FROM 340128760 THEN _bad := _bad || format(' top-custom-json app Splinterlands=%s;', _v); END IF;
    SELECT t.rc_estimate INTO _v
    FROM haf_stats_endpoints.get_network_top_custom_json('2021-03-20', '2021-03-21', 25, 'id', 'op_count') AS t
    WHERE t.json_id = 'sm_claim_daily';
    IF _v IS DISTINCT FROM 340128760 THEN _bad := _bad || format(' top-custom-json id sm_claim_daily=%s;', _v); END IF;
    -- 2021-03-20 (a Saturday) and 2021-03-21 fall in the week of 2021-03-15: one period, two rows.
    IF (SELECT string_agg(u.period || '=' || u.rc_estimate, ',' ORDER BY u.period)
        FROM haf_stats_endpoints.get_network_custom_json_usage('sm_claim_daily', '2021-03-20', '2021-03-21', 'week') AS u)
       IS DISTINCT FROM '2021-03-15=340128760' THEN
        _bad := _bad || ' custom-json-usage week;';
    END IF;
    IF _bad <> '' THEN
        RAISE EXCEPTION 'FAIL (#44): exact and estimated rows in one window:%', _bad;
    END IF;
    RAISE NOTICE 'exact rollups: a window mixing exact and estimated rows adds them up per row';
END
$mixed$;

-- The backfill: make the rows look built before the column existed, put the processor on
-- 2021-03-21 (so 2021-03-20 is finished and 2021-03-21 is not), and backfill 2021-03-20 TWICE in
-- this transaction: first with rows whose op_count no longer matches the chain, then with rows
-- whose op_bytes does not - one of each in every rollup - so every guard is needed, and the second
-- call reuses the first call's temp tables.
UPDATE haf_stats_backend.network_op_daily SET rc_exact = NULL WHERE day IN ('2021-03-20', '2021-03-21');
UPDATE haf_stats_backend.network_custom_json_daily SET rc_exact = NULL WHERE day IN ('2021-03-20', '2021-03-21');
UPDATE haf_stats_backend.account_custom_json_daily SET rc_exact = NULL WHERE account_id IN (3101, 3102);
-- Pass 1: wrong op_count on rcother's follow row, the network follow row and the op-18 row.
UPDATE haf_stats_backend.account_custom_json_daily SET op_count = op_count + 1
WHERE account_id = 3102 AND day = '2021-03-20' AND json_id = 'follow';
UPDATE haf_stats_backend.network_custom_json_daily SET op_count = op_count + 1
WHERE day = '2021-03-20' AND json_id = 'follow';
UPDATE haf_stats_backend.network_op_daily SET op_count = op_count + 1
WHERE day = '2021-03-20' AND op_type_id = 18;
-- A row that already holds a value: the backfill must leave it as it is, even when it differs.
UPDATE haf_stats_backend.network_custom_json_daily SET rc_exact = 1
WHERE day = '2021-03-20' AND json_id = 'sm_claim_daily';
UPDATE haf_stats_app.app_status SET last_processed_block = 6503;

DO $backfill$
DECLARE
    _set TEXT;
    _diff TEXT;
    _refused BOOLEAN := FALSE;
BEGIN
    SELECT string_agg(b.rollup || '=' || b.rows_set || '/' || b.rows_mismatched, ' ' ORDER BY b.rollup) INTO _set
    FROM haf_stats_app.backfill_rc_exact('2021-03-20') AS b;
    IF _set IS DISTINCT FROM 'account_custom_json_daily=2/1 network_custom_json_daily=0/1 network_op_daily=0/1' THEN
        RAISE EXCEPTION 'FAIL (#44): backfill pass 1 (op_count) set/mismatched %, expected acj 2/1 (rcother''s follow), ncj 0/1 (sm_claim_daily already holds a value, follow), nod 0/1 (op 18; op 1 stays NULL)', _set;
    END IF;
    SELECT string_agg(e.rollup || ' ' || e.k || '=' || coalesce(a.rc_exact::TEXT, 'NULL'), '; ') INTO _diff
    FROM expected_rc AS e
    LEFT JOIN actual_rc AS a ON a.rollup = e.rollup AND a.k = e.k
    WHERE e.k LIKE '%2021-03-20%'
      AND (a.k IS NULL
           OR a.rc_exact IS DISTINCT FROM CASE WHEN e.k IN ('3102/2021-03-20/follow', '2021-03-20/follow', '2021-03-20/18')
                                               THEN NULL
                                               WHEN e.rollup = 'ncj' AND e.k = '2021-03-20/sm_claim_daily' THEN 1
                                               ELSE e.rc_exact END);
    IF _diff IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL (#44): backfill pass 1 wrote the wrong rc_exact: %', _diff;
    END IF;

    -- Pass 2: counts put back, every 2021-03-20 row NULL again, and wrong op_bytes instead on
    -- rcother's sm_claim_daily row, the network follow row and the op-18 row.
    UPDATE haf_stats_backend.account_custom_json_daily SET op_count = op_count - 1
    WHERE account_id = 3102 AND day = '2021-03-20' AND json_id = 'follow';
    UPDATE haf_stats_backend.network_custom_json_daily SET op_count = op_count - 1
    WHERE day = '2021-03-20' AND json_id = 'follow';
    UPDATE haf_stats_backend.network_op_daily SET op_count = op_count - 1
    WHERE day = '2021-03-20' AND op_type_id = 18;
    UPDATE haf_stats_backend.network_op_daily SET rc_exact = NULL WHERE day = '2021-03-20';
    UPDATE haf_stats_backend.network_custom_json_daily SET rc_exact = NULL WHERE day = '2021-03-20';
    UPDATE haf_stats_backend.account_custom_json_daily SET rc_exact = NULL WHERE day = '2021-03-20' AND account_id IN (3101, 3102);
    UPDATE haf_stats_backend.account_custom_json_daily SET op_bytes = op_bytes + 1
    WHERE account_id = 3102 AND day = '2021-03-20' AND json_id = 'sm_claim_daily';
    UPDATE haf_stats_backend.network_custom_json_daily SET op_bytes = op_bytes + 1
    WHERE day = '2021-03-20' AND json_id = 'follow';
    UPDATE haf_stats_backend.network_op_daily SET op_bytes = op_bytes + 1
    WHERE day = '2021-03-20' AND op_type_id = 18;

    SELECT string_agg(b.rollup || '=' || b.rows_set || '/' || b.rows_mismatched, ' ' ORDER BY b.rollup) INTO _set
    FROM haf_stats_app.backfill_rc_exact('2021-03-20') AS b;
    IF _set IS DISTINCT FROM 'account_custom_json_daily=2/1 network_custom_json_daily=1/1 network_op_daily=0/1' THEN
        RAISE EXCEPTION 'FAIL (#44): backfill pass 2 (op_bytes) set/mismatched %, expected acj 2/1 (rcother''s sm_claim_daily), ncj 1/1 (follow), nod 0/1 (op 18)', _set;
    END IF;
    SELECT string_agg(e.rollup || ' ' || e.k || '=' || coalesce(a.rc_exact::TEXT, 'NULL'), '; ') INTO _diff
    FROM expected_rc AS e
    LEFT JOIN actual_rc AS a ON a.rollup = e.rollup AND a.k = e.k
    WHERE e.k LIKE '%2021-03-20%'
      AND (a.k IS NULL
           OR a.rc_exact IS DISTINCT FROM CASE WHEN e.k IN ('3102/2021-03-20/sm_claim_daily', '2021-03-20/follow', '2021-03-20/18')
                                               THEN NULL ELSE e.rc_exact END);
    IF _diff IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL (#44): backfill pass 2 wrote the wrong rc_exact: %', _diff;
    END IF;

    -- Pass 3: counts and bytes put back and every 2021-03-20 row NULL again, then:
    --   * already exact with matching counts (op 18, rcexact's sm_claim_daily): must keep 1;
    --   * already exact with other counts (rcother's follow, the network follow): neither filled
    --     nor counted as mismatched - only NULL rows are;
    --   * the 2021-03-21 op-18, sm_claim_daily and rcexact sm_claim_daily rows given the counts of
    --     the same key on 2021-03-20, so only the day keeps them apart (checked below: 2021-03-21
    --     must stay untouched).
    UPDATE haf_stats_backend.account_custom_json_daily SET op_bytes = op_bytes - 1
    WHERE account_id = 3102 AND day = '2021-03-20' AND json_id = 'sm_claim_daily';
    UPDATE haf_stats_backend.network_custom_json_daily SET op_bytes = op_bytes - 1
    WHERE day = '2021-03-20' AND json_id = 'follow';
    UPDATE haf_stats_backend.network_op_daily SET op_bytes = op_bytes - 1
    WHERE day = '2021-03-20' AND op_type_id = 18;
    UPDATE haf_stats_backend.network_op_daily SET rc_exact = NULL WHERE day = '2021-03-20';
    UPDATE haf_stats_backend.network_custom_json_daily SET rc_exact = NULL WHERE day = '2021-03-20';
    UPDATE haf_stats_backend.account_custom_json_daily SET rc_exact = NULL WHERE day = '2021-03-20' AND account_id IN (3101, 3102);
    UPDATE haf_stats_backend.network_op_daily SET rc_exact = 1
    WHERE day = '2021-03-20' AND op_type_id = 18;
    UPDATE haf_stats_backend.account_custom_json_daily SET rc_exact = 1
    WHERE account_id = 3101 AND day = '2021-03-20' AND json_id = 'sm_claim_daily';
    UPDATE haf_stats_backend.account_custom_json_daily SET rc_exact = 1, op_count = op_count + 1
    WHERE account_id = 3102 AND day = '2021-03-20' AND json_id = 'follow';
    UPDATE haf_stats_backend.network_custom_json_daily SET rc_exact = 1, op_bytes = op_bytes + 1
    WHERE day = '2021-03-20' AND json_id = 'follow';
    UPDATE haf_stats_backend.network_op_daily AS t SET op_count = s.op_count, op_bytes = s.op_bytes
    FROM haf_stats_backend.network_op_daily AS s
    WHERE t.day = '2021-03-21' AND s.day = '2021-03-20' AND t.op_type_id = 18 AND s.op_type_id = 18;
    UPDATE haf_stats_backend.network_custom_json_daily AS t SET op_count = s.op_count, op_bytes = s.op_bytes
    FROM haf_stats_backend.network_custom_json_daily AS s
    WHERE t.day = '2021-03-21' AND s.day = '2021-03-20' AND t.json_id = 'sm_claim_daily' AND s.json_id = 'sm_claim_daily';
    UPDATE haf_stats_backend.account_custom_json_daily AS t SET op_count = s.op_count, op_bytes = s.op_bytes
    FROM haf_stats_backend.account_custom_json_daily AS s
    WHERE t.account_id = 3101 AND s.account_id = 3101 AND t.day = '2021-03-21' AND s.day = '2021-03-20'
      AND t.json_id = 'sm_claim_daily' AND s.json_id = 'sm_claim_daily';

    SELECT string_agg(b.rollup || '=' || b.rows_set || '/' || b.rows_mismatched, ' ' ORDER BY b.rollup) INTO _set
    FROM haf_stats_app.backfill_rc_exact('2021-03-20') AS b;
    IF _set IS DISTINCT FROM 'account_custom_json_daily=1/0 network_custom_json_daily=1/0 network_op_daily=0/0' THEN
        RAISE EXCEPTION 'FAIL (#44): backfill pass 3 (values already there) set/mismatched %, expected acj 1/0 (rcother''s sm_claim_daily), ncj 1/0 (sm_claim_daily), nod 0/0', _set;
    END IF;
    SELECT string_agg(e.rollup || ' ' || e.k || '=' || coalesce(a.rc_exact::TEXT, 'NULL'), '; ') INTO _diff
    FROM expected_rc AS e
    LEFT JOIN actual_rc AS a ON a.rollup = e.rollup AND a.k = e.k
    WHERE e.k LIKE '%2021-03-20%'
      AND (a.k IS NULL
           OR a.rc_exact IS DISTINCT FROM CASE WHEN e.k IN ('2021-03-20/18', '3101/2021-03-20/sm_claim_daily',
                                                            '3102/2021-03-20/follow', '2021-03-20/follow')
                                               THEN 1 ELSE e.rc_exact END);
    IF _diff IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL (#44): backfill pass 3 replaced a value or wrote the wrong rc_exact: %', _diff;
    END IF;

    IF EXISTS (SELECT 1 FROM actual_rc AS a WHERE a.k LIKE '%2021-03-21%' AND a.rc_exact IS NOT NULL) THEN
        RAISE EXCEPTION 'FAIL (#44): backfill of 2021-03-20 touched 2021-03-21';
    END IF;

    -- A finished day with no blocks at all: nothing to do, and no error.
    IF EXISTS (SELECT 1 FROM haf_stats_app.backfill_rc_exact('2021-03-19') AS b WHERE b.rows_set > 0) THEN
        RAISE EXCEPTION 'FAIL (#44): backfill of a day without blocks set rows';
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
