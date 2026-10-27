SET ROLE haf_stats_owner;

-- Feature: per-account custom_json activity ("DApp footprint").
--
-- Every custom_json_operation (op_type 18) carries an `id` (the app/protocol tag,
-- e.g. 'follow', 'sm_claim_daily', 'ssc-mainnet-hive') and one or more signers in
-- required_posting_auths / required_auths. We aggregate, per (account, day, id), the
-- number of custom_json ops that account signed - the raw material for the account
-- "DApp footprint" dashboard (which apps an account uses and how often).
--
-- The dashboard's primary metric is activity frequency (op_count). Real per-op RC cost is
-- not available on 1.28.6 (the rc virtual op is absent), so RC is an ESTIMATE - but rather
-- than store a pre-weighted RC figure, we store its INPUTS (op_count + op_bytes) and apply
-- the calibrated rc_op_stats_daily rates at read time in the endpoint (issue #32). That way
-- a rate recalibration needs no historical backfill. op_bytes is octet_length(body_value),
-- the payload-size proxy the byte rate is calibrated against (see process_rc.sql).
--
-- The id is mapped to an app + category by the existing custom_json_app_registry
-- (seed_data.sql); the endpoint resolves it at read time with a starts_with() prefix match,
-- so no classification is stored here.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_custom_json_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    json_id TEXT NOT NULL,
    op_count INT NOT NULL DEFAULT 0,
    -- Summed payload size of these ops (octet_length of the op value); additive. The RC
    -- estimate is op_count * base_rc + op_bytes * byte_rc, applied at read time from the
    -- rc_op_stats_daily rates - inputs are stored, not the weighted RC (see process_rc.sql).
    op_bytes BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, json_id)
);

-- Idempotent migration from the earlier op-weighted rc_estimated column (issue #32):
-- the read-time model stores inputs, so add op_bytes and drop the stored RC output. Existing
-- rows need a one-time reprocess to populate op_bytes (the deploy truncates + re-backfills).
-- Guarded: no ACCESS EXCLUSIVE lock on a node that already has this column (#96).
SELECT haf_stats_app.apply_schema_migration(
    NOT EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS
            AND a.attname = 'op_bytes'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_backend.account_custom_json_daily
     ADD COLUMN IF NOT EXISTS op_bytes BIGINT NOT NULL DEFAULT 0',
    'account_custom_json_daily.op_bytes'
);

-- Guarded: no ACCESS EXCLUSIVE lock on a node where this column is already gone (#96).
SELECT haf_stats_app.apply_schema_migration(
    EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS
            AND a.attname = 'rc_estimated'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_backend.account_custom_json_daily
     DROP COLUMN IF EXISTS rc_estimated',
    'account_custom_json_daily.rc_estimated (drop)'
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
            a.attrelid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS
            AND a.attname = 'rc_exact'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_backend.account_custom_json_daily
     ADD COLUMN IF NOT EXISTS rc_exact BIGINT',
    'account_custom_json_daily.rc_exact'
);

GRANT SELECT ON haf_stats_backend.account_custom_json_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- One pass over the batch's custom_json ops (prepare_batch_rollup_ops, db/exact_rc.sql, which
-- network_custom_json_rows reads too), fanned out to one row per signer through the batch's
-- authored ops (prepare_batch_authored_ops, db/process_block_range.sql). op_count is
-- additive (DO UPDATE adds), so each block range must be processed exactly once - the same
-- exactly-once assumption the other additive counters rely on.
-- ---------------------------------------------------------------------------

-- The rows process_custom_json adds for a block range, before they are merged into the table: one per
-- group, with its op_count, op_bytes and exact RC (#44). The processor INSERTs them; the rc_exact
-- backfill (haf_stats_app.backfill_rc_exact) compares them with what a past day already holds.
DROP FUNCTION IF EXISTS haf_stats_app.account_custom_json_rows(INT, INT);
CREATE OR REPLACE FUNCTION haf_stats_app.account_custom_json_rows(
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
-- The signers are the custom_json rows of the batch's authored ops (op_class 5,
-- prepare_batch_authored_ops, db/process_block_range.sql): each op's distinct accounts across
-- required_posting_auths and required_auths, resolved to ids. An account listed under both
-- counts the op once. The op's id, day, payload size and exact RC come from the per-op rows
-- prepare_batch_rollup_ops (db/exact_rc.sql) stages once for the three rollups.
PERFORM haf_stats_app.prepare_batch_authored_ops(_first_block, _last_block);
PERFORM haf_stats_app.prepare_batch_rollup_ops(_first_block, _last_block);
RETURN QUERY
-- For a (rare) multi-signer op each signer is attributed the full op_bytes and the full
-- rc_exact, consistent with op_count counting the op once per signer (the network rollup counts
-- it once).
SELECT au.account_id, ro.day, ro.json_id, COUNT(*)::INT, SUM(ro.op_bytes)::BIGINT,
       -- Exact only when every op of the group has its share (#44); otherwise NULL.
       CASE WHEN COUNT(ro.rc_exact) = COUNT(*) THEN SUM(ro.rc_exact) END::BIGINT
FROM haf_stats_batch_authored_ops au
JOIN haf_stats_batch_rollup_ops ro ON ro.op_id = au.op_id
WHERE au.op_class = 5          -- custom_json_operation
  AND ro.op_type_id = 18       -- hive::protocol::custom_json_operation
  AND ro.json_id IS NOT NULL
GROUP BY au.account_id, ro.day, ro.json_id;
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.process_custom_json;
CREATE OR REPLACE FUNCTION haf_stats_app.process_custom_json(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
BEGIN

INSERT INTO haf_stats_backend.account_custom_json_daily AS acj (account_id, day, json_id, op_count, op_bytes, rc_exact)
SELECT r.account_id, r.day, r.json_id, r.op_count, r.op_bytes, r.rc_exact
FROM haf_stats_app.account_custom_json_rows(_first_block, _last_block) AS r
ON CONFLICT (account_id, day, json_id) DO UPDATE SET
    op_count = acj.op_count + EXCLUDED.op_count,
    op_bytes = acj.op_bytes + EXCLUDED.op_bytes,
    rc_exact = acj.rc_exact + EXCLUDED.rc_exact;

END;
$$;

RESET ROLE;
