SET ROLE haf_stats_owner;

-- Exact per-operation RC, from the per-transaction RC cost HAF records (issue #44).
--
-- HAF 1.28.8 serializes the RC a transaction actually cost into hafd.transactions.rc_cost
-- (hive/haf!972). On a node replayed on such a build it is filled in every block window sampled
-- from hardfork 20 (block 26,256,744, when RC began) to the head; earlier transactions have
-- NULL. A HAF older than 1.28.8 (1.28.6 and before) has no such column at all.
--
-- The cost belongs to the TRANSACTION, and hived charges all of it to ONE account, taken from the
-- first operation that names one: for most operations the alphabetically first of its required
-- active, else owner, else posting authorities; witness_set_properties, recover_account and
-- witness_block_approve name theirs directly (hive/hive libraries/chain/rc/resource_user.cpp).
-- haf_stats reports per OPERATION and
-- attributes each operation to the account that signed it. So a per-account total built from
-- these shares is the RC of the operations that account signed, not what it was charged: the
-- two differ only for transactions carrying operations of more than one signer. Most
-- transactions carry one operation, and that operation gets the whole cost. A transaction
-- with several user operations has its cost split across them in proportion to the
-- op-count estimate each would have been priced at (haf_stats_app.rc_avg_cost for its op
-- type, at the rate effective on its day): the decision recorded on #44. Virtual operations
-- consume no RC and take no share. Every operation of the transaction counts towards the
-- split, including operations another account signed in the same transaction, so a share does
-- not depend on which operations a caller asks about. It can depend on WHEN it is computed: the
-- daily rate sampler extends rc_op_stats_daily, so a multi-op transaction of mixed op types may
-- split a few units differently later. The transaction's total never changes.
--
-- Shares are whole RC units and add up to the transaction's cost exactly: each operation gets
-- the floor of its proportional share and the transaction's last operation (highest op id)
-- also takes the remainder. A per-event sum therefore reconciles with a per-transaction total.

-- True when this node's HAF has hafd.transactions.rc_cost. On a HAF without it the column
-- reference below must never be planned, so callers check this first; a plpgsql statement is
-- only planned when it first runs, which is what lets one definition serve both kinds of node.
DROP FUNCTION IF EXISTS haf_stats_app.rc_cost_available();
CREATE OR REPLACE FUNCTION haf_stats_app.rc_cost_available()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE a.attrelid = to_regclass('hafd.transactions')
          AND a.attname = 'rc_cost'
          AND NOT a.attisdropped
    )
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.rc_cost_available() TO haf_stats_user;

-- The most operations one call prices exactly (#44, decided 2026-10-16). Each costs about three
-- random reads (its operation, its transaction, the transaction's operations). Measured on a
-- 1.28.8 node: ~0.2 ms an op on recent blocks (0.02 ms once cached), ~0.9 ms on uncached old
-- blocks, where one account's 50,587 ops took 42 s, past the API role's 30 s statement_timeout
-- (db/builtin_roles.sql), and 12,028 ops took 11.1 s. So 15,000 keeps a cold call around 14 s.
-- A call asking for more gets no rows at all, so the caller prices the whole response with the
-- estimate rather than mixing the two. A function, not a literal, so the CI lane can lower it to
-- test that path.
DROP FUNCTION IF EXISTS haf_stats_app.exact_rc_op_cap();
CREATE OR REPLACE FUNCTION haf_stats_app.exact_rc_op_cap()
RETURNS INT
LANGUAGE sql
STABLE
AS $$
    SELECT 15000
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.exact_rc_op_cap() TO haf_stats_user;

-- How a figure was priced, for the RC endpoints' rc_source field (#101): recorded when all of its
-- units (ops, or daily rollup rows) were priced with the recorded RC, estimated when none were,
-- mixed otherwise. One definition so the four endpoints cannot disagree on the rule.
DROP FUNCTION IF EXISTS haf_stats_app.rc_source_label(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION haf_stats_app.rc_source_label(_exact BIGINT, _total BIGINT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN COALESCE(_exact, 0) <= 0 THEN 'estimated'
        WHEN _exact >= _total THEN 'recorded'
        ELSE 'mixed'
    END
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.rc_source_label(BIGINT, BIGINT) TO haf_stats_user;

-- Exact RC share of each given operation. Returns one row per operation it can price: a
-- non-virtual operation whose transaction has a recorded rc_cost. An operation it cannot
-- price (no rc_cost on its transaction, a virtual op, an unknown id, a HAF without the column)
-- has NO row, and the caller prices it with the estimate instead. Neither does any op of a call
-- asking for more than exact_rc_op_cap() ops.
--
-- Takes ids rather than an account or a range so each endpoint keeps its own way of choosing
-- operations (and its own index), and only hands over what it already selected.
DROP FUNCTION IF EXISTS haf_stats_app.exact_rc_for_ops(BIGINT []);
CREATE OR REPLACE FUNCTION haf_stats_app.exact_rc_for_ops(_op_ids BIGINT [])
RETURNS TABLE (operation_id BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
STABLE
-- The statement below is planned with _op_ids as a parameter. A cached GENERIC plan would
-- estimate the array at a handful of rows whatever its size; plan each call for its real array.
SET plan_cache_mode = force_custom_plan
AS $$
BEGIN
    IF _op_ids IS NULL OR cardinality(_op_ids) = 0
       OR cardinality(_op_ids) > haf_stats_app.exact_rc_op_cap()
       OR NOT haf_stats_app.rc_cost_available() THEN
        RETURN;
    END IF;

    -- Every lookup below is a CROSS JOIN LATERAL ... OFFSET 0 / LIMIT 1, which keeps it a
    -- per-row index probe whatever the planner estimates. Measured on a 1.28.8 node: written as
    -- plain joins, an account with ~54,000 ops in 30 days got a plan that sequentially scanned
    -- hafd.blocks (110M rows) and hafd.transactions (4.2B rows) and ran past 90 s; the endpoint
    -- it extends answers in ~3 s. OFFSET 0 stops a LATERAL subquery from being flattened back
    -- into an ordinary join.
    RETURN QUERY
    WITH asked AS MATERIALIZED (
        -- The transactions the asked-for operations belong to. trx_in_block < 0 marks a
        -- block-level virtual operation, which belongs to no transaction.
        SELECT DISTINCT hafd.operation_id_to_block_num(o.id) AS block_num, o.trx_in_block
        FROM unnest(_op_ids) AS u(id)
        CROSS JOIN LATERAL (
            SELECT op.id, op.trx_in_block FROM hafd.operations AS op WHERE op.id = u.id OFFSET 0
        ) AS o
        WHERE o.trx_in_block >= 0
    ),
    priced_tx AS MATERIALIZED (
        -- Only transactions with a recorded cost; the rest are left to the estimate.
        SELECT a.block_num, a.trx_in_block, t.rc_cost, b.day
        FROM asked AS a
        CROSS JOIN LATERAL (
            SELECT tr.rc_cost FROM hafd.transactions AS tr
            WHERE tr.block_num = a.block_num AND tr.trx_in_block = a.trx_in_block
            LIMIT 1
        ) AS t
        CROSS JOIN LATERAL (
            SELECT bl.created_at::DATE AS day FROM hafd.blocks AS bl WHERE bl.num = a.block_num LIMIT 1
        ) AS b
        WHERE t.rc_cost IS NOT NULL
    ),
    tx_ops AS MATERIALIZED (
        -- Every user operation of those transactions, not only the asked-for ones: the split
        -- is over the whole transaction.
        SELECT p.block_num, p.trx_in_block, p.rc_cost, p.day, o.id, o.op_type_id
        FROM priced_tx AS p
        CROSS JOIN LATERAL (
            SELECT op.id, op.op_type_id::SMALLINT AS op_type_id
            FROM hafd.operations AS op
            WHERE hafd.operation_id_to_block_num(op.id) = p.block_num
              AND op.trx_in_block = p.trx_in_block
            OFFSET 0
        ) AS o
        JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id AND NOT ot.is_virtual
    ),
    weight AS MATERIALIZED (
        -- One rate lookup per (op type, day), not per operation.
        SELECT k.op_type_id, k.day,
               GREATEST(haf_stats_app.rc_avg_cost(k.op_type_id, k.day), 1)::NUMERIC AS w
        FROM (SELECT DISTINCT x.op_type_id, x.day FROM tx_ops AS x) AS k
    ),
    share AS (
        SELECT x.id, x.block_num, x.trx_in_block, x.rc_cost,
               -- DIV, not FLOOR(a / b): numeric division rounds at its result scale, so a
               -- quotient a hair below an integer could round up to it. DIV truncates exactly.
               DIV(x.rc_cost * wt.w, SUM(wt.w) OVER tx)::BIGINT AS floor_share,
               ROW_NUMBER() OVER (PARTITION BY x.block_num, x.trx_in_block ORDER BY x.id DESC) AS from_last
        FROM tx_ops AS x
        JOIN weight AS wt ON wt.op_type_id = x.op_type_id AND wt.day = x.day
        WINDOW tx AS (PARTITION BY x.block_num, x.trx_in_block)
    ),
    settled AS (
        SELECT s.id,
               s.floor_share
               + CASE WHEN s.from_last = 1
                      THEN s.rc_cost - SUM(s.floor_share) OVER (PARTITION BY s.block_num, s.trx_in_block)
                      ELSE 0 END AS rc
        FROM share AS s
    )
    -- A hashed join to the asked-for ids, not `= ANY(_op_ids)`: ANY scans the array for every
    -- row, which is quadratic in the number of ops.
    SELECT st.id, st.rc::BIGINT
    FROM settled AS st
    JOIN (SELECT DISTINCT u.id FROM unnest(_op_ids) AS u(id)) AS want ON want.id = st.id;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.exact_rc_for_ops(BIGINT []) TO haf_stats_user;

-- The same exact shares for EVERY user operation in a block range, for the daily rollups (#44,
-- part 2). The block processors call it for the range they are processing; the backfill calls it
-- one day at a time. Same rule as exact_rc_for_ops - whole transaction split by rc_avg_cost
-- weights, floor plus the remainder to the highest op id - but driven by the range instead of by
-- ids, so it reads hafd.transactions through its block-range index and the range's operations as
-- prepare_batch_ops (db/process_block_range.sql) staged them, rather than probing one operation
-- at a time.
--
-- Returns nothing on a HAF without rc_cost, like exact_rc_for_ops - and nothing for a range of
-- more than 100,000 blocks. The processors work in batches of at most 10,000 (a catch-up sync)
-- or 1 (live), and the backfill a day (~28,800). Bigger ranges come from the installer's
-- self-heal of an empty network_custom_json_daily, which runs a processor over the whole chain in
-- one transaction, and from a manual process_block_range over a big range. Splitting the whole
-- chain's RC there would materialise every transaction and user operation since hardfork 20;
-- instead those rows come out without rc_exact and scripts/backfill_rc_exact.sh fills them a day
-- at a time. (The rebuild_*custom_json.sh scripts refuse a BATCH_SIZE above 100,000 for this
-- reason: they truncate first, so they would replace exact rows with NULL ones.)
DROP FUNCTION IF EXISTS haf_stats_app.exact_rc_for_range(INT, INT, SMALLINT);
DROP FUNCTION IF EXISTS haf_stats_app.exact_rc_for_range(INT, INT);
CREATE OR REPLACE FUNCTION haf_stats_app.exact_rc_for_range(
    _first_block INT,
    _last_block INT
)
RETURNS TABLE (operation_id BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
-- VOLATILE, not STABLE: it stages the range's operations (prepare_batch_ops) and reads them
-- from there.
VOLATILE
AS $$
BEGIN
    IF _first_block IS NULL OR _last_block IS NULL OR _first_block > _last_block
       OR _last_block - _first_block + 1 > 100000
       OR NOT haf_stats_app.rc_cost_available() THEN
        RETURN;
    END IF;

    PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block);

    RETURN QUERY
    WITH priced_tx AS MATERIALIZED (
        SELECT t.block_num, t.trx_in_block, t.rc_cost, b.created_at::DATE AS day
        FROM hafd.transactions AS t
        JOIN hafd.blocks AS b ON b.num = t.block_num
        WHERE t.block_num BETWEEN _first_block AND _last_block
          AND t.rc_cost IS NOT NULL
    ),
    tx_ops AS MATERIALIZED (
        SELECT p.block_num, p.trx_in_block, p.rc_cost, p.day, o.op_id AS id, o.op_type_id
        FROM haf_stats_batch_ops AS o
        JOIN priced_tx AS p
          ON p.block_num = o.block_num
         AND p.trx_in_block = o.trx_in_block
        JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id AND NOT ot.is_virtual
        WHERE o.trx_in_block >= 0
    ),
    weight AS MATERIALIZED (
        SELECT k.op_type_id, k.day,
               GREATEST(haf_stats_app.rc_avg_cost(k.op_type_id, k.day), 1)::NUMERIC AS w
        FROM (SELECT DISTINCT x.op_type_id, x.day FROM tx_ops AS x) AS k
    ),
    share AS (
        SELECT x.id, x.op_type_id, x.block_num, x.trx_in_block, x.rc_cost,
               DIV(x.rc_cost * wt.w, SUM(wt.w) OVER tx)::BIGINT AS floor_share,
               ROW_NUMBER() OVER (PARTITION BY x.block_num, x.trx_in_block ORDER BY x.id DESC) AS from_last
        FROM tx_ops AS x
        JOIN weight AS wt ON wt.op_type_id = x.op_type_id AND wt.day = x.day
        WINDOW tx AS (PARTITION BY x.block_num, x.trx_in_block)
    ),
    settled AS (
        SELECT s.id,
               s.floor_share
               + CASE WHEN s.from_last = 1
                      THEN s.rc_cost - SUM(s.floor_share) OVER (PARTITION BY s.block_num, s.trx_in_block)
                      ELSE 0 END AS rc
        FROM share AS s
    )
    SELECT st.id, st.rc::BIGINT
    FROM settled AS st;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.exact_rc_for_range(INT, INT) TO haf_stats_user;

-- The exact shares of one batch's operations, computed ONCE for the three rollups. The rollup
-- functions (network_op_rows, network_custom_json_rows, account_custom_json_rows) each call this
-- and then read the temp table, so a batch - or a backfilled day - splits its transactions' RC
-- once instead of three times. Like prepare_batch_authored_ops (db/process_block_range.sql), the
-- range-key GUC plus the temp table's existence make repeat calls for the same range no-ops; unlike
-- it, the key is set transaction-local, so it ends with the ON COMMIT DROP table (and rolls back
-- with it) instead of outliving it.
--
-- The table has a PRIMARY KEY on op_id, so an operation split twice would stop the batch rather
-- than count twice.
DROP FUNCTION IF EXISTS haf_stats_app.prepare_batch_exact_rc(INT, INT);
CREATE OR REPLACE FUNCTION haf_stats_app.prepare_batch_exact_rc(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _range_key TEXT := _first_block::TEXT || ':' || _last_block::TEXT;
BEGIN
    IF current_setting('haf_stats.batch_exact_rc_range', TRUE) = _range_key
       AND TO_REGCLASS('pg_temp.haf_stats_batch_exact_rc') IS NOT NULL THEN
        RETURN;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_batch_exact_rc (
        op_id BIGINT NOT NULL PRIMARY KEY,
        rc_exact BIGINT NOT NULL
    ) ON COMMIT DROP;

    TRUNCATE haf_stats_batch_exact_rc;

    INSERT INTO haf_stats_batch_exact_rc (op_id, rc_exact)
    SELECT e.operation_id, e.rc_exact
    FROM haf_stats_app.exact_rc_for_range(_first_block, _last_block) AS e;

    ANALYZE haf_stats_batch_exact_rc;
    PERFORM set_config('haf_stats.batch_exact_rc_range', _range_key, TRUE);
END;
$$;

-- Fill rc_exact on the three daily rollups for ONE past day (#44, part 2). Rows built before the
-- column existed, or while their day was only partly processed after an upgrade, carry NULL;
-- this recomputes the day from the chain and fills them.
--
-- It recomputes the day's rows with the processors' own grouping (network_op_rows,
-- network_custom_json_rows, account_custom_json_rows) and fills a row only when:
--   * its rc_exact is NULL - a value the processor already wrote is never replaced. The split's
--     weights come from rc_op_stats_daily, which the daily sampler extends, so recomputing a
--     multi-op transaction later can move a few units between its op types (never the
--     transaction's total); the first exact value stands;
--   * the recomputed op_count and op_bytes equal what the row holds - so a row is never given the
--     RC of a different set of operations. A NULL row that fails this is counted in
--     rows_mismatched and left NULL (the endpoints keep the estimate for it). A NULL row the
--     recomputed day has no group for is neither filled nor counted: finding those in
--     account_custom_json_daily, whose key leads with the account and which has no index on day,
--     would scan the whole table for every day.
--
-- Refuses a day that is not entirely behind the processor (the day of
-- app_status.last_processed_block or later): the processor may still add to that day's rows. A
-- past day is never written by the processor again, so the backfill can run while it is live.
DROP FUNCTION IF EXISTS haf_stats_app.backfill_rc_exact(DATE);
CREATE OR REPLACE FUNCTION haf_stats_app.backfill_rc_exact(_day DATE)
RETURNS TABLE (rollup TEXT, rows_set BIGINT, rows_mismatched BIGINT)
LANGUAGE plpgsql
VOLATILE
SET jit = OFF
AS $$
DECLARE
    _done_day DATE;
    _first INT;
    _last INT;
    _n BIGINT;
BEGIN
    SELECT b.created_at::DATE INTO _done_day
    FROM hafd.blocks AS b
    WHERE b.num = (SELECT MAX(s.last_processed_block) FROM haf_stats_app.app_status AS s);
    IF _day IS NULL OR _done_day IS NULL OR _day >= _done_day THEN
        RAISE EXCEPTION 'backfill_rc_exact: % is not a day the processor has finished (it is on %)',
            _day, _done_day;
    END IF;

    SELECT r.from_block, r.to_block INTO _first, _last
    FROM haf_stats_app.block_range_for_dates(_day, _day) AS r;
    IF _first IS NULL OR _last IS NULL THEN
        RETURN;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_backfill_nod ON COMMIT DROP AS
    SELECT * FROM haf_stats_app.network_op_rows(_first, _last) WITH NO DATA;
    TRUNCATE haf_stats_backfill_nod;
    INSERT INTO haf_stats_backfill_nod SELECT * FROM haf_stats_app.network_op_rows(_first, _last);

    UPDATE haf_stats_backend.network_op_daily AS t
    SET rc_exact = r.rc_exact
    FROM haf_stats_backfill_nod AS r
    WHERE t.day = r.day AND t.op_type_id = r.op_type_id
      AND t.rc_exact IS NULL AND r.rc_exact IS NOT NULL
      AND t.op_count = r.op_count AND t.op_bytes = r.op_bytes;
    GET DIAGNOSTICS _n = ROW_COUNT;
    rollup := 'network_op_daily'; rows_set := _n;
    SELECT count(*) INTO rows_mismatched
    FROM haf_stats_backend.network_op_daily AS t
    JOIN haf_stats_backfill_nod AS r ON t.day = r.day AND t.op_type_id = r.op_type_id
    WHERE t.rc_exact IS NULL AND r.rc_exact IS NOT NULL
      AND (t.op_count <> r.op_count OR t.op_bytes <> r.op_bytes);
    RETURN NEXT;

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_backfill_ncj ON COMMIT DROP AS
    SELECT * FROM haf_stats_app.network_custom_json_rows(_first, _last) WITH NO DATA;
    TRUNCATE haf_stats_backfill_ncj;
    INSERT INTO haf_stats_backfill_ncj SELECT * FROM haf_stats_app.network_custom_json_rows(_first, _last);

    UPDATE haf_stats_backend.network_custom_json_daily AS t
    SET rc_exact = r.rc_exact
    FROM haf_stats_backfill_ncj AS r
    WHERE t.day = r.day AND t.json_id = r.json_id
      AND t.rc_exact IS NULL AND r.rc_exact IS NOT NULL
      AND t.op_count = r.op_count AND t.op_bytes = r.op_bytes;
    GET DIAGNOSTICS _n = ROW_COUNT;
    rollup := 'network_custom_json_daily'; rows_set := _n;
    SELECT count(*) INTO rows_mismatched
    FROM haf_stats_backend.network_custom_json_daily AS t
    JOIN haf_stats_backfill_ncj AS r ON t.day = r.day AND t.json_id = r.json_id
    WHERE t.rc_exact IS NULL AND r.rc_exact IS NOT NULL
      AND (t.op_count <> r.op_count OR t.op_bytes <> r.op_bytes);
    RETURN NEXT;

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_backfill_acj ON COMMIT DROP AS
    SELECT * FROM haf_stats_app.account_custom_json_rows(_first, _last) WITH NO DATA;
    TRUNCATE haf_stats_backfill_acj;
    INSERT INTO haf_stats_backfill_acj SELECT * FROM haf_stats_app.account_custom_json_rows(_first, _last);

    UPDATE haf_stats_backend.account_custom_json_daily AS t
    SET rc_exact = r.rc_exact
    FROM haf_stats_backfill_acj AS r
    WHERE t.account_id = r.account_id AND t.day = r.day AND t.json_id = r.json_id
      AND t.rc_exact IS NULL AND r.rc_exact IS NOT NULL
      AND t.op_count = r.op_count AND t.op_bytes = r.op_bytes;
    GET DIAGNOSTICS _n = ROW_COUNT;
    rollup := 'account_custom_json_daily'; rows_set := _n;
    SELECT count(*) INTO rows_mismatched
    FROM haf_stats_backend.account_custom_json_daily AS t
    JOIN haf_stats_backfill_acj AS r ON t.account_id = r.account_id AND t.day = r.day AND t.json_id = r.json_id
    WHERE t.rc_exact IS NULL AND r.rc_exact IS NOT NULL
      AND (t.op_count <> r.op_count OR t.op_bytes <> r.op_bytes);
    RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION haf_stats_app.backfill_rc_exact(DATE) FROM public;

RESET ROLE;
