-- The shared batch staging's ops stage, loaded in parts (stage_shared_batch's slot and ops_<k>
-- steps, #171), against the session-local staging the single-session path reads
-- (prepare_batch_ops): over blocks 6630-6636, which the parts split unevenly (1, 2, 2 and 2
-- blocks), every staged row must be the same, as a multiset. The ops stage is complete only once
-- every part is in, whatever order the parts run in; a part run again stages nothing twice; and
-- the steps of the level after it stage from the parted table.
--
-- One transaction, rolled back.
\set ON_ERROR_STOP on

BEGIN;

-- Every fixture block is irreversible; the stub lane has no HAF context.
CREATE OR REPLACE FUNCTION hive.app_get_irreversible_block()
RETURNS INT
LANGUAGE sql
STABLE
AS $$
    SELECT 2147483647;
$$;

-- A virtual type the full set leaves out.
INSERT INTO hafd.operation_types (id, name, is_virtual) VALUES
(97, 'hive::protocol::ci_unstaged_virtual_operation', TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO hafd.blocks (num, created_at) VALUES
(6630, '2021-10-07 23:59:54'),
(6631, '2021-10-07 23:59:57'),
(6632, '2021-10-08 00:00:00'),
(6633, '2021-10-08 00:00:03'),
(6634, '2021-10-08 00:00:06'),
(6635, '2021-10-08 00:00:09'),
(6636, '2021-10-08 00:00:12');

-- Block 6633 holds no operation. Each other block holds non-virtual ops, a staged virtual op or
-- the unstaged one; the first and last blocks' ops sit at the parts' outer edges.
INSERT INTO hafd.operations (id, op_type_id, body_value, trx_in_block) VALUES
(hafd.operation_id(6630, 0), 1, '{"voter": "sop-alice", "author": "sop-bob", "permlink": "p", "weight": 10000}', 0),
(hafd.operation_id(6630, 1), 18, '{"id": "follow", "json": "[]", "required_auths": [], "required_posting_auths": ["sop-alice"]}', 1),
(hafd.operation_id(6631, 1), 2, '{"from": "sop-bob", "to": "sop-alice", "amount": "1.000 HIVE", "memo": ""}', 0),
(hafd.operation_id(6631, 2), 97, '{"ci": "unstaged"}', -1),
(hafd.operation_id(6632, 1), 64, '{"producer": "sop-carol", "vesting_shares": "1.000000 VESTS"}', -1),
(hafd.operation_id(6632, 2), 18, '{"id": "sm_claim_daily", "json": "{}", "required_auths": ["sop-bob"], "required_posting_auths": []}', 0),
(hafd.operation_id(6634, 1), 1, '{"voter": "sop-carol", "author": "sop-alice", "permlink": "q", "weight": 5000}', 0),
(hafd.operation_id(6634, 2), 86, '{"producer": "sop-dave"}', -1),
(hafd.operation_id(6635, 1), 2, '{"from": "sop-alice", "to": "sop-dave", "amount": "2.000 HIVE", "memo": "m"}', 0),
(hafd.operation_id(6636, 0), 18, '{"id": "follow", "json": "[1]", "required_auths": [], "required_posting_auths": ["sop-dave"]}', 0),
(hafd.operation_id(6636, 9), 1, '{"voter": "sop-dave", "author": "sop-carol", "permlink": "r", "weight": 100}', 1);

SET ROLE haf_stats_owner;

DELETE FROM haf_stats_app.processor_group_progress;
DELETE FROM haf_stats_app.shared_batch_marker;

DO $parts$
DECLARE
    _parts INT := haf_stats_app.shared_batch_ops_parts();
    _levels JSONB := haf_stats_app.shared_batch_stage_levels();
    _order INT [];
    _part INT;
    _slot SMALLINT;
    _rows BIGINT;
    _n BIGINT;
BEGIN
    IF _levels->0 <> '["slot"]'::JSONB
       OR _levels->1 <> (SELECT jsonb_agg('ops_' || k ORDER BY k) FROM generate_series(0, _parts - 1) AS k) THEN
        RAISE EXCEPTION 'FAIL: the staging levels % do not start with the slot step, then the % ops parts', _levels, _parts;
    END IF;

    PERFORM haf_stats_app.stage_shared_batch('slot', 6630, 6636);
    SELECT m.slot INTO _slot FROM haf_stats_app.shared_batch_marker AS m
    WHERE m.stage = 'slot' AND m.first_block = 6630 AND m.last_block = 6636;
    IF _slot IS NULL THEN
        RAISE EXCEPTION 'FAIL: the slot step claimed no slot for 6630-6636';
    END IF;

    -- The last part first, the first part last.
    SELECT array_agg(k ORDER BY k DESC) INTO _order FROM generate_series(0, _parts - 1) AS k;
    FOREACH _part IN ARRAY _order LOOP
        IF EXISTS (SELECT FROM haf_stats_app.shared_batch_marker AS m WHERE m.stage = 'ops') THEN
            RAISE EXCEPTION 'FAIL: the ops stage was marked complete before part % was staged', _part;
        END IF;
        PERFORM haf_stats_app.stage_shared_batch('ops_' || _part, 6630, 6636);
    END LOOP;
    IF NOT EXISTS (
        SELECT FROM haf_stats_app.shared_batch_marker AS m
        WHERE m.slot = _slot AND m.stage = 'ops' AND m.first_block = 6630 AND m.last_block = 6636
          AND m.op_types = haf_stats_app.batch_op_types(NULL)
    ) THEN
        RAISE EXCEPTION 'FAIL: the ops stage is not marked complete, with the full set''s op types, after its % parts', _parts;
    END IF;

    EXECUTE format('SELECT count(*) FROM haf_stats_app.%I', 'shared_batch_ops_' || _slot) INTO _rows;
    PERFORM haf_stats_app.stage_shared_batch('ops_1', 6630, 6636);
    EXECUTE format('SELECT count(*) FROM haf_stats_app.%I', 'shared_batch_ops_' || _slot) INTO _n;
    IF _n <> _rows THEN
        RAISE EXCEPTION 'FAIL: part 1 run again changed the staged rows from % to %', _rows, _n;
    END IF;

    -- The level after the parts reads them as one stage.
    PERFORM haf_stats_app.stage_shared_batch('authored_ops', 6630, 6636);
    PERFORM haf_stats_app.stage_shared_batch('exact_rc', 6630, 6636);
    IF NOT haf_stats_app.shared_batch_complete(6630, 6636) THEN
        RAISE EXCEPTION 'FAIL: blocks 6630-6636 are not staged complete after every step';
    END IF;

    EXECUTE format('CREATE TEMP TABLE ci_shared_ops AS SELECT * FROM haf_stats_app.%I', 'shared_batch_ops_' || _slot);
    PERFORM haf_stats_app.prepare_batch_ops(6630, 6636);

    SELECT count(*) INTO _n FROM (
        (SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes, custom_json_type_id
         FROM ci_shared_ops
         EXCEPT ALL
         SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes, custom_json_type_id
         FROM haf_stats_batch_ops)
        UNION ALL
        (SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes, custom_json_type_id
         FROM haf_stats_batch_ops
         EXCEPT ALL
         SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes, custom_json_type_id
         FROM ci_shared_ops)
    ) AS d;
    IF _n <> 0 THEN
        RAISE EXCEPTION 'FAIL: the parted shared ops stage differs from prepare_batch_ops in % rows', _n;
    END IF;
    -- Every fixture op but the unstaged virtual one.
    IF _rows <> 10 THEN
        RAISE EXCEPTION 'FAIL: the parted shared ops stage holds % rows, not 10', _rows;
    END IF;
    RAISE NOTICE 'the ops stage staged in % parts holds the same % rows as prepare_batch_ops', _parts, _rows;
END;
$parts$;

ROLLBACK;
