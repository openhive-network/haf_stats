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

-- Seed exactly one row, and only when empty: a plain INSERT (the ON CONFLICT DO
-- NOTHING never fires without a unique constraint) would add a duplicate (TRUE, 0)
-- on every re-install — and get_health reads LIMIT 1 with no ORDER BY, so it could
-- then report last_processed_block = 0.
INSERT INTO haf_stats_app.app_status (continue_processing, last_processed_block)
SELECT
    TRUE AS continue_processing,
    0 AS last_processed_block
WHERE NOT EXISTS (SELECT 1 AS one FROM haf_stats_app.app_status);

-- Collapse duplicates left by installs that predate the guard above, then enforce the
-- singleton so it cannot recur. This matters beyond tidiness — a live node here carries
-- four rows, one of them 0, and the LIMIT 1 readers would report a synced node as being
-- at block 0, flip community_data_ready for the wrong reason, and hang the CI sync gate.
-- The index expression is constant, so it admits exactly one row.
--
-- The two columns are collapsed by DIFFERENT rules, because they are written by different
-- callers and only one of them is duplicated harmlessly:
--   last_processed_block - keep the MAX. main() updates every row with no WHERE clause
--     (see the UPDATE in main() below), so these really are copies of one clock.
--   continue_processing  - AND them together FIRST. stop_processing()/allow_processing()
--     write this column, and continue_processing() reads it with BOOL_AND precisely
--     because copies can disagree. Picking a survivor by block number alone could discard
--     a FALSE stop flag and silently restart a processor an operator had stopped, which is
--     the one way this de-dup could lose real state rather than a duplicate of it.
UPDATE haf_stats_app.app_status
SET
    continue_processing = (SELECT BOOL_AND(a2.continue_processing) FROM haf_stats_app.app_status AS a2)
WHERE continue_processing IS DISTINCT FROM (
    SELECT BOOL_AND(a3.continue_processing) FROM haf_stats_app.app_status AS a3
);

DELETE FROM haf_stats_app.app_status AS a
USING (
    SELECT s.ctid AS keep_ctid
    FROM haf_stats_app.app_status AS s
    ORDER BY s.last_processed_block DESC, s.ctid DESC
    LIMIT 1
) AS k
WHERE a.ctid <> k.keep_ctid;

CREATE UNIQUE INDEX IF NOT EXISTS uq_app_status_singleton
ON haf_stats_app.app_status ((TRUE));

CREATE TABLE IF NOT EXISTS haf_stats_app.app_version (
    git_hash TEXT NOT NULL
);

-- Deployment-specific settings that the SERVED document has to reflect, so they cannot
-- be baked into the image: the same image runs behind a node route and on a bare
-- `docker compose up -d`, and those need different base URLs. (#70)
--
-- Written once by install_app.sh --swagger-url and read at REQUEST time by
-- haf_stats_endpoints.root(). A session GUC cannot carry this: install_app set
-- `custom.swagger_url` in its own psql session, which PostgREST -- connecting later, on
-- its own pool -- could never see. That is why the flag did nothing for as long as it
-- existed. Persisting it is the whole fix.
CREATE TABLE IF NOT EXISTS haf_stats_app.app_config (
    swagger_base_url TEXT
);

-- Singleton, by the same constant-expression index as app_status above: a re-install
-- must overwrite the setting rather than add a second row that readers pick from at
-- random.
CREATE UNIQUE INDEX IF NOT EXISTS uq_app_config_singleton
ON haf_stats_app.app_config ((TRUE));

INSERT INTO haf_stats_app.app_config (swagger_base_url)
SELECT NULL AS swagger_base_url
WHERE NOT EXISTS (SELECT 1 AS one FROM haf_stats_app.app_config);

GRANT SELECT ON haf_stats_app.app_status TO haf_stats_user;
GRANT SELECT ON haf_stats_app.app_version TO haf_stats_user;
-- root() runs as the anonymous role and reads this on every GET /.
GRANT SELECT ON haf_stats_app.app_config TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Lifecycle control functions
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.continue_processing;
CREATE OR REPLACE FUNCTION haf_stats_app.continue_processing()
RETURNS BOOL
LANGUAGE sql STABLE
AS $$
    -- BOOL_AND rather than LIMIT 1: the singleton index above makes them equivalent on
    -- a repaired node, but this is the function that stops the processor, so it must not
    -- depend on scan order if a duplicate ever reappears. COALESCE makes the empty-table
    -- case explicitly "keep going" rather than relying on NULL: the pre-existing LIMIT 1
    -- also returned NULL there, and `IF NOT NULL` is NULL, so that branch was not taken
    -- and main() kept going too - so this is a clarification of an unchanged behaviour,
    -- NOT a behaviour change.
    SELECT COALESCE(BOOL_AND(continue_processing), TRUE) FROM haf_stats_app.app_status;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.allow_processing;
CREATE OR REPLACE FUNCTION haf_stats_app.allow_processing()
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE haf_stats_app.app_status SET continue_processing = TRUE;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.stop_processing;
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

DROP FUNCTION IF EXISTS haf_stats_app.get_required_authorities_safe;
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

DROP FUNCTION IF EXISTS haf_stats_app.create_context_if_not_exists;
CREATE OR REPLACE FUNCTION haf_stats_app.create_context_if_not_exists()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _stages    hive.application_stages;
    _app_block INT;   -- what app_status actually says (the app's own clock)
    _seed      INT;   -- _app_block clamped to what HAF can currently serve
    _ctx_block INT;
BEGIN
    -- hafd.contexts.current_block_num and app_status.last_processed_block are ONE clock:
    -- main() takes both from _block_range.last_block in the same transaction (the loop's
    -- only COMMIT is at the top of the next hive.app_next_iteration), so an external
    -- reader can never observe them differing on a node the processor drives.
    --
    -- This function used to end with hive.app_set_current_block_num('haf_stats', 0)
    -- unconditionally, including on a node that already held processed data, while the
    -- "already exists" branch below repaired nothing. So any context lifecycle event —
    -- installing over existing data, or hive.app_remove_context / hive.app_reset_data,
    -- which sibling apps' uninstall scripts call — desynced the two PERMANENTLY: context
    -- at 0, app_status at the tip. Note hive.app_reset_data does DROP SCHEMA <context
    -- name>, and ours is the one context whose name (haf_stats) is not its schema
    -- (haf_stats_app), so it drops nothing and every row of app data survives the reset.
    --
    -- Two consequences, both silent. hive.app_next_block then hands the processor
    -- 1..head and it replays the whole chain over populated tables — and main()'s
    -- WHERE-less UPDATE rewinds app_status to the first batch, so the clocks agree again
    -- at the wrong number and the double-count guard in process_content_stats.sql loses
    -- its high-water mark. Separately, once GET /sync-status reports the context pointer
    -- (#55), a fully-synced node answers {"last_block_num": 0, "last_block_time": null}.
    --
    -- LEAST(..., consistent_block) because hive.app_context_attach raises if
    -- current_block_num > consistent_block, and app_next_iteration attaches on its first
    -- stage analysis — a seed above the node's own head would wedge the processor.
    --
    -- NO COALESCE on consistent_block, deliberately. It is NULLABLE and is NULL until HAF
    -- has its first irreversible block (massive sync, re-replay) - a state install_app.sh
    -- explicitly supports. COALESCE(..., 0) there would make this LEAST(app_block, 0) = 0
    -- and reseed the context at genesis on a node holding processed data, i.e. cause the
    -- exact failure this function exists to prevent. LEAST IGNORES NULL arguments, so
    -- leaving it out yields app_block when the node has no consistent block yet - and if
    -- that pointer really is too high, app_context_attach raises loudly, which is strictly
    -- better than a silent genesis replay over populated tables.
    -- MAX() rather than a bare scalar subquery: used as an expression, a bare subquery
    -- raises 21000 if hafd.hive_state ever holds more than one row.
    SELECT COALESCE(MAX(s.last_processed_block), 0)
      INTO _app_block
      FROM haf_stats_app.app_status AS s;

    SELECT LEAST(_app_block, (SELECT MAX(hs.consistent_block) FROM hafd.hive_state AS hs))
      INTO _seed;

    -- Kept distinct on purpose. Every message below reports _app_block when it says "what
    -- app_status holds" and _seed when it says "what the pointer was set to"; collapsing
    -- them made the WARNING claim app_status held the clamped number, which it did not.
    --
    -- The clamp only bites when HAF is BEHIND the app - a node re-replayed to a shorter
    -- chain while the app's tables survived. Seeding the pointer below app_status' high
    -- water mark does not corrupt anything, but it does not rescue the node either:
    -- process_content_stats refuses any range at or below MAX(app_status) (issue #42), so
    -- the processor will abort every batch until an operator intervenes. That is true of
    -- the unclamped and pre-#55 behaviour too - seeding above consistent_block makes
    -- app_context_attach raise, and seeding 0 hits the same #42 guard - so this is not a
    -- regression, but it must not look like a healthy repair in the log.
    IF _seed < _app_block THEN
        RAISE WARNING 'HAF is behind this app: hafd.hive_state.consistent_block is % while haf_stats_app.app_status.last_processed_block is %. Clamping the context pointer to % so hive.app_context_attach does not reject it, but the processor will NOT make progress: process_content_stats refuses any range at or below % to avoid double-counting (issue #42). Let HAF finish syncing, or rebuild the app tables - see scripts/rebuild_content_volume.sh.', _seed, _app_block, _seed, _app_block;
    END IF;

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
        PERFORM hive.app_set_current_block_num('haf_stats', _seed);

        IF _seed > 0 THEN
            -- Loud, because seeding trusts app_status. main() is the only writer of that
            -- column in this repo's entire history, so the number is sound on any node
            -- built by the processor — but if someone set it by hand, every block below
            -- it is now skipped for good rather than replayed.
            -- Name the step that actually works. Install can only RAISE this pointer, never
            -- lower it (the repair branch below returns early when the context is already
            -- at or ahead of app_status), so "reset app_status and re-run install" would
            -- leave the pointer where it is and silently do nothing.
            RAISE WARNING 'HAF context haf_stats created at block % (seeded from haf_stats_app.app_status, NOT from genesis). If this node has not actually processed that far, blocks at or below % will never be processed. Install can only raise this pointer, never lower it, so re-running install alone will NOT replay. To replay from scratch: UPDATE haf_stats_app.app_status SET last_processed_block = 0; SELECT hive.app_remove_context(''haf_stats''); then re-run install - and only on a node whose tables are empty, since replaying over populated tables double-counts (issue #42; see scripts/rebuild_content_volume.sh).', _seed, _seed;
        ELSE
            RAISE NOTICE 'HAF context haf_stats created at block 0.';
        END IF;
        RETURN;
    END IF;

    SELECT c.current_block_num INTO _ctx_block
      FROM hafd.contexts AS c
     WHERE c.name = 'haf_stats';

    -- app_context_exists() said yes but the row is unreadable here: RLS on hafd.contexts
    -- hid it, or a concurrent hive.app_remove_context won the race. Bail explicitly - a
    -- NULL _ctx_block makes every comparison below NULL, so the >= and the attached check
    -- would both fall through and we would call app_set_current_block_num on a context
    -- whose state was never read, then report 'replayed from block <NULL>'.
    IF _ctx_block IS NULL THEN
        RAISE EXCEPTION 'HAF context haf_stats exists but its row in hafd.contexts is not readable (RLS, or the context was removed concurrently). Refusing to move a pointer that cannot be inspected. Check that haf_stats_owner still INHERITs hive_applications_group.';
    END IF;

    IF _ctx_block >= _seed THEN
        RAISE NOTICE 'HAF context haf_stats already exists at block % (app_status %); nothing to repair.', _ctx_block, _app_block;
        RETURN;
    END IF;

    -- hive.app_set_current_block_num requires a detached context, and a lagging ATTACHED
    -- one means the processor is live — in which case main() owns both clocks and we
    -- must not reach in behind it.
    IF hive.app_context_is_attached('haf_stats') THEN
        RAISE WARNING 'HAF context haf_stats is at block % while app_status is at %, but the context is ATTACHED (processor running) — not repairing. Stop scripts/process_blocks.sh and re-run install to repair.', _ctx_block, _app_block;
        RETURN;
    END IF;

    PERFORM hive.app_set_current_block_num('haf_stats', _seed);
    RAISE WARNING 'HAF context haf_stats repaired: block % -> % (from haf_stats_app.app_status). This node''s context had been reset while its processed data survived; without this repair the processor would have replayed from block %.', _ctx_block, _seed, _ctx_block + 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Main block-processing loop (PROCEDURE so CALL works and transactions commit).
-- Uses hive.app_next_iteration() which automatically advances the context block
-- pointer — unlike the older hive.app_next_block() function which does not.
-- ---------------------------------------------------------------------------

-- DROP PROCEDURE, not DROP FUNCTION: PG11+ refuses to drop a procedure through
-- DROP FUNCTION, so the FUNCTION form used for the rest of this file would have
-- been a silent no-op here. Paren-less for the same reason as the others -- it
-- covers every overload, so a future signature change needs no edit in step.
-- Procedures have no return type, but CREATE OR REPLACE still aborts with
-- "cannot change name of input parameter", and an added parameter would
-- accumulate a second overload rather than replace this one.
DROP PROCEDURE IF EXISTS haf_stats_app.main;
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

DROP FUNCTION IF EXISTS haf_stats_app.backfill_rollup_if_empty;
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

DROP FUNCTION IF EXISTS haf_stats_app.backfill_rollup_if_column_null;
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
