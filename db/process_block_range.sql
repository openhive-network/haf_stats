SET ROLE haf_stats_owner;

-- Block range dispatcher.
-- Calls domain-specific processors in order. Add calls here as features are implemented.

-- ---------------------------------------------------------------------------
-- Per-processor timings, off unless the session sets haf_stats.processor_timings = on
-- (e.g. options=-c haf_stats.processor_timings=on on the block processor's connection).
--
-- process_block_range reads the setting once per batch; when it is off that comparison is
-- all it adds. The processors that call a rollup/period/retention refresh read it again
-- at the refresh call site, only on a batch that crosses the refresh's block boundary.
-- When it is on, each step's wall time and the batch's operation counts are sent to the
-- client as INFO lines, one line each, which haf_app_driver.py writes to its log when
-- run with --server-messages=INFO:
--
--   haf_stats_processor_timing {"first_block":..,"last_block":..,"step":"process_financial",
--                               "within":null,"seconds":..,"reads":["transfer_operation",...]}
--   haf_stats_operation_counts {"first_block":..,"last_block":..,"seconds":..,"counts":[
--                               {"op_type":..,"virtual":..,"rows":..}]}
--
-- "within" is NULL for a step process_block_range calls, and names the processor for a
-- refresh timed inside one, whose seconds are therefore also in that processor's.
-- "reads" names the op types a step selects ("non_virtual" for every non-virtual type):
-- prepare_batch_ops from hafd.operations, every other step from what it staged. Its rows read
-- are the batch's counts of those types. The
-- counts query is instrumentation: its own time is its "seconds", not any step's. INFO,
-- not NOTICE, because INFO reaches the client whatever client_min_messages says.
-- scripts/processor_timings_report.py parses both lines. Nothing is stored.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.report_processor_timing;
CREATE OR REPLACE FUNCTION haf_stats_app.report_processor_timing(
    _step TEXT,
    _first_block INT,
    _last_block INT,
    _started TIMESTAMPTZ,
    _reads TEXT [],
    _within TEXT
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    RAISE INFO 'haf_stats_processor_timing %', json_build_object(
        'first_block', _first_block,
        'last_block', _last_block,
        'step', _step,
        'within', _within,
        'seconds', EXTRACT(EPOCH FROM clock_timestamp() - _started),
        'reads', _reads
    );
    RETURN clock_timestamp();
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.report_operation_counts;
CREATE OR REPLACE FUNCTION haf_stats_app.report_operation_counts(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    _started TIMESTAMPTZ := clock_timestamp();
    _counts JSONB;
BEGIN
    SELECT jsonb_agg(to_jsonb(c) ORDER BY c.op_type) INTO _counts
    FROM (
        SELECT
            replace(ot.name, 'hive::protocol::', '') AS op_type,
            ot.is_virtual AS virtual,
            COUNT(*) AS rows
        FROM hafd.operations AS o
        JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id
        WHERE o.id >= hafd.operation_id(_first_block, 0)
          AND o.id < hafd.operation_id(_last_block + 1, 0)
        GROUP BY ot.name, ot.is_virtual
    ) AS c;

    -- jsonb, not json: json_agg puts a newline between elements, and the driver logs
    -- each line of a message as a line of its own.
    RAISE INFO 'haf_stats_operation_counts %', jsonb_build_object(
        'first_block', _first_block,
        'last_block', _last_block,
        'seconds', EXTRACT(EPOCH FROM clock_timestamp() - _started),
        'counts', COALESCE(_counts, '[]'::JSONB)
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- The batch's operations, read from hafd.operations once per range.
--
-- Every processor reads its operations from this ON COMMIT DROP temp table rather than from
-- hafd.operations or hive.operations_view, so each op type is read and decoded once per batch
-- however many processors use it. process_block_range stages the full set first (_op_types
-- NULL); each processor also calls this lazily with the op types it reads, so direct calls
-- (the rebuild scripts, the install self-heals, the fixtures) still work and stage only what
-- they need. The range-key GUC, the staged-type GUC and the temp table's existence make a
-- call no-op when the range is already staged with every type it asks for; both GUCs are
-- transaction-local, so they end, and roll back, with the table.
--
-- The full set is every non-virtual op (prepare_batch_authored_ops, process_network_ops and
-- exact_rc_for_range read them all), the hardcoded ids the processors filter on, and the
-- virtual types they resolve by name. hafd.operations, not operations_view: the haf_stats
-- context is non-forking, so every block it processes is irreversible.
--
-- op_bytes is the payload-size proxy the RC estimate is calibrated against (process_rc.sql),
-- serialized once here for the three rollups that sum it, and only for non-virtual ops.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.prepare_batch_ops;
CREATE OR REPLACE FUNCTION haf_stats_app.prepare_batch_ops(
    _first_block INT,
    _last_block INT,
    _op_types INT [] DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _range_key TEXT := _first_block::TEXT || ':' || _last_block::TEXT;
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

    IF current_setting('haf_stats.batch_ops_range', TRUE) = _range_key
       AND TO_REGCLASS('pg_temp.haf_stats_batch_ops') IS NOT NULL
       AND _types <@ NULLIF(current_setting('haf_stats.batch_ops_types', TRUE), '')::INT [] THEN
        RETURN;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_batch_ops (
        op_id BIGINT NOT NULL,
        block_num INT NOT NULL,
        trx_in_block SMALLINT,
        op_type_id SMALLINT NOT NULL,
        op_time TIMESTAMP NOT NULL,
        day DATE NOT NULL,
        body_value JSONB,
        op_bytes INT
    ) ON COMMIT DROP;

    TRUNCATE haf_stats_batch_ops;
    -- The processors' op_type_id filters are what the index is for; it is built after the
    -- load, which is cheaper than maintaining it through the INSERT. Dropped first so a
    -- second staging in the same transaction loads without it too.
    DROP INDEX IF EXISTS pg_temp.haf_stats_batch_ops_type_idx;

    INSERT INTO haf_stats_batch_ops
        (op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value, op_bytes)
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
      AND o.op_type_id = ANY(_types);

    CREATE INDEX haf_stats_batch_ops_type_idx ON haf_stats_batch_ops (op_type_id, op_id);
    -- Not body_value: no plan filters or joins on the JSONB, and sampling it is most of the cost.
    ANALYZE haf_stats_batch_ops (op_id, block_num, trx_in_block, op_type_id, op_time, day, op_bytes);
    PERFORM set_config('haf_stats.batch_ops_range', _range_key, TRUE);
    PERFORM set_config('haf_stats.batch_ops_types', _types::TEXT, TRUE);
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.prepare_batch_authored_ops;
CREATE OR REPLACE FUNCTION haf_stats_app.prepare_batch_authored_ops(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
SET from_collapse_limit = '16'
SET join_collapse_limit = '16'
SET enable_bitmapscan = 'off'
AS $$
DECLARE
    _range_key TEXT := _first_block::TEXT || ':' || _last_block::TEXT;
    _safe BOOLEAN := FALSE;
BEGIN
    -- Shared by process_account_cohorts and process_active_users so the authority
    -- lookup and name resolution over the batch's non-virtual ops (prepare_batch_ops)
    -- run once per batch instead of twice. process_block_range builds it before the
    -- two consumers; each consumer also calls this lazily so direct rebuild invocations
    -- still work. The range-key GUC plus the temp-table existence check make the repeat
    -- calls within a batch no-ops; the table is ON COMMIT DROP so each batch rebuilds.
    IF current_setting('haf_stats.batch_authored_ops_range', TRUE) = _range_key
       AND TO_REGCLASS('pg_temp.haf_stats_batch_authored_ops') IS NOT NULL THEN
        RETURN;
    END IF;

    PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block);

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_batch_authored_ops (
        op_id BIGINT NOT NULL,
        account_id INT NOT NULL,
        op_time TIMESTAMP NOT NULL,
        day DATE NOT NULL,
        op_class SMALLINT,
        PRIMARY KEY (op_id, account_id)
    ) ON COMMIT DROP;

    -- Plain hive.get_required_authorities first, for the types whose signers are not read from
    -- the body, in one subtransaction for the whole statement. Only if it fails is the
    -- statement run again through the per-row get_required_authorities_safe, whose
    -- subtransaction per op is what makes an op whose authorities cannot be computed
    -- contribute no rows. A batch with no such op therefore gets exactly the rows the safe
    -- wrapper would have given it, without its cost. WHEN OTHERS because the safe wrapper
    -- treats any failure as authorless; a failure that is not the authority lookup's raises
    -- again from the second run.
    <<attempt>>
    LOOP
        BEGIN
            TRUNCATE haf_stats_batch_authored_ops;

            WITH authored AS MATERIALIZED (
                SELECT DISTINCT
                    s.op_id,
                    ra.account_name AS actor_name,
                    s.op_time,
                    s.day,
                    (CASE
                        WHEN s.op_type_id = 0 THEN 3::SMALLINT                 -- vote_operation
                        WHEN s.op_type_id = 1
                         AND COALESCE(s.body_value ->> 'parent_author', '') = ''
                                              THEN 1::SMALLINT                 -- comment_operation: post
                        WHEN s.op_type_id = 1 THEN 2::SMALLINT                 -- comment_operation: comment
                        WHEN s.op_type_id = 2 THEN 4::SMALLINT                 -- transfer_operation
                        WHEN s.op_type_id = 18 THEN 5::SMALLINT                -- custom_json_operation
                        ELSE NULL::SMALLINT                                    -- other authored op: ALL rollup only
                     END) AS op_class
                FROM haf_stats_batch_ops s
                JOIN hafd.operation_types ot ON ot.id = s.op_type_id AND NOT ot.is_virtual
                -- Every arm's filter reads only the op's type and _safe, so it is a one-time
                -- filter of the arm and only the arm for the op's type runs.
                --
                -- The four types that are most of the non-virtual stream sign with fields of
                -- their body, read here directly: the same accounts hive.get_required_authorities
                -- returns for them, without building the operation for it. A body that lacks the
                -- field gives NULL, or no array element, so no row; HAF gives '' or raises,
                -- which also leaves the op no account. A non-array auths field is skipped
                -- rather than raising.
                CROSS JOIN LATERAL (
                    SELECT s.body_value ->> 'voter' WHERE s.op_type_id = 0          -- vote_operation
                    UNION ALL
                    SELECT s.body_value ->> 'author' WHERE s.op_type_id = 1         -- comment_operation
                    UNION ALL
                    SELECT s.body_value ->> 'from' WHERE s.op_type_id = 2           -- transfer_operation
                    UNION ALL
                    SELECT auth.name                                                -- custom_json_operation
                    FROM jsonb_array_elements_text(
                        CASE WHEN jsonb_typeof(s.body_value -> 'required_auths') = 'array'
                             THEN s.body_value -> 'required_auths' END
                    ) AS auth (name)
                    WHERE s.op_type_id = 18
                    UNION ALL
                    SELECT auth.name
                    FROM jsonb_array_elements_text(
                        CASE WHEN jsonb_typeof(s.body_value -> 'required_posting_auths') = 'array'
                             THEN s.body_value -> 'required_posting_auths' END
                    ) AS auth (name)
                    WHERE s.op_type_id = 18
                    UNION ALL
                    -- Every other type through HAF, in the {type, value} form it takes, as
                    -- operations_view builds it. _safe is a constant of the statement, so only
                    -- one of the two functions is ever called.
                    SELECT r.account_name
                    FROM hive.get_required_authorities(jsonb_build_object(
                        'type', replace(ot.name, 'hive::protocol::', ''),
                        'value', s.body_value
                    )) r
                    WHERE s.op_type_id NOT IN (0, 1, 2, 18) AND NOT _safe
                    UNION ALL
                    SELECT r.account_name
                    FROM haf_stats_app.get_required_authorities_safe(jsonb_build_object(
                        'type', replace(ot.name, 'hive::protocol::', ''),
                        'value', s.body_value
                    )) r
                    WHERE s.op_type_id NOT IN (0, 1, 2, 18) AND _safe
                ) ra (account_name)
                WHERE ra.account_name IS NOT NULL
            ),
            name_ids AS MATERIALIZED (
                SELECT av.name, av.id
                FROM hive.accounts_view av
                WHERE av.name IN (
                    SELECT DISTINCT actor_name
                    FROM authored
                )
            )
            INSERT INTO haf_stats_batch_authored_ops (op_id, account_id, op_time, day, op_class)
            SELECT a.op_id, ni.id, a.op_time, a.day, a.op_class
            FROM authored a
            JOIN name_ids ni ON ni.name = a.actor_name;

            EXIT attempt;
        EXCEPTION WHEN OTHERS THEN
            IF _safe THEN
                RAISE;
            END IF;
            _safe := TRUE;
        END;
    END LOOP;

    PERFORM set_config('haf_stats.batch_authored_ops_range', _range_key, FALSE);
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.process_block_range;
CREATE OR REPLACE FUNCTION haf_stats_app.process_block_range(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _timed BOOLEAN := current_setting('haf_stats.processor_timings', TRUE) = 'on';
    _t TIMESTAMPTZ;
BEGIN
    -- Each IF _timed line reports the step above it and restarts the clock. The reads
    -- lists name the op types each step selects (see report_processor_timing).
    IF _timed THEN _t := clock_timestamp(); END IF;
    -- Every processor below reads its operations from what this stages.
    PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('prepare_batch_ops', _first_block, _last_block, _t, '{non_virtual,author_reward_operation,comment_benefactor_reward_operation,curation_reward_operation,interest_operation,fill_transfer_from_savings_operation,fill_vesting_withdraw_operation,producer_reward_operation,liquidity_reward_operation,proposal_pay_operation,fill_order_operation,account_created_operation,producer_missed_operation,ineffective_delete_comment_operation}', NULL); END IF;
    PERFORM haf_stats_app.process_financial(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_financial', _first_block, _last_block, _t, '{author_reward_operation,comment_benefactor_reward_operation,curation_reward_operation,claim_reward_balance_operation,interest_operation,transfer_operation,transfer_to_savings_operation,transfer_from_savings_operation,fill_transfer_from_savings_operation,transfer_to_vesting_operation,fill_vesting_withdraw_operation,producer_reward_operation,liquidity_reward_operation,proposal_pay_operation,fill_order_operation}', NULL); END IF;
    PERFORM haf_stats_app.prepare_batch_authored_ops(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('prepare_batch_authored_ops', _first_block, _last_block, _t, '{non_virtual}', NULL); END IF;
    PERFORM haf_stats_app.process_account_cohorts(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_account_cohorts', _first_block, _last_block, _t, '{account_created_operation}', NULL); END IF;
    PERFORM haf_stats_app.process_active_users(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_active_users', _first_block, _last_block, _t, '{}', NULL); END IF;
    -- Before process_content_stats: a community registered in this batch must already be
    -- in community_registry when the comment scan classifies posts addressed to it.
    PERFORM haf_stats_app.process_community_registry(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_community_registry', _first_block, _last_block, _t, '{account_created_operation,custom_json_operation}', NULL); END IF;
    PERFORM haf_stats_app.process_content_stats(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_content_stats', _first_block, _last_block, _t, '{vote_operation,comment_operation,delete_comment_operation,ineffective_delete_comment_operation}', NULL); END IF;
    PERFORM haf_stats_app.process_content_cohorts(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_content_cohorts', _first_block, _last_block, _t, '{comment_operation}', NULL); END IF;
    -- The three rollups below each call this first and find it done; called here so its
    -- work is one step of its own rather than part of whichever rollup runs first.
    PERFORM haf_stats_app.prepare_batch_exact_rc(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('prepare_batch_exact_rc', _first_block, _last_block, _t, '{non_virtual}', NULL); END IF;
    PERFORM haf_stats_app.process_custom_json(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_custom_json', _first_block, _last_block, _t, '{custom_json_operation}', NULL); END IF;
    PERFORM haf_stats_app.process_network_ops(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_network_ops', _first_block, _last_block, _t, '{non_virtual}', NULL); END IF;
    PERFORM haf_stats_app.process_network_custom_json(_first_block, _last_block);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('process_network_custom_json', _first_block, _last_block, _t, '{custom_json_operation}', NULL); END IF;
    -- Reads hafd.blocks and the staged producer_missed ops, so it has no ordering dependency on
    -- any processor above it.
    PERFORM haf_stats_app.process_witness_blocks(_first_block, _last_block);
    IF _timed THEN
        PERFORM haf_stats_app.report_processor_timing('process_witness_blocks', _first_block, _last_block, _t, '{producer_missed_operation}', NULL);
        PERFORM haf_stats_app.report_operation_counts(_first_block, _last_block);
    END IF;
END;
$$;

RESET ROLE;
