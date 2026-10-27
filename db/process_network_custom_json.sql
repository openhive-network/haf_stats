SET ROLE haf_stats_owner;

-- Feature: network-wide custom_json usage by id (get_network_custom_json_usage,
-- get_network_top_custom_json endpoints, issue #41).
--
-- custom_json (op_type 18) is the highest-volume op class on Hive (~42% of all operations),
-- yet get_network_rc_utilization collapses every custom_json into a single op-type-18 bucket
-- and throws the `id` dimension away. This rollup keeps the per-id network usage: for each
-- (day, custom_json id) the number of custom_json ops and their summed payload bytes - the raw
-- material for "how many `follow`/`reblog`/`sm_*` ops happened network-wide, and is a given
-- action growing". It is the network sibling of the per-account account_custom_json_daily.
--
-- Design mirrors network_op_daily (process_network_ops.sql): store the RC INPUTS (op_count +
-- op_bytes), not a pre-weighted RC figure, and apply the calibrated rc_op_stats_daily rate at
-- read time (the endpoint prices op-18 activity via haf_stats_app.rc_rate), so a rate
-- recalibration needs no historical backfill. op_bytes is octet_length(body_value), the
-- payload-size proxy the byte rate is calibrated against (see process_rc.sql).
--
-- The `id` is the custom_json tag (e.g. 'follow', 'sm_claim_daily', 'ssc-mainnet-hive'), stored
-- as HAF's custom_json_type_id (hafd.operations.custom_json_type_id, a SMALLINT key of
-- hafd.custom_json_types), as account_custom_json_daily stores it. The endpoints map it back to
-- the text through hafd.custom_json_types and resolve that to a DApp app/category at read time
-- with the custom_json_app_registry starts_with() prefix match (resolve_dapp_name /
-- resolve_dapp_category), so no classification is stored here.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_custom_json_daily (
    day DATE NOT NULL,
    custom_json_type_id SMALLINT NOT NULL,
    op_count BIGINT NOT NULL DEFAULT 0,
    op_bytes BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, custom_json_type_id)
);

-- The custom_json id was stored as json_id TEXT until #120. Rewritten in place, each id to its
-- hafd.custom_json_types id, as account_custom_json_daily is (db/process_custom_json.sql, which
-- says more): ALTER COLUMN ... TYPE rewrites the table and rebuilds both its indexes, and the
-- json_id-leading index takes the new column's name. An id HAF has no entry for fails the
-- statement and leaves the table as it was. Before the CREATE INDEX below, which names the new
-- column. Guarded: no lock where json_id is already gone (#96).
SELECT haf_stats_app.apply_schema_migration(
    EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = 'haf_stats_backend.network_custom_json_daily'::REGCLASS
            AND a.attname = 'json_id'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_backend.network_custom_json_daily
     ALTER COLUMN json_id TYPE SMALLINT USING haf_stats_app.custom_json_type_id_of(json_id);
     ALTER TABLE haf_stats_backend.network_custom_json_daily
     RENAME COLUMN json_id TO custom_json_type_id;
     ALTER INDEX IF EXISTS haf_stats_backend.idx_ncj_json_id_day
     RENAME TO idx_ncj_custom_json_type_id_day',
    'network_custom_json_daily.json_id -> custom_json_type_id'
);

-- The (day, custom_json_type_id) PK serves get_network_top_custom_json's day-range scan (all ids
-- in a window). get_network_custom_json_usage filters a single id over a day range - the SECOND
-- PK column - so it needs an id-leading index to seek instead of scanning the whole day range.
-- The table is bounded (a few million (day, id) rows over full history), so the extra index is
-- cheap relative to the read win.
CREATE INDEX IF NOT EXISTS idx_ncj_custom_json_type_id_day
ON haf_stats_backend.network_custom_json_daily (custom_json_type_id, day);


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
-- One pass over the batch's staged custom_json ops (prepare_batch_custom_json_ops,
-- db/process_custom_json.sql, which carries each op's custom_json_type_id and exact RC share),
-- aggregated to (day, custom_json_type_id): the same staged rows process_custom_json reads.
-- op_count/op_bytes are additive (DO UPDATE adds), so each block range must be processed exactly
-- once - the same exactly-once assumption the other additive counters rely on.
--
-- Standalone (not folded into process_custom_json) because that processor fans each op out to
-- one row PER SIGNER (required_posting_auths UNION required_auths), so its per-account table
-- cannot be summed into correct one-row-per-op network counts. Keeping this separate gives a
-- clean, independently-rebuildable counter symmetric with network_op_daily, and the second
-- pass over the staged op-18 rows reads no JSON and joins nothing, so it is marginal.
--
-- Invariant (over the range both tables cover): SUM(op_count) / SUM(op_bytes) here per day
-- equals network_op_daily's op_type_id = 18 row, since both count the same op-18 ops once each.
-- Leaving out ops with no id (custom_json_type_id is PK-NOT NULL) is the only difference; the
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
RETURNS TABLE (day DATE, custom_json_type_id SMALLINT, op_count BIGINT, op_bytes BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
VOLATILE
SET jit = OFF
AS $$
BEGIN
-- The batch's custom_json ops with their custom_json_type_id and exact RC share, staged once for both custom_json
-- rollups (prepare_batch_custom_json_ops, db/process_custom_json.sql).
PERFORM haf_stats_app.prepare_batch_custom_json_ops(_first_block, _last_block);
RETURN QUERY
SELECT
    cj.day,
    cj.custom_json_type_id,
    COUNT(*)::BIGINT,
    SUM(cj.op_bytes)::BIGINT,
    -- Exact only when every op of the group has its share (#44); otherwise NULL.
    CASE WHEN COUNT(cj.rc_exact) = COUNT(*) THEN SUM(cj.rc_exact) END::BIGINT
FROM haf_stats_batch_custom_json_ops cj
GROUP BY cj.day, cj.custom_json_type_id;
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

INSERT INTO haf_stats_backend.network_custom_json_daily AS ncj (day, custom_json_type_id, op_count, op_bytes, rc_exact)
SELECT r.day, r.custom_json_type_id, r.op_count, r.op_bytes, r.rc_exact
FROM haf_stats_app.network_custom_json_rows(_first_block, _last_block) AS r
ON CONFLICT (day, custom_json_type_id) DO UPDATE SET
    op_count = ncj.op_count + EXCLUDED.op_count,
    op_bytes = ncj.op_bytes + EXCLUDED.op_bytes,
    rc_exact = ncj.rc_exact + EXCLUDED.rc_exact;

END;
$$;

RESET ROLE;
