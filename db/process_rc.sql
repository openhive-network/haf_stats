-- Feature: per-account RC footprint (get_account_rc_footprint endpoint).
--
-- RC costs are not stored on user operations. They appear as
-- rc_account_statuses_operation virtual ops fired after each transaction.
-- Cost per account = previous_rc - rc.current_mana from the virtual op body.
--
-- Attribution to an op type uses the first non-virtual op in the same transaction
-- (covers the common case of one op per tx on Hive).
--
-- rc_account_statuses_operation body shape (HF26+ / Shape B — array):
--   body -> 'value' -> 'account_statuses'  array of per-account entries, each with:
--     elem ->> 'account'              (account name)
--     elem ->> 'previous_rc'          (mana before tx)
--     elem -> 'rc' ->> 'current_mana' (mana after tx)
-- Uses hive.operations_view_extended (vs operations_view) to obtain the timestamp.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.rc_operation_log (
    id BIGSERIAL PRIMARY KEY,
    block_num INT NOT NULL,
    account_id INT NOT NULL,
    op_type_id SMALLINT, -- NULL when attribution is not possible
    custom_json_id TEXT, -- populated only for custom_json_operation
    rc_cost BIGINT NOT NULL,
    "timestamp" TIMESTAMP NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rol_account_ts
ON haf_stats_backend.rc_operation_log (account_id, "timestamp" DESC);

CREATE INDEX IF NOT EXISTS idx_rol_custom_json
ON haf_stats_backend.rc_operation_log (custom_json_id)
WHERE custom_json_id IS NOT NULL;

GRANT SELECT ON haf_stats_backend.rc_operation_log TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_rc(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _rc_vop_type_id    SMALLINT;
    _custom_json_op_id SMALLINT;
BEGIN
    SELECT id INTO _rc_vop_type_id
    FROM hive.operation_types
    WHERE name = 'rc_account_statuses_operation' LIMIT 1;

    SELECT id INTO _custom_json_op_id
    FROM hive.operation_types
    WHERE name = 'custom_json_operation' LIMIT 1;

    INSERT INTO haf_stats_backend.rc_operation_log
        (block_num, account_id, op_type_id, custom_json_id, rc_cost, "timestamp")
    WITH rc_events AS (
        -- One rc_account_statuses_operation virtual op per tx, batching all accounts.
        -- CROSS JOIN expands the account_statuses array into one row per account.
        -- operations_view_extended used (vs operations_view) to get the timestamp.
        SELECT
            ov.block_num,
            ov.trx_in_block,
            ov.timestamp,
            (elem ->> 'account')                                      AS account_name,
            GREATEST(0,
                (elem ->> 'previous_rc')::BIGINT -
                (elem -> 'rc' ->> 'current_mana')::BIGINT
            )                                                         AS rc_cost
        FROM hive.operations_view_extended ov
        CROSS JOIN jsonb_array_elements(ov.body -> 'value' -> 'account_statuses') AS elem
        WHERE ov.op_type_id = _rc_vop_type_id
          AND ov.block_num  BETWEEN _first_block AND _last_block
          AND (elem ->> 'previous_rc')::BIGINT
            > (elem -> 'rc' ->> 'current_mana')::BIGINT
    ),
    user_ops AS (
        -- First non-virtual op per transaction for op-type attribution.
        -- For the common case of one op per tx this is exact.
        SELECT DISTINCT ON (block_num, trx_in_block)
            block_num,
            trx_in_block,
            op_type_id,
            CASE WHEN op_type_id = _custom_json_op_id
                 THEN (body -> 'value' ->> 'id')
                 ELSE NULL END AS custom_json_id
        FROM hive.operations_view
        WHERE block_num BETWEEN _first_block AND _last_block
          AND op_type_id NOT IN (SELECT id FROM hafd.operation_types WHERE is_virtual = TRUE)
        ORDER BY block_num, trx_in_block, op_pos ASC
    )
    SELECT
        rc.block_num,
        a.id,
        uo.op_type_id,
        uo.custom_json_id,
        rc.rc_cost,
        rc.timestamp
    FROM rc_events rc
    JOIN hafd.accounts a ON a.name = rc.account_name
    LEFT JOIN user_ops uo
           ON uo.block_num    = rc.block_num
          AND uo.trx_in_block = rc.trx_in_block
    WHERE rc.rc_cost > 0
    ON CONFLICT DO NOTHING;

END;
$$;
