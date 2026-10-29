-- The rollup refreshes deferred through massive sync, and the per-batch call that runs them.
--
-- Its own file, like db/schema_migration.sql, because the endpoint-tests stub lane
-- (docker/docker-compose-ci.yml) loads the processor files without db/haf_stats_app.sql,
-- which needs a HAF, and tests/ci_hivemind_wait_locks.sql runs these real functions there.
-- install_app.sh loads it right after db/haf_stats_app.sql.

SET ROLE haf_stats_owner;

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
--     the touched creation-days while the drain is deferred. On the hivemind content source
--     that drain reads hivemind, which this batch may read only after its hivemind wait in
--     process_content_stats (#118): so there it is left recorded as
--     'engagement_after_hivemind_wait' (db/process_content_stats.sql, "Rollup refresh"), and
--     the batch's process_content_stats runs it after the wait;
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
-- and clears the record in the same transaction. A no-op when nothing is recorded. Reads no
-- hivemind table: on the hivemind source the engagement drain is recorded for after the
-- batch's hivemind wait instead (see the section header), and that record is left alone here.
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
    IF NOT EXISTS (
        SELECT 1 FROM haf_stats_app.deferred_rollup_refreshes AS d
        WHERE d.processor <> 'engagement_after_hivemind_wait'
    ) THEN
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
        IF haf_stats_app.content_source() = 'hivemind' THEN
            INSERT INTO haf_stats_app.deferred_rollup_refreshes (processor, dirty_from)
            VALUES ('engagement_after_hivemind_wait', _from)
            ON CONFLICT (processor) DO NOTHING;
        ELSE
            PERFORM haf_stats_app.refresh_engagement_touched();
            IF _timed THEN _t := haf_stats_app.report_deferred_refresh_timing('refresh_engagement_touched', _from, _as_of, _t); END IF;
        END IF;
        -- The presence-set rows only these refreshes still needed (prune_content_presence,
        -- db/process_content_stats.sql), bounded by the next batch: its refresh starts at
        -- the 1200-block bucket holding the last processed block, and it starts after _as_of.
        PERFORM haf_stats_app.prune_content_presence(
            COALESCE(
                (SELECT b.created_at::DATE FROM hafd.blocks AS b WHERE b.num = GREATEST((_last_block / 1200) * 1200, 1)),
                -- A bucket is far shorter than a day.
                _as_of::DATE - 1),
            _as_of::DATE);
    END IF;

    DELETE FROM haf_stats_app.deferred_rollup_refreshes WHERE processor = 'process_content_cohorts'
    RETURNING dirty_from INTO _from;
    IF FOUND THEN
        PERFORM haf_stats_app.refresh_author_cohort_retention(_as_of, _from);
        IF _timed THEN PERFORM haf_stats_app.report_deferred_refresh_timing('refresh_author_cohort_retention', _from, _as_of, _t); END IF;
    END IF;

    -- A row under any other name would otherwise sit here unrefreshed for good.
    IF EXISTS (
        SELECT 1 FROM haf_stats_app.deferred_rollup_refreshes AS d
        WHERE d.processor <> 'engagement_after_hivemind_wait'
    ) THEN
        RAISE EXCEPTION 'haf_stats: deferred rollup refreshes recorded for unknown processors: %',
            (SELECT string_agg(d.processor, ', ' ORDER BY d.processor) FROM haf_stats_app.deferred_rollup_refreshes AS d
             WHERE d.processor <> 'engagement_after_hivemind_wait');
    END IF;
END;
$$;

-- Called by install_app.sh: runs the recorded refreshes when the context is already past
-- massive sync, and otherwise leaves them to the first batch outside it. The record is
-- checked first so that an install that has processed nothing never reads the stage
-- (plpgsql resolves hive.get_current_stage_name only when that line runs). The engagement
-- drain recorded for after a hivemind wait runs here only if hivemind is usable through the
-- processed blocks now (run_deferred_engagement_refresh); otherwise the next batch runs it.
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
    PERFORM haf_stats_app.run_deferred_engagement_refresh();
END;
$$;

-- Called by main() and process_blocks() once per batch, before process_block_range, in the
-- batch's transaction. During MASSIVE_PROCESSING it makes this batch's processors record
-- their rollup refreshes instead of running them; on any other stage it first runs the
-- refreshes recorded so far (a no-op once they have run), all but the engagement drain on
-- the hivemind source, which this batch's process_content_stats runs after its wait.
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

RESET ROLE;
