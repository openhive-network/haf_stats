SET ROLE haf_stats_owner;

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

CREATE TABLE IF NOT EXISTS haf_stats_backend.custom_json_app_registry (
    app_id_pattern TEXT NOT NULL PRIMARY KEY,
    app_name TEXT NOT NULL,
    category TEXT NOT NULL,
    homepage TEXT
);

GRANT SELECT ON haf_stats_backend.custom_json_app_registry TO haf_stats_user;

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
    FROM hafd.operation_types
    WHERE name = 'hive::protocol::rc_account_statuses_operation' LIMIT 1;

    -- Operation-type names in hafd.operation_types are fully qualified with the
    -- 'hive::protocol::' prefix (e.g. 'hive::protocol::custom_json_operation'),
    -- matching the lookups in process_financial.sql. Without the prefix this
    -- returns NULL and custom_json DApp attribution is silently lost.
    SELECT id INTO _custom_json_op_id
    FROM hafd.operation_types
    WHERE name = 'hive::protocol::custom_json_operation' LIMIT 1;

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
          AND ov.block_num BETWEEN _first_block AND _last_block
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

-- ---------------------------------------------------------------------------
-- Estimated RC cost model
--
-- The real per-op RC consumption (rc_account_statuses_operation) lives in the
-- hive::plugins::rc namespace, which HAF's sql_serializer does not capture, so it is
-- unavailable on a standard HAF node (see docs/VERIFICATION.md). This is a deliberate
-- ESTIMATE used where the real figure is absent: a fixed per-op-type base plus a size
-- term (bigger payloads cost more RC). Rates are first-order constants - good enough for
-- the relative shape (which ops/apps cost more) but not calibrated to live rc_api rates;
-- a follow-up can swap the constants for an rc_api-sourced daily-rate table without
-- touching callers. IMMUTABLE so it can be used in the per-batch processors.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.estimate_rc_cost(_op_type_id SMALLINT, _body JSONB)
RETURNS BIGINT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT (
        CASE _op_type_id
            WHEN 0 THEN 20000000     -- vote
            WHEN 1 THEN 600000000    -- comment (creates/updates state)
            WHEN 2 THEN 150000000    -- transfer
            WHEN 18 THEN 80000000    -- custom_json
            ELSE 120000000           -- everything else
        END
        + 1500000::BIGINT * octet_length(COALESCE(_body::text, ''))
    )::BIGINT
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.estimate_rc_cost(SMALLINT, JSONB) TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Calibrated RC rate table (read-time model)
--
-- The estimated-RC endpoints store the *inputs* of the RC estimate (op_count and
-- summed payload bytes), not a pre-weighted RC figure, and multiply by the rates in
-- this table at read time. Recalibration is therefore a rate refresh with no historical
-- backfill, and every estimated-RC endpoint recalibrates together (see issue #32).
--
-- Per (day, op_type) the model is:  rc ~= op_count * base_rc + op_bytes * byte_rc
--   base_rc  size-independent RC per op = avg_cost_rc - history_rc (rc_api)
--   byte_rc  RC per payload byte        = history_rc / history_bytes (rc_api)
-- The stored op_bytes proxy is octet_length(body_value::text), which on real custom_json
-- traffic averages the same as rc_api's history_bytes (~304), so byte_rc applies directly.
-- Rates are sampled from hived rc_api.get_rc_operation_stats; seed_data.sql seeds the
-- custom_json row from a live sample and an rc_api-sourced daily refresh keeps it current.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.rc_op_stats_daily (
    day DATE NOT NULL,
    op_type_id SMALLINT NOT NULL,
    base_rc BIGINT NOT NULL,        -- size-independent RC per op (avg_cost_rc - history_rc)
    byte_rc NUMERIC NOT NULL,       -- RC per payload byte (history_rc / history_bytes)
    avg_cost_rc BIGINT,             -- rc_api reference: avg total RC cost of one op
    avg_bytes INTEGER,              -- rc_api reference: history_bytes the byte_rc was derived from
    sample_count BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_type_id)
);

GRANT SELECT ON haf_stats_backend.rc_op_stats_daily TO haf_stats_user;

-- Most recent sampled rate per op type. Endpoints apply the latest rate to all history
-- (RC unit prices drift slowly; a recalibration just inserts a newer day's row).
CREATE OR REPLACE VIEW haf_stats_backend.rc_op_rate_latest AS
SELECT DISTINCT ON (op_type_id)
    op_type_id,
    base_rc,
    byte_rc,
    avg_cost_rc,
    avg_bytes,
    day
FROM haf_stats_backend.rc_op_stats_daily
ORDER BY op_type_id ASC, day DESC;

GRANT SELECT ON haf_stats_backend.rc_op_rate_latest TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Per-day rate accessors (read-time pricing, issue #33)
--
-- Resolve the rate effective ON/BEFORE a given day for an op type: the most recent sampled
-- day <= _day, else the earliest sample (for activity predating sampling), else a default.
-- Used by the estimated-RC endpoints so each op is priced at its era's rate as the
-- rc_op_stats_daily series grows.
-- ---------------------------------------------------------------------------

-- Average total RC cost per op (op-count model, no payload-size term) - used where a
-- per-op body/byte join would be too expensive (e.g. on-demand account RC footprint).
CREATE OR REPLACE FUNCTION haf_stats_app.rc_avg_cost(_op_type_id SMALLINT, _day DATE)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE((
        SELECT r.avg_cost_rc
        FROM haf_stats_backend.rc_op_stats_daily r
        WHERE r.op_type_id = _op_type_id
        ORDER BY (r.day <= _day) DESC,
                 CASE WHEN r.day <= _day THEN r.day END DESC,
                 r.day ASC
        LIMIT 1
    ), 120000000::BIGINT)
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.rc_avg_cost(SMALLINT, DATE) TO haf_stats_user;

-- Size-aware (base_rc, byte_rc) rate; always returns exactly one row (seeded custom_json
-- defaults when no sample exists), so callers can CROSS JOIN LATERAL it per row.
CREATE OR REPLACE FUNCTION haf_stats_app.rc_rate(_op_type_id SMALLINT, _day DATE)
RETURNS TABLE (base_rc BIGINT, byte_rc NUMERIC)
LANGUAGE sql
STABLE
AS $$
    SELECT
        COALESCE(r.base_rc, 23428456::BIGINT) AS base_rc,
        COALESCE(r.byte_rc, 475000::NUMERIC)  AS byte_rc
    FROM (SELECT 1) z(x)
    LEFT JOIN LATERAL (
        SELECT rr.base_rc, rr.byte_rc
        FROM haf_stats_backend.rc_op_stats_daily rr
        WHERE rr.op_type_id = _op_type_id
        ORDER BY (rr.day <= _day) DESC,
                 CASE WHEN rr.day <= _day THEN rr.day END DESC,
                 rr.day ASC
        LIMIT 1
    ) r ON TRUE
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.rc_rate(SMALLINT, DATE) TO haf_stats_user;

RESET ROLE;
