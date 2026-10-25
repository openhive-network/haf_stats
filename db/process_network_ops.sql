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


-- #44 part 2: the EXACT RC of this row's operations, summed from their shares of the RC their
-- transactions recorded (haf_stats_app.exact_rc_for_range, db/exact_rc.sql). NULL unless EVERY
-- operation counted in the row had one: a row is exact or it is not, never half of each. NULL on a
-- HAF without rc_cost, before hardfork 20, and for rows built before this column existed until
-- scripts/backfill_rc_exact.sh has filled them. The endpoints use it where set and the estimate
-- otherwise. Guarded: no ACCESS EXCLUSIVE lock where the column already exists (#96).
SELECT haf_stats_app.apply_schema_migration(
    NOT EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = 'haf_stats_backend.network_op_daily'::REGCLASS
            AND a.attname = 'rc_exact'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_backend.network_op_daily
     ADD COLUMN IF NOT EXISTS rc_exact BIGINT',
    'network_op_daily.rc_exact'
);

GRANT SELECT ON haf_stats_backend.network_op_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- One pass over the batch's staged non-virtual ops (prepare_batch_ops,
-- db/process_block_range.sql), aggregated to (day, op_type). op_count/op_bytes
-- are additive (DO UPDATE adds), so each block range must be processed exactly once - the same
-- exactly-once assumption the other additive counters rely on.
-- ---------------------------------------------------------------------------

-- The rows process_network_ops adds for a block range, before they are merged into the table: one per
-- group, with its op_count, op_bytes and exact RC (#44). The processor INSERTs them; the rc_exact
-- backfill (haf_stats_app.backfill_rc_exact) compares them with what a past day already holds.
DROP FUNCTION IF EXISTS haf_stats_app.network_op_rows(INT, INT);
CREATE OR REPLACE FUNCTION haf_stats_app.network_op_rows(
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

INSERT INTO haf_stats_backend.network_op_daily AS nod (day, op_type_id, op_count, op_bytes, rc_exact)
SELECT r.day, r.op_type_id, r.op_count, r.op_bytes, r.rc_exact
FROM haf_stats_app.network_op_rows(_first_block, _last_block) AS r
ON CONFLICT (day, op_type_id) DO UPDATE SET
    op_count = nod.op_count + EXCLUDED.op_count,
    op_bytes = nod.op_bytes + EXCLUDED.op_bytes,
    -- NULL + anything is NULL: a day stays exact only while every batch that touched it was.
    rc_exact = nod.rc_exact + EXCLUDED.rc_exact;

END;
$$;

RESET ROLE;
