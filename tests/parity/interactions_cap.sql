-- get_account_interactions op-ceiling guard (#48).
--
-- The ceiling is the only thing standing between this endpoint and an unbounded whale scan,
-- and NO tavern test can reach it: the busiest account in the entire 5,000,000-block replay
-- corpus signs ~25,000 relevant ops, roughly 12x below any production-sane value, and the stub
-- gate has a handful of hand-seeded rows. Shipping the guard without executing it is the
-- vacuous-pass trap this repo has already paid for once (tests/parity/community_vs_hivemind.sql
-- carries an anti-vacuous-pass guard for exactly that reason), so the ceiling is a REPLACEABLE
-- function and this test replaces it.
--
-- Everything runs inside a transaction that is ROLLED BACK, so the production ceiling is
-- restored even if an assertion fails. Read-only with respect to committed state.
--
-- Skips cleanly when the endpoint is absent (a node that has not installed it yet) and when no
-- account in this database has enough operations to be worth capping.

\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
    _acct TEXT;
    _full BIGINT;
    _capped BIGINT;
    _capped_bite BIGINT;
    _recheck BIGINT;
    _band RECORD;
    _full_from DATE;
    _capped_from DATE;
    _win_from DATE;
    _win_to DATE;
    _bands INT;
BEGIN
    IF TO_REGPROC('haf_stats_endpoints.get_account_interactions') IS NULL THEN
        RAISE NOTICE 'interactions cap: get_account_interactions is not installed - skipping.';
        RETURN;
    END IF;

    -- Busiest signer of interaction-bearing ops. Needs enough volume that a lowered ceiling
    -- actually bites; below that there is nothing to assert.
    -- hive.account_operations_view, not hafd.account_operations: the endpoint reads the view,
    -- and it is what the CI stub provides (the raw table is real-HAF only), so this guard runs
    -- in both lanes rather than erroring out of the fast one.
    -- Selected by the LARGEST PER-OP-TYPE count, because that is what the ceiling actually
    -- bounds. Ranking by total ops across all four types would happily pick an account with
    -- 3 votes + 3 comments + 2 transfers + 2 custom_json: no single type exceeds a ceiling of
    -- 5, nothing is truncated, and assertion 1 below would hard-fail the whole verification run
    -- over a corpus shape that says nothing about the code.
    SELECT per_type.name INTO _acct
    FROM (
        SELECT a.name, ao.op_type_id, COUNT(*) AS n
        FROM hive.account_operations_view ao
        JOIN hafd.accounts a ON a.id = ao.account_id
        WHERE ao.op_type_id IN (0, 1, 2, 18)
          AND ao.transacting_account_id = ao.account_id
        GROUP BY a.name, ao.op_type_id
    ) per_type
    GROUP BY per_type.name
    HAVING MAX(per_type.n) > 5           -- strictly more than the ceiling, so the cap must bite
    ORDER BY MAX(per_type.n) DESC
    LIMIT 1;

    IF _acct IS NULL THEN
        RAISE NOTICE 'interactions cap: no account exceeds the test ceiling in any single op type here - skipping.';
        RETURN;
    END IF;

    -- Derive the window from the account's OWN operations rather than relying on the
    -- full-history default. The CI stub seeds block numbers that are not monotonic with their
    -- dates, so genesis..today resolves to an inverted block range there and returns nothing;
    -- an explicit window built from the data works identically in both lanes.
    SELECT MIN(b.created_at::DATE), MAX(b.created_at::DATE)
    INTO _win_from, _win_to
    FROM hive.account_operations_view ao
    JOIN hafd.accounts a ON a.id = ao.account_id
    JOIN hafd.blocks b ON b.num = ao.block_num
    WHERE a.name = _acct
      AND ao.op_type_id IN (0, 1, 2, 18)
      AND ao.transacting_account_id = ao.account_id;

    IF _win_from IS NULL THEN
        RAISE NOTICE 'interactions cap: cannot resolve a block window for % - skipping.', _acct;
        RETURN;
    END IF;

    SELECT SUM(i.interaction_count), MAX(i.covered_from)
    INTO _full, _full_from
    FROM haf_stats_endpoints.get_account_interactions(_acct, _win_from::TEXT, _win_to::TEXT, 50) i;

    IF _full IS NULL OR _full = 0 THEN
        RAISE NOTICE 'interactions cap: % has no interactions in %..% - skipping.', _acct, _win_from, _win_to;
        RETURN;
    END IF;

    -- Lower the ceiling far below that account's op count. IMMUTABLE + inlinable, same shape as
    -- the definition it replaces.
    CREATE OR REPLACE FUNCTION haf_stats_app.max_interaction_ops()
    RETURNS INT LANGUAGE sql IMMUTABLE AS 'SELECT 5';

    -- MAX, not MIN: coverage is reported PER OP TYPE, so a band whose budget was not exceeded
    -- still reports the caller's window. MIN would therefore always come back as the requested
    -- from_date and the assertion below could never fail, whatever the guard did.
    SELECT SUM(i.interaction_count), MAX(i.covered_from), COUNT(DISTINCT i.interaction_type)
    INTO _capped_bite, _capped_from, _bands
    FROM haf_stats_endpoints.get_account_interactions(_acct, _win_from::TEXT, _win_to::TEXT, 50) i;

    -- 1. The cap must actually bite.
    IF _capped_bite IS NULL OR _capped_bite >= _full THEN
        RAISE EXCEPTION 'interactions cap: ceiling of 5 did not reduce % (full=%, capped=%). The guard is not firing.',
            _acct, _full, _capped_bite;
    END IF;

    -- 2. And it must SAY SO. This is the regression that matters: an earlier revision detected
    --    truncation by comparing the oldest kept block against the oldest available block, which
    --    are EQUAL when the cap boundary falls inside a single block - so a truncated answer
    --    reported the full requested window and the client could not tell.
    IF _capped_from IS NULL OR _capped_from <= _full_from THEN
        RAISE EXCEPTION 'interactions cap: truncated to % interactions but no band moved its covered_from (latest %, uncapped %). Truncation was not disclosed.',
            _capped_bite, _capped_from, _full_from;
    END IF;

    -- 3. Per-op-type budgets: no band may be starved out entirely by another band's volume.
    IF _bands = 0 THEN
        RAISE EXCEPTION 'interactions cap: every band vanished under the ceiling; budgets are not per-type.';
    END IF;

    -- 4. Each band's counts must describe EXACTLY the window its own covered_from claims. The
    --    endpoint drops the partially-scanned boundary day for this reason; before that fix the
    --    counts included ops from a day covered_from excluded, so a client re-deriving totals
    --    over the disclosed window got FEWER interactions than the endpoint had just reported.
    --
    --    PER BAND, and re-derived with the ceiling LIFTED. covered_from is per op type, so
    --    summing across bands would compare different windows (that mistake made an earlier
    --    revision of this assertion fail spuriously), and re-deriving under the tiny test
    --    ceiling would simply truncate again instead of measuring the truth.
    CREATE TEMP TABLE _capped_bands ON COMMIT DROP AS
    SELECT i.interaction_type AS kind, SUM(i.interaction_count) AS cnt, MAX(i.covered_from) AS cf
    FROM haf_stats_endpoints.get_account_interactions(_acct, _win_from::TEXT, _win_to::TEXT, 50) i
    GROUP BY i.interaction_type;

    CREATE OR REPLACE FUNCTION haf_stats_app.max_interaction_ops()
    RETURNS INT LANGUAGE sql IMMUTABLE AS 'SELECT 100000000';

    FOR _band IN SELECT kind, cnt, cf FROM _capped_bands LOOP
        SELECT COALESCE(SUM(i.interaction_count), 0) INTO _recheck
        FROM haf_stats_endpoints.get_account_interactions(_acct, _band.cf::TEXT, _win_to::TEXT, 50) i
        WHERE i.interaction_type = _band.kind;

        IF _recheck IS DISTINCT FROM _band.cnt THEN
            RAISE EXCEPTION 'interactions cap: band % reported % interactions covering from %, but an uncapped re-derivation over that window gives %. Counts and disclosed window disagree.',
                _band.kind, _band.cnt, _band.cf, _recheck;
        END IF;
    END LOOP;

    -- 5. A NULL ceiling must NOT become "no limit" (LIMIT NULL is unbounded in PostgreSQL).
    CREATE OR REPLACE FUNCTION haf_stats_app.max_interaction_ops()
    RETURNS INT LANGUAGE sql IMMUTABLE AS 'SELECT NULL::INT';

    SELECT SUM(i.interaction_count) INTO _capped
    FROM haf_stats_endpoints.get_account_interactions(_acct, _win_from::TEXT, _win_to::TEXT, 50) i;

    IF _capped IS DISTINCT FROM _full THEN
        RAISE EXCEPTION 'interactions cap: a NULL ceiling changed the answer (% vs uncapped %); the COALESCE fallback is missing.',
            _capped, _full;
    END IF;

    RAISE NOTICE 'interactions cap OK: % truncated from % to % interactions under a ceiling of 5, disclosed as covered_from % (uncapped %), % band(s) retained; NULL ceiling falls back safely.',
        _acct, _full, _capped_bite, _capped_from, _full_from, _bands;
END $$;

ROLLBACK;
