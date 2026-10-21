-- A minimal HAF shim, so the REAL scripts/install_app.sh can run against a plain
-- PostgreSQL. (#84)
--
-- WHY THIS EXISTS. Every other lane that runs `install_app.sh` needs a REPLAYED HAF (see
-- docker/docker-compose-ci-install.yml for the cost). Everything cheaper tests something
-- adjacent: the unit suite stubs psql, so it cannot fail the way PostgreSQL does, and the
-- `endpoint-tests` lane loads the SQL files directly without the installer.
--
-- tests/ci_setup.sql stubs enough HAF for the files the endpoint-tests lane loads:
-- hafd.contexts, hafd.hive_state, hafd.operation_types, hafd.blocks,
-- hive.get_required_authorities, hive.is_instance_ready. It is NOT enough for a full
-- install -- it says so itself ("Roles (simplified - no haf_admin / HAF group
-- dependencies)"), and that lane never attempts db/haf_stats_app.sql or
-- db/builtin_roles.sql at all. What is missing is the context lifecycle API, the HAF
-- roles, and seven type objects (hafd.context_name / stage_name / blocks_distance /
-- blocks_count / application_stage / application_stages, hive.blocks_range and the
-- three hive.* compat aliases) -- 10 type objects in all, everything
-- install_app.sh needs that no HAF-less lane provides.
--
-- WHAT THIS IS NOT. It is not a HAF emulator. It implements the eight calls
-- create_context_if_not_exists() makes, plus three more -- app_context_attach,
-- app_get_current_block_num and app_remove_context -- which the shim's own smoke test,
-- tests/ci_install_verify.sql and the teardown step use, plus hive.can_impersonate,
-- which scripts/uninstall_app.sh calls directly, and hafd.live_stage(). 13 functions,
-- and the invariants they reason about. A processor cannot run against it: there is no
-- block streaming here, only context bookkeeping.
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
-- On a real node HAF has already created it, so the dependency is invisible to every lane
-- that runs against one.
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
-- (hive/haf context_rewind/data_schema.sql). There is no length rule to model.
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
-- types at CREATE time -- so without it db/haf_stats_app.sql cannot even load. This is the
-- only HAF-LESS lane that loads that file: sync and reinstall-test load it against a real
-- HAF, where the type exists, and the endpoint-tests lane hand-creates app_status and
-- app_version in ci_setup.sql instead of running it.
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

-- Retire the shapes a PRE-#87 load of this file left behind. Same reason as the DROP
-- FUNCTIONs below: everything here is written to survive a re-run, and #87 renamed the
-- composite (hive.stage -> hafd.application_stage) and re-based the alias domain
-- (hive.stage[] -> hafd.application_stage[]). The IF NOT EXISTS guards below would
-- happily leave both stale, so a local `docker compose up` without `down -v` across a
-- branch switch would build contexts out of the old composite. CI never sees this (fresh
-- postgres per job); a developer would.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
               WHERE n.nspname = 'hive' AND t.typname = 'stage' AND t.typtype = 'c') THEN
        DROP TYPE hive.stage CASCADE;      -- takes hive.application_stages with it
    END IF;
    IF EXISTS (SELECT FROM pg_type d JOIN pg_namespace n ON n.oid = d.typnamespace
               WHERE n.nspname = 'hive' AND d.typname = 'application_stages'
                 AND format_type(d.typbasetype, NULL) <> 'hafd.application_stage[]') THEN
        DROP DOMAIN hive.application_stages CASCADE;
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hafd' AND t.typname = 'application_stage') THEN
        -- hafd.application_stage, which is what HAF actually calls it
        -- (application_loop/stages.sql:8). There is NO type named hive.stage upstream --
        -- only the FUNCTION of that name (the DO block above drops a stale composite
        -- of that name left by an older load of this file).
        CREATE TYPE hafd.application_stage AS (
            name                        hafd.stage_name,
            min_head_block_distance     hafd.blocks_distance,
            blocks_limit_in_group       hafd.blocks_count,
            processing_alarm_threshold  INTERVAL
        );
    END IF;
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hafd' AND t.typname = 'application_stages') THEN
        CREATE DOMAIN hafd.application_stages AS hafd.application_stage[];
    END IF;
    -- THE COMPAT ALIASES, reproduced because HAF still ships them and #87 is about what
    -- happens when it stops. types/operation/compatibility_with_old_haf_apps.sql opens
    -- with "for compatibility with old HAF apps add some aliases for types moved to hafd
    -- schema". Keeping them here means the shim matches a node exactly; the lint-stage
    -- drift guard (.gitlab-ci.yml: haf-drift) is what notices if upstream drops them.
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hive' AND t.typname = 'application_stages') THEN
        CREATE DOMAIN hive.application_stages AS hafd.application_stage[];
    END IF;
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hive' AND t.typname = 'context_name') THEN
        CREATE DOMAIN hive.context_name AS hafd.context_name;
    END IF;
    -- The THIRD alias. compatibility_with_old_haf_apps.sql defines three domains, not
    -- two; hive.contexts_group is the argument type of the group overloads of
    -- app_context_attach/detach/set_non_forking that this shim's comments already cite.
    -- Nothing here calls them; the domain is reproduced so the shim's compat aliases
    -- match HAF's.
    IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'hive' AND t.typname = 'contexts_group') THEN
        CREATE DOMAIN hive.contexts_group AS hafd.context_name[] NOT NULL
            CONSTRAINT non_empty_contexts_group CHECK (CARDINALITY(VALUE) > 0);
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
-- On a node hafd.contexts_attachment EXISTS, and hafd.contexts has NO is_attached column
-- at all. Upstream that table carries its own REVOKE UPDATE(owner), its own ENABLE ROW
-- LEVEL SECURITY and its own four policies (authorization.sql:81-112) -- so the
-- sp_applications_*_hive_context policies this file transcribes verbatim do NOT guard
-- attach/detach on a node, and the ones that do are absent here.
--
-- Already reachable: tests/parity/context_vs_app_status.sql:146 does
-- `UPDATE hafd.contexts_attachment SET is_attached = FALSE`. Nothing routes through that
-- table in THIS lane -- every attachment read goes via hive.app_context_is_attached --
-- but the next thing that touches it directly passes install-test and fails on a node
-- with `relation "hafd.contexts_attachment" does not exist`.
--
-- Not fixed here: splitting the table means re-transcribing four more policies and
-- changing every attachment call path. It belongs with the drift guard in #87.
ALTER TABLE hafd.contexts ADD COLUMN IF NOT EXISTS is_attached  BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE hafd.contexts ADD COLUMN IF NOT EXISTS is_forking   BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE hafd.contexts ADD COLUMN IF NOT EXISTS app_schema   TEXT;

-- ---------------------------------------------------------------------------
-- Privileges on hafd.contexts
--
-- install_app.sh runs `SET ROLE haf_stats_owner` before calling
-- create_context_if_not_exists(), so the shim's functions execute as that role, not as
-- the superuser that created them. ci_setup.sql grants the group SELECT only, and its RLS
-- policy is FOR SELECT -- so without this section the install fails with `permission
-- denied for table contexts`.
--
-- Modelled on the real node rather than waved through. The production topology:
-- hive_applications_group holds ALL on hafd.contexts (TRUNCATE, INSERT, UPDATE...) and
-- CREATE on schema hafd. The grants, the column revokes, the policy
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
-- table-level GRANT ALL. It reports plain `REVOKE` and emits NO warning at all (the `no
-- privileges could be revoked` warning appears only when the role holds no privileges on
-- the object; this role holds ALL). So the statement is not merely inert, it is silently
-- inert.
--
-- DO NOT "FIX" THIS BY ENUMERATING PRIVILEGES. It is inert on a real node too, and HAF
-- proves it: hive.app_context_set_non_forking is not SECURITY DEFINER and runs
-- `UPDATE hafd.contexts SET is_forking = false` as the app role -- which would be denied
-- for every HAF app in existence if the revoke bit. A stricter stub would turn a working
-- install red.
--
-- The revoke does not model a node-side denial. It reproduces HAF's exact ACL, and the
-- consequence to be aware of is that NEITHER this shim NOR a node provides column-level
-- protection on is_forking or owner. Choosing GRANT ALL over enumeration also matters for
-- a different reason: enumeration omits TRUNCATE, which is the privilege
-- db/builtin_roles.sql's second leak probe tests.
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
-- predicate as pg_has_role(..., 'MEMBER'): pg_has_role reports TRUE for a SUPERUSER that
-- was never granted the role, and can_impersonate does not. A stub that said TRUE where HAF
-- says FALSE would let uninstall's guard pass for a role the node's policy then refuses,
-- and the DELETE would match zero rows WITHOUT ERROR -- the exact silent failure that guard
-- exists to prevent.
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
-- not a restricted USING, and that distinction is load-bearing. Under a RESTRICTED USING,
-- an UPDATE of a row you cannot impersonate simply does not SEE the row -- zero rows
-- updated, no error, caller proceeds. Under HAF's form the row is visible and the WITH
-- CHECK RAISES. A restricted USING here would turn a node's hard failure into a silent
-- no-op, which is the single failure mode this whole lane exists to rule out.
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
-- hive.stage(<name>, 0, 1) is a valid three-argument call on a node, so it must be here.
-- Typing the arguments as the domains rather than as INT/TEXT is what makes the CHECKs fire
-- at the CALL, as they do upstream, instead of at the cast inside.
--
-- Retired signatures. CREATE OR REPLACE cannot remove an overload, and both of these changed shape after the
-- file had already been loaded on some databases: hive.stage was (TEXT, INT, INT, INTERVAL)
-- and hive.app_context_attach took a second _block_num. On a fresh CI postgres this is a
-- no-op; locally, `docker compose up` without `down -v` across a branch switch would leave
-- the old ones behind, and hive.app_context_attach('haf_stats') would then be AMBIGUOUS
-- against a 2-arg overload with a defaulted second parameter. Every other object in this
-- file is written to survive a re-run (IF NOT EXISTS on all 10 type objects, 6 DROP POLICY
-- IF EXISTS before 3 CREATE POLICY), and these DROP FUNCTIONs (with the two before
-- app_create_context) make the functions survive one too.
DROP FUNCTION IF EXISTS hive.stage(TEXT, INT, INT, INTERVAL);
-- The DOMAIN-TYPED signature too, and this one is not optional. #87 changed this
-- function's RETURN type from hive.stage to hafd.application_stage, and CREATE OR
-- REPLACE cannot change a return type -- it raises 42P13. DROP FUNCTION matches argument
-- types EXACTLY, and a domain is a distinct type from its base, so the TEXT/INT form
-- above does not match the domain-typed one and would have left it standing.
DROP FUNCTION IF EXISTS hive.stage(hafd.stage_name, hafd.blocks_distance, hafd.blocks_count, INTERVAL);
DROP FUNCTION IF EXISTS hive.live_stage();
DROP FUNCTION IF EXISTS hafd.live_stage();
DROP FUNCTION IF EXISTS hive.app_context_attach(TEXT, INT);

CREATE OR REPLACE FUNCTION hive.stage(
      _name hafd.stage_name
    , _min_head_block_distance hafd.blocks_distance
    , _blocks_limit_in_group hafd.blocks_count
    , _processing_alarm_threshold INTERVAL = '5 seconds')
RETURNS hafd.application_stage
LANGUAGE sql IMMUTABLE
AS $$ SELECT ROW(_name, _min_head_block_distance, _blocks_limit_in_group,
                 _processing_alarm_threshold)::hafd.application_stage $$;

-- hafd.live_stage() is the real one (application_loop/stages.sql:15); hive.live_stage()
-- is the compat wrapper that just calls it. Both modelled, because db/haf_stats_app.sql
-- now calls the canonical one and the wrapper is what #87 is watching for removal.
-- Routed through hive.stage(), as upstream is (application_loop/stages.sql:15-24):
-- plpgsql, IMMUTABLE, body `RETURN hive.stage('live', 0, 1, '3 seconds')`. Building the
-- ROW directly would give the same value, but the dependency is the point: on a node
-- hafd.live_stage() goes through hive.stage() and therefore through the domain CHECKs, and
-- a shim that bypasses them accepts a stage a node would reject.
CREATE OR REPLACE FUNCTION hafd.live_stage()
RETURNS hafd.application_stage
LANGUAGE plpgsql IMMUTABLE
AS $$ BEGIN RETURN hive.stage('live', 0, 1, '3 seconds'); END $$;

CREATE OR REPLACE FUNCTION hive.live_stage()
RETURNS hafd.application_stage
LANGUAGE plpgsql IMMUTABLE
AS $$ BEGIN RETURN hafd.live_stage(); END $$;

CREATE OR REPLACE FUNCTION hive.app_context_exists(_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$ SELECT EXISTS (SELECT 1 FROM hafd.contexts AS c WHERE c.name = _name) $$;

-- Refuses a duplicate, like the real one: install_app.sh only calls this inside
-- `IF NOT app_context_exists`, so a shim that silently upserted would hide a caller that
-- lost that guard.
-- FOUR arguments, the fourth defaulted, as on a node, where the staged overload is
--   (_name hafd.context_name, _schema text, _stages hafd.application_stages,
--    _is_forking boolean DEFAULT true)
-- db/haf_stats_app.sql's call passes _name/_schema/_stages by NAME and so would also
-- resolve against a three-argument form, but a caller passing _is_forking => FALSE needs
-- the fourth. The first DROP below retires that older three-argument signature.
DROP FUNCTION IF EXISTS hive.app_create_context(hafd.context_name, TEXT, hive.application_stages);
DROP FUNCTION IF EXISTS hive.app_create_context(hafd.context_name, TEXT, hive.application_stages, BOOLEAN);
CREATE OR REPLACE FUNCTION hive.app_create_context(
    _name hafd.context_name, _schema TEXT, _stages hafd.application_stages,
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
    -- Inserting TRUE can cancel out against an equally-wrong set_non_forking for the
    -- install's current call ORDER, leaving the lane green on a model that fails for any
    -- reordering of create_context_if_not_exists().
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
-- ONE ARGUMENT, like HAF, which has no _block_num on either overload (app_api.sql offers
-- app_context_attach(hive.contexts_group) and app_context_attach(hafd.context_name)) -- a
-- second parameter here would let a two-argument call pass that fails on a node with
-- `function hive.app_context_attach(unknown, integer) does not exist`.
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
-- ON A NODE THE PICTURE IS LESS TIDY. On testapi, PUBLIC EXECUTE on schema hive is NOT
-- fully revoked: of 376 hive.* functions, 4 carry the default NULL ACL and 133 carry an
-- explicit PUBLIC entry. HAF's `REVOKE ... FROM PUBLIC` (authorization.sql:159) is a
-- SNAPSHOT, so anything created after it keeps the default grant. This shim's revoke is
-- therefore STRICTER than the node in absolute terms -- but strictly in the safe direction:
-- it can only make the lane red for a missing grant, never green for one a node lacks.
--
-- The node's own ACL for the functions haf_stats actually calls is explicit, not PUBLIC:
--   hive.is_instance_ready  -> haf_admin=X, hive_applications_group=X, haf_maintainer=X,
--                              haf_stats_owner=X, haf_stats_user=X
-- i.e. db/builtin_roles.sql:81 and :86 have both run there and are visible in pg_proc.proacl.
--
-- WHAT THIS DOES AND DOES NOT BUY. It makes db/builtin_roles.sql:86 falsifiable:
-- haf_stats_user is NOINHERIT and in no group, so without :86 it has no EXECUTE at all, and
-- install_app.sh's `SET ROLE haf_stats_user; ... hive.is_instance_ready()` step fails the
-- install. tests/ci_install_verify.sql asserts it directly as well.
--
-- It does NOT make :81 falsifiable. haf_stats_owner inherits EXECUTE through
-- hive_applications_group via the GRANT below, so deleting :81 changes nothing here --
-- and nothing on a node either, where HAF issues the same group grant. :81 is
-- belt-and-braces, and no assertion can defend a grant that nothing needs.
--
-- AND THE ROLE TOPOLOGY HERE IS NOT THE NODE'S. Measured on testapi, before an installer
-- carrying #88 has run there:
--   haf_stats_user  rolinherit = t, LOGIN, and a DIRECT member of hive_applications_group
-- That installer removes the group edge, after which only the INHERIT flag still differs.
-- db/builtin_roles.sql:15 creates it LOGIN NOINHERIT and never grants that group, so this
-- lane models a FRESH install, while the node carries a role an UNMERGED revision of that
-- file created (9a77508: "LOGIN INHERIT IN ROLE hive_applications_group").
-- Consequence for :86: load-bearing in the state this lane models -- and on that node too,
-- once the group edge is gone. It was redundant there only while the group supplied EXECUTE.
--
-- Because of that divergence a fresh install never reaches db/builtin_roles.sql's LEAK
-- PROBE or the #88 revoke before it, so tests/ci_break_schema.sql grants the group to
-- haf_stats_user before install-again; the revoke then runs on every pipeline and
-- ci_install_verify.sql asserts it worked. It matters because a member of that group has
-- TRUNCATE/DELETE/INSERT on hafd.contexts, gated for UPDATE/DELETE by RLS
-- (can_impersonate(haf_stats_user, haf_stats_owner) = f) but NOT for TRUNCATE, which
-- row-level security does not cover.
--
-- PLACEMENT IS LOAD-BEARING. `ON ALL FUNCTIONS` is a SNAPSHOT, not a standing rule, so
-- this must come after every CREATE FUNCTION above -- including hive.can_impersonate, and
-- including the hive.* functions tests/ci_setup.sql created earlier in the same db-setup
-- step. The install itself is unaffected: scripts/install_app.sh loads
-- db/builtin_roles.sql well before its first `SET ROLE haf_stats_owner`.
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
              hafd.live_stage()]::hafd.application_stages);

    IF NOT hive.app_context_exists(_probe) THEN
        RAISE EXCEPTION 'shim: app_create_context did not create a context';
    END IF;

    -- HAF creates a staged context DETACHED.
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
    -- would stay green without these three arms.
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

    -- THE COMPAT ALIASES, which nothing else here touches: db/haf_stats_app.sql uses the
    -- canonical hafd.* names (#87), so hive.application_stages / hive.live_stage() /
    -- hive.context_name / hive.contexts_group are otherwise asserted by nothing. These
    -- four arms catch a wrong alias here rather than on a node, and they are cheap.
    IF (SELECT hafd.live_stage()) IS DISTINCT FROM (SELECT hive.live_stage()) THEN
        RAISE EXCEPTION 'shim: hive.live_stage() and hafd.live_stage() disagree; upstream defines the former as a wrapper round the latter';
    END IF;
    PERFORM ARRAY[hive.live_stage()]::hive.application_stages;
    PERFORM 'ci_probe'::hive.context_name;
    BEGIN
        PERFORM ARRAY[]::hive.contexts_group;
        RAISE EXCEPTION 'shim: hive.contexts_group accepted an EMPTY array';
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
