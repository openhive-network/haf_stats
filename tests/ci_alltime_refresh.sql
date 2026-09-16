-- haf_stats_app.refresh_top_accounts_alltime() refreshes without making readers wait. (#95)
--
-- Runs LAST in install-test's verify service, as postgres, against the tables, the function and
-- the endpoint the REAL installer created. Everything below happens inside ONE transaction that
-- is rolled back, so uninstall and verify-gone see the install exactly as it was.
--
-- WHY IT EXISTS. The refresh used to be TRUNCATE + INSERT. TRUNCATE holds ACCESS EXCLUSIVE until
-- commit, so a get_network_top_accounts request other than hp_balance that arrived during the
-- refresh waited for its commit -- transaction_count from the first TRUNCATE, the financial
-- metrics from the second (on testapi one waited 48.4 s for the lock) -- and since #94 a request
-- whose wait plus run time passes 30 s is cancelled. The function now merges only the difference.
-- What that has to guarantee is checked here, each by its own RAISE:
--
--   CORRECT  after each refresh both tables equal a from-scratch aggregate of the monthly rollups:
--            the first refresh (the INSERT arm), then after the rollups change (UPDATE, INSERT and
--            DELETE arms). Each financial value column changes on its own key, so a merge that
--            compares only some columns leaves a stale row; and 900017..900019 have rows that share
--            an account AND a category or a direction, so a merge whose UPDATE, INSERT or DELETE
--            matches on only part of the (account, category, direction) key hits a sibling row.
--   NARROW   a refresh rewrites only the test rows whose totals changed. Measured with ctid + cmin:
--            an UPDATE, or a DELETE + re-INSERT, gives the row a new version at a new command id.
--            The changed rows must show a new version too, or the comparison could not see one.
--            900017's unchanged row sits beside two changed ones, so rewriting a whole account fails.
--   READERS  while a refresh's transaction is still open, a SECOND connection, logged in as
--            haf_stats_user (as PostgREST does on testapi and the haf_api_node stack), reads both
--            tables and calls the endpoint -- all-time and a bounded date range -- under
--            lock_timeout = 2s, and none of it hits that timeout.
--   SERIAL   while it is open, a second refresh waits, and pg_locks shows it waiting for a
--            self-conflicting lock on an all-time table while holding no lock of any mode on
--            either -- i.e. before it has read or written them -- so pg_cron's 03:30 run and an
--            install cannot interleave. (Only "it timed out" would also pass a lock taken after the
--            merges, IN SHARE MODE, or on the second table only after the first table's merge.)
--
-- The other connections are dblink over the server's local socket. dblink is contrib and ships in
-- postgres:14-alpine; CREATE EXTENSION runs inside the transaction, so the rollback removes it.
--
-- Keys 900001..900019 are far above anything ci_setup.sql or the stub seeds.

BEGIN;

CREATE EXTENSION IF NOT EXISTS dblink;

-- Both tables minus a fresh aggregate, in both directions. NULL when they match.
CREATE FUNCTION pg_temp.alltime_mismatch()
RETURNS TEXT
LANGUAGE plpgsql
AS $fn$
DECLARE
    _txn BIGINT;
    _fin BIGINT;
BEGIN
    SELECT COUNT(*) INTO _txn
    FROM (
        (
            SELECT t.account_id, t.ops::NUMERIC AS ops
            FROM haf_stats_backend.account_txn_alltime AS t
            EXCEPT ALL
            SELECT m.account_id, SUM(m.ops)
            FROM haf_stats_backend.active_users_account_monthly AS m
            WHERE m.op_class = -1
            GROUP BY m.account_id
        )
        UNION ALL
        (
            SELECT m.account_id, SUM(m.ops)
            FROM haf_stats_backend.active_users_account_monthly AS m
            WHERE m.op_class = -1
            GROUP BY m.account_id
            EXCEPT ALL
            SELECT t.account_id, t.ops::NUMERIC
            FROM haf_stats_backend.account_txn_alltime AS t
        )
    ) AS d;

    SELECT COUNT(*) INTO _fin
    FROM (
        (
            SELECT f.account_id, f.category, f.direction,
                   f.hive_nai::NUMERIC AS hive_nai, f.hbd_nai::NUMERIC AS hbd_nai,
                   f.vests_nai::NUMERIC AS vests_nai, f.op_count::NUMERIC AS op_count
            FROM haf_stats_backend.account_financial_alltime AS f
            EXCEPT ALL
            SELECT m.account_id, m.category, m.direction,
                   SUM(m.hive_nai), SUM(m.hbd_nai), SUM(m.vests_nai), SUM(m.op_count)
            FROM haf_stats_backend.account_financial_monthly AS m
            GROUP BY m.account_id, m.category, m.direction
        )
        UNION ALL
        (
            SELECT m.account_id, m.category, m.direction,
                   SUM(m.hive_nai), SUM(m.hbd_nai), SUM(m.vests_nai), SUM(m.op_count)
            FROM haf_stats_backend.account_financial_monthly AS m
            GROUP BY m.account_id, m.category, m.direction
            EXCEPT ALL
            SELECT f.account_id, f.category, f.direction,
                   f.hive_nai::NUMERIC, f.hbd_nai::NUMERIC, f.vests_nai::NUMERIC, f.op_count::NUMERIC
            FROM haf_stats_backend.account_financial_alltime AS f
        )
    ) AS d;

    IF _txn = 0 AND _fin = 0 THEN
        RETURN NULL;
    END IF;
    RETURN format('account_txn_alltime has %s mismatched row(s), account_financial_alltime %s', _txn, _fin);
END;
$fn$;

-- The physical version of every test key: ctid + cmin. cmin is the command id that wrote the
-- version, which also tells a DELETE + re-INSERT apart from an untouched row even if the new
-- version happens to land at the same ctid.
CREATE FUNCTION pg_temp.versions()
RETURNS TABLE (k TEXT, v TEXT)
LANGUAGE sql
AS $fn$
    SELECT 'txn ' || t.account_id, t.ctid::TEXT || '@' || t.cmin::TEXT
    FROM haf_stats_backend.account_txn_alltime AS t
    WHERE t.account_id BETWEEN 900001 AND 900099
    UNION ALL
    SELECT 'fin ' || f.account_id || ' ' || f.category || ' ' || f.direction,
           f.ctid::TEXT || '@' || f.cmin::TEXT
    FROM haf_stats_backend.account_financial_alltime AS f
    WHERE f.account_id BETWEEN 900001 AND 900099;
$fn$;

-- One statement over a dblink connection. NULL when it succeeded, else the error text.
CREATE FUNCTION pg_temp.remote_error(_conn TEXT, _sql TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $fn$
DECLARE
    _n BIGINT;
    _err TEXT;
BEGIN
    SELECT r.n INTO _n FROM dblink(_conn, _sql, FALSE) AS r(n BIGINT);
    _err := dblink_error_message(_conn);
    IF _err IS NULL OR _err = 'OK' THEN
        RETURN NULL;
    END IF;
    RETURN _err;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- State 1, and the first refresh (INSERT arm).
-- ---------------------------------------------------------------------------
INSERT INTO haf_stats_backend.active_users_account_monthly (month, op_class, account_id, ops)
VALUES
    ('2026-01-01', -1, 900001, 3),  -- unchanged: 3 + 2
    ('2026-02-01', -1, 900001, 2),
    ('2026-01-01', -1, 900002, 7),  -- will change
    ('2026-01-01', -1, 900003, 4),  -- will vanish
    ('2026-01-01', 0, 900004, 9);   -- another op_class: never an all-time row

INSERT INTO haf_stats_backend.account_financial_monthly
    (account_id, month, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
VALUES
    (900001, '2026-01-01', 'author_reward_operation', 'incoming', 1, 2, 3, 1),  -- unchanged, two months
    (900001, '2026-02-01', 'author_reward_operation', 'incoming', 1, 1, 1, 1),
    (900001, '2026-01-01', 'transfer_operation', 'outgoing', 2, 0, 0, 1),      -- unchanged, same account
    (900011, '2026-01-01', 'curation_reward_operation', 'incoming', 10, 10, 10, 10),  -- hive_nai changes
    (900012, '2026-01-01', 'transfer_operation', 'incoming', 10, 10, 10, 10),         -- hbd_nai changes
    (900013, '2026-01-01', 'curation_reward_operation', 'incoming', 10, 10, 10, 10),  -- vests_nai changes
    (900014, '2026-01-01', 'transfer_operation', 'outgoing', 10, 10, 10, 10),         -- op_count changes
    (900015, '2026-01-01', 'author_reward_operation', 'incoming', 5, 5, 5, 5),        -- will vanish
    -- Sibling keys: same account, and the same category or the same direction as another row.
    (900017, '2026-01-01', 'transfer_operation', 'incoming', 1, 1, 1, 1),          -- unchanged
    (900017, '2026-01-01', 'transfer_operation', 'outgoing', 2, 2, 2, 2),          -- changes (same category)
    (900017, '2026-01-01', 'curation_reward_operation', 'incoming', 3, 3, 3, 3),   -- changes (same direction)
    (900018, '2026-01-01', 'transfer_operation', 'incoming', 4, 4, 4, 4),          -- unchanged; siblings added
    (900019, '2026-01-01', 'transfer_operation', 'incoming', 5, 5, 5, 5),          -- unchanged; siblings vanish
    (900019, '2026-01-01', 'transfer_operation', 'outgoing', 6, 6, 6, 6),          -- will vanish (same category)
    (900019, '2026-01-01', 'author_reward_operation', 'incoming', 7, 7, 7, 7);     -- will vanish (same direction)

SET ROLE haf_stats_owner;
SELECT haf_stats_app.refresh_top_accounts_alltime();
RESET ROLE;

DO $check$
DECLARE
    _m TEXT := pg_temp.alltime_mismatch();
    _txn INT;
    _fin INT;
BEGIN
    IF _m IS NOT NULL THEN
        RAISE EXCEPTION 'CORRECT: after the first refresh %', _m;
    END IF;
    SELECT COUNT(*) FILTER (WHERE k LIKE 'txn %'), COUNT(*) FILTER (WHERE k LIKE 'fin %')
    INTO _txn, _fin
    FROM pg_temp.versions();
    IF _txn <> 3 OR _fin <> 14 THEN
        RAISE EXCEPTION 'FIXTURE: expected 3 txn and 14 financial test keys after the first refresh, found % and %', _txn, _fin;
    END IF;
    RAISE NOTICE 'first refresh: both all-time tables match the rollups (3 txn, 14 financial test keys)';
END;
$check$;

CREATE TEMP TABLE ci_v1 ON COMMIT DROP AS SELECT * FROM pg_temp.versions();

-- ---------------------------------------------------------------------------
-- State 2: every arm has work, and the second refresh stays OPEN for the probes.
-- ---------------------------------------------------------------------------
UPDATE haf_stats_backend.active_users_account_monthly SET ops = 8 WHERE account_id = 900002;
DELETE FROM haf_stats_backend.active_users_account_monthly WHERE account_id = 900003;
INSERT INTO haf_stats_backend.active_users_account_monthly (month, op_class, account_id, ops)
VALUES ('2026-03-01', -1, 900005, 6);

UPDATE haf_stats_backend.account_financial_monthly SET hive_nai = 11 WHERE account_id = 900011;
UPDATE haf_stats_backend.account_financial_monthly SET hbd_nai = 11 WHERE account_id = 900012;
UPDATE haf_stats_backend.account_financial_monthly SET vests_nai = 11 WHERE account_id = 900013;
UPDATE haf_stats_backend.account_financial_monthly SET op_count = 11 WHERE account_id = 900014;
DELETE FROM haf_stats_backend.account_financial_monthly WHERE account_id = 900015;
UPDATE haf_stats_backend.account_financial_monthly SET hive_nai = 12
WHERE account_id = 900017 AND category = 'transfer_operation' AND direction = 'outgoing';
UPDATE haf_stats_backend.account_financial_monthly SET hive_nai = 13
WHERE account_id = 900017 AND category = 'curation_reward_operation';
DELETE FROM haf_stats_backend.account_financial_monthly
WHERE account_id = 900019 AND NOT (category = 'transfer_operation' AND direction = 'incoming');
INSERT INTO haf_stats_backend.account_financial_monthly
    (account_id, month, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
VALUES
    (900016, '2026-03-01', 'transfer_operation', 'incoming', 1, 1, 1, 1),
    (900018, '2026-03-01', 'transfer_operation', 'outgoing', 8, 8, 8, 8),       -- new key, same category
    (900018, '2026-03-01', 'author_reward_operation', 'incoming', 9, 9, 9, 9);  -- new key, same direction

SET ROLE haf_stats_owner;
SELECT haf_stats_app.refresh_top_accounts_alltime();
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The probes, FIRST, while this transaction still holds everything both refreshes took.
-- First so that a refresh which blocks readers is reported as exactly that, before the
-- correctness checks below find whatever else is wrong with it.
-- ---------------------------------------------------------------------------
DO $probe$
DECLARE
    _alltime CONSTANT REGCLASS[] := ARRAY[
        'haf_stats_backend.account_txn_alltime'::REGCLASS,
        'haf_stats_backend.account_financial_alltime'::REGCLASS
    ];
    _pid INT;
    _w_type TEXT;
    _w_mode TEXT;
    _w_rel REGCLASS;
    _held TEXT;
    _busy BOOLEAN;
    _state TEXT;
    _reads TEXT[] := ARRAY[
        'SELECT COUNT(*) FROM haf_stats_backend.account_txn_alltime',
        'SELECT COUNT(*) FROM haf_stats_backend.account_financial_alltime',
        'SELECT COUNT(*) FROM haf_stats_endpoints.get_network_top_accounts("metric" => ''transaction_count'')',
        'SELECT COUNT(*) FROM haf_stats_endpoints.get_network_top_accounts("metric" => ''author_rewards'')',
        'SELECT COUNT(*) FROM haf_stats_endpoints.get_network_top_accounts("metric" => ''author_rewards'', '
            || '"from_date" => ''2026-01-01'', "to_date" => ''2026-01-31'')'
    ];
    _sql TEXT;
    _err TEXT;
BEGIN
    PERFORM dblink_connect('ci_reader', 'dbname=haf_block_log user=haf_stats_user');
    PERFORM dblink_exec('ci_reader', 'SET lock_timeout = ''2s''');
    FOREACH _sql IN ARRAY _reads LOOP
        _err := pg_temp.remote_error('ci_reader', _sql);
        IF _err IS NOT NULL THEN
            RAISE EXCEPTION 'READERS: a haf_stats_user connection could not run [%] while a refresh was open: %', _sql, _err;
        END IF;
    END LOOP;
    PERFORM dblink_disconnect('ci_reader');
    RAISE NOTICE 'readers: haf_stats_user read both tables and ran get_network_top_accounts (all-time and bounded) during an open refresh without waiting 2 s for a lock';

    -- SERIAL looks at WHAT a second refresh waits for, not merely THAT it waits. This transaction
    -- holds every lock both refreshes above took, so a second refresh would stop on almost any
    -- conflict -- including arrangements that still let two real refreshes overlap: the LOCK taken
    -- after the merges, IN SHARE MODE (which does not conflict with itself), or on the second
    -- table only after the first table's merge. So it is sent asynchronously and inspected in
    -- pg_locks while it waits: it must be waiting for a self-conflicting lock that readers pass,
    -- on an all-time table, while holding NO lock of any mode on either table. A held ACCESS SHARE
    -- counts too: a refresh that reads the tables before it locks them acts on a stale read.
    -- Once that is recorded it is cancelled; the error is judged by SQLSTATE, not message text.
    PERFORM dblink_connect('ci_writer', 'dbname=haf_block_log user=postgres');
    PERFORM dblink_exec('ci_writer', 'SET lock_timeout = ''30s''');
    PERFORM dblink_exec('ci_writer', 'SET statement_timeout = ''60s''');
    SELECT r.pid INTO _pid FROM dblink('ci_writer', 'SELECT pg_backend_pid()') AS r(pid INT);
    PERFORM dblink_send_query('ci_writer', 'SELECT haf_stats_app.refresh_top_accounts_alltime()');

    FOR _i IN 1..200 LOOP
        SELECT l.locktype, l.mode, l.relation::REGCLASS
        INTO _w_type, _w_mode, _w_rel
        FROM pg_locks AS l
        WHERE l.pid = _pid AND NOT l.granted
        LIMIT 1;
        IF _w_mode IS NOT NULL THEN
            SELECT string_agg(l.mode || ' on ' || l.relation::REGCLASS::TEXT, ', ' ORDER BY l.mode, l.relation)
            INTO _held
            FROM pg_locks AS l
            WHERE l.pid = _pid AND l.granted AND l.locktype = 'relation'
              AND l.relation::REGCLASS = ANY (_alltime);
            EXIT;
        END IF;
        EXIT WHEN dblink_is_busy('ci_writer') = 0;
        PERFORM pg_sleep(0.05);
    END LOOP;

    _busy := dblink_is_busy('ci_writer') = 1;
    IF _busy THEN
        PERFORM dblink_cancel_query('ci_writer');
    END IF;
    -- query_canceled by name: WHEN OTHERS deliberately does not match it, and 57014 is what the
    -- cancel above makes dblink re-raise here.
    BEGIN
        PERFORM r.v FROM dblink_get_result('ci_writer') AS r(v TEXT);
    EXCEPTION WHEN query_canceled OR OTHERS THEN
        _state := SQLSTATE;
        _err := SQLERRM;
    END;
    PERFORM dblink_disconnect('ci_writer');

    IF _w_mode IS NULL THEN
        IF _state IS NULL THEN
            RAISE EXCEPTION 'SERIAL: a second refresh ran to completion while the first was still open';
        ELSIF _busy THEN
            RAISE EXCEPTION 'SERIAL: a second refresh neither waited for a lock nor finished within 10 s (% %)', _state, _err;
        END IF;
        RAISE EXCEPTION 'SERIAL: a second refresh failed without waiting for a lock: % %', _state, _err;
    END IF;
    IF _w_type <> 'relation' OR NOT (_w_rel = ANY (_alltime))
       OR _w_mode NOT IN ('ShareUpdateExclusiveLock', 'ShareRowExclusiveLock', 'ExclusiveLock') THEN
        RAISE EXCEPTION 'SERIAL: a second refresh waited for % % on %, not for a self-conflicting table lock on an all-time table that readers pass',
            _w_type, _w_mode, COALESCE(_w_rel::TEXT, '-');
    END IF;
    IF _held IS NOT NULL THEN
        RAISE EXCEPTION 'SERIAL: a second refresh already held % when it started waiting, so part of it ran before it was serialized', _held;
    END IF;
    -- 57014: cancelled (by the cancel above); 55P03: its own lock_timeout fired first.
    IF _state IS NULL OR _state NOT IN ('57014', '55P03') THEN
        RAISE EXCEPTION 'SERIAL: a second refresh waited for % on % but then ended with % % instead of being cancelled', _w_mode, _w_rel, _state, _err;
    END IF;
    RAISE NOTICE 'serial: a second refresh waited for % on % holding no lock on either all-time table', _w_mode, _w_rel;
END;
$probe$;

DO $check$
DECLARE
    _m TEXT := pg_temp.alltime_mismatch();
    _rewritten TEXT;
    _missed TEXT;
BEGIN
    IF _m IS NOT NULL THEN
        RAISE EXCEPTION 'CORRECT: after the rollups changed, %', _m;
    END IF;

    SELECT string_agg(v1.k, ', ' ORDER BY v1.k) INTO _rewritten
    FROM ci_v1 AS v1
    JOIN pg_temp.versions() AS v2 ON v2.k = v1.k
    WHERE v1.k IN ('txn 900001',
                   'fin 900001 author_reward_operation incoming',
                   'fin 900001 transfer_operation outgoing',
                   'fin 900017 transfer_operation incoming',
                   'fin 900018 transfer_operation incoming',
                   'fin 900019 transfer_operation incoming')
      AND v2.v <> v1.v;
    IF _rewritten IS NOT NULL THEN
        RAISE EXCEPTION 'NARROW: the refresh rewrote rows whose totals did not change: %', _rewritten;
    END IF;

    SELECT string_agg(v1.k, ', ' ORDER BY v1.k) INTO _missed
    FROM ci_v1 AS v1
    JOIN pg_temp.versions() AS v2 ON v2.k = v1.k
    WHERE v1.k IN ('txn 900002',
                   'fin 900011 curation_reward_operation incoming',
                   'fin 900012 transfer_operation incoming',
                   'fin 900013 curation_reward_operation incoming',
                   'fin 900014 transfer_operation outgoing',
                   'fin 900017 transfer_operation outgoing',
                   'fin 900017 curation_reward_operation incoming')
      AND v2.v = v1.v;
    IF _missed IS NOT NULL THEN
        RAISE EXCEPTION 'NARROW: changed rows kept their row version, so this check cannot see a rewrite: %', _missed;
    END IF;
    RAISE NOTICE 'second refresh: tables match the changed rollups; the 7 changed test rows were rewritten and the 6 unchanged ones were not';
END;
$check$;

-- ---------------------------------------------------------------------------
-- Nothing changed since: a third refresh rewrites nothing.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE ci_v2 ON COMMIT DROP AS SELECT * FROM pg_temp.versions();

SET ROLE haf_stats_owner;
SELECT haf_stats_app.refresh_top_accounts_alltime();
RESET ROLE;

DO $check$
DECLARE
    _m TEXT := pg_temp.alltime_mismatch();
    _rewritten TEXT;
BEGIN
    IF _m IS NOT NULL THEN
        RAISE EXCEPTION 'CORRECT: after a refresh with nothing to do, %', _m;
    END IF;
    SELECT string_agg(COALESCE(v2.k, v3.k), ', ' ORDER BY COALESCE(v2.k, v3.k)) INTO _rewritten
    FROM ci_v2 AS v2
    FULL JOIN pg_temp.versions() AS v3 ON v3.k = v2.k
    WHERE v2.v IS DISTINCT FROM v3.v;
    IF _rewritten IS NOT NULL THEN
        RAISE EXCEPTION 'NARROW: a refresh with nothing to do rewrote: %', _rewritten;
    END IF;
    RAISE NOTICE 'third refresh: nothing changed, no test row rewritten';
END;
$check$;

ROLLBACK;
