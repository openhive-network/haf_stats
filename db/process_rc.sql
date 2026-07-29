SET ROLE haf_stats_owner;

-- RC rate model + DApp registry for the estimated-RC endpoints.
--
-- All three RC endpoints (account/network rc-footprint + network rc-utilization) now estimate
-- RC at read time from rc_op_stats_daily (see process_custom_json.sql, process_network_ops.sql
-- and the endpoints). The earlier real-vop processor (process_rc -> rc_operation_log, never
-- populated on a node where the rc vop is absent) and the op-weighted estimate_rc_cost /
-- rc_op_rate_latest are obsolete and dropped below (issue #33).

-- ---------------------------------------------------------------------------
-- Drop obsolete objects (idempotent; cleans up already-deployed instances)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS haf_stats_backend.rc_op_rate_latest;
DROP FUNCTION IF EXISTS haf_stats_app.process_rc(INT, INT);
DROP FUNCTION IF EXISTS haf_stats_app.estimate_rc_cost(SMALLINT, JSONB);
DROP TABLE IF EXISTS haf_stats_backend.rc_operation_log;

-- ---------------------------------------------------------------------------
-- DApp registry (custom_json id -> app + category), used by the dapp footprint
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.custom_json_app_registry (
    app_id_pattern TEXT NOT NULL PRIMARY KEY,
    app_name TEXT NOT NULL,
    category TEXT NOT NULL,
    homepage TEXT
);

GRANT SELECT ON haf_stats_backend.custom_json_app_registry TO haf_stats_user;

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

-- The PK (day, op_type_id) cannot seek "the samples for op type X": op_type_id is the TRAILING
-- column and Postgres has no skip scan, so it is only a non-boundary qualifier and every rate
-- lookup read the whole table. That table grows by one row per non-virtual op type PER DAY
-- (refresh_rc_op_stats), so the cost of a single lookup grew linearly with deployment age -
-- ~70us per call at ~1600 rows, and the endpoints that price per row paid it per row (#49).
-- (op_type_id, day) makes both probes in the accessors below single-tuple index scans.
CREATE INDEX IF NOT EXISTS idx_rc_op_stats_op_type_day
ON haf_stats_backend.rc_op_stats_daily (op_type_id, day);

-- ---------------------------------------------------------------------------
-- Per-day rate accessors (read-time pricing, issue #33)
--
-- Resolve the rate effective ON/BEFORE a given day for an op type: the most recent sampled
-- day <= _day, else the earliest sample (for activity predating sampling), else a default.
-- Used by the estimated-RC endpoints so each op is priced at its era's rate as the
-- rc_op_stats_daily series grows.
--
-- These two functions are the SINGLE definition of that rule - every endpoint resolves a rate
-- through them rather than re-deriving it (issue #49 folded back get_account_dapp_footprint's
-- hand-inlined copy; get_network_rc_utilization keeps its own probe only because its no-sample
-- fallback constant differs). tests/ci_setup.sql re-declares both with the same logic in a
-- compact style, because the stub CI lane never loads this file; keep the two in sync.
--
-- Both pick the as-of row with two btree-seekable probes ranked by priority rather than one
-- ORDER BY over computed keys. The original form
--     ORDER BY (day <= _day) DESC, CASE WHEN day <= _day THEN day END DESC, day ASC LIMIT 1
-- sorts EVERY sample of the op type on expressions no index can serve, so each call cost a
-- full scan plus a fresh Sort. pri 0 is the latest sample on/before _day and exists exactly
-- when one does; pri 1 is the earliest sample overall; ORDER BY pri prefers 0. That is the
-- same winner the three-key order picked, in all four cases: a sample on/before _day (key 1
-- selects that partition, key 2 takes its max day), none (keys 1 and 2 tie, key 3 takes the
-- global min day), no samples at all for the op type (no row, the COALESCE default applies),
-- and _day IS NULL (key 1 is NULL for every row so all tie, key 3 takes the global min day -
-- and pri 0's `day <= NULL` is likewise empty). Ties are impossible: the PK makes day unique
-- within an op type.
-- ---------------------------------------------------------------------------

-- Average total RC cost per op (op-count model, no payload-size term) - used where a
-- per-op body/byte join would be too expensive (e.g. on-demand account RC footprint).
--
-- The pick selects a ROW and COALESCEs afterwards, deliberately: avg_cost_rc is NULLABLE, and
-- a COALESCE pushed inside the probe would fall through to an OLDER sample whenever the
-- winning row's avg_cost_rc happened to be NULL, silently pricing at the wrong era's rate.
CREATE OR REPLACE FUNCTION haf_stats_app.rc_avg_cost(_op_type_id SMALLINT, _day DATE)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE((
        SELECT pick.avg_cost_rc
        FROM (
            (
                SELECT 0 AS pri, r.avg_cost_rc
                FROM haf_stats_backend.rc_op_stats_daily r
                WHERE r.op_type_id = _op_type_id AND r.day <= _day
                ORDER BY r.day DESC
                LIMIT 1
            )
            UNION ALL
            (
                SELECT 1 AS pri, r.avg_cost_rc
                FROM haf_stats_backend.rc_op_stats_daily r
                WHERE r.op_type_id = _op_type_id
                ORDER BY r.day ASC
                LIMIT 1
            )
        ) pick
        ORDER BY pick.pri
        LIMIT 1
    ), 120000000::BIGINT)
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.rc_avg_cost(SMALLINT, DATE) TO haf_stats_user;

-- Size-aware (base_rc, byte_rc) rate; always returns exactly one row (seeded custom_json
-- defaults when no sample exists). Callers rely on that one-row guarantee to CROSS JOIN
-- LATERAL it without losing the driving row - do not turn it into a filtering set.
--
-- Both columns come from the SAME picked row (see the block comment above), so a rate is never
-- assembled from two different eras' samples.
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
        SELECT pick.base_rc, pick.byte_rc
        FROM (
            (
                SELECT 0 AS pri, rr.base_rc, rr.byte_rc
                FROM haf_stats_backend.rc_op_stats_daily rr
                WHERE rr.op_type_id = _op_type_id AND rr.day <= _day
                ORDER BY rr.day DESC
                LIMIT 1
            )
            UNION ALL
            (
                SELECT 1 AS pri, rr.base_rc, rr.byte_rc
                FROM haf_stats_backend.rc_op_stats_daily rr
                WHERE rr.op_type_id = _op_type_id
                ORDER BY rr.day ASC
                LIMIT 1
            )
        ) pick
        ORDER BY pick.pri
        LIMIT 1
    ) r ON TRUE
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.rc_rate(SMALLINT, DATE) TO haf_stats_user;

-- Translate a block range to an account's account_op_seq_no range via binary search over the
-- unique (account_id, account_op_seq_no) index. account_operations.block_num is computed
-- (operation_id_to_block_num) and unindexed, so a block-range predicate is only a heap Filter
-- and cannot bound the scan (issue #33 review). account_op_seq_no is dense and monotonic with
-- block within an account, so ~log2(n) single-row probes find the [lo, hi] seq_no covering ops
-- in [_from_block, _to_block]; callers add account_op_seq_no BETWEEN lo AND hi to ride the
-- index. Returns no row when the account has no ops (so callers can short-circuit).
--
-- Reads hive.account_operations_view (the global view), NOT haf_stats_app.account_operations_view:
-- the app-scoped view wraps every row in a computed-block ceiling (operation_id_to_block_num <=
-- context.min_block), which is unindexable and made the helper + endpoint ~92s. The footprint
-- reads committed chain history directly, so the global view is both correct and ~100x faster.
CREATE OR REPLACE FUNCTION haf_stats_app.account_op_seq_range(
    _account_id INT,
    _from_block INT,
    _to_block INT
)
RETURNS TABLE (lo_seq BIGINT, hi_seq BIGINT)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    _min BIGINT;
    _max BIGINT;
    _l BIGINT;
    _r BIGINT;
    _mid BIGINT;
    _blk INT;
    _lo BIGINT;
    _hi BIGINT;
BEGIN
    -- Two single-row index probes via ORDER BY ... LIMIT 1, NOT a combined MIN+MAX (a combined
    -- min/max cannot use the index InitPlan and degraded to a full per-account scan ~13s).
    -- Each rides the (account_id, account_op_seq_no) index (~5ms). (#40 review)
    SELECT account_op_seq_no INTO _min FROM hive.account_operations_view
        WHERE account_id = _account_id ORDER BY account_op_seq_no ASC LIMIT 1;
    SELECT account_op_seq_no INTO _max FROM hive.account_operations_view
        WHERE account_id = _account_id ORDER BY account_op_seq_no DESC LIMIT 1;
    IF _max IS NULL THEN
        RETURN;
    END IF;

    -- smallest seq whose block_num >= _from_block
    _l := _min; _r := _max;
    WHILE _l <= _r LOOP
        _mid := (_l + _r) / 2;
        SELECT block_num INTO _blk FROM hive.account_operations_view
            WHERE account_id = _account_id AND account_op_seq_no = _mid;
        IF _blk >= _from_block THEN _lo := _mid; _r := _mid - 1; ELSE _l := _mid + 1; END IF;
    END LOOP;

    -- largest seq whose block_num <= _to_block
    _l := _min; _r := _max;
    WHILE _l <= _r LOOP
        _mid := (_l + _r) / 2;
        SELECT block_num INTO _blk FROM hive.account_operations_view
            WHERE account_id = _account_id AND account_op_seq_no = _mid;
        IF _blk <= _to_block THEN _hi := _mid; _l := _mid + 1; ELSE _r := _mid - 1; END IF;
    END LOOP;

    lo_seq := _lo; hi_seq := _hi;
    RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.account_op_seq_range(INT, INT, INT) TO haf_stats_user;

RESET ROLE;
