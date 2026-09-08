SET ROLE haf_stats_owner;

-- Feature: network RC utilization (get_network_rc_utilization endpoint).
--
-- Network-wide per-(day, op_type) operation counts and summed payload bytes - the inputs of
-- the read-time RC estimate (issue #33). The endpoint multiplies these by the calibrated
-- rc_op_stats_daily rates (base_rc per op + byte_rc per payload byte) at read time, applying
-- the rate effective on/before each day, so recalibration needs no backfill and the estimate
-- tracks chain conditions as the rate series grows.
--
-- This stores INPUTS, not a pre-weighted RC figure (same model as account_custom_json_daily),
-- and covers all non-virtual op types (virtual ops are not user-submitted and consume no RC).
-- op_bytes is octet_length(body_value), the payload-size proxy the byte rate is calibrated
-- against (see process_rc.sql).

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_op_daily (
    day DATE NOT NULL,
    op_type_id SMALLINT NOT NULL,
    op_count BIGINT NOT NULL DEFAULT 0,
    op_bytes BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_type_id)
);

GRANT SELECT ON haf_stats_backend.network_op_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- One scan of the op stream per batch, aggregated to (day, op_type). Reads hafd.operations
-- directly over an operation-id block range (same idiom as process_custom_json); the
-- haf_stats context is non-forking so every processed block is irreversible. op_count/op_bytes
-- are additive (DO UPDATE adds), so each block range must be processed exactly once - the same
-- exactly-once assumption the other additive counters rely on.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.process_network_ops;
CREATE OR REPLACE FUNCTION haf_stats_app.process_network_ops(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
BEGIN

INSERT INTO haf_stats_backend.network_op_daily AS nod (day, op_type_id, op_count, op_bytes)
SELECT
    bv.created_at::DATE AS day,
    ov.op_type_id,
    COUNT(*)::BIGINT,
    SUM(octet_length(ov.body_value::text))::BIGINT
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.operation_types ot ON ot.id = ov.op_type_id AND ot.is_virtual = FALSE
WHERE hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY bv.created_at::DATE, ov.op_type_id
ON CONFLICT (day, op_type_id) DO UPDATE SET
    op_count = nod.op_count + EXCLUDED.op_count,
    op_bytes = nod.op_bytes + EXCLUDED.op_bytes;

END;
$$;

RESET ROLE;
