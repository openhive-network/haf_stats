-- #44: haf_stats_app.exact_rc_for_ops on a HAF WITHOUT hafd.transactions.rc_cost.
--
-- The stub always has the column, so the endpoints in this lane only ever take the exact path.
-- A HAF older than 1.28.8 has no such column, and there the function must return nothing (every
-- caller then prices with the estimate) rather than fail. Nothing else in the fast lane reaches
-- that branch, and the slow lane's real HAF only reaches it if a test happens to call an
-- rc-footprint endpoint for an account with signed ops in the window.
--
-- Runs in a fresh session, so the function's statement has not been prepared yet, as on a node.
-- The column is renamed inside a transaction that is rolled back.

BEGIN;
ALTER TABLE hafd.transactions RENAME COLUMN rc_cost TO rc_cost_not_here;

DO $guard$
DECLARE
    _rows INT;
BEGIN
    IF haf_stats_app.rc_cost_available() THEN
        RAISE EXCEPTION 'FAIL (#44): rc_cost_available() is true with the column renamed away';
    END IF;
    SELECT count(*) INTO _rows FROM haf_stats_app.exact_rc_for_ops(ARRAY[6500000001]::BIGINT []);
    IF _rows <> 0 THEN
        RAISE EXCEPTION 'FAIL (#44): exact_rc_for_ops returned % row(s) on a HAF without rc_cost', _rows;
    END IF;
    RAISE NOTICE 'exact_rc_for_ops on a HAF without rc_cost: no rows, as required';
END
$guard$;

ROLLBACK;

-- And with the column back, the same call prices the op (the fixture's single-op transaction).
DO $guard$
DECLARE
    _rc BIGINT;
BEGIN
    SELECT e.rc_exact INTO _rc FROM haf_stats_app.exact_rc_for_ops(ARRAY[6500000001]::BIGINT []) AS e;
    IF _rc IS DISTINCT FROM 100000000 THEN
        RAISE EXCEPTION 'FAIL (#44): exact_rc_for_ops gave % for the single-op transaction, expected 100000000', _rc;
    END IF;
    RAISE NOTICE 'exact_rc_for_ops with rc_cost: 100000000, as required';
END
$guard$;

-- The function's contract, which the endpoints alone cannot see (they LEFT JOIN its result to
-- their own ids and treat a NULL like a missing row):
--   * an op whose transaction has no recorded cost gets NO row (6502000001, rc_cost NULL);
--   * only the asked-for ops come back, not the other ops of their transactions (asking for one
--     op of the three-op transaction 6500/1 returns that one row).
DO $guard$
DECLARE
    _rows INT;
BEGIN
    SELECT count(*) INTO _rows FROM haf_stats_app.exact_rc_for_ops(ARRAY[6502000001]::BIGINT []);
    IF _rows <> 0 THEN
        RAISE EXCEPTION 'FAIL (#44): exact_rc_for_ops returned % row(s) for an op whose transaction has no rc_cost', _rows;
    END IF;
    SELECT count(*) INTO _rows FROM haf_stats_app.exact_rc_for_ops(ARRAY[6500000011]::BIGINT []);
    IF _rows <> 1 THEN
        RAISE EXCEPTION 'FAIL (#44): exact_rc_for_ops returned % rows for one asked-for op of a three-op transaction', _rows;
    END IF;
    RAISE NOTICE 'exact_rc_for_ops contract: no row without a cost, only the asked-for ops';
END
$guard$;
