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
-- split, including operations another account signed in the same transaction, so a share is
-- the same whoever asks.
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

RESET ROLE;
