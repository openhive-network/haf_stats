-- Register haf_stats in the HAF application registry (haf#341), so the generic
-- block-processing driver can run it and so other applications can declare a
-- dependency on it. Loaded by install_app.sh step 5b: after
-- create_context_if_not_exists() (hive.app_register requires the context to exist)
-- and after db/haf_stats_app.sql, which defines haf_stats_app.process_blocks --
-- the entry procedure app_register resolves with to_regprocedure().
--
-- TOLERANT BY DESIGN. Against a HAF without the registry -- pre-haf#341, i.e. every
-- 1.28.x, which is what this repo's images pin today -- it warns and returns, so the
-- install still succeeds. scripts/process_blocks.sh probes the registry before
-- exec'ing the driver, so such a node keeps running the legacy CALL main() loop.
-- The two halves have to agree: a skipped registration with a driver that runs
-- anyway is an indefinite crash loop (hive/haf_fyp!51).
--
-- NO DEPENDENCIES ARE DECLARED, and that is a decision rather than an omission.
-- haf_stats#85 (this migration's own ticket) asserted that haf_stats reads
-- hivemind-derived data and therefore wanted hive.app_dependencies_block_limit to
-- gate it behind hivemind. It does not:
--
--   * no `hivemind` occurrence under db/ is a READ of hivemind state -- they are
--     comments describing behaviour this app re-implements, plus display strings in
--     db/seed_data.sql's DApp registry ('Hivemind Follow' and friends). An earlier
--     wording here claimed they were all comments, which a case-sensitive grep had
--     made look true;
--   * communities are derived here from raw custom_json operations into
--     haf_stats_backend.community_registry (db/process_community_registry.sql);
--   * outside tests/, hivemind_app is read only by the hivemind content source
--     (db/process_content_stats.sql), when a deployment selects it. That source waits
--     for hivemind itself, and only for content stats (wait_for_hivemind); a declared
--     dependency would hold back every processor instead. Under tests/, the parity
--     oracle reads it with dynamic SQL so it degrades when hivemind is absent.
--
-- Declaring the dependency anyway would clamp every delivered range to hivemind's
-- position and stall ingestion whenever hivemind stalls -- silently, because
-- hive.app_next_iteration commits the last_active_at heartbeat BEFORE it applies the
-- dependency limit, so docker/block-processing-healthcheck.sh would go on reporting
-- healthy at zero progress. haf_stats would get no correctness back in exchange.
--
-- SET ROLE, as step 5 does for the context itself: the registry row should be owned
-- by the same role that owns the context, not by whoever ran the installer.
SET ROLE haf_stats_owner;

DO $$
DECLARE
    _registry_available BOOLEAN;
BEGIN
    -- THREE CHECKS, because each one alone has a hole.
    --
    -- to_regprocedure('hive.app_register(text, hive.contexts_group, text, text)') on its
    -- own is the sibling form, and it RAISES rather than returning NULL when it cannot
    -- resolve the argument types: measured on PostgreSQL 14, a missing `hive` schema
    -- gives 3F000 and a missing hive.contexts_group gives 42704, because the types are
    -- resolved before the function can be declared missing. Under ON_ERROR_STOP that
    -- aborts the install instead of taking the warning below.
    --
    -- That hazard is narrower than it looks: PostgreSQL 16 made to_regprocedure
    -- soft-erroring, and both HAFs in this stack are newer -- the node runs 17.9, where
    -- all three cases return NULL (verified). It bites only against a PG <= 15 server,
    -- e.g. docker-compose-ci.yml's postgres:14-alpine stub, which defines the domain in
    -- tests/ci_haf_stub.sql anyway. So this is defence, not a live bug.
    --
    -- A bare pg_proc name lookup fixes the raising but trades it for a worse hole: it
    -- matches ANY hive.app_register regardless of arity or kind, so a signature change
    -- upstream would pass the guard and then fail the PERFORM -- aborting the install,
    -- which is the outcome all of this exists to avoid. to_regnamespace/to_regtype never
    -- raise for a missing name, so guarding the to_regprocedure call with them keeps the
    -- tolerance AND detects drift.
    -- Sequenced, not a single OR chain: PostgreSQL does not guarantee the evaluation
    -- order of a boolean expression's subexpressions (the docs say so, and recommend CASE
    -- when order matters), and here the order IS the point -- to_regprocedure must not be
    -- reached until the schema and the type are known to exist, or it raises on the very
    -- servers this tolerance exists for.
    _registry_available := to_regnamespace('hive') IS NOT NULL
                           AND to_regtype('hive.contexts_group') IS NOT NULL;

    IF _registry_available THEN
        _registry_available :=
            to_regprocedure('hive.app_register(text, hive.contexts_group, text, text)') IS NOT NULL;
    END IF;

    IF NOT _registry_available THEN
        RAISE WARNING 'HAF application registry not usable here: hive.app_register(text, hive.contexts_group, text, text) did not resolve. Either this HAF predates haf#341, or that signature changed upstream -- check which before assuming the version. haf_stats stays unregistered and block processing keeps using the legacy CALL main() loop';
        RETURN;
    END IF;

    -- Idempotent in the sense that matters here: re-running the installer against an
    -- already-registered app is the normal upgrade path (INSERT ... ON CONFLICT DO UPDATE).
    --
    -- Wrapped, because hive.app_register raises on states this repo knows occur and does
    -- not otherwise detect: a `haf_stats` context owned by someone other than
    -- haf_stats_owner ('role % does not own all of its contexts', and the UPDATE arm is
    -- policy-checked against the EXISTING row's owner), or a context already claimed by an
    -- embedding application. scripts/uninstall_app.sh documents the owner mismatch as real
    -- and undetected at install time. Under psql's ON_ERROR_STOP an uncaught raise there
    -- would fail the whole install -- so registration degrades to a warning, exactly like
    -- the registry-absent case above, and scripts/process_blocks.sh's probe then keeps the
    -- node on the legacy loop.
    BEGIN
        PERFORM hive.app_register(
            'haf_stats',
            ARRAY['haf_stats']::hive.contexts_group,
            'haf_stats_app.process_blocks'
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'haf_stats could not be registered in the HAF application registry (% - %); it stays on the legacy CALL main() loop', SQLSTATE, SQLERRM;
        RETURN;
    END;

    -- Confirmed, not assumed. hive.app_register has a branch that RAISE NOTICEs and
    -- RETURNS WITHOUT RAISING when the contexts already belong to an embedding
    -- application, so the EXCEPTION block above never fires and this would otherwise
    -- announce a registration that did not happen.
    IF EXISTS (SELECT 1 FROM hafd.applications WHERE name = 'haf_stats') THEN
        RAISE NOTICE 'haf_stats registered in the HAF application registry (entry procedure haf_stats_app.process_blocks)';
    ELSE
        RAISE WARNING 'hive.app_register did not register haf_stats (its contexts are most likely claimed by an embedding application); it stays on the legacy CALL main() loop';
    END IF;
END;
$$;

RESET ROLE;
