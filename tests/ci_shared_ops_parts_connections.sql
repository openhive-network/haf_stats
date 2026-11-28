-- The shared batch staging's ops parts (stage_shared_batch's ops_<k> steps, #171) on connections
-- of their own, as the parallel sync runs them once its staging is split. Each part commits its
-- rows with its marker, and the part that commits last -- whichever it is -- must mark the ops
-- stage complete, once: the ops-finish lock each part takes before its commit is what makes the
-- last one see every other part's marker. tests/ci_shared_ops_parts_equality.sql runs the parts in
-- one transaction, where that lock is never waited for.
--
--   OUT OF ORDER  blocks 6680-6690 (parts of 2, 3, 3 and 3 blocks), the parts committing in the
--                 order 2, 0, 3, 1: each part after the first loads its rows while the part before
--                 it is still open, holding the lock, and is seen waiting for that lock; the ops
--                 stage is not marked complete until the last part commits.
--   SHORT BATCH   blocks 6695-6696, fewer blocks than parts, so parts 0 and 2 load nothing; every
--                 part sent at once, each in a transaction of its own.
--
-- Each time exactly one ops marker must be written, with the full set's op types, every part
-- marked, and the staged rows must be prepare_batch_ops' for the range, as a multiset.
--
-- The other connections must see the fixture, so the setup is committed and undone at the end;
-- the setup, the scenarios and the connections record a failure rather than stop the file, and
-- it is raised only after the cleanup. The setup is one block, so a failure in it leaves none of
-- it behind, and the cleanup undoes only a setup that committed. dblink connects over the server's
-- local socket (see tests/ci_alltime_refresh.sql), and is dropped again only if this file created
-- it.
\set ON_ERROR_STOP on

CREATE TEMP TABLE ci173_saved AS
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') AS had_dblink, FALSE AS set_up;
CREATE TEMP TABLE ci173_result (failure TEXT);

CREATE EXTENSION IF NOT EXISTS dblink;

DO $setup$
BEGIN
    -- Every fixture block is irreversible; the stub lane has no HAF context. The stub has no such
    -- function, so creating it fails loudly if one exists.
    CREATE FUNCTION hive.app_get_irreversible_block()
    RETURNS INT
    LANGUAGE sql
    STABLE
    AS $$
        SELECT 2147483647;
    $$;

    INSERT INTO hafd.blocks (num, created_at)
    SELECT n, TIMESTAMP '2021-10-08 00:00:00' + (n - 6680) * INTERVAL '3 seconds'
    FROM generate_series(6680, 6690) AS n
    UNION ALL
    VALUES (6695, TIMESTAMP '2021-10-08 00:00:45'), (6696, TIMESTAMP '2021-10-08 00:00:48');

    -- An op at each outer edge of each part of 6680-6690, non-virtual and staged virtual; blocks
    -- 6683, 6686 and 6689 hold none.
    INSERT INTO hafd.operations (id, op_type_id, body_value, trx_in_block) VALUES
    (hafd.operation_id(6680, 0), 1, '{"voter": "spc-alice", "author": "spc-bob", "permlink": "p", "weight": 10000}', 0),
    (hafd.operation_id(6681, 1), 2, '{"from": "spc-bob", "to": "spc-alice", "amount": "1.000 HIVE", "memo": ""}', 0),
    (hafd.operation_id(6682, 0), 64, '{"producer": "spc-carol", "vesting_shares": "1.000000 VESTS"}', -1),
    (hafd.operation_id(6684, 3), 1, '{"voter": "spc-carol", "author": "spc-alice", "permlink": "q", "weight": 5000}', 1),
    (hafd.operation_id(6685, 0), 2, '{"from": "spc-alice", "to": "spc-dave", "amount": "2.000 HIVE", "memo": "m"}', 0),
    (hafd.operation_id(6687, 2), 64, '{"producer": "spc-dave", "vesting_shares": "2.000000 VESTS"}', -1),
    (hafd.operation_id(6688, 0), 1, '{"voter": "spc-dave", "author": "spc-carol", "permlink": "r", "weight": 100}', 0),
    (hafd.operation_id(6690, 5), 2, '{"from": "spc-dave", "to": "spc-bob", "amount": "3.000 HIVE", "memo": ""}', 2),
    (hafd.operation_id(6695, 0), 1, '{"voter": "spc-bob", "author": "spc-dave", "permlink": "s", "weight": 200}', 0),
    (hafd.operation_id(6696, 1), 2, '{"from": "spc-carol", "to": "spc-bob", "amount": "4.000 HIVE", "memo": ""}', 0),
    (hafd.operation_id(6696, 2), 64, '{"producer": "spc-bob", "vesting_shares": "3.000000 VESTS"}', -1);

    UPDATE ci173_saved SET set_up = TRUE;
EXCEPTION WHEN OTHERS THEN
    INSERT INTO ci173_result VALUES ('setup: ' || SQLERRM);
END;
$setup$;

-- Waits, up to 30 s, until the statement sent on _conn (backend _pid) has returned (_blocked
-- FALSE) or is waiting for the ops-finish lock (_blocked TRUE); fails if it returns while it
-- should be waiting.
CREATE FUNCTION pg_temp.ci173_wait(_conn TEXT, _pid INT, _blocked BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    _deadline TIMESTAMPTZ := clock_timestamp() + INTERVAL '30 seconds';
BEGIN
    LOOP
        IF dblink_is_busy(_conn) = 0 THEN
            IF _blocked THEN
                RAISE EXCEPTION 'FAIL: % returned without waiting for the ops-finish lock', _conn;
            END IF;
            RETURN;
        END IF;
        IF _blocked AND EXISTS (
            SELECT FROM pg_locks AS l
            WHERE l.pid = _pid AND l.locktype = 'advisory' AND NOT l.granted
              AND l.objid::BIGINT = (hashtext('ops')::BIGINT & 4294967295)
        ) THEN
            RETURN;
        END IF;
        IF clock_timestamp() > _deadline THEN
            RAISE EXCEPTION 'FAIL: % neither returned nor waited for the ops-finish lock in 30 s', _conn;
        END IF;
        PERFORM pg_sleep(0.05);
    END LOOP;
END;
$fn$;

-- The result of the statement sent on _conn, which raises its error if it failed.
CREATE FUNCTION pg_temp.ci173_returned(_conn TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
BEGIN
    PERFORM r.v FROM dblink_get_result(_conn) AS r(v TEXT);
    -- The empty result that ends it.
    PERFORM r.v FROM dblink_get_result(_conn) AS r(v TEXT);
END;
$fn$;

CREATE FUNCTION pg_temp.ci173_ops_marked(_first INT, _last INT)
RETURNS BIGINT
LANGUAGE sql
AS $fn$
    SELECT COUNT(*) FROM haf_stats_app.shared_batch_marker AS m
    WHERE m.stage = 'ops' AND m.first_block = _first AND m.last_block = _last;
$fn$;

-- Fails unless _first.._last's ops stage is marked complete once, with every part, and holds
-- prepare_batch_ops' _rows rows for the range.
CREATE FUNCTION pg_temp.ci173_check(_scenario TEXT, _first INT, _last INT, _rows BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    _parts INT := haf_stats_app.shared_batch_ops_parts();
    _slot SMALLINT;
    _staged BIGINT;
    _n BIGINT;
BEGIN
    _n := pg_temp.ci173_ops_marked(_first, _last);
    IF _n <> 1 THEN
        RAISE EXCEPTION 'FAIL: %: % ops markers for %-%, not 1', _scenario, _n, _first, _last;
    END IF;
    SELECT m.slot INTO _slot FROM haf_stats_app.shared_batch_marker AS m
    WHERE m.stage = 'ops' AND m.first_block = _first AND m.last_block = _last
      AND m.op_types = haf_stats_app.batch_op_types(NULL);
    IF _slot IS NULL THEN
        RAISE EXCEPTION 'FAIL: %: the ops marker of %-% has not the full set''s op types', _scenario, _first, _last;
    END IF;
    SELECT COUNT(*) INTO _n FROM haf_stats_app.shared_batch_marker AS m
    WHERE m.slot = _slot AND m.first_block = _first AND m.last_block = _last
      AND m.stage IN (SELECT 'ops_' || k FROM generate_series(0, _parts - 1) AS k);
    IF _n <> _parts THEN
        RAISE EXCEPTION 'FAIL: %: % of the % parts of %-% are marked', _scenario, _n, _parts, _first, _last;
    END IF;

    PERFORM haf_stats_app.prepare_batch_ops(_first, _last);
    EXECUTE format('SELECT count(*) FROM haf_stats_app.%I', 'shared_batch_ops_' || _slot) INTO _staged;
    EXECUTE format($q$
        SELECT count(*) FROM (
            (SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes, custom_json_type_id
             FROM haf_stats_app.%1$I
             EXCEPT ALL
             SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes, custom_json_type_id
             FROM haf_stats_batch_ops)
            UNION ALL
            (SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes, custom_json_type_id
             FROM haf_stats_batch_ops
             EXCEPT ALL
             SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes, custom_json_type_id
             FROM haf_stats_app.%1$I)
        ) AS d
    $q$, 'shared_batch_ops_' || _slot) INTO _n;
    IF _n <> 0 THEN
        RAISE EXCEPTION 'FAIL: %: the shared ops stage of %-% differs from prepare_batch_ops in % rows', _scenario, _first, _last, _n;
    END IF;
    IF _staged <> _rows THEN
        RAISE EXCEPTION 'FAIL: %: the shared ops stage of %-% holds % rows, not %', _scenario, _first, _last, _staged, _rows;
    END IF;
    RAISE NOTICE '%: % parts on their own connections staged %-% once, the same % rows as prepare_batch_ops',
        _scenario, _parts, _first, _last, _staged;
END;
$fn$;

-- A connection per part, and its backend. Each scenario below runs in a transaction of its own,
-- so this session holds no lock on the slot tables the next slot step empties.
CREATE TEMP TABLE ci173_conn (part INT PRIMARY KEY, pid INT NOT NULL);
DO $connect$
DECLARE
    _conn TEXT;
BEGIN
    IF EXISTS (SELECT FROM ci173_result) THEN
        RETURN;
    END IF;
    FOR _k IN 0..haf_stats_app.shared_batch_ops_parts() - 1 LOOP
        _conn := 'ci173_part_' || _k;
        PERFORM dblink_connect(_conn, format('dbname=%s user=postgres application_name=%s', current_database(), _conn));
        PERFORM dblink_exec(_conn, 'SET ROLE haf_stats_owner');
        INSERT INTO ci173_conn SELECT _k, r.pid FROM dblink(_conn, 'SELECT pg_backend_pid()') AS r(pid INT);
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    INSERT INTO ci173_result VALUES ('connect: ' || SQLERRM);
END;
$connect$;

-- OUT OF ORDER
DO $out_of_order$
DECLARE
    _order INT [] := ARRAY[2, 0, 3, 1];
    _k INT;
    _prev INT;
    _marked BIGINT;
    _conn TEXT;
BEGIN
    IF EXISTS (SELECT FROM ci173_result) THEN
        RETURN;
    END IF;
    IF haf_stats_app.shared_batch_ops_parts() <> cardinality(_order) THEN
        RAISE EXCEPTION 'FAIL: out of order: written for % parts, not %', cardinality(_order), haf_stats_app.shared_batch_ops_parts();
    END IF;
    PERFORM r.v FROM dblink('ci173_part_0', 'SELECT haf_stats_app.stage_shared_batch(''slot'', 6680, 6690)') AS r(v TEXT);
    FOR _i IN 1..cardinality(_order) LOOP
        _k := _order[_i];
        _conn := 'ci173_part_' || _k;
        PERFORM dblink_exec(_conn, 'BEGIN');
        PERFORM dblink_send_query(_conn, format('SELECT haf_stats_app.stage_shared_batch(%L, 6680, 6690)', 'ops_' || _k));
        IF _prev IS NOT NULL THEN
            -- Loaded beside the open part before it, it waits for that part's commit.
            PERFORM pg_temp.ci173_wait(_conn, (SELECT c.pid FROM ci173_conn AS c WHERE c.part = _k), TRUE);
            PERFORM dblink_exec('ci173_part_' || _prev, 'COMMIT');
        END IF;
        PERFORM pg_temp.ci173_wait(_conn, (SELECT c.pid FROM ci173_conn AS c WHERE c.part = _k), FALSE);
        PERFORM pg_temp.ci173_returned(_conn);
        -- This session sees only what the parts committed: those before _k, not _k, which has
        -- loaded its rows and is still open. Whichever part _k is, the last one included, no
        -- ops marker may be visible yet.
        _marked := pg_temp.ci173_ops_marked(6680, 6690);
        IF _marked <> 0 THEN
            RAISE EXCEPTION 'FAIL: out of order: % ops markers of 6680-6690 are visible with % of its % parts committed and part % loaded but open',
                _marked, _i - 1, cardinality(_order), _k;
        END IF;
        _prev := _k;
    END LOOP;
    PERFORM dblink_exec('ci173_part_' || _prev, 'COMMIT');
    PERFORM pg_temp.ci173_check('out of order', 6680, 6690, 8);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO ci173_result VALUES (SQLERRM);
END;
$out_of_order$;

-- SHORT BATCH
DO $short_batch$
DECLARE
    _parts INT := haf_stats_app.shared_batch_ops_parts();
BEGIN
    IF EXISTS (SELECT FROM ci173_result) THEN
        RETURN;
    END IF;
    PERFORM r.v FROM dblink('ci173_part_0', 'SELECT haf_stats_app.stage_shared_batch(''slot'', 6695, 6696)') AS r(v TEXT);
    FOR _k IN 0.._parts - 1 LOOP
        PERFORM dblink_send_query('ci173_part_' || _k, format('SELECT haf_stats_app.stage_shared_batch(%L, 6695, 6696)', 'ops_' || _k));
    END LOOP;
    FOR _k IN 0.._parts - 1 LOOP
        PERFORM pg_temp.ci173_wait('ci173_part_' || _k, (SELECT c.pid FROM ci173_conn AS c WHERE c.part = _k), FALSE);
        PERFORM pg_temp.ci173_returned('ci173_part_' || _k);
    END LOOP;
    PERFORM pg_temp.ci173_check('short batch', 6695, 6696, 3);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO ci173_result VALUES (SQLERRM);
END;
$short_batch$;

-- Cleanup, whatever the result: a part still running is cancelled, and its open transaction rolls
-- back with its connection.
DO $cleanup$
DECLARE
    _conn TEXT;
BEGIN
    FOREACH _conn IN ARRAY COALESCE(dblink_get_connections(), '{}') LOOP
        IF dblink_is_busy(_conn) = 1 THEN
            PERFORM dblink_cancel_query(_conn);
        END IF;
        PERFORM dblink_disconnect(_conn);
    END LOOP;
END;
$cleanup$;
-- The staged rows, in each slot the scenarios staged a range into.
DO $staged$
DECLARE
    _slot SMALLINT;
BEGIN
    FOR _slot IN
        SELECT DISTINCT m.slot FROM haf_stats_app.shared_batch_marker AS m
        WHERE m.stage = 'slot' AND m.first_block IN (6680, 6695)
    LOOP
        EXECUTE format('DELETE FROM haf_stats_app.%I WHERE block_num BETWEEN 6680 AND 6696', 'shared_batch_ops_' || _slot);
    END LOOP;
END;
$staged$;
DELETE FROM haf_stats_app.shared_batch_marker WHERE first_block IN (6680, 6695);
DO $fixture$
BEGIN
    IF (SELECT set_up FROM ci173_saved) THEN
        DELETE FROM hafd.operations
        WHERE id >= hafd.operation_id(6680, 0) AND id < hafd.operation_id(6697, 0);
        DELETE FROM hafd.blocks WHERE num BETWEEN 6680 AND 6696;
        DROP FUNCTION hive.app_get_irreversible_block();
    END IF;
END;
$fixture$;
DO $$
BEGIN
    IF NOT (SELECT had_dblink FROM ci173_saved) THEN
        DROP EXTENSION dblink;
    END IF;
END;
$$;

-- The bookkeeping tables are this session's temp tables, so raising here leaves nothing behind.
DO $$
DECLARE
    _failure TEXT := (SELECT string_agg(failure, '; ') FROM ci173_result);
BEGIN
    IF _failure IS NOT NULL THEN
        RAISE EXCEPTION '%', _failure;
    END IF;
END;
$$;
