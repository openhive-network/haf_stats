-- Behavioural probes for the op-type dependency assertion (issue #56).
--
-- Runs LAST in the stub lane's setup chain (docker/docker-compose-ci.yml), as postgres, after
-- every processor and the endpoints exist. psql runs the chain with ON_ERROR_STOP=1, so a
-- RAISE EXCEPTION here fails the job.
--
-- WHY THIS FILE EXISTS. The real registry cannot be asserted here: tests/ci_setup.sql seeds
-- hafd.operation_types with 7 rows whose ids are deliberately NOT mainnet's (vote is id 1 in the
-- stub, where the real chain has 1 = comment), so haf_stats_app.assert_op_types() would fail on
-- this database by construction. And the stub lane never runs scripts/install_app.sh, which is
-- the only caller of that function.
--
-- So the split is: the REAL lane (the CI sync job, which runs install_app.sh against a real
-- 93-row catalog) tests the registry's CONTENT, and this file tests the assertion's MECHANISM.
-- Without it every failure arm ships unexecuted - the real lane only ever walks the pass path.
--
-- Each arm patches haf_stats_app.expected_op_type_names() inside a transaction and ROLLBACKs, so
-- the shipped registry is left exactly as installed. Replacing the function mid-session is
-- measured to be immediately visible to assert_op_types() (PostgreSQL invalidates the dependent
-- cached plans on CREATE OR REPLACE FUNCTION), and the rollback restores the original.
--
-- FATAL arms are asserted by catching the exception. WARNING arms cannot be: a WARNING is not
-- catchable in plpgsql, so a test that only called the assertion could not tell "warned" from
-- "said nothing". Those arms assert on haf_stats_app.scanned_op_type_literals() /
-- scanned_op_type_ids() directly - the same sets the warnings are built from - AND assert that
-- assert_op_types() does NOT raise, which is the property that keeps a bookkeeping mismatch from
-- taking a production stack down.
--
-- NOTE on arm 6 noise: the stub's op ids are deliberately non-mainnet, and the processors it
-- loads hardcode 0/1/2/17/18/73, so the numeric-drift warning fires here on every run for the
-- ids the stub registry cannot legally pin (registering vote at 0 would make arm 2 fatal,
-- because this catalog says vote is 1). Arm (j) asserts that set explicitly rather than
-- pretending it is absent.

-- ---------------------------------------------------------------------------
-- Helpers. Created outside any transaction so they survive each arm's ROLLBACK.
-- ---------------------------------------------------------------------------

-- The stub-true registry: only what is both (a) actually resolvable on this stub catalog and
-- (b) sufficient to satisfy the drift arms. account_created and producer_missed are the two
-- op-type names the stub's loaded processors (process_account_cohorts,
-- process_community_registry, process_witness_blocks) carry as quoted literals, so omitting
-- either would make every arm below report drift it does not mean to test. custom_json is
-- pinned at 18, one of the few ids the stub shares with mainnet.
CREATE OR REPLACE FUNCTION pg_temp.install_registry(_extra_rows TEXT DEFAULT '')
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
BEGIN
    EXECUTE FORMAT($ddl$
        CREATE OR REPLACE FUNCTION haf_stats_app.expected_op_type_names()
        RETURNS TABLE (op_name TEXT, expected_id INT, used_by TEXT)
        LANGUAGE sql
        IMMUTABLE
        AS $body$
            SELECT t.op_name, t.expected_id, t.used_by
            FROM (VALUES
                ('hive::protocol::account_created_operation', NULL::INT, 'stub'),
                ('hive::protocol::producer_missed_operation', NULL::INT, 'stub'),
                ('hive::protocol::custom_json_operation', 18, 'stub')
                %s
            ) AS t (op_name, expected_id, used_by);
        $body$;
    $ddl$, _extra_rows);
END;
$fn$;

-- Asserts on the MESSAGE, not merely that something threw: a WHEN OTHERS that accepts any error
-- would report a typo'd function name as a passing test. The "did not fire" RAISE sits OUTSIDE
-- the inner block so that block's own handler cannot swallow it.
CREATE OR REPLACE FUNCTION pg_temp.expect_failure(_arm TEXT, _needles TEXT[])
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    _err TEXT;
    _needle TEXT;
BEGIN
    BEGIN
        PERFORM haf_stats_app.assert_op_types();
    EXCEPTION WHEN OTHERS THEN
        _err := SQLERRM;
    END;

    IF _err IS NULL THEN
        RAISE EXCEPTION '%: assert_op_types() did not raise.', _arm;
    END IF;

    FOREACH _needle IN ARRAY _needles LOOP
        IF POSITION(_needle IN _err) = 0 THEN
            RAISE EXCEPTION '%: assert_op_types() raised but did not name "%". Message: %', _arm, _needle, _err;
        END IF;
    END LOOP;

    RAISE NOTICE '% OK', _arm;
END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.expect_ok(_arm TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    _err TEXT;
BEGIN
    BEGIN
        PERFORM haf_stats_app.assert_op_types();
    EXCEPTION WHEN OTHERS THEN
        _err := SQLERRM;
    END;

    IF _err IS NOT NULL THEN
        RAISE EXCEPTION '%: assert_op_types() raised when it should have passed: %', _arm, _err;
    END IF;

    RAISE NOTICE '% OK', _arm;
END;
$fn$;

-- A drift arm is a WARNING, so assert on the set the warning is built from, and separately that
-- the install is NOT aborted. _expect_fn NULL means "this name must NOT be reported".
CREATE OR REPLACE FUNCTION pg_temp.expect_drift(_arm TEXT, _kind TEXT, _op_name TEXT, _expect_fn TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    _found TEXT;
BEGIN
    SELECT STRING_AGG(s.fn, ', ' ORDER BY s.fn) INTO _found
    FROM haf_stats_app.scanned_op_type_literals() AS s
    WHERE s.kind = _kind AND s.op_name = _op_name;

    IF _expect_fn IS NULL THEN
        IF _found IS NOT NULL THEN
            RAISE EXCEPTION '%: "%" should NOT have been reported, but was found in %', _arm, _op_name, _found;
        END IF;
    ELSE
        IF _found IS NULL THEN
            RAISE EXCEPTION '%: the scan did not report "%" at all.', _arm, _op_name;
        END IF;
        IF POSITION(_expect_fn IN _found) = 0 THEN
            RAISE EXCEPTION '%: the scan reported "%" in %, expected it to include %', _arm, _op_name, _found, _expect_fn;
        END IF;
    END IF;

    RAISE NOTICE '% OK', _arm;
END;
$fn$;

-- Exact, not a magic threshold: capture the shipped registry so a legitimate future shrink is
-- not misdiagnosed as an arm leaking its stub patch past ROLLBACK.
CREATE TEMP TABLE shipped_registry AS
SELECT * FROM haf_stats_app.expected_op_type_names();

-- ---------------------------------------------------------------------------
-- (a) Positive control. Everything registered resolves; nothing unregistered is in scope.
--     Without this the negative arms below could all be passing for the wrong reason.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
SELECT pg_temp.expect_ok('(a) positive control');
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (b) FATAL: a registered name that no longer resolves - the failure #56 is about.
--     sps_fund_operation is a real precedent: hived renamed it to dhf_funding_operation, so it
--     resolves on no current node, stub or mainnet.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry(
    $$, ('hive::protocol::sps_fund_operation', NULL::INT, 'db/nonexistent.sql')$$
);
SELECT pg_temp.expect_failure(
    '(b) missing name',
    ARRAY['hive::protocol::sps_fund_operation', 'db/nonexistent.sql', 'ZEROS']
);
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (c) FATAL: a hardcoded id that no longer belongs to the op the code means. The message must
--     carry BOTH numbers - "expected 99, found 18" is what makes it actionable.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry(
    $$, ('hive::protocol::transfer_operation', 99, 'db/process_block_range.sql')$$
);
SELECT pg_temp.expect_failure(
    '(c) drifted id',
    ARRAY['hive::protocol::transfer_operation', 'code hardcodes id 99', 'this node has id 2', 'wrong data']
);
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (d) WARNING: code resolves a name the registry does not declare.
--
--     The probe lives in haf_stats_endpoints ON PURPOSE. It is the only thing pinning the scan's
--     schema list: narrow db/op_type_registry.sql to IN ('haf_stats_app') by typo or refactor and
--     this arm fails. Without it, install_app.sh step 8f - which exists precisely so the drift
--     scan can see endpoint bodies - could silently become a duplicate of step 3d.
--
--     Asserted NOT to abort: this app only drops the exact signatures it immediately recreates
--     and never sweeps a schema, so a renamed or re-signatured function's body persists in
--     pg_proc, and a fatal drift arm would let one orphan brick every subsequent install.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
CREATE FUNCTION haf_stats_endpoints.ci_op_type_drift_probe()
RETURNS SMALLINT
LANGUAGE sql
AS $probe$
    SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_reward_operation';
$probe$;
SELECT pg_temp.expect_drift('(d) drift detected in haf_stats_endpoints', 'prefixed',
    'hive::protocol::producer_reward_operation', 'ci_op_type_drift_probe');
SELECT pg_temp.expect_ok('(d) drift warns but does not abort the install');
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (e) The scan does NOT false-positive. Regression test for the two load-bearing parts of the
--     prefixed regex; the probe body carries one shape for each:
--       * an unquoted "-- hive::protocol::x_operation" comment, which sits next to every
--         hardcoded id in db/process_content_stats.sql and db/process_content_cohorts.sql. Drop
--         the required single quotes and this arm fails;
--       * replace(ot.name, 'hive::protocol::', ''), which appears in three rc-footprint
--         endpoints. Drop the required "_operation" suffix (e.g. '[^'']*') and that bare prefix
--         captures the EMPTY STRING as an op name, so this arm fails - as would every install.
--     This arm does NOT discriminate "+" from "*": with the suffix required, neither matches the
--     bare prefix. "+" is simply the tight form. Do not "fix" the regex on the strength of this
--     arm passing under both.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
CREATE FUNCTION haf_stats_app.ci_op_type_comment_probe()
RETURNS TEXT
LANGUAGE sql
AS $probe$
    -- A name no Hive node has and no processor can resolve. expect_drift's NULL branch reads only
    -- scanned_op_type_literals(), never hafd.operation_types, so the name does not have to be real
    -- - and a synthetic one is what makes this arm independent of which processors the stub chain
    -- happens to load. A real op name here would couple it: db/process_financial.sql resolves
    -- producer_reward by name, so adding that file to docker-compose-ci.yml would fail this arm.
    -- hive::protocol::ci_comment_probe_operation
    SELECT replace(name, 'hive::protocol::', '') FROM hafd.operation_types WHERE id = 18;
$probe$;
SELECT pg_temp.expect_drift('(e) comment and bare prefix are not captured', 'prefixed',
    'hive::protocol::ci_comment_probe_operation', NULL);
SELECT pg_temp.expect_ok('(e) scan does not false-positive');
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (f) Environment self-guards, which are asymmetric on purpose.
--     An ABSENT catalog means this is not a HAF database: warn and return, so the assertion
--     never fails an install for an environment condition.
--     An EMPTY catalog means it IS a HAF database in which every name lookup in every processor
--     returns NULL - the exact silent-zeros state this assertion exists to eliminate - so that
--     one is a hard failure. A warning there would exit 0 and nobody reads the setup log.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
ALTER TABLE hafd.operation_types RENAME TO ci_operation_types_hidden;
SELECT pg_temp.expect_ok('(f1) absent catalog warns and returns');
ROLLBACK;

BEGIN;
SELECT pg_temp.install_registry();
DELETE FROM hafd.operation_types;
SELECT pg_temp.expect_failure(
    '(f2) empty catalog is a hard failure',
    ARRAY['hafd.operation_types is empty']
);
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (f3) A caller without USAGE on schema hafd must warn and return, not raise. TO_REGCLASS is
--      NOT safe to call bare for this: on a schema that exists but is not accessible it raises
--      42501 rather than returning NULL, which from install_app.sh would read as genuine op-type
--      breakage, and which contradicts the README's claim that the function is safe to run by
--      hand. Guarded by TO_REGNAMESPACE plus an insufficient_privilege handler.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
CREATE ROLE ci_op_type_nousage NOLOGIN;
GRANT USAGE ON SCHEMA haf_stats_app TO ci_op_type_nousage;
GRANT EXECUTE ON FUNCTION haf_stats_app.assert_op_types(BOOLEAN, BOOLEAN) TO ci_op_type_nousage;
SET ROLE ci_op_type_nousage;
SELECT pg_temp.expect_ok('(f3) no USAGE on hafd warns and returns');
RESET ROLE;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (g) The scan sees a SQL-standard BEGIN ATOMIC body. Same probe as (d), in the other body
--     style: such a function keeps its body in pg_proc.prosqlbody and leaves prosrc as the EMPTY
--     STRING, so a scan of prosrc alone reports "registry OK" without having looked at it.
--     Nothing else catches that - sqlfluff parses BEGIN ATOMIC happily, so the CI lint would not
--     reject the style either.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
CREATE FUNCTION haf_stats_app.ci_op_type_atomic_probe()
RETURNS SMALLINT
LANGUAGE sql
STABLE
BEGIN ATOMIC
    SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_reward_operation';
END;
SELECT pg_temp.expect_drift('(g) BEGIN ATOMIC bodies are scanned', 'prefixed',
    'hive::protocol::producer_reward_operation', 'ci_op_type_atomic_probe');
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (h) FATAL: a name looked up WITHOUT the 'hive::protocol::' prefix. This is defect D5
--     (docs/VERIFICATION.md) reproduced - the founding example of the whole file - and it is
--     invisible to every other arm: the registry's prefixed row still resolves, so arm 1 passes,
--     and the prefixed scan cannot match an unprefixed literal, so arm 3 says nothing. It is
--     fatal rather than a warning because hafd.operation_types stores only qualified names, so
--     such a lookup is NULL on every node that has ever existed - broken the moment it is written.
--     The probe lives in haf_stats_backend, pinning the third schema in the scan's list.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
CREATE FUNCTION haf_stats_backend.ci_op_type_d5_probe()
RETURNS SMALLINT
LANGUAGE sql
AS $probe$
    SELECT id FROM hafd.operation_types WHERE name = 'producer_reward_operation';
$probe$;
SELECT pg_temp.expect_drift('(h) unprefixed lookup is detected in haf_stats_backend', 'unprefixed',
    'producer_reward_operation', 'ci_op_type_d5_probe');
SELECT pg_temp.expect_failure(
    '(h) unprefixed lookup is FATAL',
    ARRAY['producer_reward_operation', 'ci_op_type_d5_probe', 'prefix']
);
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (i) WARNING: a registered name that no installed function resolves any more. Left unattended,
--     these are exactly what make arm 1 abort an install over a dependency the code has dropped,
--     so they are surfaced rather than left to be discovered by a future hived rename.
-- ---------------------------------------------------------------------------
BEGIN;
-- Seeded rather than reusing a real op name. The assertion is "no installed function uses this
-- row", which any processor added to the stub chain could falsify - db/process_financial.sql
-- resolves transfer_operation by name, which is what this arm used to register. The row still has
-- to RESOLVE in the catalog, or fatal arm 1 fires before arm 5 is ever reported.
INSERT INTO hafd.operation_types (id, name, is_virtual)
VALUES (240, 'hive::protocol::ci_stale_probe_operation', TRUE)
ON CONFLICT (id) DO NOTHING;
SELECT pg_temp.install_registry(
    $$, ('hive::protocol::ci_stale_probe_operation', NULL::INT, 'nothing resolves this any more')$$
);
DO $$
DECLARE
    _n INT;
BEGIN
    -- Mirrors arm 5's own predicate: dead only when NEITHER the name nor the pinned id is in code.
    SELECT COUNT(*) INTO _n
    FROM haf_stats_app.expected_op_type_names() AS e
    WHERE NOT EXISTS (
          SELECT 1 FROM haf_stats_app.scanned_op_type_literals() AS s
          WHERE s.kind = 'prefixed' AND s.op_name = e.op_name
      )
      AND NOT EXISTS (
          SELECT 1 FROM haf_stats_app.scanned_op_type_ids() AS s
          WHERE s.op_id = e.expected_id
      );
    IF _n = 0 THEN
        RAISE EXCEPTION '(i) stale registry row was not detected';
    END IF;
    RAISE NOTICE '(i) stale registry row detected OK (% row(s))', _n;
END
$$;
SELECT pg_temp.expect_ok('(i) stale registry row warns but does not abort');
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (j) WARNING: numeric op ids hardcoded in code that the registry does not declare. Without this
--     the numeric half of the registry is only ever checked registry-against-catalog, so
--     changing IN (17, 73) to IN (17, 74) in a processor would pass every other arm in silence.
--     The stub's loaded processors hardcode 0/1/2/17/18/73 and the stub registry can only
--     legally pin 18, so the expected report here is exactly the other five.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
DO $$
DECLARE
    _found TEXT;
BEGIN
    -- Ordered in the subquery and aggregated outside, so the ids come out in NUMERIC order.
    -- STRING_AGG(DISTINCT ...) would force ORDER BY to match the DISTINCT expression, i.e. text
    -- order - which produced the correct-but-alarming '0,1,17,2,73'.
    SELECT STRING_AGG(q.op_id::TEXT, ',') INTO _found
    FROM (
        SELECT DISTINCT s.op_id
        FROM haf_stats_app.scanned_op_type_ids() AS s
        WHERE NOT EXISTS (
            SELECT 1 FROM haf_stats_app.expected_op_type_names() AS e WHERE e.expected_id = s.op_id
        )
        ORDER BY s.op_id
    ) AS q;
    IF _found IS DISTINCT FROM '0,1,2,17,73' THEN
        RAISE EXCEPTION '(j) unregistered numeric op ids = [%], expected [0,1,2,17,73]. The stub processors hardcode 0/1/2/17/18/73 and the stub registry pins only 18.', COALESCE(_found, 'none');
    END IF;
    RAISE NOTICE '(j) unregistered numeric op ids detected OK: %', _found;
END
$$;
SELECT pg_temp.expect_ok('(j) numeric id drift warns but does not abort');
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (k) scanned_op_type_ids() must not ABORT on a body whose op-id literal is the last thing on
--     its line. The capture is greedy over [0-9,[:space:]], so "op_type_id = 73," + newline used
--     to yield a whitespace-only fragment; bare TRIM strips only SPACES, so the newline survived
--     a "<> ''" guard and the ::INT cast raised 22P02 - aborting the install from inside arm 6's
--     own scan, which the severity model says must never be able to do that. Worse than a
--     warning, because it raised before any arm's WARNING printed, so the log showed only
--     'invalid input syntax for type integer' with no mention of op types.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
CREATE FUNCTION haf_stats_backend.ci_op_type_multiline_probe()
RETURNS TABLE (flag BOOLEAN, n INT)
LANGUAGE sql
AS $probe$
    SELECT o.op_type_id = 73,
           o.op_type_id
    FROM hafd.operations AS o
    LIMIT 1;
$probe$;
DO $$
DECLARE
    _ids TEXT;
BEGIN
    -- string_agg forces the cast to be evaluated: a bare COUNT(*) lets the planner skip the
    -- projection entirely, which is exactly how this bug hid the first time it was looked for.
    SELECT STRING_AGG(s.op_id::TEXT, ',' ORDER BY s.op_id) INTO _ids
    FROM haf_stats_app.scanned_op_type_ids() AS s
    WHERE s.fn LIKE '%ci_op_type_multiline_probe%';

    IF _ids IS DISTINCT FROM '73' THEN
        RAISE EXCEPTION '(k) expected the probe to report id 73, got [%]', COALESCE(_ids, 'none');
    END IF;
    RAISE NOTICE '(k) trailing-comma body scanned without aborting OK';
END
$$;
SELECT pg_temp.expect_ok('(k) trailing-comma body does not abort the assertion');
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (l) The FATAL unprefixed arm must not fire on an unprefixed op name used as DATA. This app
--     stores exactly that: process_financial writes 'author_reward_operation' as a category
--     value and the endpoints compare category = 'transfer_operation'. The arm's regex anchors
--     on the WORD "name" (\m) precisely so a column or alias ending in "name" - op_name, opname,
--     type_name - is not mistaken for a catalog lookup. Without \m this arm fails, and the
--     install would abort telling the developer to add a prefix that would make the query wrong.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
CREATE FUNCTION haf_stats_backend.ci_op_type_data_column_probe()
RETURNS INT
LANGUAGE sql
AS $probe$
    SELECT COUNT(*)::INT
    FROM (SELECT 'transfer_operation'::TEXT AS op_name) AS q
    WHERE q.op_name = 'transfer_operation';
$probe$;
SELECT pg_temp.expect_drift('(l) an op name used as data is not a D5 hit', 'unprefixed',
    'transfer_operation', NULL);
SELECT pg_temp.expect_ok('(l) unprefixed arm does not fire on data columns');
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (m) THE RE-INSTALL CASE. Arm 4 is the only FATAL arm driven by the code scan, so unlike arms 1
--     and 2 it can see a body this release did not write. install_app.sh calls the assertion
--     twice for that reason, and this arm pins the difference:
--
--       step 3d  assert_op_types(FALSE)  endpoints excluded from the fatal arm
--       step 8f  assert_op_types()       full surface, after step 6 replaced them
--
--     Without the scope, a release FIXING a shipped unprefixed lookup in an endpoint would abort
--     at 3d against the previous release's body - before step 6 could replace it - and the fix
--     would be uninstallable. Every other arm only ever sees probes it created itself in the
--     same install generation, so nothing else models this.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry();
-- Stands in for a stale endpoint body carrying a D5 lookup from an earlier release.
CREATE FUNCTION haf_stats_endpoints.ci_op_type_stale_endpoint_probe()
RETURNS SMALLINT
LANGUAGE sql
AS $probe$
    SELECT id FROM hafd.operation_types WHERE name = 'producer_reward_operation';
$probe$;
DO $$
DECLARE
    _err TEXT;
BEGIN
    -- 3d form: must NOT abort, or the fix for this very body could never be installed.
    BEGIN
        PERFORM haf_stats_app.assert_op_types(FALSE);
    EXCEPTION WHEN OTHERS THEN
        _err := SQLERRM;
    END;
    IF _err IS NOT NULL THEN
        RAISE EXCEPTION '(m) step-3d form aborted on a stale endpoint body - a release fixing that body could not install: %', _err;
    END IF;

    -- 8f form: the full surface MUST still catch it, or scoping would have created a blind spot.
    _err := NULL;
    BEGIN
        PERFORM haf_stats_app.assert_op_types();
    EXCEPTION WHEN OTHERS THEN
        _err := SQLERRM;
    END;
    IF _err IS NULL THEN
        RAISE EXCEPTION '(m) step-8f form did NOT catch the unprefixed endpoint lookup';
    END IF;
    IF POSITION('ci_op_type_stale_endpoint_probe' IN _err) = 0 THEN
        RAISE EXCEPTION '(m) step-8f form raised but did not name the function: %', _err;
    END IF;
    IF POSITION('DROP FUNCTION' IN _err) = 0 THEN
        RAISE EXCEPTION '(m) the arm-4 message must give the DROP FUNCTION recovery, since the site may no longer exist in the tree. Got: %', _err;
    END IF;
    RAISE NOTICE '(m) stale endpoint body: 3d tolerates it, 8f catches it and says how to recover OK';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- (n) THE ESCAPE HATCH. HAF_STATS_SKIP_OP_TYPE_ASSERT=1 (install_app.sh) passes _bypass_fatal,
--     which DOWNGRADES the fatal arms to one loud warning rather than skipping the check. It
--     exists for the one case the step-3d scoping cannot reach: an orphaned body in pg_proc that
--     no longer exists in the source tree, where the only real fix is a manual DROP FUNCTION on
--     the node and the failure mode meanwhile is "the whole stack will not start".
--
--     Three things have to hold, and a plain "it did not raise" would only prove the first:
--       * with the flag off, the condition still aborts;
--       * with it on, the install proceeds;
--       * with it on, the assertion does NOT claim to be OK - the diagnosis is still printed and
--         the success NOTICE is suppressed, so a bypassed install cannot read as a clean one.
-- ---------------------------------------------------------------------------
BEGIN;
SELECT pg_temp.install_registry(
    $$, ('hive::protocol::sps_fund_operation', NULL::INT, 'db/nonexistent.sql')$$
);
SELECT pg_temp.expect_failure(
    '(n) with the hatch closed the condition still aborts',
    ARRAY['hive::protocol::sps_fund_operation']
);
DO $$
DECLARE
    _err TEXT;
BEGIN
    BEGIN
        PERFORM haf_stats_app.assert_op_types(TRUE, TRUE);
    EXCEPTION WHEN OTHERS THEN
        _err := SQLERRM;
    END;
    IF _err IS NOT NULL THEN
        RAISE EXCEPTION '(n) the hatch did not open - assert_op_types(TRUE, TRUE) still aborted: %', _err;
    END IF;
    RAISE NOTICE '(n) escape hatch downgrades the fatal arm without skipping it OK';
END
$$;
ROLLBACK;

-- ---------------------------------------------------------------------------
-- The shipped registry must be exactly as installed: every arm above rolled back.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    _diff INT;
    _n INT;
BEGIN
    SELECT COUNT(*) INTO _diff FROM (
        SELECT op_name, expected_id, used_by FROM haf_stats_app.expected_op_type_names()
        EXCEPT ALL
        SELECT op_name, expected_id, used_by FROM shipped_registry
    ) AS a;

    IF _diff <> 0 THEN
        RAISE EXCEPTION 'the shipped op-type registry differs from the one captured before the arms ran: an arm leaked its stub patch past ROLLBACK';
    END IF;

    SELECT COUNT(*) INTO _diff FROM (
        SELECT op_name, expected_id, used_by FROM shipped_registry
        EXCEPT ALL
        SELECT op_name, expected_id, used_by FROM haf_stats_app.expected_op_type_names()
    ) AS b;

    IF _diff <> 0 THEN
        RAISE EXCEPTION 'the shipped op-type registry lost row(s) that were present before the arms ran';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname LIKE 'haf_stats%' AND p.proname LIKE 'ci_op_type%') THEN
        RAISE EXCEPTION 'a probe function survived its ROLLBACK';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ci_op_type_nousage') THEN
        RAISE EXCEPTION 'the (f3) probe role survived its ROLLBACK';
    END IF;

    SELECT COUNT(*) INTO _n FROM shipped_registry;
    RAISE NOTICE 'op-type assertion probes OK: % registered dependencies, registry byte-identical', _n;
END
$$;
