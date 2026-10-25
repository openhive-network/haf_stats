SET ROLE haf_stats_owner;

-- Feature: witness block production and reliability (get_witness_missed_blocks endpoint,
-- issue #54; frontends block_explorer_ui#769 and #774).
--
-- Per (day, producer) block production: how many blocks a witness produced, how many
-- scheduled slots it missed, and the first/last block at which it missed. hafbe exposes a
-- LIFETIME missed_blocks counter on the witness list and no windowed figure at all, so
-- "missed blocks in the last 30 days" - and the reliability rate that needs a denominator -
-- has no home in any existing HAF API.
--
-- Both counters live here, not just produced_count. Serving misses from raw hafd.operations at
-- read time (the shape the issue sketched) is fast enough on its own - op-86 is index-backed,
-- 34 ms over a 30-day window - but it would compute the headline rate from two different
-- clocks: this rollup is bounded by app_status.last_processed_block while raw operations run to
-- the HAF head. Those diverge exactly when the app lags, so the reliability number would be
-- wrong precisely when someone is looking at it because something is wrong. One table, one
-- clock. It also lets order_by=last_missed rank before the LIMIT, and collapses what would be a
-- cross-source FULL OUTER JOIN into a single indexed range scan.
--
-- produced_count alone would have needed a rollup regardless: hafd.blocks has no aggregate over
-- (day, producer), so a windowed GROUP BY scans the whole num range - 1.17 s over 30 days on a
-- full node, ~14 s over a year, well past the 2 s Wax client timeout.
--
-- Sizing: ~90-120 producers/day on modern Hive, so ~33-44k rows/year (the 2016 mining era is
-- denser - 68,623 rows over the 5M-block replay corpus, which had ~12,000 miner-witnesses).

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.witness_blocks_daily (
    day DATE NOT NULL,
    producer_account_id INT NOT NULL,
    produced_count BIGINT NOT NULL DEFAULT 0,
    missed_count BIGINT NOT NULL DEFAULT 0,
    first_missed_block INT,
    last_missed_block INT,
    PRIMARY KEY (day, producer_account_id)
);

-- No secondary index, deliberately. The endpoint's witness= filter matches on the SECOND PK
-- column, which is what earned network_custom_json_daily its reversed idx_ncj_json_id_day - but
-- that table holds a few million (day, json_id) rows and this one holds tens of thousands per
-- year, two orders of magnitude less. Every read is already bounded by the day range, and the
-- unfiltered worst case (a full-history witness= scan over the whole replay corpus, 68,623 rows)
-- is a few hundred pages. Under the standard issue #53 applied when it dropped idx_acd /
-- idx_afd_account_day - the PK already serves the predicate, and index maintenance on a
-- continuously-upserted processor table is not free - a second index here is speculative.
-- Revisit if the table passes ~1M rows or the witness path shows up in pg_stat_statements.
GRANT SELECT ON haf_stats_backend.witness_blocks_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- Two aggregations per batch, UNION ALLed and re-grouped so exactly one row reaches each
-- conflict key. Produced comes from hafd.blocks over the batch's num range (a PK range scan;
-- producer_account_id is already an account id, so no name resolution). Missed comes from the
-- producer_missed_operation stream, whose body carries the witness NAME.
--
-- The counters are additive (DO UPDATE adds), so each block range must be processed exactly
-- once - the same exactly-once assumption the other additive counters rely on. The haf_stats
-- context is non-forking, so every processed block is irreversible and delivered once.
--
-- The outer GROUP BY over the UNION ALL is load-bearing: without it a producer that both
-- produced and missed within one batch would supply two rows for the same conflict key and
-- Postgres would raise "ON CONFLICT DO UPDATE command cannot affect row a second time".
--
-- first_missed_block / last_missed_block merge with LEAST / GREATEST, which in PostgreSQL
-- IGNORE NULL inputs (LEAST(NULL, 5) = 5) rather than propagating them. That is exactly the
-- behaviour needed: a batch that adds produced blocks but no misses supplies NULL and leaves
-- the stored extremes untouched. Unlike the additive counters these two are idempotent and
-- order-independent, so they reconstruct identically at any BATCH_SIZE and after a
-- TRUNCATE + replay - which tests/parity/witness_blocks_rebuild_consistency.sql proves.
-- Block numbers are monotonic with created_at, so aggregating MIN/MAX across the days of a
-- window yields that window's true first/last miss.
--
-- The op type is resolved by NAME, not as the literal 86. Non-virtual op ids are
-- consensus-ordered and stable (which is why process_custom_json can hardcode 18), but VIRTUAL
-- op ids are assigned after the non-virtual block and can shift between hived versions;
-- process_financial resolves all of its types by name for the same reason.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.process_witness_blocks;
CREATE OR REPLACE FUNCTION haf_stats_app.process_witness_blocks(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _producer_missed_id INT := (
        SELECT id FROM hafd.operation_types
        WHERE name = 'hive::protocol::producer_missed_operation'
    );
BEGIN

PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[_producer_missed_id]);

INSERT INTO haf_stats_backend.witness_blocks_daily AS wb (
    day, producer_account_id, produced_count, missed_count, first_missed_block, last_missed_block
)
SELECT
    s.day,
    s.producer_account_id,
    SUM(s.produced_count)::BIGINT,
    SUM(s.missed_count)::BIGINT,
    MIN(s.first_missed_block)::INT,
    MAX(s.last_missed_block)::INT
FROM (
    SELECT
        bv.created_at::DATE AS day,
        bv.producer_account_id AS producer_account_id,
        COUNT(*)::BIGINT AS produced_count,
        0::BIGINT AS missed_count,
        NULL::INT AS first_missed_block,
        NULL::INT AS last_missed_block
    FROM hafd.blocks bv
    WHERE bv.num BETWEEN _first_block AND _last_block
    GROUP BY bv.created_at::DATE, bv.producer_account_id

    UNION ALL

    -- producer_missed_operation's body_value is the BARE value object {"producer": "..."}, so
    -- ->> 'producer' is a witness name; resolve it to an account id here so the whole table is
    -- keyed consistently with the produced arm. Verified 100% resolvable over the replay corpus
    -- (44,300 ops, 0 NULL, 0 unmatched); the parity guard's SUM(missed_count) vs a raw op count
    -- is what would catch a silent drop if that ever stopped holding. The ops are the batch's
    -- staged ones (prepare_batch_ops, db/process_block_range.sql).
    SELECT
        ov.day,
        a.id,
        0::BIGINT,
        COUNT(*)::BIGINT,
        MIN(ov.block_num)::INT,
        MAX(ov.block_num)::INT
    FROM haf_stats_batch_ops ov
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'producer')
    WHERE ov.op_type_id = _producer_missed_id
    GROUP BY ov.day, a.id
) s
GROUP BY s.day, s.producer_account_id
ON CONFLICT (day, producer_account_id) DO UPDATE SET
    produced_count = wb.produced_count + EXCLUDED.produced_count,
    missed_count = wb.missed_count + EXCLUDED.missed_count,
    first_missed_block = LEAST(wb.first_missed_block, EXCLUDED.first_missed_block),
    last_missed_block = GREATEST(wb.last_missed_block, EXCLUDED.last_missed_block);

END;
$$;

RESET ROLE;
