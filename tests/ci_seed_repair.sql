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
DECLARE
    _resets INT;
BEGIN
    -- DID reset-app RUN? Nothing else here can tell: without it `install` takes the
    -- "already exists" branch and every later check still sees the right owner, schemas
    -- and pointer, so the MERGE TARGET would be satisfying assertions meant for the
    -- commit under test.
    --
    -- ci_reset_app.sql inserts one row per run and runs exactly twice -- db-setup, then
    -- reset-app. Two rows is therefore positive evidence that the second call happened;
    -- one row means the reset-app service is gone.
    SELECT count(*) INTO _resets FROM public.ci_reset_marker;
    IF _resets <> 2 THEN
        RAISE EXCEPTION 'tests/ci_reset_app.sql ran % time(s), expected 2 (db-setup, then '
                        'reset-app). With only db-setup''s call, install-baseline creates '
                        'the schemas and `install` takes the "already exists" branch -- so '
                        'the merge target, not this commit, satisfies every assertion about '
                        'what an install CREATES.', _resets;
    END IF;

    -- install #1 must have created the context AND seeded it from app_status (0 here).
    -- Asserted at this point rather than at the end, because the whole purpose of the
    -- UPDATE below is to move it -- so the final verify can no longer see this state.
    -- IS DISTINCT FROM, not <>. With no context row the scalar subquery is NULL, `NULL
    -- <> 0` is NULL, and plpgsql treats that as false -- so `<>` silently ACCEPTS "there
    -- is no context". Then install #2 takes the CREATE branch with _seed = 5000 and
    -- produces a context that satisfies every assertion in ci_install_verify.sql, and the
    -- lane cannot tell "#1 created, #2 repaired" from "#1 did nothing, #2 created".
    IF (SELECT c.current_block_num FROM hafd.contexts AS c WHERE c.name = 'haf_stats')
       IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'install #1 left the context at % (NULL = no context row at all). '
                        'It should exist, at block 0.',
            (SELECT c.current_block_num FROM hafd.contexts AS c WHERE c.name = 'haf_stats');
    END IF;

    -- WHAT THIS DOES NOT PROVE. app_status is 0 on a fresh install, so install #1's seed
    -- call is app_set_current_block_num(0) -- the same value hive.app_create_context
    -- INSERTs. Deleting that seed from the CREATE branch is therefore invisible here, and
    -- cannot be covered without a non-zero app_status before install #1, which the install
    -- itself creates. The REPAIR branch's seed is covered, by the 5000 below.

    UPDATE haf_stats_app.app_status SET last_processed_block = 5000;

    RAISE NOTICE 'seed-repair: context at 0, app_status moved to 5000 -- install #2 must now repair';
END
$seed$;
