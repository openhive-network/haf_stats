-- The retention window of the per-account daily rows (#124, db/daily_retention.sql), over a
-- synthetic 2023 history of six accounts, in one transaction that is rolled back: the history and
-- what the rollups and endpoints give over it unpruned are set up once, and each scenario runs
-- from there and is rolled back to it.
--
--   A. A batch prunes: active_users_daily and account_custom_json_daily keep their rows from the
--      window's first day on, account_custom_json_monthly gets the months before it, and the
--      rollups, get_network_top_accounts transaction_count and the two custom_json footprints are
--      what they were before the prune, for in-window and month-aligned ranges, on both the
--      endpoints' fast and ordered paths. A range starting before the window is the range widened
--      to whole months. A refresh from genesis afterwards restates nothing it cannot recount.
--   B. During massive sync the active-user refreshes are deferred: the prune restates the periods
--      before the window first and moves the record up, and the deferred refresh then completes
--      the rollups to exactly what one refresh over the unpruned history gives. This lane has no
--      haf_stats_app.run_deferred_rollup_refreshes (db/haf_stats_app.sql needs a HAF), so the
--      deferred refresh is run as that function runs it: from the record to the last processed
--      day. The CI sync runs the real one over a pruned replay (tests/ci_deferred_refresh_*.sql).
--   C. A database from before #124 mid-replay - active_users_daily on its old key with
--      idx_aud_opclass_day, the rollups owed from the first day, nothing pruned - converted by
--      haf_stats_app.upgrade_daily_retention: the same end state as A and B.
--
-- The fixtures' own custom_json rows (2020 and 2021) are older than the window too, so they are
-- rolled up as well, and their footprints are compared like the synthetic ones.

\set ON_ERROR_STOP on

-- Day i of the history (0 = 2023-01-01, 195 = 2023-07-15) is block 7,200,000 + 1200 i, so every day
-- starts a 1200-block refresh bucket.
CREATE FUNCTION pg_temp.day_block(_day DATE) RETURNS INT LANGUAGE sql IMMUTABLE AS $$
    SELECT 7200000 + (_day - DATE '2023-01-01') * 1200
$$;

-- The synthetic history, into whatever shape the two daily tables have.
CREATE FUNCTION pg_temp.seed_history() RETURNS VOID LANGUAGE plpgsql AS $fn$
BEGIN
    INSERT INTO hafd.accounts (id, name)
    SELECT 960000 + k, 'retention-' || chr(96 + k) FROM generate_series(1, 6) AS k
    ON CONFLICT DO NOTHING;
    INSERT INTO hafd.blocks (num, created_at, total_vesting_shares, total_vesting_fund_hive)
    SELECT pg_temp.day_block(d::DATE), d + INTERVAL '6 hours', 1000000000, 1000000000
    FROM generate_series(DATE '2023-01-01', DATE '2023-07-15', INTERVAL '1 day') AS d
    ON CONFLICT DO NOTHING;
    -- Two custom_json rates, the second fractional, so each day must be priced at its own.
    INSERT INTO haf_stats_backend.rc_op_stats_daily (day, op_type_id, base_rc, byte_rc, avg_cost_rc, avg_bytes, sample_count)
    VALUES ('2023-01-01', 18, 20000000, 400000.5, 30000000, 40, 10),
           ('2023-03-15', 18, 25000000, 512345.25, 36000000, 44, 10)
    ON CONFLICT DO NOTHING;

    INSERT INTO haf_stats_backend.active_users_daily (day, op_class, account_id, ops)
    SELECT d.day, c.op_class, 960000 + k, c.ops
    FROM (SELECT g::DATE AS day, (g::DATE - DATE '2023-01-01') AS i
          FROM generate_series(DATE '2023-01-01', DATE '2023-07-15', INTERVAL '1 day') AS g) AS d
    CROSS JOIN generate_series(1, 6) AS k
    CROSS JOIN LATERAL (
        SELECT -1::SMALLINT AS op_class, 1 + (d.i * k) % 7 AS ops
        UNION ALL SELECT 3::SMALLINT, 1 + d.i % 3 WHERE d.i % 2 = 0
        UNION ALL SELECT 5::SMALLINT, 2 WHERE k % 2 = 1
    ) AS c
    WHERE d.i % (k + 1) <> 0;
    INSERT INTO haf_stats_backend.active_user_ops_daily (day, op_class, operations)
    SELECT au.day, au.op_class, SUM(au.ops)
    FROM haf_stats_backend.active_users_daily AS au
    WHERE au.day >= '2023-01-01'
    GROUP BY au.day, au.op_class
    ON CONFLICT (day, op_class) DO UPDATE SET operations = EXCLUDED.operations;

    INSERT INTO haf_stats_backend.account_custom_json_daily (account_id, day, custom_json_type_id, op_count, op_bytes, rc_exact)
    SELECT 960000 + k, d.day, hafd.ci_custom_json_type_id(t.id), 1 + (d.i + k) % 5,
           50 * (1 + (d.i + k) % 5) + 7 * t.n + d.i,
           CASE WHEN d.i % 4 = 0 THEN 1000000 * (1 + (d.i + k) % 5) + d.i END
    FROM (SELECT g::DATE AS day, (g::DATE - DATE '2023-01-01') AS i
          FROM generate_series(DATE '2023-01-01', DATE '2023-07-15', INTERVAL '1 day') AS g) AS d
    CROSS JOIN generate_series(1, 4) AS k
    CROSS JOIN (VALUES (1, 'sm_claim_reward'), (2, 'follow'), (3, 'retention_app')) AS t (n, id)
    WHERE (d.i + k + t.n) % 3 <> 0;

    -- retention-a's signed ops, which bound get_account_rc_footprint's window: a transfer every
    -- third day and a custom_json every day.
    INSERT INTO hive.account_operations_view (account_id, transacting_account_id, block_num, op_type_id, account_op_seq_no)
    SELECT 960001, 960001, pg_temp.day_block(o.day), o.op_type_id,
           ROW_NUMBER() OVER (ORDER BY o.day, o.op_type_id)
    FROM (
        SELECT g::DATE AS day, 18::SMALLINT AS op_type_id
        FROM generate_series(DATE '2023-01-01', DATE '2023-07-15', INTERVAL '1 day') AS g
        UNION ALL
        SELECT g::DATE, 2::SMALLINT
        FROM generate_series(DATE '2023-01-01', DATE '2023-07-15', INTERVAL '3 days') AS g
    ) AS o;
END;
$fn$;

-- The rollups' synthetic periods, whole rows.
CREATE FUNCTION pg_temp.rollup_rows() RETURNS TABLE (rollup TEXT, r TEXT) LANGUAGE sql STABLE AS $fn$
    SELECT 'active_users_period_counts', pc::TEXT FROM haf_stats_backend.active_users_period_counts AS pc
    WHERE pc.period >= '2022-12-26'
    UNION ALL
    SELECT 'active_users_account_monthly', am::TEXT FROM haf_stats_backend.active_users_account_monthly AS am
    WHERE am.month >= '2023-01-01'
$fn$;

-- What the endpoints answer, one row per case. The *_rounded cases start before every window
-- these scenarios prune to and must answer as their month-aligned twin (column twin) after it.
CREATE TEMP TABLE retention_case (name TEXT PRIMARY KEY, twin TEXT);
CREATE FUNCTION pg_temp.answers() RETURNS TABLE (name TEXT, answer TEXT) LANGUAGE plpgsql AS $fn$
BEGIN
    -- get_network_top_accounts transaction_count: the default (fast) path and the ordered path.
    RETURN QUERY
    SELECT c.name || CASE WHEN o.ob IS NULL THEN '' ELSE '/' || o.ob || '_' || o.dir END,
           (SELECT string_agg(r::TEXT, '|' ORDER BY r.rank)
            FROM haf_stats_endpoints.get_network_top_accounts('transaction_count', c.from_day, c.to_day, 10, o.ob, o.dir) AS r)
    FROM (VALUES
        ('tc_aligned_jan_feb', '2023-01-01', '2023-02-28'),
        ('tc_aligned_feb', '2023-02-01', '2023-02-28'),
        ('tc_aligned_span', '2023-02-01', '2023-06-20'),
        ('tc_window', '2023-06-05', '2023-07-10'),
        ('tc_window_month', '2023-06-01', '2023-06-30'),
        ('tc_rounded', '2023-01-15', '2023-02-10'),
        ('tc_rounded_span', '2023-02-14', '2023-06-20')
    ) AS c (name, from_day, to_day)
    CROSS JOIN (VALUES (NULL::TEXT, 'desc'), ('account', 'asc'), ('op_count', 'asc')) AS o (ob, dir);

    -- The two custom_json footprints that read the rollup.
    RETURN QUERY
    SELECT c.name || '/' || a.name || '/' || g.by,
           CASE WHEN g.by = 'dapp'
                THEN haf_stats_endpoints.get_account_dapp_footprint(a.name, c.from_day, c.to_day)::TEXT
                ELSE (SELECT string_agg(r::TEXT, '|' ORDER BY r.label)
                      FROM haf_stats_endpoints.get_account_rc_footprint(a.name, c.from_day, c.to_day, g.by) AS r)
           END
    FROM (VALUES
        ('cj_aligned', '2023-01-01', '2023-03-31'),
        ('cj_aligned_jan_feb', '2023-01-01', '2023-02-28'),
        ('cj_aligned_span', '2023-02-01', '2023-06-20'),
        ('cj_window', '2023-06-05', '2023-07-10'),
        ('cj_rounded', '2023-01-10', '2023-02-20'),
        ('cj_fixture_2020', '2020-06-01', '2020-06-30'),
        ('cj_fixture_2021', '2021-03-01', '2021-03-31')
    ) AS c (name, from_day, to_day)
    CROSS JOIN (VALUES ('retention-a'), ('retention-b'), ('dapptester'), ('rctester')) AS a (name)
    CROSS JOIN (VALUES ('dapp'), ('app'), ('category')) AS g (by);
END;
$fn$;

-- Every case against the answers taken before anything was pruned: equal, or for a rounded case,
-- equal to its twin's. A widened range differs from the exact one in these fixtures (checked, so
-- the rounded cases test something).
CREATE TEMP TABLE retention_before (name TEXT PRIMARY KEY, answer TEXT);
CREATE FUNCTION pg_temp.check_answers(_scenario TEXT) RETURNS VOID LANGUAGE plpgsql AS $fn$
DECLARE
    _bad TEXT;
    _n INT;
BEGIN
    SELECT count(*) INTO _n FROM retention_before AS b WHERE b.answer IS NOT NULL;
    IF _n < 50 THEN
        RAISE EXCEPTION '%: only % cases have an answer before the prune, too few to test anything', _scenario, _n;
    END IF;
    SELECT string_agg(c.name, ', ' ORDER BY c.name) INTO _bad
    FROM retention_case AS c
    JOIN pg_temp.answers() AS a ON a.name = c.name
    JOIN retention_before AS b ON b.name = COALESCE(c.twin, c.name)
    WHERE a.answer IS DISTINCT FROM b.answer;
    IF _bad IS NOT NULL THEN
        RAISE EXCEPTION '%: these endpoint answers changed with the prune: %', _scenario, _bad;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM retention_case AS c
        JOIN retention_before AS r ON r.name = c.name JOIN retention_before AS t ON t.name = c.twin
        WHERE c.twin LIKE 'tc_%' AND r.answer IS DISTINCT FROM t.answer)
       OR NOT EXISTS (
        SELECT 1 FROM retention_case AS c
        JOIN retention_before AS r ON r.name = c.name JOIN retention_before AS t ON t.name = c.twin
        WHERE c.twin LIKE 'cj_%' AND r.answer IS DISTINCT FROM t.answer) THEN
        RAISE EXCEPTION '%: no rounded case answered differently from its twin before the prune, so none tests the rounding', _scenario;
    END IF;
    RAISE NOTICE '%: % endpoint answers as before the prune', _scenario,
        (SELECT count(*) FROM retention_case);
END;
$fn$;

-- The rollups against those of one refresh over the whole unpruned history.
CREATE TEMP TABLE retention_rollups (rollup TEXT, r TEXT);
CREATE FUNCTION pg_temp.check_rollups(_scenario TEXT) RETURNS VOID LANGUAGE plpgsql AS $fn$
DECLARE
    _missing BIGINT;
    _extra BIGINT;
BEGIN
    SELECT count(*) INTO _missing FROM (SELECT * FROM retention_rollups EXCEPT ALL SELECT * FROM pg_temp.rollup_rows()) AS x;
    SELECT count(*) INTO _extra FROM (SELECT * FROM pg_temp.rollup_rows() EXCEPT ALL SELECT * FROM retention_rollups) AS x;
    IF _missing <> 0 OR _extra <> 0 OR (SELECT count(*) FROM retention_rollups) < 400 THEN
        RAISE EXCEPTION '%: the rollups lack % rows and have % rows that one refresh over the unpruned history gives / does not give (% rows expected)',
            _scenario, _missing, _extra, (SELECT count(*) FROM retention_rollups);
    END IF;
    RAISE NOTICE '%: % rollup rows, as one refresh over the unpruned history gives them', _scenario,
        (SELECT count(*) FROM retention_rollups);
END;
$fn$;

CREATE FUNCTION pg_temp.check_pruned(_scenario TEXT, _keep DATE) RETURNS VOID LANGUAGE plpgsql AS $fn$
BEGIN
    IF (SELECT string_agg(f.daily_table || '=' || f.kept_from, ',' ORDER BY f.daily_table) FROM haf_stats_app.daily_retention_floor AS f)
       IS DISTINCT FROM format('account_custom_json_daily=%s,active_users_daily=%s', _keep, _keep) THEN
        RAISE EXCEPTION '%: the retention floors are %, expected % for both tables', _scenario,
            (SELECT string_agg(f.daily_table || '=' || f.kept_from, ',') FROM haf_stats_app.daily_retention_floor AS f), _keep;
    END IF;
    IF (SELECT MIN(au.day) FROM haf_stats_backend.active_users_daily AS au) <> _keep
       OR (SELECT MIN(acj.day) FROM haf_stats_backend.account_custom_json_daily AS acj) <> _keep THEN
        RAISE EXCEPTION '%: the daily tables start at % and %, not at the floor %', _scenario,
            (SELECT MIN(au.day) FROM haf_stats_backend.active_users_daily AS au),
            (SELECT MIN(acj.day) FROM haf_stats_backend.account_custom_json_daily AS acj), _keep;
    END IF;
    -- Every daily row before the floor is in a monthly one: op counts per (account, month).
    IF EXISTS (
        SELECT 1 FROM retention_cj_before AS b
        WHERE b.month < _keep
          AND b.op_count IS DISTINCT FROM (
              SELECT SUM(m.op_count) FROM haf_stats_backend.account_custom_json_monthly AS m
              WHERE m.account_id = b.account_id AND m.month = b.month)
    ) OR EXISTS (SELECT 1 FROM haf_stats_backend.account_custom_json_monthly AS m WHERE m.month >= _keep) THEN
        RAISE EXCEPTION '%: account_custom_json_monthly does not hold exactly the months before %', _scenario, _keep;
    END IF;
END;
$fn$;
CREATE TEMP TABLE retention_cj_before (account_id INT, month DATE, op_count BIGINT);

CREATE FUNCTION pg_temp.run_deferred_active_users() RETURNS VOID LANGUAGE plpgsql AS $fn$
DECLARE
    _from DATE;
BEGIN
    DELETE FROM haf_stats_app.deferred_rollup_refreshes WHERE processor = 'process_active_users'
    RETURNING dirty_from INTO _from;
    PERFORM haf_stats_app.refresh_active_users_periods(_from, '2023-07-15');
    PERFORM haf_stats_app.refresh_active_users_account_monthly(_from, '2023-07-15');
END;
$fn$;

BEGIN;
SELECT pg_temp.seed_history();
SELECT haf_stats_app.refresh_active_users_periods('2023-01-01', '2023-07-15');
SELECT haf_stats_app.refresh_active_users_account_monthly('2023-01-01', '2023-07-15');
INSERT INTO retention_rollups SELECT * FROM pg_temp.rollup_rows();
INSERT INTO retention_before SELECT * FROM pg_temp.answers();
INSERT INTO retention_case (name, twin)
SELECT b.name,
       CASE WHEN b.name LIKE 'tc_rounded_span%' THEN replace(b.name, 'tc_rounded_span', 'tc_aligned_span')
            WHEN b.name LIKE 'tc_rounded%' THEN replace(b.name, 'tc_rounded', 'tc_aligned_jan_feb')
            WHEN b.name LIKE 'cj_rounded%' THEN replace(b.name, 'cj_rounded', 'cj_aligned_jan_feb')
       END
FROM retention_before AS b;
INSERT INTO retention_cj_before
SELECT acj.account_id, DATE_TRUNC('month', acj.day)::DATE, SUM(acj.op_count)
FROM haf_stats_backend.account_custom_json_daily AS acj GROUP BY 1, 2;
SAVEPOINT unpruned;

-- ---------------------------------------------------------------------------
-- A. A batch prunes.
-- ---------------------------------------------------------------------------

-- A batch crossing the bucket that starts 2023-05-08: the window is 35 days back, from 2023-04-03,
-- so it keeps 2023-04-01 on. That first day is a Saturday: its week starts in March.
SELECT haf_stats_app.process_daily_retention(pg_temp.day_block('2023-05-08') + 1, pg_temp.day_block('2023-05-08') + 1200);
SELECT pg_temp.check_pruned('A', '2023-04-01');
SELECT pg_temp.check_rollups('A');
SELECT pg_temp.check_answers('A');

-- A later batch in the same window prunes nothing more.
SELECT haf_stats_app.process_daily_retention(pg_temp.day_block('2023-05-09') + 1, pg_temp.day_block('2023-05-09') + 1200);
SELECT pg_temp.check_pruned('A, a batch later', '2023-04-01');

-- A refresh from genesis restates only from the floor: the periods before it keep their counts.
SELECT haf_stats_app.refresh_active_users_periods('2016-03-24');
SELECT haf_stats_app.refresh_active_users_account_monthly('2016-03-24');
SELECT pg_temp.check_rollups('A, refreshed from genesis');
ROLLBACK TO SAVEPOINT unpruned;

-- ---------------------------------------------------------------------------
-- B. Massive sync: the refreshes are deferred, from the first day of May on.
-- ---------------------------------------------------------------------------

-- As a sync whose deferral started on 2023-05-01 leaves them: refreshed up to the end of April
-- (whose last week ends on its last day), nothing after.
DELETE FROM haf_stats_backend.active_users_period_counts WHERE period >= '2023-05-01';
DELETE FROM haf_stats_backend.active_users_account_monthly WHERE month >= '2023-05-01';
INSERT INTO haf_stats_app.deferred_rollup_refreshes (processor, dirty_from) VALUES ('process_active_users', '2023-05-01');

-- The bucket from 2023-07-08: the window keeps 2023-06-01 (a Thursday) on, so May - and the week
-- of 2023-05-29, which ends in June - must be restated before May's rows go.
SELECT haf_stats_app.process_daily_retention(pg_temp.day_block('2023-07-08') + 1, pg_temp.day_block('2023-07-08') + 1200);
DO $b$
BEGIN
    IF (SELECT d.dirty_from FROM haf_stats_app.deferred_rollup_refreshes AS d WHERE d.processor = 'process_active_users')
       IS DISTINCT FROM DATE '2023-06-01' THEN
        RAISE EXCEPTION 'B: the deferred active-user refresh is recorded from %, not from the new floor 2023-06-01',
            (SELECT d.dirty_from FROM haf_stats_app.deferred_rollup_refreshes AS d WHERE d.processor = 'process_active_users');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM haf_stats_backend.active_users_period_counts
                   WHERE period_type = 'week' AND period = '2023-05-29')
       OR NOT EXISTS (SELECT 1 FROM haf_stats_backend.active_users_account_monthly WHERE month = '2023-05-01')
       OR EXISTS (SELECT 1 FROM haf_stats_backend.active_users_period_counts
                  WHERE period_type = 'day' AND period >= '2023-06-01') THEN
        RAISE EXCEPTION 'B: the prune did not restate exactly the periods before the floor that the deferred refresh owed';
    END IF;
END
$b$;
SELECT pg_temp.check_pruned('B', '2023-06-01');
SELECT pg_temp.run_deferred_active_users();
SELECT pg_temp.check_rollups('B, after the deferred refresh');
SELECT pg_temp.check_answers('B');
ROLLBACK TO SAVEPOINT unpruned;

-- ---------------------------------------------------------------------------
-- C. A database from before #124, mid-replay, converted in place.
-- ---------------------------------------------------------------------------

SET LOCAL ROLE haf_stats_owner;
CREATE TABLE haf_stats_backend.active_users_daily_old (
    day DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    account_id INT NOT NULL,
    ops INT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_class, account_id)
);
INSERT INTO haf_stats_backend.active_users_daily_old SELECT * FROM haf_stats_backend.active_users_daily;
DROP TABLE haf_stats_backend.active_users_daily;
ALTER TABLE haf_stats_backend.active_users_daily_old RENAME TO active_users_daily;
CREATE INDEX idx_aud_opclass_day ON haf_stats_backend.active_users_daily (op_class, day) INCLUDE (account_id, ops);
RESET ROLE;
CREATE TEMP TABLE retention_c_daily AS
SELECT au.* FROM haf_stats_backend.active_users_daily AS au WHERE au.day >= '2023-06-01';
-- Massive sync from 2023-01-01: no synthetic period refreshed yet.
DELETE FROM haf_stats_backend.active_users_period_counts WHERE period >= '2022-12-26';
DELETE FROM haf_stats_backend.active_users_account_monthly WHERE month >= '2023-01-01';
INSERT INTO haf_stats_app.deferred_rollup_refreshes (processor, dirty_from) VALUES ('process_active_users', '2023-01-01');
-- Nothing pruned yet (this lane's own install of db/daily_retention.sql recorded a floor).
DELETE FROM haf_stats_app.daily_retention_floor;
-- Processed up to 2023-07-15: the window keeps 2023-06-01 on.
UPDATE haf_stats_app.app_status SET last_processed_block = pg_temp.day_block('2023-07-15');

SELECT set_config('retention.acj_oid', 'haf_stats_backend.account_custom_json_daily'::REGCLASS::OID::TEXT, TRUE);
CALL haf_stats_app.upgrade_daily_retention(FALSE);

DO $c$
BEGIN
    IF (SELECT pg_get_constraintdef(c.oid) FROM pg_constraint AS c
        WHERE c.conrelid = 'haf_stats_backend.active_users_daily'::REGCLASS AND c.contype = 'p')
       IS DISTINCT FROM 'PRIMARY KEY (op_class, day, account_id)'
       OR to_regclass('haf_stats_backend.idx_aud_opclass_day') IS NOT NULL
       OR to_regclass('haf_stats_backend.active_users_daily_kept') IS NOT NULL
       OR to_regclass('haf_stats_backend.account_custom_json_daily_kept') IS NOT NULL THEN
        RAISE EXCEPTION 'C: active_users_daily is not re-keyed on (op_class, day, account_id) without idx_aud_opclass_day';
    END IF;
    IF NOT has_table_privilege('haf_stats_user', 'haf_stats_backend.active_users_daily', 'SELECT')
       OR NOT has_table_privilege('haf_stats_user', 'haf_stats_backend.account_custom_json_daily', 'SELECT') THEN
        RAISE EXCEPTION 'C: a rebuilt daily table is not readable by haf_stats_user';
    END IF;
    IF EXISTS (SELECT * FROM retention_c_daily EXCEPT ALL SELECT * FROM haf_stats_backend.active_users_daily)
       OR EXISTS (SELECT * FROM haf_stats_backend.active_users_daily EXCEPT ALL SELECT * FROM retention_c_daily) THEN
        RAISE EXCEPTION 'C: active_users_daily does not hold exactly its rows from 2023-06-01 on';
    END IF;
    IF 'haf_stats_backend.account_custom_json_daily'::REGCLASS::OID = current_setting('retention.acj_oid')::OID THEN
        RAISE EXCEPTION 'C: account_custom_json_daily was pruned in place, not replaced by a copy of its kept rows';
    END IF;
    IF (SELECT d.dirty_from FROM haf_stats_app.deferred_rollup_refreshes AS d WHERE d.processor = 'process_active_users')
       IS DISTINCT FROM DATE '2023-06-01' THEN
        RAISE EXCEPTION 'C: the deferred active-user refresh is recorded from %, not from the floor 2023-06-01',
            (SELECT d.dirty_from FROM haf_stats_app.deferred_rollup_refreshes AS d WHERE d.processor = 'process_active_users');
    END IF;
END
$c$;
SELECT pg_temp.check_pruned('C', '2023-06-01');
SELECT pg_temp.check_answers('C');
SELECT pg_temp.run_deferred_active_users();
SELECT pg_temp.check_rollups('C, after the deferred refresh');

-- Installed again: the floor is recorded, so nothing is converted or pruned a second time.
CALL haf_stats_app.upgrade_daily_retention(FALSE);
SELECT pg_temp.check_pruned('C, upgraded again', '2023-06-01');
SELECT pg_temp.check_answers('C, upgraded again');
ROLLBACK TO SAVEPOINT unpruned;

-- The rc_exact days the roll-up settles first: a day with a custom_json rollup row that is not
-- exact and blocks that record RC (2021-03-20 in the fixture), not one whose blocks record none.
INSERT INTO haf_stats_backend.network_custom_json_daily (day, custom_json_type_id, op_count, op_bytes)
VALUES ('2021-03-20', hafd.ci_custom_json_type_id('retention_app'), 1, 10),
       ('2023-02-02', hafd.ci_custom_json_type_id('retention_app'), 1, 10);
DO $settle$
BEGIN
    IF (SELECT array_agg(u ORDER BY u) FROM haf_stats_app.custom_json_rc_unsettled_days('2021-01-01', '2023-07-01') AS u)
       IS DISTINCT FROM ARRAY[DATE '2021-03-20'] THEN
        RAISE EXCEPTION 'the unsettled rc_exact days are %, expected only 2021-03-20',
            (SELECT array_agg(u ORDER BY u) FROM haf_stats_app.custom_json_rc_unsettled_days('2021-01-01', '2023-07-01') AS u);
    END IF;
    IF EXISTS (SELECT 1 FROM haf_stats_app.custom_json_rc_unsettled_days('2021-03-21', '2023-07-01')) THEN
        RAISE EXCEPTION 'custom_json_rc_unsettled_days returned a day outside its range';
    END IF;
END
$settle$;
ROLLBACK;
