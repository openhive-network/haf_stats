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
-- The id is stored as HAF's custom_json_type_id (hafd.operations.custom_json_type_id, a SMALLINT
-- key of hafd.custom_json_types), not as its text: 2 bytes instead of ~14 in every row and again in
-- the primary key, and the batch groups on it without reading the JSON. The endpoints map it back
-- to the text through hafd.custom_json_types, and to an app + category by the existing
-- custom_json_app_registry (seed_data.sql) with a starts_with() prefix match at read time, so no
-- classification is stored here.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_custom_json_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    custom_json_type_id SMALLINT NOT NULL,
    op_count INT NOT NULL DEFAULT 0,
    -- Summed payload size of these ops (octet_length of the op value); additive. The RC
    -- estimate is op_count * base_rc + op_bytes * byte_rc, applied at read time from the
    -- rc_op_stats_daily rates - inputs are stored, not the weighted RC (see process_rc.sql).
    op_bytes BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, custom_json_type_id)
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

-- The custom_json id was stored as json_id TEXT until #120. Rewritten in place, each id to its
-- hafd.custom_json_types id: the rows are history the processor has already been through, so the
-- table is converted rather than dropped and replayed. ALTER COLUMN ... TYPE rewrites the table and
-- rebuilds its primary key in the one statement, under ACCESS EXCLUSIVE for the whole rewrite: on a
-- large deployment that is a while (measured ~5 s per million rows, so ~30 min at 320M rows, plus
-- the I/O of the table), and readers of the table wait for it. An id HAF has no entry for fails the
-- statement (haf_stats_app.custom_json_type_id_of), and the table is left as it was. Guarded: no
-- lock where json_id is already gone (#96).
DO $notice$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS
            AND a.attname = 'json_id'
            AND NOT a.attisdropped
    ) THEN
        -- From pg_class, which takes no lock on the table (pg_total_relation_size would).
        RAISE NOTICE 'haf_stats: rewriting account_custom_json_daily (~% rows, % heap) from json_id TEXT to custom_json_type_id SMALLINT. On a large deployment this takes a while (~5 s per million rows, ~30 min at 320M rows), and readers of the table wait for it.',
            (SELECT GREATEST(c.reltuples, 0)::BIGINT FROM pg_class AS c WHERE c.oid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS),
            (SELECT pg_size_pretty(c.relpages::BIGINT * current_setting('block_size')::BIGINT) FROM pg_class AS c WHERE c.oid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS);
    END IF;
END
$notice$;

SELECT haf_stats_app.apply_schema_migration(
    EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS
            AND a.attname = 'json_id'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_backend.account_custom_json_daily
     ALTER COLUMN json_id TYPE SMALLINT USING haf_stats_app.custom_json_type_id_of(json_id);
     ALTER TABLE haf_stats_backend.account_custom_json_daily
     RENAME COLUMN json_id TO custom_json_type_id',
    'account_custom_json_daily.json_id -> custom_json_type_id'
);

GRANT SELECT ON haf_stats_backend.account_custom_json_daily TO haf_stats_user;

-- The same rows at month grain, for the days before the retention window: account_custom_json_daily
-- keeps only the window, and haf_stats_app.roll_up_account_custom_json (db/daily_retention.sql)
-- moves each older month here once its rc_exact is final. rc is that month's RC as the endpoints
-- price a day - rc_exact where the day's row had it, else the estimate at the rate effective that
-- day - summed over its days when it was rolled up, so a later rate recalibration does not reprice
-- it. exact_ops is how many of op_count were priced with rc_exact.
CREATE TABLE IF NOT EXISTS haf_stats_backend.account_custom_json_monthly (
    account_id INT NOT NULL,
    month DATE NOT NULL,
    custom_json_type_id SMALLINT NOT NULL,
    op_count BIGINT NOT NULL,
    op_bytes BIGINT NOT NULL,
    rc NUMERIC NOT NULL,
    exact_ops BIGINT NOT NULL,
    PRIMARY KEY (account_id, month, custom_json_type_id)
);

GRANT SELECT ON haf_stats_backend.account_custom_json_monthly TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- The batch's custom_json ops with an id, as both custom_json rollups (account_custom_json_rows
-- below, network_custom_json_rows in process_network_custom_json.sql) group and sum them: day,
-- custom_json_type_id (staged by prepare_batch_ops), payload size and exact RC share
-- (prepare_batch_exact_rc, db/exact_rc.sql), NULL where the op has none. The shares are joined to
-- the ops here, once per batch, instead of in each rollup. Only custom_json: network_op_rows reads
-- every non-virtual op once anyway, and copying them all here costs more than the join it would
-- save. An op with no id is in no row of either rollup (custom_json_type_id is part of both keys),
-- so it is not staged.
-- Staged like prepare_batch_exact_rc: transaction-local range key, ON COMMIT DROP table.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.prepare_batch_custom_json_ops(INT, INT);
CREATE OR REPLACE FUNCTION haf_stats_app.prepare_batch_custom_json_ops(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _range_key TEXT := _first_block::TEXT || ':' || _last_block::TEXT;
BEGIN
    IF current_setting('haf_stats.batch_custom_json_ops_range', TRUE) = _range_key
       AND TO_REGCLASS('pg_temp.haf_stats_batch_custom_json_ops') IS NOT NULL THEN
        RETURN;
    END IF;

    PERFORM haf_stats_app.prepare_batch_exact_rc(_first_block, _last_block);
    PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[18]);

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_batch_custom_json_ops (
        op_id BIGINT NOT NULL,
        day DATE NOT NULL,
        custom_json_type_id SMALLINT NOT NULL,
        op_bytes INT,
        rc_exact BIGINT
    ) ON COMMIT DROP;

    TRUNCATE haf_stats_batch_custom_json_ops;

    INSERT INTO haf_stats_batch_custom_json_ops (op_id, day, custom_json_type_id, op_bytes, rc_exact)
    SELECT ov.op_id, ov.day, ov.custom_json_type_id, ov.op_bytes, ex.rc_exact
    FROM haf_stats_batch_ops AS ov
    LEFT JOIN haf_stats_batch_exact_rc AS ex ON ex.op_id = ov.op_id
    WHERE ov.op_type_id = 18   -- hive::protocol::custom_json_operation
      AND ov.custom_json_type_id IS NOT NULL;

    ANALYZE haf_stats_batch_custom_json_ops;
    PERFORM set_config('haf_stats.batch_custom_json_ops_range', _range_key, TRUE);
END;
$$;

-- ---------------------------------------------------------------------------
-- Processor
--
-- One row per (custom_json op, signer), the op_class 5 rows prepare_batch_authored_ops
-- (db/process_block_range.sql) already resolved for process_active_users: an op's distinct
-- signers across required_posting_auths and required_auths, each resolved to its account id.
-- Each takes the op's day, custom_json_type_id, payload size and exact RC share from
-- prepare_batch_custom_json_ops above. op_count is additive (DO UPDATE adds), so each block range
-- must be processed exactly once - the same exactly-once assumption the other additive counters
-- rely on.
-- ---------------------------------------------------------------------------

-- The rows process_custom_json adds for a block range, before they are merged into the table: one per
-- group, with its op_count, op_bytes and exact RC (#44). The processor INSERTs them; the rc_exact
-- backfill (haf_stats_app.backfill_rc_exact) compares them with what a past day already holds.
DROP FUNCTION IF EXISTS haf_stats_app.account_custom_json_rows(INT, INT);
CREATE OR REPLACE FUNCTION haf_stats_app.account_custom_json_rows(
    _first_block INT,
    _last_block INT
)
RETURNS TABLE (account_id INT, day DATE, custom_json_type_id SMALLINT, op_count INT, op_bytes BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
VOLATILE
SET jit = OFF
AS $$
BEGIN
PERFORM haf_stats_app.prepare_batch_authored_ops(_first_block, _last_block);
PERFORM haf_stats_app.prepare_batch_custom_json_ops(_first_block, _last_block);
RETURN QUERY
-- A multi-signer op attributes the full op_bytes and the full rc_exact to each signer,
-- consistent with op_count counting the op once per signer (the network rollup counts it once).
SELECT a.account_id, cj.day, cj.custom_json_type_id, COUNT(*)::INT, SUM(cj.op_bytes)::BIGINT,
       -- Exact only when every op of the group has its share (#44); otherwise NULL.
       CASE WHEN COUNT(cj.rc_exact) = COUNT(*) THEN SUM(cj.rc_exact) END::BIGINT
FROM haf_stats_batch_authored_ops a
JOIN haf_stats_batch_custom_json_ops cj ON cj.op_id = a.op_id
WHERE a.op_class = 5   -- custom_json_operation
GROUP BY a.account_id, cj.day, cj.custom_json_type_id;
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

INSERT INTO haf_stats_backend.account_custom_json_daily AS acj (account_id, day, custom_json_type_id, op_count, op_bytes, rc_exact)
SELECT r.account_id, r.day, r.custom_json_type_id, r.op_count, r.op_bytes, r.rc_exact
FROM haf_stats_app.account_custom_json_rows(_first_block, _last_block) AS r
ON CONFLICT (account_id, day, custom_json_type_id) DO UPDATE SET
    op_count = acj.op_count + EXCLUDED.op_count,
    op_bytes = acj.op_bytes + EXCLUDED.op_bytes,
    rc_exact = acj.rc_exact + EXCLUDED.rc_exact;

END;
$$;

RESET ROLE;
