-- =============================================================================
-- witness_blocks_rebuild_consistency.sql — drift guard for issue #54.
--
-- witness_blocks_daily is maintained by two different arithmetics in one upsert:
-- produced_count / missed_count ADD, while first_missed_block / last_missed_block
-- merge with LEAST / GREATEST. Addition is order-dependent only in the trivial sense,
-- but the MIN/MAX merge is the part that could silently depend on how the chain was
-- sliced into batches — a day is 28,800 blocks and batches are ~10,000, so every day
-- is assembled from at least three separate calls, and every one of them re-merges the
-- extremes. This guard proves the table is a pure function of the block range and NOT
-- of the batch boundaries:
--
--   1. fingerprint the live table
--   2. TRUNCATE and replay [1, last_processed_block] in ~10,000-block batches
--      -> must reproduce the fingerprint exactly
--   3. TRUNCATE and replay the SAME range as ONE batch
--      -> must reproduce it again
--
-- Step 2 is also what scripts/rebuild_witness_blocks.sh does, so a passing run means
-- the rebuild script reproduces live history rather than a plausible-looking variant.
--
-- It then re-derives the whole table straight from hafd.blocks + producer_missed ops
-- and asserts row-for-row equality, so a processor bug that is merely CONSISTENT
-- (reproduced identically by every path) still fails.
--
-- Non-destructive: everything runs inside a REPEATABLE READ transaction that is ROLLED
-- BACK at the end, so the live table is left exactly as found, pass or fail.
--
-- Concurrency: this TRUNCATEs and replays under an ACCESS EXCLUSIVE lock. A processor
-- parked at the chain head (the CI stack, whose haf node stops at REPLAY_STOP_AT_BLOCK)
-- never writes again and is harmless, so we do not refuse to run merely because a
-- haf_stats_app.main backend exists; instead we take the lock up front under a
-- lock_timeout and fail fast with a clear message if it is genuinely still writing.
-- =============================================================================
\set ON_ERROR_STOP on

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout = '60s';

DO $$
BEGIN
    LOCK TABLE haf_stats_backend.witness_blocks_daily IN ACCESS EXCLUSIVE MODE;
EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION 'witness rebuild guard: could not lock witness_blocks_daily within 60s - '
                    'the haf_stats processor appears to still be writing. Stop it and re-run.';
END $$;

-- md5 over the ordered rows, not COUNT/SUM: an offsetting swap between two producers
-- would leave the totals intact and must still fail.
CREATE OR REPLACE FUNCTION pg_temp.witness_fingerprint()
RETURNS TEXT LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(
        md5(string_agg(
            concat_ws('|', wb.day, wb.producer_account_id, wb.produced_count,
                      wb.missed_count, wb.first_missed_block, wb.last_missed_block),
            E'\n' ORDER BY wb.day, wb.producer_account_id)),
        'EMPTY')
    FROM haf_stats_backend.witness_blocks_daily wb;
$fn$;

DO $$
DECLARE
    _tip INT;
    _live TEXT;
    _batched TEXT;
    _single TEXT;
    _b INT;
    _drift BIGINT;
BEGIN
    SELECT COALESCE(MAX(last_processed_block), 0) INTO _tip FROM haf_stats_app.app_status;
    IF _tip < 1 THEN
        RAISE EXCEPTION 'witness rebuild guard: the app has processed no blocks (tip=%)', _tip;
    END IF;

    _live := pg_temp.witness_fingerprint();
    IF _live = 'EMPTY' THEN
        RAISE EXCEPTION 'witness rebuild guard: witness_blocks_daily is empty at tip % - the '
                        'processor never populated it, which is exactly the failure this guard exists to catch', _tip;
    END IF;

    -- (2) batched replay, the shape scripts/rebuild_witness_blocks.sh uses
    TRUNCATE TABLE haf_stats_backend.witness_blocks_daily;
    _b := 1;
    WHILE _b <= _tip LOOP
        PERFORM haf_stats_app.process_witness_blocks(_b, LEAST(_b + 9999, _tip));
        _b := _b + 10000;
    END LOOP;
    _batched := pg_temp.witness_fingerprint();

    IF _batched IS DISTINCT FROM _live THEN
        RAISE EXCEPTION 'witness rebuild guard: a batched replay of [1, %] did not reproduce live '
                        'history (live md5 %, rebuilt md5 %). scripts/rebuild_witness_blocks.sh '
                        'would therefore write different history than the live processor.',
                        _tip, _live, _batched;
    END IF;

    -- (3) the same range as ONE batch: isolates any dependence on batch boundaries,
    -- which is the only way the LEAST/GREATEST merge could go wrong.
    TRUNCATE TABLE haf_stats_backend.witness_blocks_daily;
    PERFORM haf_stats_app.process_witness_blocks(1, _tip);
    _single := pg_temp.witness_fingerprint();

    IF _single IS DISTINCT FROM _live THEN
        RAISE EXCEPTION 'witness rebuild guard: replaying [1, %] as a single batch produced a '
                        'DIFFERENT table than the batched replay (single md5 %, live md5 %). The '
                        'first_missed_block / last_missed_block merge depends on batch boundaries.',
                        _tip, _single, _live;
    END IF;

    -- (4) independent re-derivation straight from the source relations. Catches a
    -- processor that is self-consistent but wrong.
    WITH raw AS (
        SELECT bv.created_at::DATE AS day, bv.producer_account_id AS pid,
               COUNT(*)::BIGINT AS produced_count, 0::BIGINT AS missed_count,
               NULL::INT AS fmb, NULL::INT AS lmb
        FROM hafd.blocks bv
        WHERE bv.num BETWEEN 1 AND _tip
        GROUP BY 1, 2
        UNION ALL
        SELECT bv.created_at::DATE, a.id, 0, COUNT(*)::BIGINT, MIN(bv.num)::INT, MAX(bv.num)::INT
        FROM hafd.operations ov
        JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
        JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'producer')
        WHERE ov.op_type_id = (
                SELECT id FROM hafd.operation_types
                WHERE name = 'hive::protocol::producer_missed_operation')
          AND hafd.operation_id_to_block_num(ov.id) BETWEEN 1 AND _tip
        GROUP BY 1, 2
    ),
    ref AS (
        SELECT r.day, r.pid,
               SUM(r.produced_count) AS produced_count, SUM(r.missed_count) AS missed_count,
               MIN(r.fmb) AS fmb, MAX(r.lmb) AS lmb
        FROM raw r GROUP BY r.day, r.pid
    )
    SELECT COUNT(*) INTO _drift
    FROM ref rf
    FULL OUTER JOIN haf_stats_backend.witness_blocks_daily wb
        ON wb.day = rf.day AND wb.producer_account_id = rf.pid
    WHERE wb.produced_count IS DISTINCT FROM rf.produced_count
       OR wb.missed_count IS DISTINCT FROM rf.missed_count
       OR wb.first_missed_block IS DISTINCT FROM rf.fmb
       OR wb.last_missed_block IS DISTINCT FROM rf.lmb;

    IF _drift <> 0 THEN
        RAISE EXCEPTION 'witness rebuild guard: % (day, producer) row(s) disagree with a direct '
                        're-derivation from hafd.blocks + producer_missed ops', _drift;
    END IF;

    RAISE NOTICE 'witness rebuild guard OK: [1, %] reproduces identically at 10k batches, as a '
                 'single batch, and against a direct re-derivation', _tip;
END $$;

-- (5) Endpoint-level parity. The tavern .pat.json files are captured FROM the endpoint, so on
-- their own they only prove it has not changed - not that it was ever right. This re-derives the
-- top-by-missed producer for a fixed window straight from hafd and asserts the endpoint agrees on
-- every field, which breaks that circularity. The window is inside the replay corpus and clear of
-- the partial edge days.
DO $$
DECLARE
    _ep RECORD;
    _rf RECORD;
    _lo DATE := '2016-08-01';
    _hi DATE := '2016-08-31';
BEGIN
    SELECT w.producer, w.missed_count, w.produced_count, w.rate,
           w.first_missed_block, w.last_missed_block
      INTO _ep
      FROM haf_stats_endpoints.get_witness_missed_blocks(_lo::TEXT, _hi::TEXT) w
     LIMIT 1;

    IF _ep IS NULL THEN
        RAISE EXCEPTION 'witness endpoint parity: no rows for % .. % - the endpoint cannot see the rollup', _lo, _hi;
    END IF;

    WITH bounds AS (
        SELECT MIN(bv.num) AS lo, MAX(bv.num) AS hi
        FROM hafd.blocks bv
        WHERE bv.created_at >= _lo::TIMESTAMP AND bv.created_at < (_hi + 1)::TIMESTAMP
    ),
    produced AS (
        SELECT COUNT(*)::BIGINT AS n
        FROM hafd.blocks bv, bounds b
        WHERE bv.num BETWEEN b.lo AND b.hi
          AND bv.producer_account_id = (SELECT a.id FROM hafd.accounts a WHERE a.name = _ep.producer)
    ),
    missed AS (
        SELECT COUNT(*)::BIGINT AS n,
               MIN(hafd.operation_id_to_block_num(ov.id))::INT AS fmb,
               MAX(hafd.operation_id_to_block_num(ov.id))::INT AS lmb
        FROM hafd.operations ov, bounds b
        WHERE ov.op_type_id = (
                SELECT ot.id FROM hafd.operation_types ot
                WHERE ot.name = 'hive::protocol::producer_missed_operation')
          AND hafd.operation_id_to_block_num(ov.id) BETWEEN b.lo AND b.hi
          AND (ov.body_value ->> 'producer') = _ep.producer
    )
    SELECT p.n AS produced_count, m.n AS missed_count, m.fmb, m.lmb,
           ROUND(m.n::NUMERIC / NULLIF(p.n + m.n, 0), 6) AS rate
      INTO _rf
      FROM produced p, missed m;

    IF _ep.missed_count IS DISTINCT FROM _rf.missed_count
       OR _ep.produced_count IS DISTINCT FROM _rf.produced_count
       OR _ep.rate IS DISTINCT FROM _rf.rate
       OR _ep.first_missed_block IS DISTINCT FROM _rf.fmb
       OR _ep.last_missed_block IS DISTINCT FROM _rf.lmb THEN
        RAISE EXCEPTION 'witness endpoint parity: % disagrees with a raw re-derivation over % .. % '
                        '(endpoint missed=%/produced=%/rate=%/first=%/last=%; raw missed=%/produced=%/rate=%/first=%/last=%)',
                        _ep.producer, _lo, _hi,
                        _ep.missed_count, _ep.produced_count, _ep.rate, _ep.first_missed_block, _ep.last_missed_block,
                        _rf.missed_count, _rf.produced_count, _rf.rate, _rf.fmb, _rf.lmb;
    END IF;

    RAISE NOTICE 'witness endpoint parity OK: % matches a raw re-derivation over % .. % '
                 '(missed %, produced %, rate %)',
                 _ep.producer, _lo, _hi, _ep.missed_count, _ep.produced_count, _ep.rate;
END $$;

-- (6) Missed-arm liveness, against a reference that shares NONE of the processor's premises.
--
-- Steps 2-5 are all blind to one class of failure: they re-derive the missed arm with the same
-- op-type-resolved-by-name subquery, the same `body_value ->> 'producer'` extraction and the same
-- INNER JOIN to hafd.accounts that process_witness_blocks uses. If any of those premises stops
-- holding - hived renames the virtual op, or a HAF version delivers the WRAPPED
-- {"type":..., "value":{...}} body shape so ->> 'producer' is NULL, or a producer name stops
-- resolving - the reference reproduces the same zeros and every check above passes green while the
-- endpoint reports a 100%-reliable witness set. That was reproduced, not hypothesised: dropping
-- all 44,300 misses left steps 4, 5 and the slot band all passing.
--
-- So this step counts op-86 rows RAW: no name parse, no accounts join, op type resolved by id
-- through a separate path. It is the check db/process_witness_blocks.sql promises.
DO $$
DECLARE
    _op_id INT;
    _raw_ops BIGINT;
    _rollup_missed BIGINT;
    _null_producer BIGINT;
    _tip INT;
BEGIN
    SELECT COALESCE(MAX(last_processed_block), 0) INTO _tip FROM haf_stats_app.app_status;

    SELECT id INTO _op_id FROM hafd.operation_types
    WHERE name = 'hive::protocol::producer_missed_operation';

    IF _op_id IS NULL THEN
        RAISE EXCEPTION 'witness missed-arm guard: hafd.operation_types has no '
                        'hive::protocol::producer_missed_operation. process_witness_blocks resolves the '
                        'op type by that exact name, so every miss is being silently dropped.';
    END IF;

    -- Bare count: this is the number the rollup MUST reproduce.
    SELECT COUNT(*) INTO _raw_ops
    FROM hafd.operations ov
    WHERE ov.op_type_id = _op_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN 1 AND _tip;

    SELECT COALESCE(SUM(wb.missed_count), 0) INTO _rollup_missed
    FROM haf_stats_backend.witness_blocks_daily wb;

    IF _rollup_missed IS DISTINCT FROM _raw_ops THEN
        RAISE EXCEPTION 'witness missed-arm guard: rollup holds % missed events but hafd.operations '
                        'has % producer_missed ops in [1, %]. The missed arm is dropping events - most '
                        'likely the body shape or a producer name that no longer resolves against '
                        'hafd.accounts.', _rollup_missed, _raw_ops, _tip;
    END IF;

    -- The INNER JOIN to hafd.accounts is what would silently drop an event; assert its input is
    -- always present rather than trusting that it is.
    SELECT COUNT(*) INTO _null_producer
    FROM hafd.operations ov
    WHERE ov.op_type_id = _op_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN 1 AND _tip
      AND (ov.body_value ->> 'producer') IS NULL;

    IF _null_producer <> 0 THEN
        RAISE EXCEPTION 'witness missed-arm guard: % producer_missed op(s) have no top-level '
                        '"producer" key. This HAF build is probably delivering the wrapped '
                        '{"type":...,"value":{...}} body shape, which process_witness_blocks does not '
                        'parse.', _null_producer;
    END IF;

    RAISE NOTICE 'witness missed-arm guard OK: % missed events reconcile with a raw op-86 count '
                 '(no name parse, no accounts join), 0 unparseable producer keys', _raw_ops;
END $$;

-- Slot sanity, reported not asserted. produced + missed is ~28,800 per day, but a chain halt
-- loses slots outright (no block AND no miss op is recorded) and a halt straddling midnight can
-- hand one back, so equality is NOT an invariant: the 5M replay corpus has 5 legitimate
-- exceptions plus the two partial edge days. A loose band still catches a systematic drop,
-- which is what this is for.
DO $$
DECLARE
    _bad BIGINT;
    _total BIGINT;
BEGIN
    WITH per_day AS (
        SELECT wb.day, SUM(wb.produced_count + wb.missed_count) AS slots
        FROM haf_stats_backend.witness_blocks_daily wb
        GROUP BY wb.day
    ),
    -- Drop the first and last covered day: both are partial by construction (chain genesis
    -- on one end, the replay/sync head on the other).
    interior AS (
        SELECT p.day, p.slots FROM per_day p
        WHERE p.day > (SELECT MIN(q.day) FROM per_day q)
          AND p.day < (SELECT MAX(q.day) FROM per_day q)
    )
    SELECT COUNT(*) FILTER (WHERE i.slots NOT BETWEEN 28000 AND 28801), COUNT(*)
    INTO _bad, _total
    FROM interior i;

    IF _total > 0 AND _bad > _total / 10 THEN
        RAISE EXCEPTION 'witness slot sanity: % of % interior days fall outside 28000..28801 '
                        'slots - that is too many to be chain halts', _bad, _total;
    END IF;
    RAISE NOTICE 'witness slot sanity OK: % of % interior days outside 28000..28801 (chain halts)',
                 _bad, _total;
END $$;

ROLLBACK;
