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
-- "reads" names the op types a step selects from the operation stream ("non_virtual" for
-- every non-virtual type), so its rows read are the batch's counts of those types. The
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
BEGIN
    -- Shared by process_account_cohorts and process_active_users so the operation
    -- stream (operations_view + get_required_authorities_safe + name resolution) is
    -- scanned once per batch instead of twice. process_block_range builds it before the
    -- two consumers; each consumer also calls this lazily so direct rebuild invocations
    -- still work. The range-key GUC plus the temp-table existence check make the repeat
    -- calls within a batch no-ops; the table is ON COMMIT DROP so each batch rebuilds.
    IF current_setting('haf_stats.batch_authored_ops_range', TRUE) = _range_key
       AND TO_REGCLASS('pg_temp.haf_stats_batch_authored_ops') IS NOT NULL THEN
        RETURN;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_batch_authored_ops (
        op_id BIGINT NOT NULL,
        account_id INT NOT NULL,
        op_time TIMESTAMP NOT NULL,
        day DATE NOT NULL,
        op_class SMALLINT,
        PRIMARY KEY (op_id, account_id)
    ) ON COMMIT DROP;

    TRUNCATE haf_stats_batch_authored_ops;

    WITH authored AS MATERIALIZED (
        SELECT DISTINCT
            ov.id AS op_id,
            ra.account_name AS actor_name,
            b.created_at AS op_time,
            b.created_at::DATE AS day,
            (CASE
                WHEN ov.op_type_id = 0 THEN 3::SMALLINT                 -- vote_operation
                WHEN ov.op_type_id = 1
                 AND COALESCE(ov.body_value ->> 'parent_author', '') = ''
                                       THEN 1::SMALLINT                 -- comment_operation: post
                WHEN ov.op_type_id = 1 THEN 2::SMALLINT                 -- comment_operation: comment
                WHEN ov.op_type_id = 2 THEN 4::SMALLINT                 -- transfer_operation
                WHEN ov.op_type_id = 18 THEN 5::SMALLINT                -- custom_json_operation
                ELSE NULL::SMALLINT                                     -- other authored op: ALL rollup only
             END) AS op_class
        FROM hive.operations_view ov
        JOIN hafd.blocks b ON b.num = ov.block_num
        CROSS JOIN LATERAL haf_stats_app.get_required_authorities_safe(ov.body) ra
        WHERE ov.block_num BETWEEN _first_block AND _last_block
          AND ov.id >= hafd.operation_id(_first_block, 0)
          AND ov.id <  hafd.operation_id(_last_block + 1, 0)
          AND ra.account_name IS NOT NULL
          AND ov.op_type_id IN (SELECT id FROM hafd.operation_types WHERE NOT is_virtual)
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
    -- Reads hafd.blocks / hafd.operations directly, so it has no ordering dependency on any
    -- processor above it.
    PERFORM haf_stats_app.process_witness_blocks(_first_block, _last_block);
    IF _timed THEN
        PERFORM haf_stats_app.report_processor_timing('process_witness_blocks', _first_block, _last_block, _t, '{producer_missed_operation}', NULL);
        PERFORM haf_stats_app.report_operation_counts(_first_block, _last_block);
    END IF;
END;
$$;

RESET ROLE;
