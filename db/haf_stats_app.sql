-- Core HAF Stats app: schemas, control tables, HAF context, lifecycle, and main loop.

-- ---------------------------------------------------------------------------
-- Schemas
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS haf_stats_app AUTHORIZATION haf_stats_owner;
CREATE SCHEMA IF NOT EXISTS haf_stats_backend AUTHORIZATION haf_stats_owner;
CREATE SCHEMA IF NOT EXISTS haf_stats_endpoints AUTHORIZATION haf_stats_owner;

GRANT USAGE ON SCHEMA haf_stats_app TO haf_stats_user;
GRANT USAGE ON SCHEMA haf_stats_backend TO haf_stats_user;
GRANT USAGE ON SCHEMA haf_stats_endpoints TO haf_stats_user;

SET ROLE haf_stats_owner;

-- ---------------------------------------------------------------------------
-- Control tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_app.app_status (
    continue_processing BOOL NOT NULL DEFAULT TRUE,
    last_processed_block INT NOT NULL DEFAULT 0
);

-- Seed exactly one row, and only when empty: app_status has no unique constraint,
-- so a plain INSERT (the ON CONFLICT DO NOTHING never fires without one) would add
-- a duplicate (TRUE, 0) on every re-install — and get_health reads LIMIT 1 with no
-- ORDER BY, so it could then report last_processed_block = 0.
INSERT INTO haf_stats_app.app_status (continue_processing, last_processed_block)
SELECT
    TRUE AS continue_processing,
    0 AS last_processed_block
WHERE NOT EXISTS (SELECT 1 AS one FROM haf_stats_app.app_status);

CREATE TABLE IF NOT EXISTS haf_stats_app.app_version (
    git_hash TEXT NOT NULL
);

GRANT SELECT ON haf_stats_app.app_status TO haf_stats_user;
GRANT SELECT ON haf_stats_app.app_version TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Lifecycle control functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.continue_processing()
RETURNS BOOL
LANGUAGE sql STABLE
AS $$
    SELECT continue_processing FROM haf_stats_app.app_status LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION haf_stats_app.allow_processing()
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE haf_stats_app.app_status SET continue_processing = TRUE;
$$;

CREATE OR REPLACE FUNCTION haf_stats_app.stop_processing()
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE haf_stats_app.app_status SET continue_processing = FALSE;
$$;

-- ---------------------------------------------------------------------------
-- Crash-safe authority lookup
--
-- hive.get_required_authorities() (a HAF C++ function) FC_ASSERTs on a handful of
-- legacy ops — e.g. "Asset amount cannot be negative", observed ~block 23.5M on a
-- 1.28.6 mainnet node. Called raw inside the per-batch LATERAL of
-- process_account_cohorts / process_active_users, one such op aborts the whole
-- statement → the batch → the processor, which then restart-loops forever on that
-- poisoned batch. The integration-tests CI replays only 5,000,000 blocks, so it
-- never reaches them; a full-history sync would.
--
-- This wrapper evaluates get_required_authorities under an exception guard: any op
-- whose authority computation throws contributes ZERO rows, i.e. is treated as
-- authorless — the exact same outcome as pow/pow2 mined ops, which the inner join
-- already drops. The processors continue past the bad op instead of dying.
--
-- Trade-offs: WHEN OTHERS is deliberately broad (the lost signal is a few legacy
-- ops; a dead processor is strictly worse). The exception block makes each call a
-- subtransaction, but the wrapped call is read-only so no XID is assigned (no XID
-- burn) — only modest per-row overhead, verified not to regress massive sync.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.get_required_authorities_safe(_body JSONB)
RETURNS TABLE (account_name TEXT)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY SELECT ra.account_name FROM hive.get_required_authorities(_body) ra;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$;

-- ---------------------------------------------------------------------------
-- HAF context registration (called once at install)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.create_context_if_not_exists()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _stages hive.application_stages;
BEGIN
    IF NOT hive.app_context_exists('haf_stats') THEN
        _stages := ARRAY[
            hive.stage('MASSIVE_PROCESSING', 101, 10000, '20 seconds'),
            hive.live_stage()
        ]::hive.application_stages;
        PERFORM hive.app_create_context(
            _name   => 'haf_stats'::hafd.context_name,
            _schema => 'haf_stats_app',
            _stages => _stages
        );
        PERFORM hive.app_context_set_non_forking('haf_stats');
        PERFORM hive.app_context_detach('haf_stats');
        PERFORM hive.app_set_current_block_num('haf_stats', 0);
        RAISE NOTICE 'HAF context haf_stats created.';
    ELSE
        RAISE NOTICE 'HAF context haf_stats already exists, skipping.';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Main block-processing loop (PROCEDURE so CALL works and transactions commit).
-- Uses hive.app_next_iteration() which automatically advances the context block
-- pointer — unlike the older hive.app_next_block() function which does not.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE haf_stats_app.main(
    IN _context hafd.CONTEXT_NAME DEFAULT 'haf_stats'
)
LANGUAGE plpgsql
AS $$
DECLARE
    _block_range hive.blocks_range;
BEGIN
    PERFORM haf_stats_app.allow_processing();
    RAISE NOTICE 'haf_stats starting. Last processed block: %', hive.app_get_current_block_num(_context);

    -- During the initial MASSIVE_PROCESSING sync we replay millions of blocks
    -- as fast as possible; durability of each batch does not matter because a
    -- crash just restarts the bounded replay (the source of truth is HAF, and
    -- last_processed_block lets us resume). synchronous_commit = OFF removes the
    -- per-batch fsync wait — the balance_tracker massive-sync optimisation. We
    -- restore it to ON below once the context reaches the LIVE stage so live
    -- updates stay durable.
    IF hive.get_current_stage_name(_context) = 'MASSIVE_PROCESSING' THEN
        SET synchronous_commit = OFF;
    END IF;

    LOOP
        CALL hive.app_next_iteration(_context, _block_range, NULL, NULL);

        IF NOT haf_stats_app.continue_processing() THEN
            ROLLBACK;
            RAISE NOTICE 'haf_stats stopped at block %', hive.app_get_current_block_num(_context);
            RETURN;
        END IF;

        IF _block_range IS NULL THEN
            CONTINUE;
        END IF;

        -- Re-enable durable commits once we leave massive sync for LIVE.
        IF current_setting('synchronous_commit') = 'off'
           AND hive.get_current_stage_name(_context) <> 'MASSIVE_PROCESSING' THEN
            SET synchronous_commit = ON;
        END IF;

        PERFORM haf_stats_app.process_block_range(_block_range.first_block, _block_range.last_block);
        UPDATE haf_stats_app.app_status SET last_processed_block = _block_range.last_block;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- One-time self-heal for the precomputed endpoint rollups (called by install_app.sh)
--
-- The period rollups (account_cohort_retention, active_users_period_counts,
-- network_vote_period_counts) ship empty and their endpoints read them directly. The
-- forward refresh hook inside each processor only touches recent periods, so on an
-- already-synced node - installing a new app version over existing data - the historical
-- rollup would stay empty and the endpoint return [] until someone manually ran a genesis
-- backfill: a silent regression that is easy to forget on a fresh environment. After the
-- processors are loaded, install_app.sh calls this once per rollup: if the rollup is empty
-- but its source table already has data, it runs the supplied full-history refresh.
-- Idempotent (a populated rollup is left untouched, so re-installs are cheap) and a no-op
-- on a node still replaying from genesis (source empty -> the hook builds the rollup
-- forward as the replay advances). _refresh_call is a complete SQL statement so each
-- rollup passes its own refresh signature (the period rollups take a genesis _lo DATE;
-- cohort retention takes an _as_of TIMESTAMP = chain head). On a large already-synced node
-- the refresh is a full re-aggregation and can take a while - it runs in the setup
-- container, which the processor waits on, so the rollup is populated before serving.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.backfill_rollup_if_empty(
    _rollup REGCLASS,
    _source REGCLASS,
    _refresh_call TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _rollup_has_rows BOOLEAN;
    _source_has_rows BOOLEAN;
BEGIN
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s)', _rollup) INTO _rollup_has_rows;
    IF _rollup_has_rows THEN
        RETURN;  -- already populated; nothing to do
    END IF;

    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s)', _source) INTO _source_has_rows;
    IF NOT _source_has_rows THEN
        RETURN;  -- fresh node still replaying from genesis; the hook will fill it forward
    END IF;

    RAISE NOTICE 'haf_stats: % is empty but % has data - running one-time full backfill', _rollup, _source;
    EXECUTE _refresh_call;
END;
$$;

-- ---------------------------------------------------------------------------
-- Companion to backfill_rollup_if_empty for the SCHEMA-upgrade case: a rollup
-- that gained new columns via ALTER TABLE ... ADD COLUMN IF NOT EXISTS keeps its
-- existing rows, so backfill_rollup_if_empty (which only fires on an empty rollup)
-- never repopulates them and the new columns stay NULL. Pass a sentinel column
-- that the current refresh always writes non-NULL (e.g. a COUNT that is >= 0); a
-- NULL in it marks a row written before the upgrade. When any such row exists,
-- run the full refresh once to populate the new columns. Idempotent: after the
-- refresh no row has a NULL sentinel, so it does not fire again. On a fresh
-- genesis node the rollup is empty, so EXISTS is false and this is a no-op.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.backfill_rollup_if_column_null(
    _rollup REGCLASS,
    _sentinel_col TEXT,
    _refresh_call TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _has_null BOOLEAN;
BEGIN
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE %I IS NULL)', _rollup, _sentinel_col)
        INTO _has_null;
    IF NOT _has_null THEN
        RETURN;  -- no pre-upgrade rows (or empty rollup); nothing to do
    END IF;

    RAISE NOTICE 'haf_stats: % has rows with NULL % - running one-time full refresh to populate upgrade columns', _rollup, _sentinel_col;
    EXECUTE _refresh_call;
END;
$$;

RESET ROLE;
