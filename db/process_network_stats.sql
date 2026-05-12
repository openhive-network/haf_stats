-- Network-level stats and supply snapshot processors (Items 6 / 1.1).

-- ---------------------------------------------------------------------------
-- Network daily stats: transaction throughput and new accounts.
-- DAU is computed here as distinct accounts with at least one non-virtual op.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_network_stats(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO haf_stats_backend.network_daily_stats
        (day, dau, total_transactions, ops_by_type, new_accounts)
    WITH block_dates AS (
        SELECT
            DATE(hb.created_at)   AS day,
            hb.num                AS block_num
        FROM hafd.blocks hb
        WHERE hb.num BETWEEN _first_block AND _last_block
    ),
    daily_ops AS (
        SELECT
            bd.day,
            COUNT(DISTINCT
                COALESCE(
                    hot.body -> 'value' ->> 'required_posting_auths' ->> 0,
                    hot.body -> 'value' ->> 'required_auths'         ->> 0
                )
            )                                          AS dau,
            COUNT(*)                                   AS total_ops,
            jsonb_object_agg(
                ot.name,
                COUNT(*)
            )                                          AS ops_by_type
        FROM hive.operations_view hot
        JOIN block_dates bd ON bd.block_num = hot.block_num
        JOIN hive.operation_types ot ON ot.id = hot.op_type_id
        WHERE hot.is_virtual = FALSE
        GROUP BY bd.day
    ),
    new_accounts AS (
        SELECT
            DATE(hb.created_at)  AS day,
            COUNT(*)             AS cnt
        FROM hive.operations_view hov
        JOIN hafd.blocks hb ON hb.num = hov.block_num
        WHERE hov.block_num BETWEEN _first_block AND _last_block
          AND hov.op_type_id = hive.get_op_type_id('account_create_operation')
        GROUP BY DATE(hb.created_at)
    )
    SELECT
        do2.day,
        do2.dau,
        do2.total_ops,
        do2.ops_by_type,
        COALESCE(na.cnt, 0)
    FROM daily_ops do2
    LEFT JOIN new_accounts na ON na.day = do2.day
    ON CONFLICT (day) DO UPDATE SET
        dau                = network_daily_stats.dau                + EXCLUDED.dau,
        total_transactions = network_daily_stats.total_transactions + EXCLUDED.total_transactions,
        ops_by_type        = network_daily_stats.ops_by_type        || EXCLUDED.ops_by_type,
        new_accounts       = network_daily_stats.new_accounts       + EXCLUDED.new_accounts;
END;
$$;

-- ---------------------------------------------------------------------------
-- Supply snapshots: sampled once per UTC day.
-- Reads dynamic_global_properties from the get_dynamic_global_properties
-- virtual op embedded at the start of each block.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_supply_snapshot(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _last_snapshot_day DATE;
    _block_day         DATE;
BEGIN
    SELECT DATE("timestamp") INTO _last_snapshot_day
    FROM haf_stats_backend.supply_snapshots
    ORDER BY block_num DESC
    LIMIT 1;

    -- Only write a snapshot if we've advanced to a new UTC day
    SELECT DATE(created_at) INTO _block_day
    FROM hafd.blocks
    WHERE num = _last_block;

    IF _last_snapshot_day IS NOT NULL AND _block_day <= _last_snapshot_day THEN
        RETURN;
    END IF;

    -- dynamic_global_properties_object is embedded in 'system_warning' virtual ops
    -- or accessible via the hafd.dynamic_global_properties view if available.
    -- Fallback: read the latest block's metadata directly from hafd.blocks.
    --
    -- TODO: Verify the exact view/column name on the target HAF version.
    --       hafd.blocks may expose total_vesting_fund_hive, current_supply etc.
    --       as columns added by the sql_serializer plugin.

    INSERT INTO haf_stats_backend.supply_snapshots
        (block_num, "timestamp",
         hive_virtual_supply, hive_circulating, hbd_circulating,
         total_vests, hive_in_savings, hbd_in_savings)
    SELECT
        _last_block,
        created_at,
        total_vesting_fund_hive,        -- HIVE locked as HP
        current_supply,
        current_hbd_supply,
        total_vesting_shares,
        hive_savings_balance,           -- column names TBC against live hafd schema
        hbd_savings_balance,
        0                               -- reward_fund populated separately if needed
    FROM hafd.blocks
    WHERE num = _last_block
    ON CONFLICT (block_num) DO NOTHING;
END;
$$;
