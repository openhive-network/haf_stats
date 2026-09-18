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

GRANT SELECT ON haf_stats_backend.account_custom_json_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- One scan of the custom_json op stream per batch, fanned out to one row per signer.
-- Reads hafd.operations directly (op_type 18 + operation_id_to_block_num(id) BETWEEN,
-- served by hive_operations_op_type_id_block_num) - the haf_stats context is non-forking
-- so every processed block is irreversible; same idiom as process_financial. op_count is
-- additive (DO UPDATE adds), so each block range must be processed exactly once - the same
-- exactly-once assumption the other additive counters rely on.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.process_custom_json;
CREATE OR REPLACE FUNCTION haf_stats_app.process_custom_json(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
SET from_collapse_limit = '16'
SET join_collapse_limit = '16'
AS $$
BEGIN

WITH ops AS MATERIALIZED (
    -- One custom_json op per row, with its id, the day it landed, and its payload size.
    SELECT
        ov.id AS op_id,
        bv.created_at::DATE AS day,
        ov.body_value ->> 'id' AS json_id,
        ov.body_value AS body,
        octet_length(ov.body_value::text) AS op_bytes
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    WHERE ov.op_type_id = 18   -- hive::protocol::custom_json_operation
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
),
-- Fan each op out to its signer(s): required_posting_auths UNION required_auths.
-- UNION (not UNION ALL) dedups an account listed under both auths so it counts the op once.
-- The op's payload size rides along; for a (rare) multi-signer op each signer is attributed
-- the full op_bytes, consistent with op_count counting the op once per signer.
signers AS (
    SELECT o.op_id, o.day, o.json_id, o.op_bytes, s.signer
    FROM ops o
    CROSS JOIN LATERAL (
        SELECT jsonb_array_elements_text(o.body -> 'required_posting_auths') AS signer
        UNION
        SELECT jsonb_array_elements_text(o.body -> 'required_auths')
    ) s
    WHERE o.json_id IS NOT NULL
),
-- Resolve the DISTINCT signer-name set once (anti-seq-scan idiom, mirrors
-- process_active_users); a busy bot recurs thousands of times per batch.
name_ids AS MATERIALIZED (
    SELECT av.name, av.id
    FROM hive.accounts_view av
    WHERE av.name IN (SELECT DISTINCT signer FROM signers)
)
INSERT INTO haf_stats_backend.account_custom_json_daily AS acj (account_id, day, json_id, op_count, op_bytes)
SELECT ni.id, sg.day, sg.json_id, COUNT(*)::INT, SUM(sg.op_bytes)::BIGINT
FROM signers sg
JOIN name_ids ni ON ni.name = sg.signer
GROUP BY ni.id, sg.day, sg.json_id
ON CONFLICT (account_id, day, json_id) DO UPDATE SET
    op_count = acj.op_count + EXCLUDED.op_count,
    op_bytes = acj.op_bytes + EXCLUDED.op_bytes;

END;
$$;

RESET ROLE;
