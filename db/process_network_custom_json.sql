SET ROLE haf_stats_owner;

-- Feature: network-wide custom_json usage by id (get_network_custom_json_usage,
-- get_network_top_custom_json endpoints, issue #41).
--
-- custom_json (op_type 18) is the highest-volume op class on Hive (~42% of all operations),
-- yet get_network_rc_utilization collapses every custom_json into a single op-type-18 bucket
-- and throws the `id` dimension away. This rollup keeps the per-id network usage: for each
-- (day, json_id) the number of custom_json ops and their summed payload bytes - the raw
-- material for "how many `follow`/`reblog`/`sm_*` ops happened network-wide, and is a given
-- action growing". It is the network sibling of the per-account account_custom_json_daily.
--
-- Design mirrors network_op_daily (process_network_ops.sql): store the RC INPUTS (op_count +
-- op_bytes), not a pre-weighted RC figure, and apply the calibrated rc_op_stats_daily rate at
-- read time (the endpoint prices op-18 activity via haf_stats_app.rc_rate), so a rate
-- recalibration needs no historical backfill. op_bytes is octet_length(body_value), the
-- payload-size proxy the byte rate is calibrated against (see process_rc.sql).
--
-- The `id` is the raw custom_json tag read from the op body (body_value ->> 'id', e.g.
-- 'follow', 'sm_claim_daily', 'ssc-mainnet-hive'); the endpoints resolve it to a DApp
-- app/category at read time with the custom_json_app_registry starts_with() prefix match
-- (resolve_dapp_name / resolve_dapp_category), so no classification is stored here. This is
-- deliberately keyed by the id STRING, not a custom_json_type_id: the whole custom_json stack
-- (account_custom_json_daily, the registry, the resolvers) keys on the string, and no
-- hafd.custom_json_types dictionary exists on this deployment.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_custom_json_daily (
    day DATE NOT NULL,
    json_id TEXT NOT NULL,
    op_count BIGINT NOT NULL DEFAULT 0,
    op_bytes BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, json_id)
);

-- The (day, json_id) PK serves get_network_top_custom_json's day-range scan (all ids in a
-- window). get_network_custom_json_usage filters a single json_id over a day range - the
-- SECOND PK column - so it needs a json_id-leading index to seek instead of scanning the whole
-- day range. The table is bounded (a few million (day, json_id) rows over full history), so the
-- extra index is cheap relative to the read win.
CREATE INDEX IF NOT EXISTS idx_ncj_json_id_day
ON haf_stats_backend.network_custom_json_daily (json_id, day);


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
            a.attrelid = 'haf_stats_backend.network_custom_json_daily'::REGCLASS
            AND a.attname = 'rc_exact'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_backend.network_custom_json_daily
     ADD COLUMN IF NOT EXISTS rc_exact BIGINT',
    'network_custom_json_daily.rc_exact'
);

GRANT SELECT ON haf_stats_backend.network_custom_json_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- One pass over the batch's staged custom_json ops (prepare_batch_ops, db/process_block_range.sql),
-- aggregated to (day, json_id): the same staged rows process_custom_json and
-- process_community_registry read. op_count/op_bytes are additive (DO UPDATE adds), so
-- each block range must be processed exactly once - the same exactly-once assumption the other
-- additive counters rely on.
--
-- Standalone (not folded into process_custom_json) because that processor fans each op out to
-- one row PER SIGNER (required_posting_auths UNION required_auths), so its per-account table
-- cannot be summed into correct one-row-per-op network counts. Keeping this separate gives a
-- clean, independently-rebuildable counter symmetric with network_op_daily, and the second
-- pass over the staged op-18 rows is marginal against the per-account fan-out process_custom_json
-- already pays.
--
-- Invariant (over the range both tables cover): SUM(op_count) / SUM(op_bytes) here per day
-- equals network_op_daily's op_type_id = 18 row, since both count the same op-18 ops once each.
-- The body_value ->> 'id' IS NOT NULL guard (json_id is PK-NOT NULL) is the only difference; the
-- `id` is a required consensus field on custom_json_operation, so no op-18 op is dropped on
-- mainnet.
-- ---------------------------------------------------------------------------

-- The rows process_network_custom_json adds for a block range, before they are merged into the table: one per
-- group, with its op_count, op_bytes and exact RC (#44). The processor INSERTs them; the rc_exact
-- backfill (haf_stats_app.backfill_rc_exact) compares them with what a past day already holds.
DROP FUNCTION IF EXISTS haf_stats_app.network_custom_json_rows(INT, INT);
CREATE OR REPLACE FUNCTION haf_stats_app.network_custom_json_rows(
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

DROP FUNCTION IF EXISTS haf_stats_app.process_network_custom_json;
CREATE OR REPLACE FUNCTION haf_stats_app.process_network_custom_json(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
BEGIN

INSERT INTO haf_stats_backend.network_custom_json_daily AS ncj (day, json_id, op_count, op_bytes, rc_exact)
SELECT r.day, r.json_id, r.op_count, r.op_bytes, r.rc_exact
FROM haf_stats_app.network_custom_json_rows(_first_block, _last_block) AS r
ON CONFLICT (day, json_id) DO UPDATE SET
    op_count = ncj.op_count + EXCLUDED.op_count,
    op_bytes = ncj.op_bytes + EXCLUDED.op_bytes,
    rc_exact = ncj.rc_exact + EXCLUDED.rc_exact;

END;
$$;

RESET ROLE;
