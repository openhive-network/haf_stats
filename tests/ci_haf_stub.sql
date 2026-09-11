-- A minimal HAF shim, so the REAL scripts/install_app.sh can run against a plain
-- PostgreSQL. (#84)
--
-- WHY THIS EXISTS. Every lane that runs `install_app.sh` needs a REPLAYED HAF: `sync`
-- starts haf-stats-setup, and `reinstall-test` compose-runs it but is gated behind sync.
-- Measured, `sync` runs 374.5-566.2s (6.2-9.4 min) across the six successful runs in
-- the project's last 100 jobs, on top of find_haf_image and
-- prepare_haf_data. Everything cheaper tests something adjacent: the unit suite stubs
-- psql, so it cannot fail the way PostgreSQL does, and the `endpoint-tests` lane loads
-- the SQL files directly without the installer. That is how a `psql -c` bug no unit test
-- could see cost two red sync pipelines.
--
-- tests/ci_setup.sql stubs enough HAF for the files the endpoint-tests lane loads:
-- hafd.contexts, hafd.hive_state, hafd.operation_types, hafd.blocks,
-- hive.get_required_authorities, hive.is_instance_ready. It is NOT enough for a full
-- install -- it says so itself ("Roles (simplified - no haf_admin / HAF group
-- dependencies)"), and that lane never attempts db/haf_stats_app.sql or
-- db/builtin_roles.sql at all. What is missing is the context lifecycle API, the HAF
-- roles, and seven type objects (hafd.context_name / stage_name / blocks_distance /
-- blocks_count, hive.blocks_range / stage / application_stages) -- everything
-- install_app.sh needs that no HAF-less lane provides.
--
-- WHAT THIS IS NOT. It is not a HAF emulator. It implements the eight calls
-- create_context_if_not_exists() makes, plus three more -- app_context_attach,
-- app_get_current_block_num and app_remove_context -- which the shim's own smoke test,
-- tests/ci_install_verify.sql and the teardown step use, plus hive.can_impersonate,
-- which scripts/uninstall_app.sh calls directly. TWELVE functions, and the
-- invariants they reason about. A processor cannot run against it: there is no block
-- streaming here, only context bookkeeping.
--
-- ON FIDELITY. A shim that accepts everything makes the lane green while the real thing
-- would fail, which is worse than no lane. So each function below ENFORCES the rule the
-- caller depends on, and tests/ci_install_verify.sql asserts the shim's own behaviour as
-- well as the installer's -- otherwise a stub that quietly does nothing looks identical
-- to a successful install.

-- ---------------------------------------------------------------------------
-- Roles HAF provides
--
-- ci_setup.sql creates the app's own roles and the two hive_applications groups, but not
-- haf_admin -- HAF's superrole, which db/builtin_roles.sql:63 grants haf_stats_owner to.
-- The first run of this lane failed there, which is the gap it exists to find: on a real
-- node HAF has already created it, so nothing in this repo ever noticed the dependency.
--
-- NOLOGIN is enough: the install only ever GRANTs INTO this role, it never connects as
-- it. Kept deliberately unprivileged rather than SUPERUSER so the lane cannot pass by
-- being allowed to do anything.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_admin') THEN
        CREATE ROLE haf_admin NOLOGIN;
    END IF;
    -- Not referenced as a ROLE anywhere in this repo -- every `hived` hit is prose about
    -- the daemon. Created anyway, cheaply, because HAF does create it and a future grant
    -- that assumes it would fail here in a way that is tedious to trace back.
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hived') THEN
        CREATE ROLE hived NOLOGIN;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- HAF's domain is `TEXT NOT NULL CONSTRAINT non_empty_context CHECK (LENGTH(VALUE) != 0)`
-- (hive/haf context_rewind/data_schema.sql). There is no length rule to model -- an
-- earlier version of this comment claimed one, and contradicted the inner comment below.
--
-- NOT MODELLED, deliberately: HAF also rejects names outside [a-zA-Z0-9_], but it does so
-- in hive.context_create (rewind_api.sql), not in the domain. The installer hardcodes
-- 'haf_stats', so the only way to reach that rule from this repo is uninstall's
-- ${HAF_STATS_CONTEXT}; putting the check on the DOMAIN here would place it somewhere HAF
-- does not have it, which is its own kind of infidelity.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hafd' AND t.typname = 'context_name') THEN
        -- TEXT, not NAME. NAME truncates at 63 bytes BEFORE a domain CHECK would run,
        -- so it silently shortens a name a node stores verbatim.
        CREATE DOMAIN hafd.context_name AS TEXT NOT NULL CHECK (length(VALUE) > 0);
    END IF;
END
$$;

-- haf_stats_app.main() DECLAREs a variable of this type, and plpgsql resolves declared
-- types at CREATE time -- so without it db/haf_stats_app.sql cannot even load. That file
-- had never been loaded in a HAF-LESS lane: install_app.sh:184 loads it unconditionally,
-- so sync and reinstall-test always have -- but only ever against a real HAF, where the
-- type exists. The endpoint-tests lane hand-creates app_status and app_version in
-- ci_setup.sql instead of running that file, so the dependency was invisible to anything
-- cheap.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hive' AND t.typname = 'blocks_range') THEN
        CREATE TYPE hive.blocks_range AS (
            first_block INT,
            last_block  INT
        );
    END IF;
END
$$;

-- HAF builds its stage type out of CHECKed domains, so an invalid stage is rejected at
-- CAST time, before app_create_context is entered. Modelled: without them
-- hive.stage('MASSIVE PROCESSING', ...) (a space), a zero batch size or a negative
-- distance all pass here and are refused by a node.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hafd' AND t.typname = 'stage_name') THEN
        CREATE DOMAIN hafd.stage_name AS TEXT CHECK (VALUE ~ '^[A-Za-z0-9_]+$');
    END IF;
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hafd' AND t.typname = 'blocks_distance') THEN
        CREATE DOMAIN hafd.blocks_distance AS INTEGER CHECK (VALUE >= 0);
    END IF;
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hafd' AND t.typname = 'blocks_count') THEN
        CREATE DOMAIN hafd.blocks_count AS INTEGER CHECK (VALUE > 0);
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hive' AND t.typname = 'stage') THEN
        -- Field names are HAF's (hive/haf application_loop/stages.sql), not invented
        -- ones. Positional ROW(...) construction -- all this repo does -- works either
        -- way, but `(_stages[1]).min_head_block_distance` is valid on a node and was an
        -- error here under the old names.
        --
        -- Upstream this composite is hafd.application_stage and there is NO type called
        -- hive.stage (only the function of that name); hive.application_stages is a domain
        -- over hafd.application_stage[]. The shim keeps the hive.stage name because
        -- db/haf_stats_app.sql declares variables of it -- renaming would be a change to
        -- the code under test rather than to the stub.
        CREATE TYPE hive.stage AS (
            name                        hafd.stage_name,
            min_head_block_distance     hafd.blocks_distance,
            blocks_limit_in_group       hafd.blocks_count,
            processing_alarm_threshold  INTERVAL
        );
    END IF;
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hive' AND t.typname = 'application_stages') THEN
        CREATE DOMAIN hive.application_stages AS hive.stage[];
    END IF;
END
$$;

-- NOTE ON ORDER: the columns are added BEFORE the privileges below, because
-- `REVOKE UPDATE (is_forking, owner)` names a column and cannot run before it exists.

-- ---------------------------------------------------------------------------
-- Context bookkeeping columns
--
-- ci_setup.sql's hafd.contexts models what GET /sync-status reads (name, owner,
-- current_block_num, irreversible_block). The lifecycle API needs two more bits of state.
-- Added here rather than there so the endpoint/tavern lane is untouched.
-- ---------------------------------------------------------------------------

-- ATTACHMENT IS THE WRONG SHAPE HERE, AND IT IS A LIVE TRAP -- not a cosmetic one.
-- Measured on the live node by a parallel review: hafd.contexts_attachment EXISTS, and
-- hafd.contexts has NO is_attached column at all. Upstream that table carries its own
-- REVOKE UPDATE(owner), its own ENABLE ROW LEVEL SECURITY and its own four policies
-- (authorization.sql:81-112) -- so the sp_applications_*_hive_context policies this file
-- transcribes verbatim do NOT guard attach/detach on a node, and the ones that do are
-- absent here.
--
-- Already reachable: tests/parity/context_vs_app_status.sql:146 does
-- `UPDATE hafd.contexts_attachment SET is_attached = FALSE`. Nothing routes through that
-- table in THIS lane -- every attachment read goes via hive.app_context_is_attached --
-- but the next thing that touches it directly passes install-test and fails on a node
-- with `relation "hafd.contexts_attachment" does not exist`.
--
-- Not fixed here: splitting the table means re-transcribing four more policies and
-- changing every attachment call path. Recorded in the MR's Scope and limits, and it
-- belongs with the drift guard in #87.
ALTER TABLE hafd.contexts ADD COLUMN IF NOT EXISTS is_attached  BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE hafd.contexts ADD COLUMN IF NOT EXISTS is_forking   BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE hafd.contexts ADD COLUMN IF NOT EXISTS app_schema   TEXT;

-- ---------------------------------------------------------------------------
-- Privileges on hafd.contexts
--
-- install_app.sh runs `SET ROLE haf_stats_owner` before calling
-- create_context_if_not_exists(), so the shim's functions execute as that role, not as
-- the superuser that created them. ci_setup.sql grants the group SELECT only, and its RLS
-- policy is FOR SELECT -- so the install failed with `permission denied for table
-- contexts` until this existed.
--
-- Modelled on the real node rather than waved through. db/builtin_roles.sql's own warning
-- states the production topology: hive_applications_group "grants TRUNCATE/INSERT/UPDATE
-- on hafd.contexts and CREATE on schema hafd". The grants, the column revokes, the policy
-- names and the policy bodies below are transcribed from the source of truth --
-- hive/haf src/hive_fork_manager/authorization.sql -- not inferred from call sites.
--
-- So: the group may write, but only rows it owns. A blanket `USING (TRUE)` would let the
-- lane pass on a privilege topology no node has, which is the same failure mode as a
-- permissive shim -- green here, denied in production.
-- ---------------------------------------------------------------------------

-- Transcribed from authorization.sql:68 and :78 -- including the fact that the REVOKE is
-- INERT. PostgreSQL resolves the relation ACL first and consults per-column ACLs only for
-- bits the relation ACL does not supply, so a column REVOKE cannot cut back a preceding
-- table-level GRANT ALL. It reports plain `REVOKE` and emits NO warning at all -- checked
-- in job 3271957's db-setup output, because an earlier version of this comment asserted a
-- `no privileges could be revoked` warning that PostgreSQL does not produce here (that
-- one appears when the role holds no privileges on the object; this role holds ALL).
-- So the statement is not merely inert, it is silently inert.
--
-- DO NOT "FIX" THIS BY ENUMERATING PRIVILEGES. It is inert on a real node too, and HAF
-- proves it: hive.app_context_set_non_forking is not SECURITY DEFINER and runs
-- `UPDATE hafd.contexts SET is_forking = false` as the app role -- which would be denied
-- for every HAF app in existence if the revoke bit. A stricter stub would turn a working
-- install red.
--
-- An earlier version of this comment claimed the revoke modelled a node-side denial. It
-- does not. It reproduces HAF's exact ACL, and the consequence to be aware of is that
-- NEITHER this shim NOR a node provides column-level protection on is_forking or owner.
-- Choosing GRANT ALL over enumeration still matters for a different reason: enumeration
-- omitted TRUNCATE, which is the privilege db/builtin_roles.sql's second leak probe tests.
GRANT ALL ON hafd.contexts TO hive_applications_group;
REVOKE UPDATE (is_forking, owner) ON hafd.contexts FROM hive_applications_group;
GRANT CREATE ON SCHEMA hafd TO hive_applications_group;

-- ci_setup.sql declares hafd.contexts.id as SERIAL, so an INSERT also needs the sequence.
-- Granted across the schema rather than by name: the sequence is an implementation
-- detail of that column, and naming it here would break silently if the stub table were
-- ever redefined with IDENTITY or a different column order.
GRANT USAGE ON ALL SEQUENCES IN SCHEMA hafd TO hive_applications_group;

DROP POLICY IF EXISTS sp_applications_hive_context_insert ON hafd.contexts;
DROP POLICY IF EXISTS dp_hive_context ON hafd.contexts;
-- INSERT is STRICT EQUALITY in HAF (`current_user = owner`), and applies to every role
-- rather than a group. pg_has_role(..., 'MEMBER') is strictly weaker: haf_admin is
-- granted haf_stats_owner, so it could insert a row owned by haf_stats_owner here and be
-- refused on a node.
CREATE POLICY dp_hive_context ON hafd.contexts
FOR INSERT
WITH CHECK (current_user = owner);

-- hive.can_impersonate, VERBATIM from hive/haf src/hive_fork_manager/authorization.sql.
-- Copied rather than approximated because scripts/uninstall_app.sh calls it DIRECTLY --
-- its guard 2 asks the question the DELETE policy asks -- and because it is not the same
-- predicate as pg_has_role(..., 'MEMBER'), which an earlier revision of this shim used:
-- pg_has_role reports TRUE for a SUPERUSER that was never granted the role, and
-- can_impersonate does not. A stub that said TRUE where HAF says FALSE would let
-- uninstall's guard pass for a role the node's policy then refuses, and the DELETE would
-- match zero rows WITHOUT ERROR -- the exact silent failure that guard exists to prevent.
CREATE OR REPLACE FUNCTION hive.can_impersonate(_role_to_check IN TEXT, _required_role IN TEXT)
RETURNS BOOLEAN
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
  __retval BOOLEAN := FALSE;
BEGIN
  --- Trivial case
  IF (_role_to_check = _required_role) THEN
    RETURN TRUE;
  END IF;

  WITH RECURSIVE role_membership AS MATERIALIZED
  (
     SELECT oid FROM pg_roles WHERE rolname = _role_to_check
     UNION
     SELECT m.roleid
     FROM role_membership rm
     JOIN pg_auth_members m ON m.member = rm.oid
  ),membership AS
  (
    SELECT oid::regrole::text AS rolename FROM role_membership
  )
  SELECT into __retval EXISTS(SELECT NULL FROM membership m WHERE m.rolename = _required_role);

  RETURN __retval;
END
$$;

-- The write policies, also verbatim. Note HAF's UPDATE is `USING(TRUE) WITH CHECK(...)`,
-- not a restricted USING: that distinction is load-bearing and the earlier revision had it
-- backwards. Under a RESTRICTED USING, an UPDATE of a row you cannot impersonate simply
-- does not SEE the row -- zero rows updated, no error, caller proceeds. Under HAF's form
-- the row is visible and the WITH CHECK RAISES. So the old shim turned a node's hard
-- failure into a silent no-op, which is the single failure mode this whole lane exists to
-- rule out.
DROP POLICY IF EXISTS sp_applications_hive_context_update ON hafd.contexts;
DROP POLICY IF EXISTS sp_applications_update_hive_context ON hafd.contexts;
CREATE POLICY sp_applications_update_hive_context ON hafd.contexts
FOR UPDATE TO hive_applications_group
USING (TRUE)
WITH CHECK (hive.can_impersonate(current_user, owner));

DROP POLICY IF EXISTS sp_applications_hive_context_delete ON hafd.contexts;
DROP POLICY IF EXISTS sp_applications_delete_hive_context ON hafd.contexts;
CREATE POLICY sp_applications_delete_hive_context ON hafd.contexts
FOR DELETE TO hive_applications_group
USING (hive.can_impersonate(current_user, owner));

-- ---------------------------------------------------------------------------
-- The API install_app.sh actually calls
-- ---------------------------------------------------------------------------

-- Parameter names, domain-typed arguments and the 4th argument DEFAULT all match
-- hive/haf application_loop/stages_functions.sql:124-128. The default matters:
-- hive.stage(<name>, 0, 1) is a valid three-argument call on a node and was an error here
-- while this function required four. Typing the arguments as the domains rather than as
-- INT/TEXT is what makes the CHECKs fire at the CALL, as they do upstream, instead of at
-- the cast inside.
-- Retired signatures. CREATE OR REPLACE cannot remove an overload, and both of these
-- changed shape after the file had already been loaded on some databases: hive.stage was
-- (TEXT, INT, INT, INTERVAL) and hive.app_context_attach took a second _block_num. On a
-- fresh CI postgres this is a no-op; locally, `docker compose up` without `down -v`
-- across a branch switch would leave the old ones behind, and
-- hive.app_context_attach('haf_stats') would then be AMBIGUOUS against a 2-arg overload
-- with a defaulted second parameter. Every other object in this file is written to
-- survive a re-run (IF NOT EXISTS on all seven types, DROP POLICY IF EXISTS before all
-- five policies); these two now are too.
DROP FUNCTION IF EXISTS hive.stage(TEXT, INT, INT, INTERVAL);
DROP FUNCTION IF EXISTS hive.app_context_attach(TEXT, INT);

CREATE OR REPLACE FUNCTION hive.stage(
      _name hafd.stage_name
    , _min_head_block_distance hafd.blocks_distance
    , _blocks_limit_in_group hafd.blocks_count
    , _processing_alarm_threshold INTERVAL = '5 seconds')
RETURNS hive.stage
LANGUAGE sql IMMUTABLE
AS $$ SELECT ROW(_name, _min_head_block_distance, _blocks_limit_in_group,
                 _processing_alarm_threshold)::hive.stage $$;

CREATE OR REPLACE FUNCTION hive.live_stage()
RETURNS hive.stage
LANGUAGE sql IMMUTABLE
AS $$ SELECT ROW('live', 0, 1, '3 seconds'::INTERVAL)::hive.stage $$;

CREATE OR REPLACE FUNCTION hive.app_context_exists(_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$ SELECT EXISTS (SELECT 1 FROM hafd.contexts AS c WHERE c.name = _name) $$;

-- Refuses a duplicate, like the real one: install_app.sh only calls this inside
-- `IF NOT app_context_exists`, so a shim that silently upserted would hide a caller that
-- lost that guard.
-- FOUR arguments, the fourth defaulted -- measured on the live node, where the staged
-- overload is
--   (_name hafd.context_name, _schema text, _stages hafd.application_stages,
--    _is_forking boolean DEFAULT true)
-- The shim had three. db/haf_stats_app.sql's call passes _name/_schema/_stages by NAME and
-- so resolves against both, which is why this never showed up -- verified by PREPAREing
-- that exact call shape against the node. But a caller passing _is_forking => FALSE would
-- work on a node and fail here with "function does not exist".
DROP FUNCTION IF EXISTS hive.app_create_context(hafd.context_name, TEXT, hive.application_stages);
CREATE OR REPLACE FUNCTION hive.app_create_context(
    _name hafd.context_name, _schema TEXT, _stages hive.application_stages,
    _is_forking BOOLEAN DEFAULT TRUE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM hafd.contexts AS c WHERE c.name = _name) THEN
        RAISE EXCEPTION 'context % already exists', _name;
    END IF;
    IF _stages IS NULL OR array_length(_stages, 1) IS NULL THEN
        RAISE EXCEPTION 'context % created with no stages', _name;
    END IF;
    -- DETACHED, like HAF: its staged app_create_context passes _is_attached = False.
    -- An earlier revision inserted TRUE, which cancelled out against the equally-wrong
    -- set_non_forking below for the install's current call ORDER -- so the lane was green
    -- on a model that would have failed for any reordering of
    -- create_context_if_not_exists().
    INSERT INTO hafd.contexts (name, owner, current_block_num, irreversible_block,
                               is_attached, is_forking, app_schema)
    VALUES (_name, CURRENT_USER, 0, 0, FALSE, _is_forking, _schema);
END
$$;

-- Real HAF does NOT merely flip a flag: it detaches, clears is_forking, and then
-- RE-ATTACHES at the context's current block (hive/haf app_api.sql), leaving the context
-- ATTACHED. Modelled because the difference is not cosmetic -- an install that called
-- set_non_forking AFTER detaching would find the context attached again, and its
-- subsequent app_set_current_block_num would fail on a node while passing against a
-- flag-only stub.
CREATE OR REPLACE FUNCTION hive.app_context_set_non_forking(_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _already BOOLEAN;
BEGIN
    SELECT NOT c.is_forking INTO _already FROM hafd.contexts AS c WHERE c.name = _name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no such context: %', _name;
    END IF;
    IF _already THEN
        RETURN;                      -- HAF returns early when it is already non-forking
    END IF;
    UPDATE hafd.contexts SET is_forking = FALSE, is_attached = TRUE WHERE name = _name;
END
$$;

-- RAISES on a missing context rather than returning NULL. HAF's app_context_are_attached
-- raises 'No contexts or attached and detached contexts are present in the same group %'.
-- The difference is reachable: db/haf_stats_app.sql's repair branch calls this, and a NULL
-- makes its IF false, so the stub would fall through to app_set_current_block_num where a
-- node had already aborted.
CREATE OR REPLACE FUNCTION hive.app_context_is_attached(_name TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _attached BOOLEAN;
BEGIN
    SELECT c.is_attached INTO _attached FROM hafd.contexts AS c WHERE c.name = _name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Contexts do not exist: %', _name;
    END IF;
    RETURN _attached;
END
$$;

CREATE OR REPLACE FUNCTION hive.app_context_detach(_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE hafd.contexts SET is_attached = FALSE WHERE name = _name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no such context: %', _name;
    END IF;
END
$$;

-- Real HAF refuses to attach a context whose pointer is ahead of what the node can serve.
-- create_context_if_not_exists() reasons about exactly this ("app_context_attach raises
-- if current_block_num > consistent_block"), and clamps its seed with LEAST to avoid it.
-- Enforced so that the clamp is a live requirement here, not decoration.
-- ONE ARGUMENT, like HAF. An earlier revision took an optional _block_num, which HAF has
-- on neither overload (app_api.sql offers app_context_attach(hive.contexts_group) and
-- app_context_attach(hafd.context_name)) -- so a future two-argument call would have been
-- green here and `function hive.app_context_attach(unknown, integer) does not exist` on a
-- node.
CREATE OR REPLACE FUNCTION hive.app_context_attach(_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _consistent INT;
    _current    INT;
BEGIN
    SELECT c.current_block_num INTO _current FROM hafd.contexts AS c WHERE c.name = _name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Contexts do not exist: %', _name;
    END IF;
    SELECT MAX(s.consistent_block) INTO _consistent FROM hafd.hive_state AS s;
    IF _consistent IS NOT NULL AND _current > _consistent THEN
        RAISE EXCEPTION 'context % cannot be attached at block % : consistent_block is %',
            _name, _current, _consistent;
    END IF;
    UPDATE hafd.contexts SET is_attached = TRUE WHERE name = _name;
END
$$;

-- Requires a DETACHED context, which is why create_context_if_not_exists() detaches
-- first and why its repair branch bails when the context is attached.
CREATE OR REPLACE FUNCTION hive.app_set_current_block_num(_name TEXT, _block_num INT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _attached BOOLEAN;
BEGIN
    SELECT c.is_attached INTO _attached FROM hafd.contexts AS c WHERE c.name = _name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no such context: %', _name;
    END IF;
    IF _attached THEN
        RAISE EXCEPTION 'context % is attached; detach before moving its block pointer', _name;
    END IF;
    UPDATE hafd.contexts SET current_block_num = _block_num WHERE name = _name;
END
$$;

-- Same as app_context_is_attached: HAF raises 'Contexts do not exist' rather than
-- returning NULL (hive/haf app_api.sql).
CREATE OR REPLACE FUNCTION hive.app_get_current_block_num(_name TEXT)
RETURNS INT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _block INT;
BEGIN
    SELECT c.current_block_num INTO _block FROM hafd.contexts AS c WHERE c.name = _name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Contexts do not exist: %', _name;
    END IF;
    RETURN _block;
END
$$;

CREATE OR REPLACE FUNCTION hive.app_remove_context(_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM hafd.contexts WHERE name = _name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no such context: %', _name;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- The PUBLIC revoke, which is what makes db/builtin_roles.sql defendable
-- ---------------------------------------------------------------------------
-- hive/haf authorization.sql:159-160. Without it PostgreSQL grants EXECUTE on every
-- function to PUBLIC by default, so in CI every role -- including haf_stats_user, which
-- backs the UNAUTHENTICATED PostgREST connection -- could call every hive.* function.
--
-- MEASURED AGAINST THE LIVE NODE, and the answer is more complicated than either this
-- comment or the commit that added it first said.
--
-- On testapi, PUBLIC EXECUTE on schema hive is NOT fully revoked: of 376 hive.* functions,
-- 4 carry the default NULL ACL and 133 carry an explicit PUBLIC entry. HAF's
-- `REVOKE ... FROM PUBLIC` (authorization.sql:159) is a SNAPSHOT, so anything created
-- after it keeps the default grant. This shim's revoke is therefore STRICTER than the node
-- in absolute terms -- but strictly in the safe direction: it can only make the lane red
-- for a missing grant, never green for one a node lacks.
--
-- The node's own ACL for the functions haf_stats actually calls is explicit, not PUBLIC:
--   hive.is_instance_ready  -> haf_admin=X, hive_applications_group=X, haf_maintainer=X,
--                              haf_stats_owner=X, haf_stats_user=X
-- i.e. db/builtin_roles.sql:81 and :86 have both run there and are visible in pg_proc.proacl.
--
-- WHAT THIS DOES AND DOES NOT BUY -- stated precisely, because the commit that added it
-- overclaimed. It makes db/builtin_roles.sql:86 falsifiable: haf_stats_user is NOINHERIT
-- and in no group, so without :86 it has no EXECUTE at all, and install_app.sh's
-- `SET ROLE haf_stats_user; ... hive.is_instance_ready()` step fails the install.
-- tests/ci_install_verify.sql asserts it directly as well.
--
-- It does NOT make :81 falsifiable. haf_stats_owner inherits EXECUTE through
-- hive_applications_group via the GRANT below, so deleting :81 changes nothing here --
-- and nothing on a node either, where HAF issues the same group grant. :81 is
-- belt-and-braces, and no assertion can defend a grant that nothing needs.
--
-- AND THE ROLE TOPOLOGY HERE IS NOT THE NODE'S. Measured on testapi:
--   haf_stats_user  rolinherit = t, LOGIN, and a DIRECT member of hive_applications_group
-- db/builtin_roles.sql:15 creates it LOGIN NOINHERIT and never grants that group, so this
-- lane models a FRESH install while the node carries a role HAF's own
-- create_haf_app_role.sh provisioned first -- builtin_roles' CREATE arm never ran there.
-- Consequence for :86: load-bearing in the state this lane models, redundant on that node,
-- where the group supplies EXECUTE anyway.
--
-- The same divergence means this lane never reaches db/builtin_roles.sql's LEAK PROBE
-- (its WARNING arm at :123-127). That arm FIRES on testapi today -- measured:
-- pg_has_role(haf_stats_user, hive_applications_group, MEMBER) = t, and
-- has_table_privilege(haf_stats_user, hafd.contexts, TRUNCATE/DELETE/INSERT) = t, t, t.
-- So the anon PostgREST role can write hafd.contexts there, gated for UPDATE/DELETE by
-- RLS (can_impersonate(haf_stats_user, haf_stats_owner) = f) but NOT for TRUNCATE, which
-- row-level security does not cover. haf_fyp_user was taken out of that group; haf_stats_user
-- was not. Reported by the installer on every run, unremediated, and out of scope here.
--
-- What the revoke is really for: without it PostgreSQL's default PUBLIC grant lets EVERY
-- role call EVERY hive.* function, including haf_stats_user, which backs the
-- UNAUTHENTICATED PostgREST connection. That is a privilege topology no node has.
--
-- PLACEMENT IS LOAD-BEARING. `ON ALL FUNCTIONS` is a SNAPSHOT, not a standing rule, so
-- this must come after every CREATE FUNCTION above -- including hive.can_impersonate, and
-- including the hive.* functions tests/ci_setup.sql created earlier in the same db-setup
-- step. The install itself is unaffected: scripts/install_app.sh loads
-- db/builtin_roles.sql at line 181, well before its first `SET ROLE haf_stats_owner` at
-- line 251.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA hive FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA hive TO hive_applications_group;

-- The shim's own smoke test, run at load time. A stub that fails to create or move a
-- context would otherwise be indistinguishable from a successful install, because
-- install_app.sh's own output is the same either way.
DO $$
DECLARE
    _probe CONSTANT TEXT := 'ci_shim_probe';
BEGIN
    PERFORM hive.app_create_context(_probe::hafd.context_name, 'ci_probe_schema',
        ARRAY[hive.stage('MASSIVE_PROCESSING', 101, 10000, '20 seconds'),
              hive.live_stage()]::hive.application_stages);

    IF NOT hive.app_context_exists(_probe) THEN
        RAISE EXCEPTION 'shim: app_create_context did not create a context';
    END IF;

    -- HAF creates a staged context DETACHED. This probe asserted the opposite until the
    -- semantics were corrected, and then failed -- which is the smoke test doing its job:
    -- a change to the contract should break the thing that documents the contract.
    IF hive.app_context_is_attached(_probe) THEN
        RAISE EXCEPTION 'shim: app_create_context left the context ATTACHED; HAF creates it detached';
    END IF;

    -- set_non_forking RE-ATTACHES on a node, so after it the pointer must be refused.
    PERFORM hive.app_context_set_non_forking(_probe);
    IF NOT hive.app_context_is_attached(_probe) THEN
        RAISE EXCEPTION 'shim: app_context_set_non_forking did not re-attach, as HAF does';
    END IF;
    BEGIN
        PERFORM hive.app_set_current_block_num(_probe, 5);
        RAISE EXCEPTION 'shim: app_set_current_block_num accepted an ATTACHED context';
    EXCEPTION
        WHEN SQLSTATE 'P0001' THEN
            IF SQLERRM LIKE '%accepted an ATTACHED context%' THEN RAISE; END IF;
    END;

    PERFORM hive.app_context_detach(_probe);
    PERFORM hive.app_set_current_block_num(_probe, 5);

    IF hive.app_get_current_block_num(_probe) <> 5 THEN
        RAISE EXCEPTION 'shim: the block pointer did not move';
    END IF;
    IF hive.app_context_is_attached(_probe) THEN
        RAISE EXCEPTION 'shim: app_context_detach did not detach';
    END IF;
    IF (SELECT c.is_forking FROM hafd.contexts AS c WHERE c.name = _probe) THEN
        RAISE EXCEPTION 'shim: app_context_set_non_forking did not clear the flag';
    END IF;

    PERFORM hive.app_remove_context(_probe);
    IF hive.app_context_exists(_probe) THEN
        RAISE EXCEPTION 'shim: app_remove_context did not remove it';
    END IF;

    -- can_impersonate, which uninstall_app.sh's guard 2 names directly and which none of
    -- the sequence above exercises (the policies it guards are not enforced for the
    -- superuser loading this file: postgres owns hafd.contexts and RLS there is ENABLE,
    -- not FORCE). The haf_admin -> haf_stats_owner membership arm lives in
    -- tests/ci_install_verify.sql because that GRANT is db/builtin_roles.sql:63's, i.e.
    -- the install's. The roles themselves already exist here -- ci_setup.sql creates them
    -- before this file loads.
    IF NOT hive.can_impersonate('haf_admin', 'haf_admin') THEN
        RAISE EXCEPTION 'shim: can_impersonate is false for the trivial self case';
    END IF;
    -- THE DOMAIN CHECKS, which nothing else can fail. No call site in this repo passes
    -- an invalid stage -- db/haf_stats_app.sql's two are both valid -- so every CHECK on
    -- hafd.stage_name / blocks_distance / blocks_count could be STRIPPED and the lane
    -- would stay green, despite the comment above them justifying their existence at
    -- length. These three arms are what make that comment true.
    BEGIN
        PERFORM hive.stage('MASSIVE PROCESSING', 101, 10000, '20 seconds');
        RAISE EXCEPTION 'shim: hafd.stage_name accepted a name with a space';
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
    BEGIN
        PERFORM hive.stage('MASSIVE_PROCESSING', -1, 10000, '20 seconds');
        RAISE EXCEPTION 'shim: hafd.blocks_distance accepted a negative distance';
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;
    BEGIN
        PERFORM hive.stage('MASSIVE_PROCESSING', 101, 0, '20 seconds');
        RAISE EXCEPTION 'shim: hafd.blocks_count accepted a zero batch size';
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;

    -- THE DISCRIMINATING ARM. The trivial case above passes under pg_has_role too, so it
    -- would not catch a swap back to it. This one is the whole reason the function is
    -- transcribed rather than approximated: postgres is a superuser, so
    -- pg_has_role(..., 'MEMBER') answers TRUE for it against any role, while
    -- can_impersonate walks pg_auth_members and answers FALSE.
    IF hive.can_impersonate('postgres', 'hive_applications_group') THEN
        RAISE EXCEPTION 'shim: can_impersonate says a superuser can impersonate a role it '
                        'was never granted. That is pg_has_role behaviour, not HAF''s.';
    END IF;

    RAISE NOTICE 'HAF context shim OK (create-detached / non-forking re-attaches / attached-seed refused / detach / seed / remove / can_impersonate)';
END
$$;
