SET ROLE haf_stats_owner;

-- ---------------------------------------------------------------------------
-- Op-type dependency registry + install-time assertion (issue #56).
--
-- Several processors resolve a Hive operation type by NAME at runtime, e.g.
--   SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_missed_operation'
-- Resolving by name is CORRECT - virtual op ids are assigned after the non-virtual block and
-- shift between hived versions (see db/process_witness_blocks.sql) - but it fails SILENTLY. If
-- hived renames an op the lookup returns NULL, the aggregation arm matches no rows, and the
-- endpoint reports zeros with no error anywhere.
--
-- That is not hypothetical. hive::protocol::sps_fund_operation no longer resolves on current
-- hived (it was renamed to dhf_funding_operation), and docs/VERIFICATION.md D5 records the same
-- class of bug inside this repo: process_rc looked up 'custom_json_operation' WITHOUT the
-- 'hive::protocol::' prefix, got NULL, and silently lost every custom_json attribution.
--
-- The mirror of the same risk is a HARDCODED NUMERIC id. Non-virtual ids are consensus-ordered
-- and stable (vote 0, comment 1, transfer 2, delete_comment 17, custom_json 18) - but id 73 is
-- ineffective_delete_comment_operation, a VIRTUAL op hardcoded numerically in
-- db/process_content_stats.sql as IN (17, 73). If that id ever moves, the processor keeps
-- matching rows - they are just the wrong operation's rows - so failed deletes get treated as
-- effective and live comments silently drop out of comment_registry. Wrong data, not zeros.
--
-- expected_op_type_names() is the SINGLE place a dependency is declared. A processor that needs
-- a new op type registers it HERE.
--
-- ---------------------------------------------------------------------------
-- SEVERITY MODEL - which arms abort the install, and why the split exists
-- ---------------------------------------------------------------------------
-- FATAL (RAISE EXCEPTION). Something is broken RIGHT NOW, on this node, in a way that produces
-- wrong or empty data with no other symptom:
--   arm 1  a registered name no longer resolves            -> that lookup is NULL today
--   arm 2  a registered id no longer carries its name      -> that filter reads a different op
--   arm 4  a name is looked up WITHOUT the required prefix -> that lookup is NULL today (D5)
--
-- WARNING (install continues). The registry and the code have drifted apart, but nothing is
-- broken on this node today:
--   arm 3  code resolves a name the registry does not declare
--   arm 5  the registry declares a name no installed function resolves any more
--   arm 6  code hardcodes an op id the registry does not declare
--
-- Arms 3, 5 and 6 are deliberately NOT fatal, and that is a correctness decision rather than a
-- soft one. This app only drops exact signatures: the ones it immediately recreates, plus a
-- few commented tombstones for retired signatures (in db/process_rc.sql,
-- db/process_content_stats.sql and this file) -
-- it never sweeps a schema - so a RENAMED or RE-SIGNATURED function's body persists in pg_proc,
-- and the schemas themselves are CREATE SCHEMA IF NOT EXISTS. If a later release renames a
-- processor and deletes its now-unused registry row, the ORPHANED body is still there carrying
-- that literal. A fatal arm 3 would then abort every subsequent install, and since
-- haf-stats-process gates on setup service_completed_successfully and haf-stats-api on
-- haf-stats-process, the whole stack would stay down over a bookkeeping mismatch with no
-- data-correctness content, recoverable only by a manual DROP FUNCTION on the production node.
-- The same argument applies in reverse to arm 5. Drift is a code-review concern; broken data is
-- an install concern.
--
-- ---------------------------------------------------------------------------
-- KNOWN LIMITS of the scans. They read INSTALLED FUNCTION BODIES, so they do not see:
--   * a db/*.sql that install_app.sh does not load. There is none today (the last one,
--     db/process_network_stats.sql, was deleted in #81);
--   * op-type literals in non-function objects (view definitions, column defaults, constraints).
--     Checked: the views in the three app schemas carry none today;
--   * a name or id assembled at runtime by concatenation or format() rather than written out.
-- Anything in those categories still has to be registered by hand.
--
-- scanned_op_type_ids() additionally only recognises `op_type_id =` and `op_type_id IN (`, so it
-- does not see `op_type_id = ANY(ARRAY[17, 73])`, `op_type_id BETWEEN a AND b`, or the reversed
-- `18 = op_type_id`. Arm 6 is warning-only, so a miss there costs coverage rather than
-- correctness - but do not read its silence as proof that no id is hardcoded.
--
-- Runs from scripts/install_app.sh only - never from process_block_range(). A RAISE inside the
-- block loop would halt ingestion for EVERY endpoint over one broken arm.
-- ---------------------------------------------------------------------------

-- Dropped rather than replaced: CREATE OR REPLACE cannot change a function's return type, and
-- these are the kind of signatures that grow a column.
DROP FUNCTION IF EXISTS haf_stats_app.expected_op_type_names();
DROP FUNCTION IF EXISTS haf_stats_app.scanned_op_type_literals();
DROP FUNCTION IF EXISTS haf_stats_app.scanned_op_type_ids();
-- Signature changed (gained the fatal-scan scope flag), so the old 0-arg form has to go:
-- CREATE OR REPLACE would leave it behind as an overload and every call would be ambiguous.
--
-- THE CURRENT SIGNATURE IS DROPPED TOO, and that line is the whole point of #60. The two
-- below cover the HISTORICAL forms; without the third, a plain CREATE FUNCTION collides
-- with the function a previous install of THIS version already created:
--     ERROR: function "assert_op_types" already exists with same argument types
-- install_app.sh runs this through psql_cmd (ON_ERROR_STOP=on), so the install aborts
-- with exit 3. That takes the whole app down by the GATING CHAIN, not by any restart
-- policy: haf-stats-process gates on the installer's service_completed_successfully, and
-- haf-stats-api gates on that.
--
-- Deliberately NOT "restart: on-failure on the setup service". !77 asserted that, was
-- wrong, and retracted it in scripts/install_app.sh and README.md -- this repo's compose
-- files contain no `restart:` key at all. It is true of the NODE's own module file, which
-- is where the 33 restarts observed on testapi came from; it is not true here.
--
-- The first install on a fresh database always worked, which is why this shipped. The
-- three functions above avoid it by dropping their own signatures; this one did not.
DROP FUNCTION IF EXISTS haf_stats_app.assert_op_types();
DROP FUNCTION IF EXISTS haf_stats_app.assert_op_types(BOOLEAN);
DROP FUNCTION IF EXISTS haf_stats_app.assert_op_types(BOOLEAN, BOOLEAN);

CREATE FUNCTION haf_stats_app.expected_op_type_names()
RETURNS TABLE (op_name TEXT, expected_id INT, used_by TEXT)
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT
        t.op_name,
        t.expected_id,
        t.used_by
    FROM (
        VALUES
        -- Resolved by NAME into locals. expected_id is NULL: the id is never assumed.
        ('hive::protocol::author_reward_operation',              NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::comment_benefactor_reward_operation',  NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::curation_reward_operation',            NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::claim_reward_balance_operation',       NULL::INT, 'db/process_financial.sql'),
        ('hive::protocol::interest_operation',                   NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::transfer_to_savings_operation',        NULL::INT, 'db/process_financial.sql'),
        ('hive::protocol::transfer_from_savings_operation',      NULL::INT, 'db/process_financial.sql'),
        ('hive::protocol::fill_transfer_from_savings_operation', NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::transfer_to_vesting_operation',        NULL::INT, 'db/process_financial.sql'),
        ('hive::protocol::fill_vesting_withdraw_operation',      NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::producer_reward_operation',            NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::liquidity_reward_operation',           NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::proposal_pay_operation',               NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::fill_order_operation',                 NULL::INT, 'db/process_financial.sql, db/process_block_range.sql'),
        ('hive::protocol::producer_missed_operation',            NULL::INT,
            'db/process_witness_blocks.sql, db/process_block_range.sql (GET /witnesses/missed-blocks reports zero misses)'),
        ('hive::protocol::account_created_operation',            NULL::INT,
            'db/process_account_cohorts.sql, db/process_community_registry.sql, db/process_block_range.sql'),

        -- Hardcoded NUMERIC ids: the name must exist AND still carry this id.
        -- 0/1/2/17/18 are non-virtual and consensus-ordered, so they are stable by construction;
        -- 73 is VIRTUAL and is the reason this column exists. transfer_operation is BOTH
        -- name-resolved (process_financial) and id-pinned (process_block_range), hence one row.
        ('hive::protocol::vote_operation',                       0,
            'db/process_block_range.sql, db/process_content_stats.sql (id 0)'),
        ('hive::protocol::comment_operation',                    1,
            'db/process_block_range.sql, db/process_content_stats.sql, db/process_content_cohorts.sql (id 1)'),
        ('hive::protocol::transfer_operation',                   2,
            'db/process_financial.sql (by name), db/process_block_range.sql (id 2)'),
        ('hive::protocol::delete_comment_operation',             17,
            'db/process_content_stats.sql (id 17, in IN (17, 73))'),
        ('hive::protocol::custom_json_operation',                18,
            'db/process_custom_json.sql, db/process_network_custom_json.sql, db/process_block_range.sql, db/process_community_registry.sql, db/seed_data.sql, endpoints/endpoint_schema.sql (id 18)'),
        ('hive::protocol::ineffective_delete_comment_operation', 73,
            'db/process_content_stats.sql, db/process_block_range.sql (id 73, VIRTUAL - the unstable one)')
    ) AS t (op_name, expected_id, used_by);
$fn$;

-- ---------------------------------------------------------------------------
-- What the INSTALLED CODE actually references. Split out of assert_op_types() so the arms can
-- share one scan and so the tests can assert on the set directly rather than on warning text
-- (a WARNING is not catchable in plpgsql, so a test that only called the assertion could not
-- tell "warned" from "said nothing").
--
-- kind = 'prefixed'   a correct, fully-qualified lookup           -> must be registered (arm 3)
-- kind = 'unprefixed' a name lookup MISSING the required prefix   -> broken today (arm 4)
--
-- A LANGUAGE sql function with a SQL-standard BEGIN ATOMIC body keeps its body in
-- pg_proc.prosqlbody and leaves prosrc as the EMPTY STRING, so scanning prosrc alone would skip
-- it silently. pg_get_function_sqlbody() deparses that form (PG14+, so both lanes) and preserves
-- the surrounding single quotes the regexes depend on; it returns NULL rather than erroring for
-- plpgsql and internal functions, hence the COALESCE tail. NOT pg_get_functiondef(), which also
-- covers both forms but RAISES '"x" is an aggregate function' for prokind = 'a' and would turn
-- "someone adds a CREATE AGGREGATE to these schemas" into a hard failure of every install.
--
-- Two parts of the 'prefixed' regex are load-bearing. DO NOT relax either:
--   * the surrounding single quotes keep the "-- hive::protocol::comment_operation" comments
--     that sit beside the hardcoded ids in process_content_stats / process_content_cohorts from
--     matching;
--   * the "_operation" suffix keeps replace(ot.name, 'hive::protocol::', '') in the three
--     rc-footprint endpoints from matching. Drop the suffix (e.g. '[^'']*') and that bare prefix
--     captures the EMPTY STRING as an "op name": 22 matches instead of 18.
-- "[a-z0-9_]+" is the tight form because an op name is never empty, but the quantifier is NOT
-- currently load-bearing: with the suffix required, "*" and "+" both yield the same 18 matches.
--
-- The 'unprefixed' regex anchors on the WORD "name" - \m is start-of-word in Postgres ARE and
-- "_" is a word character, so it matches `name =` / `ot.name =` / `hafd.operation_types.name =`
-- but NOT op_name, opname, type_name, app_name. That anchor is load-bearing and this arm is
-- FATAL: this app legitimately stores op names UNPREFIXED as DATA (process_financial writes
-- 'author_reward_operation' as a category value, the endpoints compare
-- category = 'transfer_operation'), so without \m any future column or alias ending in "name"
-- compared to a *_operation literal would abort the install - and the message would tell the
-- developer to add a prefix that would make that query wrong. Measured: 0 hits across every
-- installed function, and it still catches the exact D5 shape.
--
-- This file's own functions are excluded: expected_op_type_names() carries every literal by
-- definition, so scanning it would make the guard vacuous.
-- ---------------------------------------------------------------------------
CREATE FUNCTION haf_stats_app.scanned_op_type_literals()
RETURNS TABLE (kind TEXT, op_name TEXT, fn TEXT)
LANGUAGE sql
STABLE
AS $fn$
    WITH bodies AS (
        SELECT
            n.nspname || '.' || p.proname AS fn,
            COALESCE(NULLIF(p.prosrc, ''), PG_GET_FUNCTION_SQLBODY(p.oid), '') AS body
        FROM pg_proc AS p
        INNER JOIN pg_namespace AS n ON p.pronamespace = n.oid
        WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
          AND p.proname NOT IN (
              'expected_op_type_names', 'assert_op_types',
              'scanned_op_type_literals', 'scanned_op_type_ids'
          )
    )

    SELECT 'prefixed'::TEXT, m.parts[1], b.fn
    FROM bodies AS b
    CROSS JOIN LATERAL REGEXP_MATCHES(
        b.body, $re$'(hive::protocol::[a-z0-9_]+_operation)'$re$, 'g'
    ) AS m (parts)

    UNION

    SELECT 'unprefixed'::TEXT, m.parts[1], b.fn
    FROM bodies AS b
    CROSS JOIN LATERAL REGEXP_MATCHES(
        b.body, $re$\mname[[:space:]]*=[[:space:]]*'([a-z0-9_]+_operation)'$re$, 'g'
    ) AS m (parts);
$fn$;

-- Numeric op ids written as literals in installed code. Without this the numeric half of the
-- registry is only ever checked registry-against-catalog: changing IN (17, 73) to IN (17, 74) in
-- a processor, or adding a filter on a brand-new id, would pass every other arm silently. The
-- pattern deliberately matches only digits after "op_type_id =" / "op_type_id IN (", so
-- "op_type_id = _producer_missed_id" and "op_type_id IN (SELECT ...)" are skipped, not misparsed.
CREATE FUNCTION haf_stats_app.scanned_op_type_ids()
RETURNS TABLE (op_id INT, fn TEXT)
LANGUAGE sql
STABLE
AS $fn$
    SELECT DISTINCT
        d.digits[1]::INT,
        n.nspname || '.' || p.proname
    FROM pg_proc AS p
    INNER JOIN pg_namespace AS n ON p.pronamespace = n.oid
    CROSS JOIN LATERAL REGEXP_MATCHES(
        COALESCE(NULLIF(p.prosrc, ''), PG_GET_FUNCTION_SQLBODY(p.oid), ''),
        -- \m (word start) for the same reason arm 4's regex needs it: without it the pattern
        -- matches INSIDE an identifier, so a plpgsql local like `_rc_op_type_id = 5` would be
        -- reported as a hardcoded catalog id. Warning-only noise, but noise that trains people
        -- to ignore the arm.
        $re$\mop_type_id[[:space:]]*(?:=|IN)[[:space:]]*\(?[[:space:]]*([0-9][0-9,[:space:]]*)\)?$re$,
        'g'
    ) AS m (parts)
    -- Digit runs are pulled out of the capture with a second match rather than split on ',' and
    -- trimmed. The capture is greedy over [0-9,[:space:]], so a body with the id last on its line
    -- ("SET op_type_id = 73," + newline) yields a trailing whitespace-only fragment - and bare
    -- TRIM strips only SPACES, so a newline or tab survives a "<> ''" guard and the ::INT cast
    -- aborts the install with a raw 22P02 that never mentions op types. Matching [0-9]+ makes
    -- every value that reaches the cast a digit run by construction. The outer group is anchored
    -- on [0-9], so this always matches at least once and no site is lost.
    CROSS JOIN LATERAL REGEXP_MATCHES(m.parts[1], $re$[0-9]+$re$, 'g') AS d (digits)
    WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints')
      AND p.proname NOT IN (
          'expected_op_type_names', 'assert_op_types',
          'scanned_op_type_literals', 'scanned_op_type_ids'
      );
$fn$;

-- _fatal_scan_includes_endpoints controls whether the code-scan-driven FATAL arm (arm 4) may
-- abort on a body in haf_stats_endpoints. install_app.sh passes FALSE at step 3d, where those
-- bodies are still the PREVIOUS release's, and leaves the default TRUE for step 8f once step 6
-- has replaced them - see the arm 4 comment for why that ordering is load-bearing.
-- haf_stats_app and haf_stats_backend need no such guard: step 3 has just reloaded every body
-- this release ships for them. The WARNING arms are never scoped - they cannot abort anything,
-- so seeing the whole surface early is free.
--
-- _bypass_fatal downgrades the three fatal arms to a single loud WARNING instead of aborting.
-- It exists because the fatal arms can, in one residual case, make a node unrecoverable from the
-- source tree: an ORPHANED body in pg_proc (a renamed or re-signatured function this release no
-- longer ships) carrying an unprefixed lookup will fail arm 4 at step 8f, and the only fix is a
-- manual DROP FUNCTION on the node. Scoping the 3d call does not cover that, and the failure mode
-- is "the whole stack will not start". Set HAF_STATS_SKIP_OP_TYPE_ASSERT=1 for the install that
-- gets you back up, then fix the underlying cause and unset it.
--
-- It DOWNGRADES rather than SKIPS on purpose. A flag that silences the check entirely gets set
-- during an outage and then stays set, and the next person sees a clean install log over broken
-- data. This way the full diagnosis is still printed, every time, and it says plainly that the
-- gate was bypassed - so the log itself is the reminder.
CREATE FUNCTION haf_stats_app.assert_op_types(
    _fatal_scan_includes_endpoints BOOLEAN DEFAULT TRUE,
    _bypass_fatal BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    _catalog REGCLASS;
    _missing TEXT;
    _drifted TEXT;
    _unprefixed TEXT;
    _unregistered TEXT;
    _stale TEXT;
    _unregistered_ids TEXT;
    _names INT;
    _ids INT;
    _fatal TEXT;
BEGIN
    -- Environment self-guards. Both are WARNING + RETURN: never fail an install for an
    -- environment condition.
    --
    -- TO_REGCLASS is NOT safe to call bare here. On a schema that exists but on which the caller
    -- lacks USAGE it RAISES 42501 'permission denied for schema hafd' rather than returning NULL
    -- (measured on PG14.23), because the lookup does an ACL check before the missing_ok path.
    -- README advertises this function as safe to run by hand, and install_app.sh deliberately
    -- omits `|| true` on the grounds that environment conditions are handled in here - so a bare
    -- call would surface a raw 42501 that reads as genuine op-type breakage. TO_REGNAMESPACE has
    -- no such ACL check, and the handler covers the relation-level case.
    IF TO_REGNAMESPACE('hafd') IS NULL THEN
        RAISE WARNING 'schema hafd does not exist on this database - skipping the op-type assertion. This is not a HAF database.';
        RETURN;
    END IF;

    BEGIN
        _catalog := TO_REGCLASS('hafd.operation_types');
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE WARNING 'no USAGE on schema hafd for %, so the op-type assertion cannot read hafd.operation_types - skipping. Grant USAGE ON SCHEMA hafd, or run this as haf_stats_owner.', CURRENT_USER;
        RETURN;
    END;

    IF _catalog IS NULL THEN
        RAISE WARNING 'hafd.operation_types does not exist on this database - skipping the op-type assertion. HAF moved the catalog.';
        RETURN;
    END IF;

    -- An EMPTY catalog is a hard failure, NOT a warning. This IS a HAF database, and every name
    -- lookup in every processor would return NULL - precisely the silent-zeros failure this file
    -- exists to eliminate. A warning exits 0, compose proceeds, and nobody reads the setup log.
    -- Unreachable on the real stack anyway: haf-stats-setup gates on haf service_healthy, whose
    -- healthcheck is hive.is_instance_ready(), and hived's sql_serializer populates this catalog
    -- up front in one statement rather than lazily as ops are encountered (measured: op types
    -- with zero occurrences in a 5M-block 2016 replay are all present), so there is no
    -- partially-populated state to threshold against.
    IF NOT EXISTS (SELECT 1 FROM hafd.operation_types) THEN
        RAISE EXCEPTION 'hafd.operation_types is empty: hived has not populated the op-type catalog on this node. Every op type haf_stats resolves by name would return NULL and every affected endpoint would report zeros. Start HAF, then re-run scripts/install_app.sh.';
    END IF;

    -- Arm 1: a registered name that no longer resolves. THE failure this issue is about.
    SELECT STRING_AGG(FORMAT('%s (used by %s)', e.op_name, e.used_by), E'\n  ' ORDER BY e.op_name)
    INTO _missing
    FROM haf_stats_app.expected_op_type_names() AS e
    WHERE NOT EXISTS (
        SELECT 1 FROM hafd.operation_types AS ot WHERE ot.name = e.op_name
    );

    -- Arm 2: the mirror - a name that still exists but no longer carries the id the code writes.
    -- The LEFT JOIN and the 'no such name' fallback are defensive only: under the IF/ELSIF chain
    -- below, arm 2 is reached only when _missing IS NULL, i.e. when every registered name DOES
    -- resolve, so ot.id cannot be NULL here today. They exist so this query stays correct if the
    -- arms are ever reported independently instead of as a chain. IS DISTINCT FROM, never "=" on
    -- a scalar subquery: that form yields NULL on a missing row and the branch would not fire.
    SELECT STRING_AGG(
        FORMAT('%s: code hardcodes id %s, this node has id %s (used by %s)',
            e.op_name, e.expected_id, COALESCE(ot.id::TEXT, 'no such name'), e.used_by),
        E'\n  ' ORDER BY e.op_name)
    INTO _drifted
    FROM haf_stats_app.expected_op_type_names() AS e
    LEFT JOIN hafd.operation_types AS ot ON ot.name = e.op_name
    WHERE e.expected_id IS NOT NULL
      AND ot.id IS DISTINCT FROM e.expected_id;

    -- Arm 4: a name looked up WITHOUT the 'hive::protocol::' prefix. hafd.operation_types stores
    -- only fully-qualified names, so such a lookup is NULL on every node that has ever existed -
    -- it is broken the moment it is written, which is why this is fatal rather than a warning.
    -- This is defect D5 (docs/VERIFICATION.md) reproduced; arms 1 and 3 are both blind to it,
    -- because the registry's prefixed row still resolves and the prefixed scan never matches.
    --
    -- It is the ONLY fatal arm driven by the code scan, so it needs the scope guard that arms 1
    -- and 2 do not: those read the registry and the catalog, which carry nothing from an earlier
    -- release. The exposure is an ORDERING one, not just orphans. install_app.sh's first call
    -- runs BEFORE the endpoints are reloaded, so on a re-install pg_proc still holds the previous
    -- release's haf_stats_endpoints bodies - and if a shipped release ever contained a D5 lookup
    -- in an endpoint, the release that FIXES it would abort against the stale body before step 6
    -- could replace it. The fix would be uninstallable. So the first call is scoped to the
    -- schemas step 3 has just reloaded, and the full surface waits for the second call.
    SELECT STRING_AGG(FORMAT('%s (in %s)', s.op_name, s.fn), E'\n  ' ORDER BY s.op_name, s.fn)
    INTO _unprefixed
    FROM haf_stats_app.scanned_op_type_literals() AS s
    WHERE s.kind = 'unprefixed'
      AND (_fatal_scan_includes_endpoints OR SPLIT_PART(s.fn, '.', 1) <> 'haf_stats_endpoints');

    -- Arm 3: registry drift - code resolves a name nobody registered.
    SELECT STRING_AGG(FORMAT('%s (in %s)', s.op_name, s.fn), E'\n  ' ORDER BY s.op_name, s.fn)
    INTO _unregistered
    FROM haf_stats_app.scanned_op_type_literals() AS s
    WHERE s.kind = 'prefixed'
      AND NOT EXISTS (
          SELECT 1 FROM haf_stats_app.expected_op_type_names() AS e WHERE e.op_name = s.op_name
      );

    -- Arm 5: the reverse - a registered row no installed function uses any more. Left unattended
    -- these are what make arms 1 AND 2 abort an install over a dependency the code has dropped,
    -- so BOTH ways of using a row have to be checked: a row is dead only when its name appears in
    -- no body AND its pinned id appears in no body. transfer_operation is exactly why that is an
    -- AND rather than either alone - it is name-resolved in process_financial and id-pinned in
    -- process_block_range, so either signal on its own keeps it alive. For a name-only row
    -- expected_id IS NULL, so the id clause can never match and such rows behave as before.
    SELECT STRING_AGG(
        e.op_name || COALESCE(' (pinned at id ' || e.expected_id || ')', ''),
        E'\n  ' ORDER BY e.op_name)
    INTO _stale
    FROM haf_stats_app.expected_op_type_names() AS e
    WHERE NOT EXISTS (
        SELECT 1 FROM haf_stats_app.scanned_op_type_literals() AS s
        WHERE s.kind = 'prefixed' AND s.op_name = e.op_name
    )
    AND NOT EXISTS (
        SELECT 1 FROM haf_stats_app.scanned_op_type_ids() AS s
        WHERE s.op_id = e.expected_id
    );

    -- Arm 6: a numeric op id in the code that the registry does not declare, so arm 2 is not
    -- watching it.
    SELECT STRING_AGG(FORMAT('%s (in %s)', s.op_id, s.fn), E'\n  ' ORDER BY s.op_id, s.fn)
    INTO _unregistered_ids
    FROM haf_stats_app.scanned_op_type_ids() AS s
    WHERE NOT EXISTS (
        SELECT 1 FROM haf_stats_app.expected_op_type_names() AS e WHERE e.expected_id = s.op_id
    );

    -- Warnings first, so they are still on the operator's screen when a fatal arm aborts below.
    IF _unregistered IS NOT NULL THEN
        RAISE WARNING E'op-type registry drift - these names are resolved in code but not declared in db/op_type_registry.sql:\n  %\nRegister each one, so that a future hived rename fails arm 1 instead of silently zeroing an endpoint.', _unregistered;
    END IF;

    IF _stale IS NOT NULL THEN
        RAISE WARNING E'op-type registry drift - these rows are declared in db/op_type_registry.sql but no installed function resolves the name or hardcodes the id any more:\n  %\nDelete the rows. Left in place they will abort a future install over a rename or an id shift that no longer matters to this app.', _stale;
    END IF;

    IF _unregistered_ids IS NOT NULL THEN
        RAISE WARNING E'op-type registry drift - these op ids are hardcoded in code but not declared in db/op_type_registry.sql:\n  %\nAdd an expected_id row for each, or the pin is unguarded: if that id ever moves the processor reads a different operation with no error.', _unregistered_ids;
    END IF;

    -- IF/ELSIF rather than three independent IFs: SQL does not guarantee short-circuit
    -- evaluation, and one arm's failure usually explains the others (a hived upgrade that renames
    -- one op typically moves several). Each arm reports EVERY offender, not just the first.
    IF _missing IS NOT NULL THEN
        _fatal := FORMAT(E'haf_stats depends on op type(s) that are no longer in hafd.operation_types:\n  %s\nThe processor resolves the type by that exact NAME, so the lookup returns NULL, the aggregation arm matches no rows, and the endpoint reports ZEROS with no error (hived renamed sps_fund_operation to dhf_funding_operation once already). Fix the name at the site named above AND in db/op_type_registry.sql, the one place these are declared; if the dependency is gone, delete its row there.', _missing);
    ELSIF _drifted IS NOT NULL THEN
        _fatal := FORMAT(E'haf_stats hardcodes op type id(s) that no longer match hafd.operation_types:\n  %s\nThe processor filters on the literal id, so it is now reading a DIFFERENT operation - silently wrong data, not zeros. Switch the site to a name lookup, or update both the code and the expected_id in db/op_type_registry.sql.', _drifted);
    ELSIF _unprefixed IS NOT NULL THEN
        _fatal := FORMAT(E'haf_stats looks up op type name(s) without the required ''hive::protocol::'' prefix:\n  %s\nhafd.operation_types stores only fully-qualified names, so each of these resolves to NULL on every node and its aggregation arm silently matches nothing. This is defect D5 (docs/VERIFICATION.md) again.\n\nThe function is named above. If it still exists in the source tree, add the prefix there. If it does NOT - a renamed or re-signatured function whose old body was never dropped - this is an ORPHAN left in pg_proc by an earlier release, and the fix is to drop it on this node: DROP FUNCTION <the function named above>(<its argument types>); then re-run scripts/install_app.sh. \\df+ <name> lists the signatures.', _unprefixed);
    END IF;

    IF _fatal IS NOT NULL THEN
        -- Not bypassed: this raises, so nothing below it runs.
        IF NOT _bypass_fatal THEN
            RAISE EXCEPTION '%', _fatal
                USING HINT = 'If this node must come up before the cause can be fixed, re-run scripts/install_app.sh with HAF_STATS_SKIP_OP_TYPE_ASSERT=1. That downgrades this to a warning; it does not fix the data.';
        END IF;

        RAISE WARNING E'OP-TYPE ASSERTION BYPASSED - HAF_STATS_SKIP_OP_TYPE_ASSERT is set, so this install is proceeding over a condition that would normally abort it. The data it describes is wrong or empty on this node until the cause is fixed. Unset the variable once it is.\n\n%', _fatal;
        RETURN;   -- the warning IS the outcome; do not fall through to the "registry OK" notice
    END IF;

    SELECT COUNT(*), COUNT(e.expected_id) INTO _names, _ids
    FROM haf_stats_app.expected_op_type_names() AS e;

    RAISE NOTICE 'haf_stats: op-type registry OK - % name(s) resolve in hafd.operation_types, % hardcoded id(s) still match', _names, _ids;
END;
$fn$;

RESET ROLE;
