-- The staging of a block-processing batch against the query shapes it replaced, kept below
-- verbatim as the reference (the old shapes are pg_temp functions or, for process_active_users,
-- its two aggregates as plain SELECTs):
--   * prepare_batch_ops joins the range's blocks as a materialized set, not hafd.blocks directly;
--   * prepare_batch_authored_ops adds its primary key after the load;
--   * process_active_users counts COUNT(*) per account, and distinct ops through a grouping;
--   * account_custom_json_rows takes its signers from the authored ops (op_class 5), and the three
--     rollups read the per-op rows prepare_batch_rollup_ops joins to the exact RC once.
-- Over one synthetic batch (blocks 9701-9703, two days) of custom_json ops with several signers,
-- with a signer under both auth lists, with a signer listed twice, with an unknown signer and with
-- no id, beside votes, posts, comments, transfers and an op resolved through
-- hive.get_required_authorities, in transactions with and without a recorded RC and with none,
-- every row must be identical: as one batch, and one block at a time. Then a mutation: the
-- authored ops given the duplicate signers a signer expansion without DISTINCT would give them,
-- which both account_custom_json_rows and process_active_users must then get wrong.
--
-- One transaction, rolled back.
\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.network_op_rows_before(
    _first_block INT,
    _last_block INT
)
RETURNS TABLE (day DATE, op_type_id SMALLINT, op_count BIGINT, op_bytes BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
VOLATILE
SET jit = OFF
AS $$
BEGIN
PERFORM haf_stats_app.prepare_batch_exact_rc(_first_block, _last_block);
PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block);
RETURN QUERY
WITH ex AS (
    -- The batch's shares, computed once for the three rollups (prepare_batch_exact_rc, above).
    SELECT c.op_id AS operation_id, c.rc_exact
    FROM haf_stats_batch_exact_rc AS c
)
SELECT
    ov.day,
    ov.op_type_id,
    COUNT(*)::BIGINT,
    SUM(ov.op_bytes)::BIGINT,
    -- Exact only when every op of the group has its share (#44); otherwise NULL.
    CASE WHEN COUNT(ex.rc_exact) = COUNT(*) THEN SUM(ex.rc_exact) END::BIGINT
FROM haf_stats_batch_ops ov
JOIN hafd.operation_types ot ON ot.id = ov.op_type_id AND ot.is_virtual = FALSE
LEFT JOIN ex ON ex.operation_id = ov.op_id
GROUP BY ov.day, ov.op_type_id;
END;
$$;

CREATE FUNCTION pg_temp.network_custom_json_rows_before(
    _first_block INT,
    _last_block INT
)
RETURNS TABLE (day DATE, json_id TEXT, op_count BIGINT, op_bytes BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
VOLATILE
SET jit = OFF
AS $$
BEGIN
PERFORM haf_stats_app.prepare_batch_exact_rc(_first_block, _last_block);
PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[18]);
RETURN QUERY
WITH ex AS (
    -- The batch's shares, computed once for the three rollups (prepare_batch_exact_rc, above).
    SELECT c.op_id AS operation_id, c.rc_exact
    FROM haf_stats_batch_exact_rc AS c
)
SELECT
    ov.day,
    ov.body_value ->> 'id' AS json_id,
    COUNT(*)::BIGINT,
    SUM(ov.op_bytes)::BIGINT,
    -- Exact only when every op of the group has its share (#44); otherwise NULL.
    CASE WHEN COUNT(ex.rc_exact) = COUNT(*) THEN SUM(ex.rc_exact) END::BIGINT
FROM haf_stats_batch_ops ov
LEFT JOIN ex ON ex.operation_id = ov.op_id
WHERE ov.op_type_id = 18   -- hive::protocol::custom_json_operation
  AND ov.body_value ->> 'id' IS NOT NULL
GROUP BY ov.day, ov.body_value ->> 'id';
END;
$$;

CREATE FUNCTION pg_temp.account_custom_json_rows_before(
    _first_block INT,
    _last_block INT
)
RETURNS TABLE (account_id INT, day DATE, json_id TEXT, op_count INT, op_bytes BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
VOLATILE
SET jit = OFF
SET from_collapse_limit = '16'
SET join_collapse_limit = '16'
AS $$
BEGIN
PERFORM haf_stats_app.prepare_batch_exact_rc(_first_block, _last_block);
PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[18]);
RETURN QUERY
WITH ex AS (
    -- The batch's shares, computed once for the three rollups (prepare_batch_exact_rc, above).
    SELECT c.op_id AS operation_id, c.rc_exact
    FROM haf_stats_batch_exact_rc AS c
),
ops AS MATERIALIZED (
    -- One custom_json op per row, with its id, the day it landed, its payload size, and its
    -- exact RC share where its transaction recorded one (#44).
    SELECT
        ov.op_id,
        ov.day,
        ov.body_value ->> 'id' AS json_id,
        ov.body_value AS body,
        ov.op_bytes,
        ex.rc_exact
    FROM haf_stats_batch_ops ov
    LEFT JOIN ex ON ex.operation_id = ov.op_id
    WHERE ov.op_type_id = 18   -- hive::protocol::custom_json_operation
),
-- Fan each op out to its signer(s): required_posting_auths UNION required_auths.
-- UNION (not UNION ALL) dedups an account listed under both auths so it counts the op once.
-- The op's payload size and exact RC ride along; for a (rare) multi-signer op each signer is
-- attributed the full op_bytes and the full rc_exact, consistent with op_count counting the op
-- once per signer (the network rollup counts it once).
signers AS (
    SELECT o.op_id, o.day, o.json_id, o.op_bytes, o.rc_exact, s.signer
    FROM ops o
    CROSS JOIN LATERAL (
        SELECT jsonb_array_elements_text(o.body -> 'required_posting_auths') AS signer
        UNION
        SELECT jsonb_array_elements_text(o.body -> 'required_auths')
    ) s
    WHERE o.json_id IS NOT NULL
),
-- Resolve the DISTINCT signer-name set once (anti-seq-scan idiom, mirrors
-- process_active_users); a busy bot recurs thousands of times per batch.
name_ids AS MATERIALIZED (
    SELECT av.name, av.id
    FROM hive.accounts_view av
    WHERE av.name IN (SELECT DISTINCT signer FROM signers)
)
SELECT ni.id::INT, sg.day, sg.json_id, COUNT(*)::INT, SUM(sg.op_bytes)::BIGINT,
       -- Exact only when every op of the group has its share (#44); otherwise NULL.
       CASE WHEN COUNT(sg.rc_exact) = COUNT(*) THEN SUM(sg.rc_exact) END::BIGINT
FROM signers sg
JOIN name_ids ni ON ni.name = sg.signer
GROUP BY ni.id, sg.day, sg.json_id;
END;
$$;

CREATE FUNCTION pg_temp.batch_ops_before(
    _first_block INT,
    _last_block INT,
    _op_types INT [] DEFAULT NULL
)
RETURNS TABLE (
    op_id BIGINT, block_num INT, trx_in_block SMALLINT, op_type_id SMALLINT, op_time TIMESTAMP,
    day DATE, body_value JSONB, op_bytes INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    _types INT [] := _op_types;
BEGIN
    IF _types IS NULL THEN
        SELECT ARRAY[0, 1, 2, 17, 18, 73] || ARRAY_AGG(ot.id ORDER BY ot.id) INTO _types
        FROM hafd.operation_types AS ot
        WHERE NOT ot.is_virtual
           OR ot.name IN (
               'hive::protocol::author_reward_operation',
               'hive::protocol::comment_benefactor_reward_operation',
               'hive::protocol::curation_reward_operation',
               'hive::protocol::interest_operation',
               'hive::protocol::fill_transfer_from_savings_operation',
               'hive::protocol::fill_vesting_withdraw_operation',
               'hive::protocol::producer_reward_operation',
               'hive::protocol::liquidity_reward_operation',
               'hive::protocol::proposal_pay_operation',
               'hive::protocol::fill_order_operation',
               'hive::protocol::account_created_operation',
               'hive::protocol::producer_missed_operation'
           );
    END IF;

    RETURN QUERY
    SELECT
        o.id,
        b.num,
        o.trx_in_block,
        o.op_type_id,
        b.created_at,
        b.created_at::DATE,
        o.body_value,
        CASE WHEN ot.is_virtual IS NOT TRUE THEN octet_length(o.body_value::TEXT) END
    FROM hafd.operations AS o
    JOIN hafd.blocks AS b ON b.num = hafd.operation_id_to_block_num(o.id)
    LEFT JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id
    -- Both forms of the range: the id range is the operations primary key's, which suits the
    -- batch's full set; the derived block number is the Index Cond of
    -- hive_operations_op_type_id_block_num, which suits a direct call that stages one or two
    -- types over a long range (the install self-heals, the rebuild scripts).
    WHERE o.id >= hafd.operation_id(_first_block, 0)
      AND o.id < hafd.operation_id(_last_block + 1, 0)
      AND hafd.operation_id_to_block_num(o.id) BETWEEN _first_block AND _last_block
      AND o.op_type_id = ANY(_types)::INT [];
END;
$$;

-- The symmetric difference of two queries' rows, NULLs equal, as text; NULL when there is none.
CREATE FUNCTION pg_temp.row_diff(_label TEXT, _before TEXT, _now TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    _diff TEXT;
BEGIN
    EXECUTE format(
        'SELECT string_agg(d.side || '' '' || d.r, ''; '' ORDER BY d.r) FROM ('
        '  SELECT ''before only'' AS side, x::TEXT AS r FROM ((%1$s) EXCEPT ALL (%2$s)) AS x'
        '  UNION ALL'
        '  SELECT ''now only'', x::TEXT FROM ((%2$s) EXCEPT ALL (%1$s)) AS x'
        ') AS d', _before, _now)
    INTO _diff;
    RETURN CASE WHEN _diff IS NOT NULL THEN _label || ': ' || _diff END;
END;
$$;

UPDATE haf_stats_app.app_status SET last_processed_block = 0;

-- The chain's vote_operation id; the stub gives its name to id 1, the chain's comment_operation.
UPDATE hafd.operation_types SET name = 'hive::protocol::comment_operation' WHERE id = 1;
INSERT INTO hafd.operation_types (id, name, is_virtual) VALUES
(0, 'hive::protocol::vote_operation', FALSE),
(3, 'hive::protocol::transfer_to_vesting_operation', FALSE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO hafd.blocks (num, created_at) VALUES
(9701, '2021-10-01 00:00:00'),
(9702, '2021-10-01 00:00:03'),
(9703, '2021-10-02 00:00:00');

INSERT INTO hafd.accounts (id, name) VALUES
(97001, 'stg-alice'),
(97002, 'stg-bob'),
(97003, 'stg-carol');

-- Block 9702 tx 0 has no transactions row, so its ops have no exact RC; nor has 9701 tx 2, whose
-- cost is NULL. 9701 tx 4 is a three-op transaction its cost is split across.
INSERT INTO hafd.transactions (block_num, trx_in_block, rc_cost) VALUES
(9701, 0, 1000),
(9701, 1, 2000),
(9701, 2, NULL),
(9701, 3, 500),
(9701, 4, 300),
(9701, 5, 700),
(9702, 1, 900),
(9703, 0, 400),
(9703, 1, 100);

INSERT INTO hafd.operations (id, op_type_id, body_value, trx_in_block) VALUES
(hafd.operation_id(9701, 1), 18, '{"id": "follow", "required_auths": [], "required_posting_auths": ["stg-alice", "stg-bob"], "json": "[]"}', 0),
(hafd.operation_id(9701, 2), 18, '{"id": "sm_x", "required_auths": ["stg-alice"], "required_posting_auths": ["stg-alice", "stg-carol"], "json": "{}"}', 1),
(hafd.operation_id(9701, 3), 18, '{"id": "follow", "required_auths": [], "required_posting_auths": ["stg-bob"], "json": "[]"}', 2),
(hafd.operation_id(9701, 4), 18, '{"required_auths": [], "required_posting_auths": ["stg-alice"], "json": "[]"}', 3),
(hafd.operation_id(9701, 5), 0, '{"voter": "stg-alice", "author": "stg-bob", "permlink": "p", "weight": 10000}', 4),
(hafd.operation_id(9701, 6), 1, '{"author": "stg-bob", "permlink": "p", "parent_author": "", "parent_permlink": "t", "body": "b"}', 4),
(hafd.operation_id(9701, 7), 18, '{"id": "follow", "required_auths": [], "required_posting_auths": ["stg-carol"], "json": "[]"}', 4),
(hafd.operation_id(9701, 8), 64, '{"producer": "stg-carol"}', NULL),
(hafd.operation_id(9701, 9), 2, '{"from": "stg-carol", "to": "stg-alice", "amount": "1", "memo": ""}', 5),
(hafd.operation_id(9702, 1), 1, '{"author": "stg-alice", "permlink": "c", "parent_author": "stg-bob", "parent_permlink": "p", "body": "b"}', 0),
(hafd.operation_id(9702, 2), 18, '{"id": "follow", "required_auths": [], "required_posting_auths": ["stg-bob", "stg-bob"], "json": "[]"}', 0),
(hafd.operation_id(9702, 3), 3, '{"from": "stg-carol", "to": "stg-carol", "_signer": "stg-carol"}', 1),
(hafd.operation_id(9702, 4), 18, '{"id": "sm_x", "required_auths": [], "required_posting_auths": ["stg-nobody", "stg-alice"], "json": "{}"}', 1),
(hafd.operation_id(9703, 1), 18, '{"id": "follow", "required_auths": ["stg-bob"], "required_posting_auths": ["stg-alice"], "json": "[]"}', 0),
(hafd.operation_id(9703, 2), 0, '{"voter": "stg-bob", "author": "stg-alice", "permlink": "c", "weight": 5000}', 1);

DELETE FROM haf_stats_backend.active_users_daily WHERE day IN ('2021-10-01', '2021-10-02');
DELETE FROM haf_stats_backend.active_user_ops_daily WHERE day IN ('2021-10-01', '2021-10-02');

-- The old process_active_users aggregates, verbatim, over whatever haf_stats_batch_authored_ops holds.
CREATE TEMP VIEW active_users_membership_before AS
        SELECT day, op_class, account_id, COUNT(DISTINCT op_id) AS ops
        FROM haf_stats_batch_authored_ops
        WHERE op_class IS NOT NULL
        GROUP BY day, op_class, account_id
        UNION ALL
        SELECT day, -1::SMALLINT, account_id, COUNT(DISTINCT op_id)
        FROM haf_stats_batch_authored_ops
        GROUP BY day, account_id;
