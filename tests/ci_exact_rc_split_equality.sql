-- exact_rc_for_range and exact_rc_for_ops, which give a transaction with one user operation its
-- whole rc_cost without the weighted split, against the versions that split every transaction,
-- kept below verbatim as the reference. Over the rcexact fixture (tests/ci_setup.sql, blocks
-- 6500-6503: single-op and multi-op transactions, op types of different weights, a weight per
-- day, the zero-rate clamp, a remainder, a virtual op beside a single user op, a NULL cost) plus
-- block 6506 below, every (op_id, rc_exact) row must be identical. prepare_batch_exact_rc, which
-- now adds its primary key after the load, must hold the same rows and have the key, also when it
-- is staged twice in one transaction.
--
-- One transaction, rolled back.
\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.exact_rc_for_range_before(
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

CREATE FUNCTION pg_temp.exact_rc_for_ops_before(_op_ids BIGINT [])
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

-- Block 6506 (2021-03-21), more shapes than the fixture's: a four-op transaction of three
-- weights (vote 300,000,000, transfer clamped to 1, custom_json 167,828,015) whose highest id is
-- a custom_json, a lone transfer (a clamped weight), a custom_json beside a virtual op, a lone
-- vote with a cost of 0, and two votes sharing a cost of 1 (each floor is 0, so the whole cost is
-- the remainder).
INSERT INTO hafd.blocks (num, created_at, total_vesting_shares, total_vesting_fund_hive)
VALUES (6506, '2021-03-21 00:00:18', 1000000000, 1000000000);
INSERT INTO hafd.transactions (block_num, trx_in_block, rc_cost) VALUES
(6506, 0, 999999999),
(6506, 1, 7),
(6506, 2, 11),
(6506, 3, 0),
(6506, 4, 1);
INSERT INTO hafd.operations (id, op_type_id, body_value, trx_in_block) VALUES
(6506000001, 1, '{}', 0),
(6506000002, 2, '{}', 0),
(6506000003, 18, '{"id": "sm_claim_daily", "required_posting_auths": ["rcexact"]}', 0),
(6506000004, 18, '{"id": "follow", "required_posting_auths": ["rcother"]}', 0),
(6506000011, 2, '{}', 1),
(6506000021, 18, '{"id": "follow", "required_posting_auths": ["rcother"]}', 2),
(6506000022, 64, '{}', 2),
(6506000031, 1, '{}', 3),
(6506000041, 1, '{}', 4),
(6506000042, 1, '{}', 4);

DO $range$
DECLARE
    _n BIGINT;
    _diff TEXT;
BEGIN
    -- The comparison means something only if the range has both kinds of transaction.
    SELECT count(*) INTO _n FROM pg_temp.exact_rc_for_range_before(6500, 6506);
    IF _n <> 21 THEN
        RAISE EXCEPTION 'FAIL (#116): the reference priced % ops of blocks 6500-6506, expected 21', _n;
    END IF;

    SELECT string_agg(format('%s: before %s, now %s', coalesce(b.operation_id, a.operation_id),
                             coalesce(b.rc_exact::TEXT, 'no row'), coalesce(a.rc_exact::TEXT, 'no row')),
                      '; ' ORDER BY coalesce(b.operation_id, a.operation_id))
    INTO _diff
    FROM pg_temp.exact_rc_for_range_before(6500, 6506) AS b
    FULL JOIN haf_stats_app.exact_rc_for_range(6500, 6506) AS a ON a.operation_id = b.operation_id
    WHERE a.rc_exact IS DISTINCT FROM b.rc_exact OR a.operation_id IS NULL OR b.operation_id IS NULL;
    IF _diff IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL (#116): exact_rc_for_range differs from the full split: %', _diff;
    END IF;

    -- One batch per block too: each batch stages its own operations.
    FOR _b IN 6500..6506 LOOP
        IF EXISTS (
            (SELECT * FROM pg_temp.exact_rc_for_range_before(_b, _b)
             EXCEPT ALL SELECT * FROM haf_stats_app.exact_rc_for_range(_b, _b))
            UNION ALL
            (SELECT * FROM haf_stats_app.exact_rc_for_range(_b, _b)
             EXCEPT ALL SELECT * FROM pg_temp.exact_rc_for_range_before(_b, _b))
        ) THEN
            RAISE EXCEPTION 'FAIL (#116): exact_rc_for_range(%, %) differs from the full split', _b, _b;
        END IF;
    END LOOP;
    RAISE NOTICE 'exact_rc_for_range: the same 21 rows as the full split';
END
$range$;

DO $ops$
DECLARE
    _all BIGINT [];
    _ids BIGINT [];
    _diff TEXT;
BEGIN
    -- Every op of the blocks, virtual and unpriced ones included, then each op on its own (a
    -- transaction's split must not depend on which of its ops are asked for).
    SELECT array_agg(o.id ORDER BY o.id) INTO _all
    FROM hafd.operations AS o
    WHERE o.id BETWEEN 6500000000 AND 6506999999;

    FOR _ids IN SELECT _all UNION ALL SELECT ARRAY[u.id] FROM unnest(_all) AS u(id) LOOP
        SELECT string_agg(format('%s: before %s, now %s', coalesce(b.operation_id, a.operation_id),
                                 coalesce(b.rc_exact::TEXT, 'no row'), coalesce(a.rc_exact::TEXT, 'no row')),
                          '; ' ORDER BY coalesce(b.operation_id, a.operation_id))
        INTO _diff
        FROM pg_temp.exact_rc_for_ops_before(_ids) AS b
        FULL JOIN haf_stats_app.exact_rc_for_ops(_ids) AS a ON a.operation_id = b.operation_id
        WHERE a.rc_exact IS DISTINCT FROM b.rc_exact OR a.operation_id IS NULL OR b.operation_id IS NULL;
        IF _diff IS NOT NULL THEN
            RAISE EXCEPTION 'FAIL (#116): exact_rc_for_ops(%) differs from the full split: %', _ids, _diff;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM haf_stats_app.exact_rc_for_ops(_all)) <> 21 THEN
        RAISE EXCEPTION 'FAIL (#116): exact_rc_for_ops priced the wrong number of the blocks'' ops';
    END IF;
    RAISE NOTICE 'exact_rc_for_ops: the same rows as the full split, for all the ops and for each alone';
END
$ops$;

-- prepare_batch_exact_rc for two ranges in one transaction: the second drops the first's key,
-- reloads and adds it again.
DO $staged$
DECLARE
    _r INT [];
BEGIN
    FOREACH _r SLICE 1 IN ARRAY ARRAY[[6500, 6503], [6503, 6506]] LOOP
        PERFORM haf_stats_app.prepare_batch_exact_rc(_r[1], _r[2]);
        IF EXISTS (
            (SELECT t.op_id, t.rc_exact FROM haf_stats_batch_exact_rc AS t
             EXCEPT ALL SELECT * FROM pg_temp.exact_rc_for_range_before(_r[1], _r[2]))
            UNION ALL
            (SELECT * FROM pg_temp.exact_rc_for_range_before(_r[1], _r[2])
             EXCEPT ALL SELECT t.op_id, t.rc_exact FROM haf_stats_batch_exact_rc AS t)
        ) THEN
            RAISE EXCEPTION 'FAIL (#116): haf_stats_batch_exact_rc for %-% differs from the full split', _r[1], _r[2];
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint AS c
            WHERE c.conrelid = 'pg_temp.haf_stats_batch_exact_rc'::REGCLASS AND c.contype = 'p'
        ) THEN
            RAISE EXCEPTION 'FAIL (#116): haf_stats_batch_exact_rc for %-% has no primary key', _r[1], _r[2];
        END IF;
    END LOOP;
    RAISE NOTICE 'prepare_batch_exact_rc: the full split''s rows, under a primary key, staged twice';
END
$staged$;

ROLLBACK;
