-- What a real install_app.sh run must have left behind. (#84)
--
-- Runs after the three installs since reset-app -- install, install-again, install-under-lock --
-- against the stub database (docker/docker-compose-ci-install.yml).
-- psql runs it with ON_ERROR_STOP=1, so a RAISE EXCEPTION here fails the job.
--
-- Two kinds of assertion, and the second is the one that keeps this lane honest:
--
--   * what the INSTALLER produced -- schemas, control tables, the context, grants
--   * what the SHIM did -- because a stub that quietly accepts everything makes this
--     lane green while a real node would fail, and `install_app.sh` exits 0 either way.
--     Asserting only the installer's exit code would test nothing but the shim's
--     willingness to agree.

DO $verify$
DECLARE
    _n          INT;
    _ctx_block  INT;
    _attached   BOOLEAN;
    _forking    BOOLEAN;
    _owner      NAME;
BEGIN
    -- ---------------------------------------------------------------- schemas
    SELECT count(*) INTO _n FROM pg_namespace
     WHERE nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints');
    IF _n <> 3 THEN
        RAISE EXCEPTION 'install: expected 3 haf_stats schemas, found %', _n;
    END IF;

    -- ------------------------------------------------------- the served surface
    SELECT count(DISTINCT p.proname) INTO _n
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'haf_stats_endpoints';
    -- Exact, not a floor: `>= 20` let five endpoints vanish silently, and the count is
    -- printed in the NOTICE below anyway.
    IF _n <> 25 THEN
        RAISE EXCEPTION 'install: % distinct functions in haf_stats_endpoints, expected '
                        '25. IF YOU ADDED OR REMOVED AN ENDPOINT THIS IS THE NUMBER TO '
                        'BUMP -- it is a fixture, not a defect. It is exact rather than '
                        'a floor because `>= 20` once let five endpoints vanish '
                        'silently.', _n;
    END IF;

    -- root() is what PostgREST serves at GET /, and #70 made it read app_config.
    IF to_regprocedure('haf_stats_endpoints.root()') IS NULL THEN
        RAISE EXCEPTION 'install: haf_stats_endpoints.root() is missing';
    END IF;

    -- #44: the exact-RC functions both RC footprint endpoints call. Asserted here because the
    -- endpoint-tests lane loads db/exact_rc.sql itself, so only this lane would notice
    -- install_app.sh no longer loading it - and every rc-footprint call would then fail.
    IF to_regprocedure('haf_stats_app.exact_rc_for_ops(bigint[])') IS NULL
       OR to_regprocedure('haf_stats_app.exact_rc_op_cap()') IS NULL
       OR to_regprocedure('haf_stats_app.rc_cost_available()') IS NULL THEN
        RAISE EXCEPTION 'install: the exact-RC functions from db/exact_rc.sql are missing';
    END IF;

    -- ------------------------------------------------------------ control state
    IF to_regclass('haf_stats_app.app_status') IS NULL THEN
        RAISE EXCEPTION 'install: haf_stats_app.app_status is missing';
    END IF;

    -- #70 added app_config AND writes it (install_app.sh's --swagger-url). One row,
    -- singleton enforced.
    SELECT count(*) INTO _n FROM haf_stats_app.app_config;
    IF _n <> 1 THEN
        RAISE EXCEPTION 'install: app_config holds % rows, expected exactly 1', _n;
    END IF;

    -- app_status must also be a singleton after three installs -- the seed is guarded by
    -- WHERE NOT EXISTS, and a regression there shows up only on a repeat run.
    SELECT count(*) INTO _n FROM haf_stats_app.app_status;
    IF _n <> 1 THEN
        RAISE EXCEPTION 'install: app_status holds % rows after three installs, expected 1', _n;
    END IF;

    -- The #70 regression class this lane was partly built for: step 6 of install_app.sh
    -- writes app_config.swagger_base_url. Asserting only count(*) would pass if that
    -- write silently affected zero rows. No --swagger-url is passed here, so the default
    -- `localhost` is stored and root() rejects it at request time.
    IF (SELECT c.swagger_base_url FROM haf_stats_app.app_config AS c) IS DISTINCT FROM 'localhost' THEN
        RAISE EXCEPTION 'install: app_config.swagger_base_url is %, expected the '
                        'unpassed default -- step 6 did not write it',
                        (SELECT c.swagger_base_url FROM haf_stats_app.app_config AS c);
    END IF;

    -- ---------------------------------------------------------- can_impersonate
    -- The predicate uninstall_app.sh's guard 2 calls directly, and the one the DELETE
    -- policy on hafd.contexts is written in.
    --
    -- Only ONE of the four arms below needs the install to have run: the
    -- haf_admin -> haf_stats_owner edge, which comes from db/builtin_roles.sql:63.
    -- tests/ci_setup.sql creates both app roles before the shim loads, so the others
    -- could have lived in the shim's own probe.
    --
    -- AND BE CLEAR ABOUT WHAT THESE COVER. They test the FUNCTION, not the policies it is
    -- used in. Nothing in this lane enforces the UPDATE or DELETE policy on hafd.contexts
    -- -- see the note in the MR and in docker-compose-ci-install.yml's uninstall service.
    -- The INSERT policy IS enforced, and the owner assertion below is what catches it.
    IF NOT hive.can_impersonate('haf_stats_owner', 'haf_stats_owner') THEN
        RAISE EXCEPTION 'install: can_impersonate is false for the trivial self case';
    END IF;
    IF NOT hive.can_impersonate('haf_admin', 'haf_stats_owner') THEN
        RAISE EXCEPTION 'install: haf_admin cannot impersonate haf_stats_owner. '
                        'db/builtin_roles.sql:63 grants that; without it uninstall_app.sh '
                        'guard 2 refuses and the context can never be removed.';
    END IF;
    -- The arm that distinguishes can_impersonate from pg_has_role. postgres is a
    -- superuser, so pg_has_role(...,'MEMBER') answers TRUE for it against haf_stats_owner
    -- while HAF's function answers FALSE. Without this, a swap back to pg_has_role passes
    -- every other check in this file.
    IF hive.can_impersonate('postgres', 'haf_stats_owner') THEN
        RAISE EXCEPTION 'install: can_impersonate says the superuser can impersonate '
                        'haf_stats_owner. That is pg_has_role behaviour; HAF walks '
                        'pg_auth_members and has no superuser arm.';
    END IF;
    IF hive.can_impersonate('haf_stats_user', 'haf_stats_owner') THEN
        RAISE EXCEPTION 'install: haf_stats_user can impersonate haf_stats_owner. That '
                        'role backs an UNAUTHENTICATED PostgREST connection, and the '
                        'UPDATE/DELETE policies on hafd.contexts are written in exactly '
                        'this predicate -- so it could rewind or drop the HAF context.';
    END IF;

    -- db/builtin_roles.sql:86, the one hive.* EXECUTE grant this lane can actually
    -- defend. haf_stats_user is NOINHERIT and belongs to no group, so the PUBLIC revoke
    -- in ci_haf_stub.sql leaves it with nothing unless :86 runs.
    --
    -- Its SIBLING AT :81 IS NOT DEFENDABLE, and saying so here is the point:
    -- haf_stats_owner inherits EXECUTE through hive_applications_group (ci_setup.sql
    -- creates hive_applications_owner_group IN ROLE hive_applications_group;
    -- db/builtin_roles.sql:53-54 grants it to the owner), so deleting :81 changes
    -- nothing -- here OR on a node, where HAF grants the group too. An earlier commit
    -- message claimed the PUBLIC revoke made both falsifiable. It made one.
    IF NOT has_function_privilege('haf_stats_user', 'hive.is_instance_ready()', 'EXECUTE') THEN
        RAISE EXCEPTION 'install: haf_stats_user cannot EXECUTE hive.is_instance_ready(). '
                        'db/builtin_roles.sql:86 grants that, and without it GET '
                        '/sync-status answers 503 on a healthy node.';
    END IF;

    -- ------------------------------------------------------------------- grants
    -- The anon role must be able to execute the endpoints and read what they read.
    -- A missing grant is a 401/permission-denied on a live node, not an install failure.
    -- NOT asserting EXECUTE on root(): PostgreSQL grants EXECUTE to PUBLIC by default for
    -- every function and nothing here revokes it, so that check passes no matter what the
    -- installer does. It read like coverage and was none.
    IF NOT has_table_privilege('haf_stats_user', 'haf_stats_app.app_config', 'SELECT') THEN
        RAISE EXCEPTION 'install: haf_stats_user cannot SELECT app_config (#70 would 500)';
    END IF;
    IF NOT has_schema_privilege('haf_stats_user', 'haf_stats_endpoints', 'USAGE') THEN
        RAISE EXCEPTION 'install: haf_stats_user has no USAGE on haf_stats_endpoints';
    END IF;

    -- --------------------------------------------------------------- the context
    -- This is the step the stub lane could never reach, and the reason for the shim.
    SELECT c.current_block_num, c.is_attached, c.is_forking, c.owner
      INTO _ctx_block, _attached, _forking, _owner
      FROM hafd.contexts AS c
     WHERE c.name = 'haf_stats';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'install: no HAF context named haf_stats was created';
    END IF;

    -- 5000, not 0. install #1 seeds 0 (asserted by the seed-repair step); that step then
    -- moves app_status to 5000, so install #2 takes the REPAIR branch and calls
    -- hive.app_set_current_block_num. 5000 is therefore a value only that call can have
    -- produced -- where 0 was also the shim's INSERT default, making the old assertion
    -- true whether or not the installer seeded anything.
    --
    -- This assertion earned its place on the lane's third run: ci_setup.sql pre-seeds a
    -- haf_stats context at block 6000, so the installer was taking its "already exists"
    -- branch and never calling hive.app_create_context at all. The lane was green-adjacent
    -- while covering none of context creation. docker-compose-ci-install.yml now deletes
    -- that row -- and seed-repair then moved app_status to 5000, which is why the
    -- expectation is 5000 and not 0. (An earlier version of this line still said 0, three
    -- lines above an assertion on 5000.) Both halves matter: the delete is what makes
    -- install #1 create, and seed-repair is what makes install #2 repair.
    IF _ctx_block <> 5000 THEN
        RAISE EXCEPTION 'install: context pointer is %, expected 5000. install #2 should '
                        'have taken the repair branch and moved it to match app_status.',
                        _ctx_block;
    END IF;

    -- THE CHECK THAT KEEPS THE PRIVILEGE MODEL ALIVE. An earlier revision selected the
    -- owner, printed it in the NOTICE below, and never compared it -- which left the
    -- lane's central claim undefended.
    --
    -- haf_stats_app.create_context_if_not_exists() is plain LANGUAGE plpgsql with no
    -- SECURITY DEFINER, so install_app.sh's `SET ROLE haf_stats_owner` is the ONLY thing
    -- forcing the INSERT through the grants and ownership-scoped RLS in ci_haf_stub.sql.
    -- Drop that SET ROLE, or give the function SECURITY DEFINER, and the install runs as
    -- the connecting superuser -- which OWNS hafd.contexts, and RLS there is ENABLE but
    -- not FORCE, so the owner bypasses every policy. The context is created with the
    -- wrong owner and every other assertion here still passes.
    --
    -- WHY THIS IS WORSE THAN IT LOOKS. An earlier version of this comment said a real
    -- node would then fail with `permission denied for table contexts`. It would NOT --
    -- measured on the live node by a parallel review: hafd.contexts is owned by
    -- haf_admin, relrowsecurity = t, relforcerowsecurity = f. So the node's installer
    -- ALSO bypasses RLS as the owner, silently creates a mis-owned context, and the
    -- damage surfaces much later as the RLS loop in hive.app_next_block, where the
    -- processor cannot see its own context row.
    --
    -- So this assertion is the single most valuable line in the lane, and for a stronger
    -- reason than the one first given: on a node the failure it catches is SILENT, not
    -- loud. (Run 4 of this lane's failure table was loud only because in CI the table is
    -- owned by postgres while the install had already SET ROLE to a non-owner.)
    IF _owner <> 'haf_stats_owner' THEN
        RAISE EXCEPTION 'install: the context is owned by %, not haf_stats_owner. The '
                        'installer did not SET ROLE, so the grants and RLS this lane '
                        'exists to exercise were bypassed -- it ran as a superuser that '
                        'cannot fail.', _owner;
    END IF;

    -- Both of these are calls the installer makes explicitly, and both are invisible
    -- unless something checks the state afterwards.
    IF _forking THEN
        RAISE EXCEPTION 'install: hive.app_context_set_non_forking was not applied -- HAF '
                        'would rewind haf_stats tables on a fork';
    END IF;
    IF _attached THEN
        RAISE EXCEPTION 'install: the context was left ATTACHED; install detaches so the '
                        'block pointer can be seeded';
    END IF;

    RAISE NOTICE 'install verified: 3 schemas, % endpoint functions, context at block % '
                 '(detached, non-forking, owner %)',
                 (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
                   WHERE ns.nspname = 'haf_stats_endpoints'), _ctx_block, _owner;
END
$verify$;

-- ---------------------------------------------------------------------------
-- The API statement budget is set cluster-wide on haf_stats_user. (#94)
--
-- The VALUES are proven by tests/ci_login_timeout.sql, which LOGS IN as haf_stats_user
-- (must get 30s) and as haf_stats_owner (must get 0) -- a superuser session cannot prove
-- either, because role settings are not applied on SET ROLE. This block covers the one
-- thing a login cannot see: that the setting is on the role for EVERY database
-- (setdatabase = 0), not scoped to whichever database this lane happens to use.
--
-- It asserts only that such an entry EXISTS, deliberately not its spelling: 30000,
-- '30000ms' and '30s' are the same setting but are stored as written, and comparing the
-- stored text made an equivalent value fail here while the login probe passed -- measured.
DO $timeout$
DECLARE
    _cluster_wide INT;
    _all_rows     TEXT;
BEGIN
    SELECT count(*) INTO _cluster_wide
      FROM pg_db_role_setting AS s
      JOIN pg_roles AS r ON r.oid = s.setrole
     CROSS JOIN LATERAL unnest(s.setconfig) AS c
     WHERE r.rolname = 'haf_stats_user' AND s.setdatabase = 0
       AND c LIKE 'statement_timeout=%';

    IF _cluster_wide = 0 THEN
        SELECT string_agg(coalesce(d.datname, '<all databases>') || ': '
                          || array_to_string(s.setconfig, ', '), '; ')
          INTO _all_rows
          FROM pg_db_role_setting AS s
          JOIN pg_roles AS r ON r.oid = s.setrole
          LEFT JOIN pg_database AS d ON d.oid = s.setdatabase
         WHERE r.rolname = 'haf_stats_user';
        RAISE EXCEPTION 'install: haf_stats_user has no statement_timeout for all databases '
                        '(its settings: %). db/builtin_roles.sql sets one; without it the API '
                        'runs uncapped wherever PostgREST logs in as haf_stats_user.',
                        coalesce(_all_rows, 'none');
    END IF;

    -- CI-ONLY: passwords, so the verify service can LOG IN as each role for
    -- tests/ci_login_timeout.sql. This lane's postgres uses scram for TCP and neither role
    -- has one. It is a throwaway database, and both roles are dropped at uninstall.
    ALTER ROLE haf_stats_user PASSWORD 'ci-login-probe';
    ALTER ROLE haf_stats_owner PASSWORD 'ci-login-probe';

    RAISE NOTICE 'install verified: haf_stats_user has a statement_timeout for all databases';
END
$timeout$;

-- ---------------------------------------------------------------------------
-- The shim is not a rubber stamp.
--
-- Everything above would also pass against a shim whose functions did nothing at all,
-- provided the tables happened to look right. These arms prove the shim still ENFORCES
-- the rules install_app.sh depends on, so a future "simplification" of it cannot quietly
-- turn this lane into a no-op. Run inside a rolled-back transaction: the context created
-- by the install must survive for anything that looks at it later.
-- ---------------------------------------------------------------------------

BEGIN;

DO $shim$
BEGIN
    -- A second create must be refused; install_app.sh only calls it guarded by
    -- app_context_exists, so a permissive shim would hide a caller that lost the guard.
    BEGIN
        PERFORM hive.app_create_context('haf_stats'::hafd.context_name, 'haf_stats_app',
            ARRAY[hafd.live_stage()]::hafd.application_stages);
        RAISE EXCEPTION 'shim: app_create_context accepted a DUPLICATE context';
    EXCEPTION
        WHEN SQLSTATE 'P0001' THEN
            IF SQLERRM LIKE '%accepted a DUPLICATE%' THEN RAISE; END IF;
    END;

    -- Moving the pointer on an ATTACHED context must be refused: that is exactly why
    -- create_context_if_not_exists() detaches first, and why its repair branch bails
    -- when the processor holds the context.
    PERFORM hive.app_context_attach('haf_stats');
    BEGIN
        PERFORM hive.app_set_current_block_num('haf_stats', 1);
        RAISE EXCEPTION 'shim: app_set_current_block_num accepted an ATTACHED context';
    EXCEPTION
        WHEN SQLSTATE 'P0001' THEN
            IF SQLERRM LIKE '%accepted an ATTACHED%' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'shim enforcement verified: duplicate create and attached-seed both refused';
END
$shim$;

-- The upgrade branch of the guarded migrations actually ran. (#96)
--
-- tests/ci_break_schema.sql undid all 17 guarded upgrades before install-again: twelve columns
-- dropped, rc_estimated put back, the pre-canonical income/expense CHECK restored NOT VALID, and
-- one 'income' and one 'incoming' row written. Without break-schema only one of the 14 DDL strings
-- (comment_registry.community's ADD COLUMN) ever ran in CI, so a typo in any other, or a catalog
-- test that is wrongly always-FALSE, shipped green. install-under-lock then proves the opposite
-- direction -- that no guard fires once everything is applied (tests/ci_install_no_upgrade.sh).
DO $upgraded$
DECLARE
    _wrong TEXT;
    _def TEXT;
BEGIN
    SELECT string_agg(format('%s.%s', t.rel, t.col), ', ') INTO _wrong
    FROM (
        VALUES
        ('haf_stats_backend.active_users_daily', 'ops', TRUE),
        ('haf_stats_backend.comment_registry', 'community', TRUE),
        ('haf_stats_backend.account_custom_json_daily', 'op_bytes', TRUE),
        ('haf_stats_backend.account_custom_json_daily', 'rc_estimated', FALSE),
        ('haf_stats_backend.account_custom_json_daily', 'rc_exact', TRUE),
        ('haf_stats_backend.network_op_daily', 'rc_exact', TRUE),
        ('haf_stats_backend.network_custom_json_daily', 'rc_exact', TRUE),
        ('haf_stats_backend.account_cohort_retention', 'eligible_at_7d', TRUE),
        ('haf_stats_backend.account_cohort_retention', 'eligible_at_30d', TRUE),
        ('haf_stats_backend.account_cohort_retention', 'eligible_at_90d', TRUE),
        ('haf_stats_backend.author_cohort_retention', 'eligible_at_30d', TRUE),
        ('haf_stats_backend.author_cohort_retention', 'eligible_at_90d', TRUE),
        ('haf_stats_backend.author_cohort_retention', 'eligible_at_180d', TRUE)
    ) AS t (rel, col, present)
    WHERE EXISTS (
        SELECT 1 FROM pg_attribute AS a
        WHERE a.attrelid = t.rel::REGCLASS AND a.attname = t.col AND NOT a.attisdropped
    ) <> t.present;
    IF _wrong IS NOT NULL THEN
        RAISE EXCEPTION 'install: the guarded upgrades did not repair what break-schema undid: %', _wrong;
    END IF;

    -- ... and break-schema really did undo them on THIS database: every table it dropped a column
    -- from still carries the dropped attribute. Without this, a lane where break-schema never ran
    -- would satisfy every assertion above.
    SELECT string_agg(t.rel, ', ') INTO _wrong
    FROM (
        VALUES
        ('haf_stats_backend.active_users_daily'),
        ('haf_stats_backend.comment_registry'),
        ('haf_stats_backend.account_custom_json_daily'),
        ('haf_stats_backend.network_op_daily'),
        ('haf_stats_backend.network_custom_json_daily'),
        ('haf_stats_backend.account_cohort_retention'),
        ('haf_stats_backend.author_cohort_retention')
    ) AS t (rel)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_attribute AS a WHERE a.attrelid = t.rel::REGCLASS AND a.attisdropped
    );
    IF _wrong IS NOT NULL THEN
        RAISE EXCEPTION 'install: no dropped column on % - break-schema did not run against this database', _wrong;
    END IF;

    SELECT pg_get_constraintdef(c.oid) INTO _def
    FROM pg_constraint AS c
    WHERE c.conrelid = 'haf_stats_backend.account_financial_daily'::REGCLASS
      AND c.conname = 'account_financial_daily_direction_check'
      AND c.convalidated;
    IF _def IS NULL THEN
        RAISE EXCEPTION 'install: account_financial_daily has no VALIDATED direction CHECK - the guarded constraint swap did not run';
    END IF;
    IF _def NOT LIKE '%''incoming''%''outgoing''%' OR _def LIKE '%''income''%' THEN
        RAISE EXCEPTION 'install: account_financial_daily still carries a pre-canonical direction CHECK: %', _def;
    END IF;

    IF EXISTS (
        SELECT 1 FROM haf_stats_backend.account_financial_daily
        WHERE account_id = 900901 AND direction = 'income'
    ) THEN
        RAISE EXCEPTION 'install: the pre-canonical income row break-schema wrote is still there - the guarded DELETE did not run';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM haf_stats_backend.account_financial_daily
        WHERE account_id = 900901 AND direction = 'incoming'
    ) THEN
        RAISE EXCEPTION 'install: the canonical incoming row break-schema wrote is gone - the guarded DELETE removed a row it must keep';
    END IF;

    RAISE NOTICE 'install verified: install-again re-applied all 17 guarded upgrades (12 columns back, rc_estimated gone, canonical CHECK validated, the income row deleted and the incoming row kept)';
END
$upgraded$;

-- install-again removed the group memberships break-schema gave haf_stats_user. (#88)
--
-- One MEMBER check covers both arms: it is transitive, and hive_applications_owner_group is
-- itself a member of hive_applications_group here, so an edge left to either group fails it.
--
-- Both membership AND the privilege: MEMBER catches a NOINHERIT member that could still
-- SET ROLE into the group; has_table_privilege catches the TRUNCATE itself arriving some
-- other way. Without the revoke in db/builtin_roles.sql, the first check fails here.
DO $anon$
BEGIN
    IF pg_has_role('haf_stats_user', 'hive_applications_group', 'MEMBER') THEN
        RAISE EXCEPTION 'install: haf_stats_user is still a member of hive_applications_group - db/builtin_roles.sql did not remove the edge break-schema gave it, so the PostgREST anon role keeps TRUNCATE on hafd.contexts';
    END IF;
    IF has_table_privilege('haf_stats_user', 'hafd.contexts', 'TRUNCATE') THEN
        RAISE EXCEPTION 'install: haf_stats_user can still TRUNCATE hafd.contexts';
    END IF;
    RAISE NOTICE 'install verified: the installer removed haf_stats_user from hive_applications_group';
END
$anon$;

-- apply_schema_migration hands back the caller's lock_timeout. (#96)
--
-- It sets 3 s for each attempt with set_config(..., TRUE), which would otherwise last until the
-- END of the caller's transaction: every install caller is a single autocommit statement today,
-- but a caller inside a larger transaction would give everything after it a 3 s lock_timeout.
DO $restore$
BEGIN
    PERFORM set_config('lock_timeout', '7s', TRUE);
    PERFORM haf_stats_app.apply_schema_migration(TRUE, 'SELECT 1', 'ci probe: lock_timeout hand-back');
    IF current_setting('lock_timeout') <> '7s' THEN
        RAISE EXCEPTION 'install: apply_schema_migration left lock_timeout at % for the rest of its caller''s transaction (expected the caller''s 7s)',
            current_setting('lock_timeout');
    END IF;
    RAISE NOTICE 'install verified: apply_schema_migration restored the caller''s lock_timeout';
END
$restore$;

ROLLBACK;
