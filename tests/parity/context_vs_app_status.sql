-- Guard: the HAF context pointer and the app's own clock must agree (#55).
--
-- Runs against a genuinely processed stack, so unlike tests/ci_privileges.sql (which
-- proves the plumbing over a stub) this is the only check in the repo that ever looks at
-- real processor state.
--
-- hafd.contexts.current_block_num and haf_stats_app.app_status.last_processed_block are
-- ONE clock: haf_stats_app.main() takes both from _block_range.last_block in the same
-- transaction, and the loop's only COMMIT is at the top of the next
-- hive.app_next_iteration. So on a node the processor drives they are equal, and any
-- persistent disagreement means the context was reset out from under the data or the node
-- was processed out of band.
--
-- That state is not hypothetical: create_context_if_not_exists() used to hard-zero the
-- pointer even on a node that already held data, and hive.app_reset_data() does
-- DROP SCHEMA <context name> — haf_stats is the one context whose name (haf_stats) is not
-- its schema (haf_stats_app), so a reset drops nothing and leaves every row in place.
-- db/haf_stats_app.sql now seeds and repairs the pointer; this guard is the tripwire for
-- the moment that regresses.
--
-- It passes trivially on a healthy cached replay. That is the point — it costs nothing
-- until something breaks, and what it catches is otherwise silent: GET /sync-status would
-- answer {"last_block_num": 0, "last_block_time": null} with HTTP 200 on a fully-synced
-- node, and the processor would replay the chain from genesis over populated tables.
--
-- The read goes through haf_stats_app.sync_status() under the API role, so a failure here
-- also covers the SECURITY DEFINER, its EXECUTE grant, and RLS on hafd.contexts.

DO $$
DECLARE
    _ctx INT;
    _app INT;
    -- The MASSIVE_PROCESSING batch size from create_context_if_not_exists().
    --
    -- This is NOT about reading mid-transaction - both values come from one snapshot of one
    -- statement, so that state is unobservable. The real reason is that main() calls
    -- hive.app_next_iteration FIRST in each loop pass, and that call is the commit boundary:
    -- it commits the previous batch's process_block_range + UPDATE app_status and advances
    -- the context pointer to the NEXT range. So a COMMITTED one-batch lead of the context
    -- over app_status is a normal steady state, visible to any reader. Tightening this to
    -- equality would make the guard flap on every running node.
    _batch CONSTANT INT := 10000;
BEGIN
    SET LOCAL ROLE haf_stats_user;
    SELECT s.context_block_num, s.app_block_num
      INTO _ctx, _app
      FROM haf_stats_app.sync_status() AS s;
    RESET ROLE;

    IF _ctx IS NULL THEN
        RAISE EXCEPTION 'haf_stats_app.sync_status() returned no row as haf_stats_user: the HAF context is missing, or haf_stats_owner (the definer owner) lost hive_applications_group so RLS on hafd.contexts hides it. GET /sync-status would answer HTTP 503.';
    END IF;

    IF _app > 0 AND _ctx = 0 THEN
        RAISE EXCEPTION 'HAF context is at block 0 while the app reports % processed. GET /sync-status would answer {"last_block_num": 0, "last_block_time": null} with HTTP 200 on a synced node, and scripts/process_blocks.sh would replay from genesis over populated tables. Re-run scripts/install_app.sh — create_context_if_not_exists() repairs a detached lagging pointer.', _app;
    END IF;

    IF abs(_ctx - _app) > _batch THEN
        RAISE EXCEPTION 'HAF context (%) and app_status (%) disagree by more than one batch. main() writes both in one transaction, so this means the context was reset or the node was processed out of band. Re-running scripts/install_app.sh only RAISES a lagging pointer; see the WARNING in create_context_if_not_exists() for the replay procedure if the context is ahead.', _ctx, _app;
    END IF;

    RAISE NOTICE 'context/app_status parity OK: context %, app_status %', _ctx, _app;
END
$$;

-- ---------------------------------------------------------------------------
-- Regression coverage for the seed/repair itself.
--
-- The assertions above are state predicates: they observe whether the two clocks agree,
-- but they never call create_context_if_not_exists(), so on a healthy node they pass
-- whether or not the seed/repair logic still exists. Reverting it would go unnoticed here
-- until a node actually got into the broken state - which is exactly the silent failure
-- this guard was added for. This section manufactures that state and asserts the function
-- climbs out of it, so a revert goes red on a healthy node.
--
-- Everything is rolled back. Two gates keep it safe to run against a real node: the
-- function must be installed, and the processor must be idle. The mutation takes row locks
-- on hafd.contexts and hafd.contexts_attachment, which a running processor writes every
-- iteration, so we skip entirely unless last_active_at is stale - never block the tip.
-- Requires a connection that can UPDATE hafd.contexts; run_verification.sh connects as
-- haf_admin, the table owner, and RLS on that table is not FORCED.
-- ---------------------------------------------------------------------------
BEGIN;
DO $$
DECLARE
    _seed       INT;
    _consistent INT;
    _after      INT;
    _age        INTERVAL;
BEGIN
    IF TO_REGPROC('haf_stats_app.create_context_if_not_exists') IS NULL THEN
        RAISE NOTICE 'context seed/repair: function not installed - skipping.';
        RETURN;
    END IF;

    -- LOCALTIMESTAMP, not now() and not now() AT TIME ZONE 'UTC'. last_active_at is
    -- `timestamp without time zone`, and HAF writes it as `NOW()` (hive_fork_manager's
    -- app_api.sql:211 and app_api_impl.sql:46/605) - an implicit timestamptz -> timestamp
    -- cast, which yields the SESSION's local wall clock, not UTC. LOCALTIMESTAMP is
    -- exactly that same expression, so the two are always comparable.
    -- Getting this wrong is not cosmetic: under TimeZone = America/New_York a context
    -- touched one second ago would age to ~+4h, the idle gate below would pass, and the
    -- destructive section would run against a LIVE processor - taking row locks on
    -- hafd.contexts that the processor writes every iteration, i.e. exactly the "never
    -- block the tip" hazard this gate exists to prevent. East of UTC the age goes negative
    -- and the section would skip for good. It reads correct on a TimeZone = UTC box either
    -- way, which is why it has to be reasoned about rather than tested locally.
    SELECT LOCALTIMESTAMP - c.last_active_at INTO _age
    FROM hafd.contexts AS c WHERE c.name = 'haf_stats';

    IF _age IS NULL OR _age < INTERVAL '5 minutes' THEN
        -- WARNING, not NOTICE: this section is the ONLY coverage of the seed/repair logic,
        -- and in the lane that runs it (regression-test, against the cached stack) the
        -- processor loop keeps last_active_at fresh every iteration, so it is skipped
        -- essentially always. A silent skip means guard 6 reports PASS whether or not the
        -- repair logic still exists - exactly the vacuous pass this file's header says it
        -- prevents. Surfacing it is the honest minimum; genuinely covering the branch needs
        -- a stopped processor (or a throwaway context), which this guard cannot arrange.
        RAISE WARNING 'context seed/repair: NOT EXERCISED - the processor is live (last_active_at age %). This guard therefore did not verify the seed/repair branch of create_context_if_not_exists().', _age;
        RETURN;
    END IF;

    -- MAX(), matching the discipline applied in db/sync_status.sql and db/haf_stats_app.sql:
    -- a bare unaggregated read leaves _seed NULL on an empty hafd.hive_state, and the very
    -- next statement would then fail the NOT NULL on app_status.last_processed_block with a
    -- bare 23502 instead of any message of ours.
    SELECT MAX(hs.consistent_block) INTO _consistent FROM hafd.hive_state AS hs;

    IF _consistent IS NULL OR _consistent < 1 THEN
        RAISE WARNING 'context seed/repair: NOT EXERCISED - the node reports no consistent block (%). There is no sentinel below the head to seed with.', _consistent;
        RETURN;
    END IF;

    -- At or below the node's own consistent block, so the LEAST(..., consistent_block)
    -- clamp inside create_context_if_not_exists() is a no-op on this value. Deriving the
    -- sentinel from _consistent rather than GREATEST(1, ...) matters: with a consistent
    -- block of 0 the old form seeded 1 while the function clamped to 0, and the assertion
    -- below then reported a regression on healthy code.
    _seed := LEAST(4321, _consistent);

    UPDATE haf_stats_app.app_status SET last_processed_block = _seed;

    -- Model the detached node the repair exists for. A cached CI stack is ATTACHED (the
    -- sync job gates on hive.is_app_in_sync, which requires it), and the repair is a
    -- deliberate no-op while attached, so without this the section would prove nothing.
    UPDATE hafd.contexts_attachment SET is_attached = FALSE
     WHERE context_id = (SELECT c.id FROM hafd.contexts AS c WHERE c.name = 'haf_stats');

    UPDATE hafd.contexts SET current_block_num = 0 WHERE name = 'haf_stats';

    SET LOCAL ROLE haf_stats_owner;   -- the role install_app.sh calls it as
    PERFORM haf_stats_app.create_context_if_not_exists();
    RESET ROLE;

    SELECT c.current_block_num INTO _after
    FROM hafd.contexts AS c WHERE c.name = 'haf_stats';

    IF _after <> _seed THEN
        RAISE EXCEPTION 'create_context_if_not_exists() left the HAF context at % on a detached node whose app_status says % - the seed/repair has regressed to the unconditional hard-zero. GET /sync-status would report block 0 on a synced node, and the processor would replay from genesis over populated tables.', _after, _seed;
    END IF;

    RAISE NOTICE 'context seed/repair OK: detached context 0 -> % from app_status.', _after;
END
$$;
ROLLBACK;
