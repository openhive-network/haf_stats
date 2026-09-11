-- What a real uninstall_app.sh run must have removed. (#84)
--
-- Runs after the teardown in docker/docker-compose-ci-install.yml. NOTHING IN CI HAD
-- EVER RUN uninstall_app.sh AGAINST A DATABASE before this lane -- which is the whole
-- point, and is a stronger statement than the one an earlier version of this comment
-- made ("the only references anywhere were three --help/argument smoke assertions in
-- docker-build"). That was false: tests/unit/test_uninstall_app.py holds 51 tests and
-- tests/unit/test_script_arguments.py parametrises over the script in three more places,
-- all run by shell-tests. They stub psql, so none of them reaches a server.
--
-- uninstall_app.sh does run scripts/uninstall_verify.sql itself, but that path is
-- PERMISSIVE by design: the destructive steps push past errors the way upstream teardowns
-- do, and the script reports survivors rather than failing on them. So this asserts
-- independently, and covers the one thing uninstall_verify.sql structurally cannot --
-- hafd.contexts, which it may not name in a FROM clause because PostgreSQL resolves
-- relation names at parse time, before any predicate could guard them.

DO $gone$
DECLARE
    _survivors TEXT;
    _ctx       INT;
BEGIN
    SELECT string_agg(n.nspname, ', ' ORDER BY n.nspname) INTO _survivors
      FROM pg_namespace AS n
     WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints');

    IF _survivors IS NOT NULL THEN
        RAISE EXCEPTION 'uninstall: these schemas survived the teardown: %', _survivors;
    END IF;

    -- The context is the half uninstall_verify.sql cannot check, and the half that
    -- matters to a co-located node: a leftover row keeps HAF feeding blocks to an app
    -- that no longer has a schema to put them in.
    SELECT count(*) INTO _ctx FROM hafd.contexts WHERE name = 'haf_stats';
    IF _ctx <> 0 THEN
        RAISE EXCEPTION 'uninstall: the HAF context haf_stats survived the teardown';
    END IF;

    -- STEP 5's ROLE DROP, which nothing asserted until now. uninstall_app.sh:515-545
    -- runs DROP OWNED BY + DROP ROLE for both app roles; delete that whole block and
    -- every other assertion in this file still passed. Roles are CLUSTER-wide, so a
    -- leftover is exactly the kind of damage a co-located node inherits -- and it is
    -- invisible to uninstall_verify.sql, which cannot name a role it may have dropped.
    SELECT string_agg(r.rolname, ', ' ORDER BY r.rolname) INTO _survivors
      FROM pg_roles AS r
     WHERE r.rolname IN ('haf_stats_owner', 'haf_stats_user');

    IF _survivors IS NOT NULL THEN
        RAISE EXCEPTION 'uninstall: these roles survived the teardown: %. They are '
                        'cluster-wide, so they outlive this database.', _survivors;
    END IF;

    -- TEARDOWN SCOPE. With one context row in the table, "haf_stats is gone" and
    -- "hafd.contexts was emptied" are indistinguishable -- an unscoped
    -- DELETE FROM hafd.contexts in hive.app_remove_context, or a widened
    -- HAF_STATS_SCHEMAS/HAF_STATS_ROLES in uninstall_app.sh, would read as success here
    -- while a real node lost every other app's registration. db-setup plants a decoy
    -- owned by a different role (so uninstall_app.sh's own guard cannot claim it), and
    -- this is the assertion that makes the blast radius observable.
    IF NOT EXISTS (SELECT 1 FROM hafd.contexts WHERE name = 'ci_bystander_app') THEN
        RAISE EXCEPTION 'uninstall: the bystander context ci_bystander_app is GONE. The '
                        'teardown is not scoped to haf_stats -- on a shared node this '
                        'would have unregistered another application.';
    END IF;

    RAISE NOTICE 'uninstall verified: schemas, roles and the HAF context are gone, and the bystander context survived';
END
$gone$;
