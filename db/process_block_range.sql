SET ROLE haf_stats_owner;

-- Block range dispatcher.
-- Calls domain-specific processors in order. Add calls here as features are implemented.

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

CREATE OR REPLACE FUNCTION haf_stats_app.process_block_range(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM haf_stats_app.process_financial(_first_block, _last_block);
    PERFORM haf_stats_app.prepare_batch_authored_ops(_first_block, _last_block);
    PERFORM haf_stats_app.process_account_cohorts(_first_block, _last_block);
    PERFORM haf_stats_app.process_active_users(_first_block, _last_block);
    PERFORM haf_stats_app.process_content_stats(_first_block, _last_block);
    PERFORM haf_stats_app.process_content_cohorts(_first_block, _last_block);
    PERFORM haf_stats_app.process_custom_json(_first_block, _last_block);
    PERFORM haf_stats_app.process_network_ops(_first_block, _last_block);
END;
$$;

RESET ROLE;
