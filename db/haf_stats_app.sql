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

-- The rollup refreshes skipped during massive sync (see defer_rollup_refresh below): one
-- row per processor whose refresh call was skipped, holding the earliest day (or, for the
-- cohort retention refreshes, the earliest cohort month) any skipped call would have
-- refreshed from. A regular logged table written in the batch's own transaction, so a
-- crash between batches loses no row: the batch that recorded it either committed or
-- will be redelivered.
CREATE TABLE IF NOT EXISTS haf_stats_app.deferred_rollup_refreshes (
    processor TEXT PRIMARY KEY,
    dirty_from DATE NOT NULL
);

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
-- burn). Even so that is one subtransaction per op, so prepare_batch_authored_ops
-- calls hive.get_required_authorities plainly and falls back to this wrapper only for a
-- batch whose plain statement failed.
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
    -- hafd.*, not hive.*. Upstream keeps hive.application_stages and hive.live_stage()
    -- only in types/operation/compatibility_with_old_haf_apps.sql -- a file whose first
    -- line is "for compatibility with old HAF apps add some aliases for types moved to
    -- hafd schema". The canonical names are hafd.application_stages and
    -- hafd.live_stage(), and both exist in the HAF we pin (1.28.6) as well as develop,
    -- verified against both refs. hive.stage() below is NOT a compat alias -- it is
    -- canonical, defined in application_loop/stages_functions.sql -- so it stays. (#87)
    _stages    hafd.application_stages;
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
            hafd.live_stage()
        ]::hafd.application_stages;
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
-- Rollup refreshes deferred through massive sync
--
-- The period, monthly and retention rollups are re-aggregations of the processors' daily
-- and member tables (upserts of the recomputed rows, never additive), refreshed whenever a
-- batch crosses a 1200-block bucket. Every 10,000-block massive batch crosses one, so each
-- re-aggregated its month to date again, and nothing reads the rollups before the API
-- serves. So during MASSIVE_PROCESSING each processor records, in place of its refresh
-- call, the earliest day that call would have refreshed from, and the first batch outside
-- massive sync runs each recorded refresh once from that day. The final rows are the same:
--
--   * the day/week/month periods and the monthly rollups restate every period from their
--     lower bound to the last processed day out of tables that are complete for those days;
--   * refresh_engagement_touched drains engagement_touched_days, which keeps accumulating
--     the touched creation-days while the drain is deferred;
--   * cohort retention reads only the member flags and its _as_of. A flag stops changing
--     180 days after the member's creation, and a cohort leaves the per-batch refresh's
--     window a month after that, so a cohort that has left it was last refreshed with every
--     member matured, which a later refresh with every member matured reproduces. The
--     cohorts still in the window were last refreshed with _as_of = the last refreshing
--     batch's last block time; run_deferred_rollup_refreshes passes the last processed
--     block's, the same block whenever the last massive batch crossed a bucket (any batch
--     of 1200 blocks or more does). Nothing reads now() or the refreshing batch's blocks.
--
-- The deferral is per batch and opt-in: main() and process_blocks() turn it on through
-- prepare_rollup_refreshes, and a processor called any other way (the rebuild scripts, the
-- fixtures) refreshes as before.
-- ---------------------------------------------------------------------------

-- TRUE when the caller's refresh is deferred (and recorded from _dirty_from), so the caller
-- must skip it; FALSE when it must run it now.
DROP FUNCTION IF EXISTS haf_stats_app.defer_rollup_refresh;
CREATE OR REPLACE FUNCTION haf_stats_app.defer_rollup_refresh(
    _processor TEXT,
    _dirty_from DATE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF current_setting('haf_stats.defer_rollup_refreshes', TRUE) IS DISTINCT FROM 'on' THEN
        RETURN FALSE;
    END IF;

    -- The WHERE keeps the common case (an earlier day already recorded) from writing a row.
    INSERT INTO haf_stats_app.deferred_rollup_refreshes AS d (processor, dirty_from)
    VALUES (_processor, _dirty_from)
    ON CONFLICT (processor) DO UPDATE SET dirty_from = EXCLUDED.dirty_from
    WHERE EXCLUDED.dirty_from < d.dirty_from;
    RETURN TRUE;
END;
$$;

-- Each deferred refresh's wall time, as an INFO line in report_processor_timing's shape
-- (db/process_block_range.sql), when haf_stats.processor_timings is on.
DROP FUNCTION IF EXISTS haf_stats_app.report_deferred_refresh_timing;
CREATE OR REPLACE FUNCTION haf_stats_app.report_deferred_refresh_timing(
    _step TEXT,
    _dirty_from DATE,
    _as_of TIMESTAMP,
    _started TIMESTAMPTZ
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    RAISE INFO 'haf_stats_deferred_refresh_timing %', json_build_object(
        'step', _step,
        'dirty_from', _dirty_from,
        'as_of', _as_of,
        'seconds', EXTRACT(EPOCH FROM clock_timestamp() - _started)
    );
    RETURN clock_timestamp();
END;
$$;

-- Runs every recorded refresh once, from its recorded day up to the last processed block,
-- and clears the record in the same transaction. A no-op when nothing is recorded.
DROP FUNCTION IF EXISTS haf_stats_app.run_deferred_rollup_refreshes;
CREATE OR REPLACE FUNCTION haf_stats_app.run_deferred_rollup_refreshes()
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    _last_block INT;
    _as_of TIMESTAMP;
    _from DATE;
    _timed BOOLEAN := current_setting('haf_stats.processor_timings', TRUE) = 'on';
    _t TIMESTAMPTZ;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM haf_stats_app.deferred_rollup_refreshes) THEN
        RETURN;
    END IF;

    SELECT MAX(s.last_processed_block) INTO _last_block FROM haf_stats_app.app_status AS s;
    SELECT b.created_at INTO _as_of FROM hafd.blocks AS b WHERE b.num = _last_block;
    -- A record exists only once a batch has been processed, and a processed block is in
    -- hafd.blocks; refreshing up to a NULL day would restate nothing and clear the record.
    IF _as_of IS NULL THEN
        RAISE EXCEPTION 'haf_stats: deferred rollup refreshes are recorded, but the last processed block % is not in hafd.blocks', _last_block;
    END IF;

    IF _timed THEN _t := clock_timestamp(); END IF;

    DELETE FROM haf_stats_app.deferred_rollup_refreshes WHERE processor = 'process_financial'
    RETURNING dirty_from INTO _from;
    IF FOUND THEN
        PERFORM haf_stats_app.refresh_financial_monthly(_from, _as_of::DATE);
        IF _timed THEN _t := haf_stats_app.report_deferred_refresh_timing('refresh_financial_monthly', _from, _as_of, _t); END IF;
    END IF;

    DELETE FROM haf_stats_app.deferred_rollup_refreshes WHERE processor = 'process_account_cohorts'
    RETURNING dirty_from INTO _from;
    IF FOUND THEN
        PERFORM haf_stats_app.refresh_account_cohort_retention(_as_of, _from);
        IF _timed THEN _t := haf_stats_app.report_deferred_refresh_timing('refresh_account_cohort_retention', _from, _as_of, _t); END IF;
    END IF;

    DELETE FROM haf_stats_app.deferred_rollup_refreshes WHERE processor = 'process_active_users'
    RETURNING dirty_from INTO _from;
    IF FOUND THEN
        PERFORM haf_stats_app.refresh_active_users_periods(_from, _as_of::DATE);
        IF _timed THEN _t := haf_stats_app.report_deferred_refresh_timing('refresh_active_users_periods', _from, _as_of, _t); END IF;
        PERFORM haf_stats_app.refresh_active_users_account_monthly(_from, _as_of::DATE);
        IF _timed THEN _t := haf_stats_app.report_deferred_refresh_timing('refresh_active_users_account_monthly', _from, _as_of, _t); END IF;
    END IF;

    DELETE FROM haf_stats_app.deferred_rollup_refreshes WHERE processor = 'process_content_stats'
    RETURNING dirty_from INTO _from;
    IF FOUND THEN
        PERFORM haf_stats_app.refresh_network_vote_periods(_from, _as_of::DATE);
        IF _timed THEN _t := haf_stats_app.report_deferred_refresh_timing('refresh_network_vote_periods', _from, _as_of, _t); END IF;
        PERFORM haf_stats_app.refresh_network_content_periods(_from, _as_of::DATE);
        IF _timed THEN _t := haf_stats_app.report_deferred_refresh_timing('refresh_network_content_periods', _from, _as_of, _t); END IF;
        PERFORM haf_stats_app.refresh_engagement_touched();
        IF _timed THEN _t := haf_stats_app.report_deferred_refresh_timing('refresh_engagement_touched', _from, _as_of, _t); END IF;
    END IF;

    DELETE FROM haf_stats_app.deferred_rollup_refreshes WHERE processor = 'process_content_cohorts'
    RETURNING dirty_from INTO _from;
    IF FOUND THEN
        PERFORM haf_stats_app.refresh_author_cohort_retention(_as_of, _from);
        IF _timed THEN PERFORM haf_stats_app.report_deferred_refresh_timing('refresh_author_cohort_retention', _from, _as_of, _t); END IF;
    END IF;

    -- A row under any other name would otherwise sit here unrefreshed for good.
    IF EXISTS (SELECT 1 FROM haf_stats_app.deferred_rollup_refreshes) THEN
        RAISE EXCEPTION 'haf_stats: deferred rollup refreshes recorded for unknown processors: %',
            (SELECT string_agg(processor, ', ' ORDER BY processor) FROM haf_stats_app.deferred_rollup_refreshes);
    END IF;
END;
$$;

-- Called by install_app.sh: runs the recorded refreshes when the context is already past
-- massive sync, and otherwise leaves them to the first batch outside it. The record is
-- checked first so that an install that has processed nothing never reads the stage
-- (plpgsql resolves hive.get_current_stage_name only when that line runs).
DROP FUNCTION IF EXISTS haf_stats_app.run_deferred_rollup_refreshes_past_massive;
CREATE OR REPLACE FUNCTION haf_stats_app.run_deferred_rollup_refreshes_past_massive()
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM haf_stats_app.deferred_rollup_refreshes) THEN
        RETURN;
    END IF;
    IF hive.get_current_stage_name('haf_stats') IS NOT DISTINCT FROM 'MASSIVE_PROCESSING' THEN
        RAISE NOTICE 'haf_stats: the context is in massive sync; its deferred rollup refreshes run on the first batch outside it';
        RETURN;
    END IF;
    PERFORM haf_stats_app.run_deferred_rollup_refreshes();
END;
$$;

-- Called by main() and process_blocks() once per batch, before process_block_range, in the
-- batch's transaction. During MASSIVE_PROCESSING it makes this batch's processors record
-- their rollup refreshes instead of running them; on any other stage it first runs the
-- refreshes recorded so far (a no-op once they have run).
DROP FUNCTION IF EXISTS haf_stats_app.prepare_rollup_refreshes;
CREATE OR REPLACE FUNCTION haf_stats_app.prepare_rollup_refreshes(
    _massive BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    -- Transaction-local, so it never outlives the batch it was set for.
    PERFORM set_config('haf_stats.defer_rollup_refreshes', CASE WHEN _massive THEN 'on' ELSE 'off' END, TRUE);
    IF NOT _massive THEN
        PERFORM haf_stats_app.run_deferred_rollup_refreshes();
    END IF;
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
    _massive BOOLEAN;
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

        _massive := hive.get_current_stage_name(_context) = 'MASSIVE_PROCESSING';

        -- Re-enable durable commits once we leave massive sync for LIVE.
        IF current_setting('synchronous_commit') = 'off' AND NOT _massive THEN
            SET synchronous_commit = ON;
        END IF;

        PERFORM haf_stats_app.prepare_rollup_refreshes(_massive);
        PERFORM haf_stats_app.process_block_range(_block_range.first_block, _block_range.last_block);
        UPDATE haf_stats_app.app_status SET last_processed_block = _block_range.last_block;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Driver entry point (haf#341 / hive.app_register): ONE delivered range, and the
-- driver -- not this procedure -- owns the transaction.
--
-- Same per-range work as main()'s loop body. What it leaves out is deliberate, and
-- each omission matters:
--
--   * NO COMMIT and no ROLLBACK. haf_app_driver.py opens the transaction, calls
--     this, and commits. A COMMIT here would end the driver's transaction
--     underneath it.
--   * NO continue_processing() gate. That flag only ever broke main()'s loop; a
--     driver call has no loop to break out of, so returning early on it would let
--     the driver commit the range as processed with nothing written -- silent data
--     loss rather than a stop. hive.app_pause is the registry-era equivalent, which
--     makes stop_processing()/allow_processing()/continue_processing() legacy-loop
--     machinery from here on.
--   * NO hive.app_next_iteration(). The driver calls it and hands us what it
--     returned, which is also what moves the context pointer and writes the
--     last_active_at heartbeat the container healthcheck reads.
--
-- A NULL range returns without work. Note the driver never actually delivers one -- it
-- maps both a SQL NULL and the all-NULL composite to None and skips the CALL -- so this
-- arm is for a manual CALL or a --process-python run, and for parity with main(), which
-- `CONTINUE`s on the NULL that hive.app_next_iteration yields when no block has arrived.
--
-- The search_path pin is belt-and-braces rather than a fix. Everything reached from here
-- resolves schema-qualified, and the unqualified tables in the block path --
-- haf_stats_batch_ops and haf_stats_batch_authored_ops (process_block_range.sql),
-- haf_stats_community_batch_stage (process_content_stats.sql) and
-- haf_stats_batch_exact_rc (exact_rc.sql) -- are all TEMP, and
-- pg_temp is searched first for relations whether or not it is listed. But the legacy
-- loop inherits `"$user", public` from haf_stats_owner's session (verified on the node:
-- the role carries no rolconfig) while the driver's connection is not ours to assume, and
-- reputation_tracker!223 pins it for that reason.
--
-- pg_catalog FIRST, matching db/sync_status.sql, this file's only other pinned path. It
-- is implicitly searched first when unlisted, so naming it last would have DEMOTED it
-- below public for every function and operator resolved anywhere in the call tree. That
-- is benign on a node where public holds only extension objects and PUBLIC lacks CREATE,
-- and it is not a risk worth carrying for nothing.
-- ---------------------------------------------------------------------------

-- DROP then CREATE, for the same overload reason as main() above -- but note it opens a
-- window the legacy loop does not have. This file is loaded with run_sql_file, not
-- run_sql_file_atomic, so the two statements are separate transactions and the procedure
-- briefly does not exist. main() is already executing by then and PostgreSQL lets a
-- running function be dropped; the driver CALLs this one FRESH on every range, so a
-- re-install against a live driver can land a range in the window and take 42883 --
-- which haf_app_driver.py does not catch, so PID 1 exits. Self-healing where a restart
-- policy exists, a stopped container where there is none. Stop the processor before
-- re-installing on a registry-capable HAF.
DROP PROCEDURE IF EXISTS haf_stats_app.process_blocks;
CREATE OR REPLACE PROCEDURE haf_stats_app.process_blocks(
    _block_range hive.BLOCKS_RANGE
)
LANGUAGE plpgsql
SET search_path = pg_catalog, haf_stats_app, public
AS $$
DECLARE
    _massive BOOLEAN;
BEGIN
    IF _block_range IS NULL THEN
        RETURN;
    END IF;

    _massive := hive.get_current_stage_name('haf_stats') = 'MASSIVE_PROCESSING';

    -- The massive-sync durability trade main() makes, kept identical. SET is
    -- session-scoped, so it outlives the driver's per-range transaction and is
    -- re-asserted cheaply on each call; the ELSIF restores durable commits once the
    -- context leaves MASSIVE_PROCESSING, which matters here precisely because the
    -- driver's session outlives any single stage.
    IF _massive THEN
        SET synchronous_commit = OFF;
    ELSE
        -- RESET, not `SET = ON`, which is where this deliberately differs from main().
        -- The loop's version clamps to ON and tests for the literal 'off', so a node
        -- configured `local`/`remote_write`/`remote_apply` either escapes the restore
        -- entirely or is silently promoted to ON for the session. RESET restores whatever
        -- postgresql.conf or the role actually says. It matters more here than in the
        -- loop because the driver re-enters this procedure on every delivered range.
        RESET synchronous_commit;
    END IF;

    PERFORM haf_stats_app.prepare_rollup_refreshes(_massive);
    PERFORM haf_stats_app.process_block_range(_block_range.first_block, _block_range.last_block);
    UPDATE haf_stats_app.app_status SET last_processed_block = _block_range.last_block;
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
