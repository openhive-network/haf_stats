-- Between the two installs: prove install #1 seeded the pointer, then give install #2
-- something to repair. (#84)
--
-- WHY THIS EXISTS. Without it install #2 took create_context_if_not_exists()'s
-- `_ctx_block >= _seed` early return -- "already exists at block 0; nothing to repair" --
-- so it never called hive.app_context_is_attached or hive.app_set_current_block_num.
-- Deleting the whole second install left every assertion in ci_install_verify.sql
-- passing, which is a fair definition of a service that proves nothing.
--
-- 5000 is chosen against ci_setup.sql's hafd.hive_state.consistent_block = 6000: the
-- seed clamps with LEAST(app_status, consistent_block), so 5000 survives the clamp. A
-- value above 6000 would be clamped back down and prove nothing about the repair branch.
--
-- In a file rather than inline in the compose command because the DO block's $$ delimiters
-- collide with Compose's own $-interpolation, and every other step in this lane already
-- loads a file.

DO $seed$
BEGIN
    -- install #1 must have created the context AND seeded it from app_status (0 here).
    -- Asserted at this point rather than at the end, because the whole purpose of the
    -- UPDATE below is to move it -- so the final verify can no longer see this state.
    -- IS DISTINCT FROM, not <>. The scalar subquery returns NULL when install #1 left no
    -- context row at all, `NULL <> 0` is NULL, and plpgsql treats NULL as false -- so the
    -- old form silently ACCEPTED "there is no context". That is not academic: with no row
    -- here, install #2 takes the CREATE branch with _seed = 5000 and produces a context at
    -- 5000 owned by haf_stats_owner, detached and non-forking, which satisfies every
    -- assertion in ci_install_verify.sql. The lane could not tell "#1 created, #2
    -- repaired" from "#1 did nothing, #2 created".
    IF (SELECT c.current_block_num FROM hafd.contexts AS c WHERE c.name = 'haf_stats')
       IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'install #1 left the context at % (NULL = no context row at all). '
                        'It should exist, at block 0.',
            (SELECT c.current_block_num FROM hafd.contexts AS c WHERE c.name = 'haf_stats');
    END IF;

    -- WHAT THIS DOES NOT PROVE, stated because the reverse was claimed once. app_status is
    -- 0 on a fresh install, so install #1's own seed call is app_set_current_block_num(0)
    -- -- the same value hive.app_create_context INSERTs. Deleting that seed from the
    -- CREATE branch of create_context_if_not_exists() is therefore invisible to this lane.
    -- Covering it would need app_status to be non-zero before install #1, which cannot
    -- happen: install #1 is what creates the table. The REPAIR branch's seed is covered,
    -- by the 5000 below.

    UPDATE haf_stats_app.app_status SET last_processed_block = 5000;

    RAISE NOTICE 'seed-repair: context at 0, app_status moved to 5000 -- install #2 must now repair';
END
$seed$;
