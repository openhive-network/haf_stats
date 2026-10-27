-- The custom_json-era staging of a massive-sync batch, against the statements it replaced, which
-- are kept below verbatim as the reference:
--   * prepare_batch_ops' full set, now read block by block rather than joined to hafd.blocks
--     per operation;
--   * prepare_batch_authored_ops, whose primary key is now added after the load;
--   * process_active_users' counts, now COUNT(*) per account and one DISTINCT per op;
--   * account_custom_json_rows, now built from the authored ops' custom_json signers instead
--     of re-reading the signers from the bodies;
--   * account_custom_json_rows and network_custom_json_rows, which now read the batch's
--     custom_json ops with their id and exact RC share staged once (prepare_batch_custom_json_ops).
--
-- Blocks 6610-6612 cross midnight and hold votes, posts, comments, transfers, a virtual op, and
-- custom_json ops: one signer, several signers, an account in both auth lists, a signer that is
-- no account, no id at all, and ops in priced transactions, in an unpriced one and in none. Every
-- comparison runs over the whole range and over each block as a batch of its own. Mutation
-- checks then run the shipped functions with a defect put in, and the comparison must catch it.
--
-- One transaction, rolled back.
\set ON_ERROR_STOP on

BEGIN;

UPDATE haf_stats_app.app_status SET last_processed_block = 0;

-- The chain's vote_operation id; the stub gives its name to id 1, the chain's comment_operation.
UPDATE hafd.operation_types SET name = 'hive::protocol::comment_operation' WHERE id = 1;
INSERT INTO hafd.operation_types (id, name, is_virtual) VALUES
(0, 'hive::protocol::vote_operation', FALSE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO hafd.blocks (num, created_at) VALUES
(6610, '2021-10-05 23:59:57'),
(6611, '2021-10-06 00:00:00'),
(6612, '2021-10-06 00:00:03');

INSERT INTO hafd.accounts (id, name) VALUES
(66101, 'cjb-alice'),
(66102, 'cjb-bob'),
(66103, 'cjb-carol'),
(66104, 'cjb-dave');

-- 6610 tx 0 and tx 1, 6611 tx 1 and 6612 tx 0 are priced; 6611 tx 0 has no recorded cost; 6610
-- tx 2 has no transaction row; ops without trx_in_block belong to no transaction.
INSERT INTO hafd.transactions (block_num, trx_in_block, rc_cost) VALUES
(6610, 0, 900000),
(6610, 1, 700001),
(6611, 0, NULL),
(6611, 1, 300000),
(6612, 0, 50000);

INSERT INTO hafd.operations (id, op_type_id, body_value, trx_in_block) VALUES
(hafd.operation_id(6610, 1), 0, '{"voter": "cjb-alice", "author": "cjb-bob", "permlink": "p", "weight": 10000}', 0),
(hafd.operation_id(6610, 2), 18, '{"id": "follow", "json": "[]", "required_auths": [], "required_posting_auths": ["cjb-alice"]}', 0),
(hafd.operation_id(6610, 3), 18, '{"id": "sm_claim_daily", "json": "{}", "required_auths": ["cjb-bob"], "required_posting_auths": ["cjb-carol", "cjb-bob"]}', 1),
(hafd.operation_id(6610, 4), 2, '{"from": "cjb-bob", "to": "cjb-alice", "amount": "1.000 HIVE", "memo": ""}', 1),
(hafd.operation_id(6610, 5), 1, '{"author": "cjb-carol", "permlink": "post", "parent_author": "", "body": "x"}', 2),
(hafd.operation_id(6610, 6), 18, '{"json": "{}", "required_auths": [], "required_posting_auths": ["cjb-dave"]}', 0),
(hafd.operation_id(6610, 7), 18, '{"id": "follow", "json": "[1]", "required_auths": [], "required_posting_auths": ["cjb-alice", "cjb-nobody"]}', NULL),
(hafd.operation_id(6611, 1), 18, '{"id": "sm_claim_daily", "json": "{}", "required_auths": [], "required_posting_auths": ["cjb-alice", "cjb-bob"]}', 0),
(hafd.operation_id(6611, 2), 0, '{"voter": "cjb-bob", "author": "cjb-carol", "permlink": "post", "weight": 5000}', 0),
(hafd.operation_id(6611, 3), 18, '{"id": "follow", "json": "[2]", "required_auths": ["cjb-carol"], "required_posting_auths": []}', 1),
(hafd.operation_id(6611, 4), 1, '{"author": "cjb-dave", "permlink": "re", "parent_author": "cjb-carol", "body": "y"}', 1),
(hafd.operation_id(6611, 5), 2, '{"from": "cjb-alice", "to": "cjb-dave", "amount": "2.000 HIVE", "memo": "m"}', 1),
(hafd.operation_id(6611, 6), 64, '{"producer": "cjb-dave"}', 1),
(hafd.operation_id(6612, 1), 18, '{"id": "follow", "json": "[3]", "required_auths": [], "required_posting_auths": ["cjb-carol"]}', 0);

DELETE FROM haf_stats_backend.active_users_daily WHERE day IN (DATE '2021-10-05', DATE '2021-10-06');
DELETE FROM haf_stats_backend.active_user_ops_daily WHERE day IN (DATE '2021-10-05', DATE '2021-10-06');

-- Rows of query _a that are not in query _b, and the other way round, as a multiset.
CREATE FUNCTION pg_temp.ci_diff(_a TEXT, _b TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    _n BIGINT;
BEGIN
    EXECUTE format('SELECT count(*) FROM ((%s EXCEPT ALL %s) UNION ALL (%s EXCEPT ALL %s)) AS d',
                   _a, _b, _b, _a)
    INTO _n;
    RETURN _n;
END;
$$;

-- The replaced rollup functions, verbatim but for their names and for the key they return: the id
-- they read from the body is mapped to its hafd.custom_json_types id, the column the rollups store
-- now, so the shipped functions' staged custom_json_type_id is checked against the body's id.
CREATE FUNCTION pg_temp.account_custom_json_rows_before(
    _first_block INT,
    _last_block INT
)
RETURNS TABLE (account_id INT, day DATE, custom_json_type_id SMALLINT, op_count INT, op_bytes BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
VOLATILE
SET jit = OFF
SET from_collapse_limit = '16'
SET join_collapse_limit = '16'
AS $$
BEGIN
PERFORM haf_stats_app.prepare_batch_exact_rc(_first_block, _last_block);
PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[18]);
RETURN QUERY
WITH ex AS (
    -- The batch's shares, computed once for the three rollups (prepare_batch_exact_rc, above).
    SELECT c.op_id AS operation_id, c.rc_exact
    FROM haf_stats_batch_exact_rc AS c
),
ops AS MATERIALIZED (
    -- One custom_json op per row, with its id, the day it landed, its payload size, and its
    -- exact RC share where its transaction recorded one (#44).
    SELECT
        ov.op_id,
        ov.day,
        ov.body_value ->> 'id' AS json_id,
        ov.body_value AS body,
        ov.op_bytes,
        ex.rc_exact
    FROM haf_stats_batch_ops ov
    LEFT JOIN ex ON ex.operation_id = ov.op_id
    WHERE ov.op_type_id = 18   -- hive::protocol::custom_json_operation
),
-- Fan each op out to its signer(s): required_posting_auths UNION required_auths.
-- UNION (not UNION ALL) dedups an account listed under both auths so it counts the op once.
-- The op's payload size and exact RC ride along; for a (rare) multi-signer op each signer is
-- attributed the full op_bytes and the full rc_exact, consistent with op_count counting the op
-- once per signer (the network rollup counts it once).
signers AS (
    SELECT o.op_id, o.day, o.json_id, o.op_bytes, o.rc_exact, s.signer
    FROM ops o
    CROSS JOIN LATERAL (
        SELECT jsonb_array_elements_text(o.body -> 'required_posting_auths') AS signer
        UNION
        SELECT jsonb_array_elements_text(o.body -> 'required_auths')
    ) s
    WHERE o.json_id IS NOT NULL
),
-- Resolve the DISTINCT signer-name set once (anti-seq-scan idiom, mirrors
-- process_active_users); a busy bot recurs thousands of times per batch.
name_ids AS MATERIALIZED (
    SELECT av.name, av.id
    FROM hive.accounts_view av
    WHERE av.name IN (SELECT DISTINCT signer FROM signers)
)
SELECT ni.id::INT, sg.day, cjt.id, COUNT(*)::INT, SUM(sg.op_bytes)::BIGINT,
       -- Exact only when every op of the group has its share (#44); otherwise NULL.
       CASE WHEN COUNT(sg.rc_exact) = COUNT(*) THEN SUM(sg.rc_exact) END::BIGINT
FROM signers sg
JOIN name_ids ni ON ni.name = sg.signer
JOIN hafd.custom_json_types cjt ON cjt.custom_json_id = sg.json_id
GROUP BY ni.id, sg.day, cjt.id;
END;
$$;


CREATE FUNCTION pg_temp.network_custom_json_rows_before(
    _first_block INT,
    _last_block INT
)
RETURNS TABLE (day DATE, custom_json_type_id SMALLINT, op_count BIGINT, op_bytes BIGINT, rc_exact BIGINT)
LANGUAGE plpgsql
VOLATILE
SET jit = OFF
AS $$
BEGIN
PERFORM haf_stats_app.prepare_batch_exact_rc(_first_block, _last_block);
PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[18]);
RETURN QUERY
WITH ex AS (
    -- The batch's shares, computed once for the three rollups (prepare_batch_exact_rc, above).
    SELECT c.op_id AS operation_id, c.rc_exact
    FROM haf_stats_batch_exact_rc AS c
)
SELECT
    ov.day,
    cjt.id,
    COUNT(*)::BIGINT,
    SUM(ov.op_bytes)::BIGINT,
    -- Exact only when every op of the group has its share (#44); otherwise NULL.
    CASE WHEN COUNT(ex.rc_exact) = COUNT(*) THEN SUM(ex.rc_exact) END::BIGINT
FROM haf_stats_batch_ops ov
LEFT JOIN ex ON ex.operation_id = ov.op_id
JOIN hafd.custom_json_types cjt ON cjt.custom_json_id = ov.body_value ->> 'id'
WHERE ov.op_type_id = 18   -- hive::protocol::custom_json_operation
  AND ov.body_value ->> 'id' IS NOT NULL
GROUP BY ov.day, cjt.id;
END;
$$;


SET ROLE haf_stats_owner;

-- ---------------------------------------------------------------------------
-- 1. prepare_batch_ops' full set and prepare_batch_authored_ops
-- ---------------------------------------------------------------------------
DO $staging$
DECLARE
    _r INT [];
    _n BIGINT;
BEGIN
    -- Three times in one transaction, so each later staging drops the key and adds it again.
    FOREACH _r SLICE 1 IN ARRAY ARRAY[[6610, 6612], [6611, 6611], [6610, 6612]] LOOP
        PERFORM haf_stats_app.prepare_batch_ops(_r[1], _r[2]);

        -- The replaced statement, over the op types the full set staged.
        _n := pg_temp.ci_diff(
            'SELECT op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value::TEXT, op_bytes,
                    custom_json_type_id
             FROM haf_stats_batch_ops',
            format($q$
            SELECT
                o.id,
                b.num,
                o.trx_in_block,
                o.op_type_id::SMALLINT,
                b.created_at,
                b.created_at::DATE,
                o.body_value::TEXT,
                CASE WHEN ot.is_virtual IS NOT TRUE THEN octet_length(o.body_value::TEXT) END,
                o.custom_json_type_id
            FROM hafd.operations AS o
            JOIN hafd.blocks AS b ON b.num = hafd.operation_id_to_block_num(o.id)
            LEFT JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id
            WHERE o.id >= hafd.operation_id(%1$s, 0)
              AND o.id < hafd.operation_id(%2$s + 1, 0)
              AND hafd.operation_id_to_block_num(o.id) BETWEEN %1$s AND %2$s
              AND o.op_type_id = ANY(%3$L::INT [])$q$,
            _r[1], _r[2], current_setting('haf_stats.batch_ops_types')));
        IF _n <> 0 THEN
            RAISE EXCEPTION 'FAIL: haf_stats_batch_ops for %-% differs from the replaced statement in % rows', _r[1], _r[2], _n;
        END IF;

        PERFORM haf_stats_app.prepare_batch_authored_ops(_r[1], _r[2]);
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint AS c
            WHERE c.conrelid = 'pg_temp.haf_stats_batch_authored_ops'::REGCLASS AND c.contype = 'p'
              AND pg_get_constraintdef(c.oid) = 'PRIMARY KEY (op_id, account_id)'
        ) THEN
            RAISE EXCEPTION 'FAIL: haf_stats_batch_authored_ops for %-% has no primary key (op_id, account_id)', _r[1], _r[2];
        END IF;
    END LOOP;

    -- The authored rows themselves, by value: bob is in both auth lists of 6610:3 and is one
    -- row; cjb-nobody is no account; the op without an id still has its signer.
    IF (SELECT string_agg(format('%s:%s:%s', a.op_id, a.account_id, coalesce(a.op_class::TEXT, '-')), ','
                          ORDER BY a.op_id, a.account_id)
        FROM haf_stats_batch_authored_ops AS a)
       IS DISTINCT FROM
       '6610000001:66101:3,6610000002:66101:5,6610000003:66102:5,6610000003:66103:5,6610000004:66102:4,'
       '6610000005:66103:1,6610000006:66104:5,6610000007:66101:5,6611000001:66101:5,6611000001:66102:5,'
       '6611000002:66102:3,6611000003:66103:5,6611000004:66104:2,6611000005:66101:4,6612000001:66103:5' THEN
        RAISE EXCEPTION 'FAIL: the authored rows of 6610-6612 are not the expected ones';
    END IF;

    -- The key is what makes a COUNT(*) per account a count of operations.
    BEGIN
        INSERT INTO haf_stats_batch_authored_ops (op_id, account_id, op_time, day, op_class)
        SELECT op_id, account_id, op_time, day, op_class FROM haf_stats_batch_authored_ops LIMIT 1;
        RAISE EXCEPTION 'FAIL: haf_stats_batch_authored_ops took an (op, account) pair twice';
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;
    RAISE NOTICE 'prepare_batch_ops / prepare_batch_authored_ops: the replaced rows, keyed, staged three times';
END
$staging$;

-- ---------------------------------------------------------------------------
-- 2. The three rollups
-- ---------------------------------------------------------------------------
DO $rollups$
DECLARE
    _r INT [];
    _n BIGINT;
    _f TEXT;
BEGIN
    FOREACH _r SLICE 1 IN ARRAY ARRAY[[6610, 6612], [6610, 6610], [6611, 6611], [6612, 6612], [6610, 6612]] LOOP
        FOREACH _f IN ARRAY ARRAY['account_custom_json_rows', 'network_custom_json_rows'] LOOP
            _n := pg_temp.ci_diff(
                format('SELECT * FROM haf_stats_app.%s(%s, %s)', _f, _r[1], _r[2]),
                format('SELECT * FROM pg_temp.%s_before(%s, %s)', _f, _r[1], _r[2]));
            IF _n <> 0 THEN
                RAISE EXCEPTION 'FAIL: %(%, %) differs from the replaced function in % rows', _f, _r[1], _r[2], _n;
            END IF;
        END LOOP;
    END LOOP;

    -- And by value, so a fixture the reference also got wrong cannot pass: bob signs 6610:3 once
    -- (both lists), the op without an id is in no row, follow on 2021-10-05 mixes a priced op
    -- with an op of no transaction (NULL), 2021-10-06's sm_claim_daily is unpriced (NULL).
    IF (SELECT string_agg(format('%s/%s/%s=%s/%s/%s', r.account_id, r.day, cjt.custom_json_id, r.op_count, r.op_bytes,
                                 coalesce(r.rc_exact::TEXT, 'NULL')), ',' ORDER BY r.account_id, r.day, cjt.custom_json_id)
        FROM haf_stats_app.account_custom_json_rows(6610, 6612) AS r
        JOIN hafd.custom_json_types AS cjt ON cjt.id = r.custom_json_type_id)
       IS DISTINCT FROM
       (SELECT string_agg(x, ',' ORDER BY x) FROM unnest(ARRAY[
           format('66101/2021-10-05/follow=2/%s/NULL', (SELECT sum(octet_length(body_value::TEXT)) FROM hafd.operations WHERE id IN (6610000002, 6610000007))),
           format('66101/2021-10-06/sm_claim_daily=1/%s/NULL', (SELECT octet_length(body_value::TEXT) FROM hafd.operations WHERE id = 6611000001)),
           format('66102/2021-10-05/sm_claim_daily=1/%s/%s', (SELECT octet_length(body_value::TEXT) FROM hafd.operations WHERE id = 6610000003),
                  (SELECT e.rc_exact FROM haf_stats_app.exact_rc_for_range(6610, 6610) AS e WHERE e.operation_id = 6610000003)),
           format('66102/2021-10-06/sm_claim_daily=1/%s/NULL', (SELECT octet_length(body_value::TEXT) FROM hafd.operations WHERE id = 6611000001)),
           format('66103/2021-10-05/sm_claim_daily=1/%s/%s', (SELECT octet_length(body_value::TEXT) FROM hafd.operations WHERE id = 6610000003),
                  (SELECT e.rc_exact FROM haf_stats_app.exact_rc_for_range(6610, 6610) AS e WHERE e.operation_id = 6610000003)),
           format('66103/2021-10-06/follow=2/%s/%s', (SELECT sum(octet_length(body_value::TEXT)) FROM hafd.operations WHERE id IN (6611000003, 6612000001)),
                  (SELECT sum(e.rc_exact) FROM haf_stats_app.exact_rc_for_range(6611, 6612) AS e WHERE e.operation_id IN (6611000003, 6612000001)))
       ]) AS x) THEN
        RAISE EXCEPTION 'FAIL: account_custom_json_rows(6610, 6612) are not the expected rows';
    END IF;
    -- The exact shares exist where the fixture says, so the NULL / exact contrast above is real.
    IF (SELECT count(*) FROM haf_stats_app.exact_rc_for_range(6610, 6612)) <> 9 THEN
        RAISE EXCEPTION 'FAIL: the fixture priced % ops, expected 9',
            (SELECT count(*) FROM haf_stats_app.exact_rc_for_range(6610, 6612));
    END IF;
    RAISE NOTICE 'account/network custom_json rows: the replaced functions'' rows, per batch and over the range';
END
$rollups$;

-- ---------------------------------------------------------------------------
-- 3. process_active_users
-- ---------------------------------------------------------------------------
DO $active$
DECLARE
    _r INT [];
    _n BIGINT;
BEGIN
    -- One batch per block, as the processor adds them; then the tables against the replaced
    -- statements summed over the same batches.
    CREATE TEMP TABLE ci_membership_before (day DATE, op_class SMALLINT, account_id INT, ops BIGINT) ON COMMIT DROP;
    CREATE TEMP TABLE ci_op_counts_before (day DATE, op_class SMALLINT, operations BIGINT) ON COMMIT DROP;
    FOREACH _r SLICE 1 IN ARRAY ARRAY[[6610, 6610], [6611, 6612]] LOOP
        PERFORM haf_stats_app.prepare_batch_authored_ops(_r[1], _r[2]);
        -- The replaced statements' SELECTs.
        INSERT INTO ci_membership_before
        SELECT day, op_class, account_id, COUNT(DISTINCT op_id) AS ops
        FROM haf_stats_batch_authored_ops
        WHERE op_class IS NOT NULL
        GROUP BY day, op_class, account_id
        UNION ALL
        SELECT day, -1::SMALLINT, account_id, COUNT(DISTINCT op_id)
        FROM haf_stats_batch_authored_ops
        GROUP BY day, account_id;
        INSERT INTO ci_op_counts_before
        SELECT day, op_class, COUNT(DISTINCT op_id) AS operations
        FROM haf_stats_batch_authored_ops
        WHERE op_class IS NOT NULL
        GROUP BY day, op_class
        UNION ALL
        SELECT day, -1::SMALLINT, COUNT(DISTINCT op_id)
        FROM haf_stats_batch_authored_ops
        GROUP BY day;

        PERFORM haf_stats_app.process_active_users(_r[1], _r[2]);
    END LOOP;

    _n := pg_temp.ci_diff(
        $q$SELECT day, op_class, account_id, ops::BIGINT FROM haf_stats_backend.active_users_daily
           WHERE day IN (DATE '2021-10-05', DATE '2021-10-06')$q$,
        $q$SELECT day, op_class, account_id, SUM(ops)::BIGINT FROM ci_membership_before GROUP BY 1, 2, 3$q$);
    IF _n <> 0 THEN
        RAISE EXCEPTION 'FAIL: active_users_daily differs from the replaced statement in % rows', _n;
    END IF;
    _n := pg_temp.ci_diff(
        $q$SELECT day, op_class, operations FROM haf_stats_backend.active_user_ops_daily
           WHERE day IN (DATE '2021-10-05', DATE '2021-10-06')$q$,
        $q$SELECT day, op_class, SUM(operations)::BIGINT FROM ci_op_counts_before GROUP BY 1, 2$q$);
    IF _n <> 0 THEN
        RAISE EXCEPTION 'FAIL: active_user_ops_daily differs from the replaced statement in % rows', _n;
    END IF;

    -- By value: 2021-10-06 has 6 authored ops, 3 of them custom_json, one of those signed by
    -- alice and bob; each of alice, bob and carol signed 2 of the day's ops, dave 1.
    IF (SELECT string_agg(op_class || '=' || operations, ',' ORDER BY op_class)
        FROM haf_stats_backend.active_user_ops_daily WHERE day = DATE '2021-10-06')
       IS DISTINCT FROM '-1=6,2=1,3=1,4=1,5=3' THEN
        RAISE EXCEPTION 'FAIL: active_user_ops_daily for 2021-10-06 is not the expected counts';
    END IF;
    IF (SELECT string_agg(account_id || '=' || ops, ',' ORDER BY account_id)
        FROM haf_stats_backend.active_users_daily WHERE day = DATE '2021-10-06' AND op_class = -1)
       IS DISTINCT FROM '66101=2,66102=2,66103=2,66104=1' THEN
        RAISE EXCEPTION 'FAIL: active_users_daily ALL rows for 2021-10-06 are not the expected counts';
    END IF;
    RAISE NOTICE 'process_active_users: the replaced statements'' rows, over two batches';
END
$active$;

-- ---------------------------------------------------------------------------
-- 4. Mutation checks: the shipped functions with a defect put in. The comparisons above must
--    see each one, or they prove nothing.
-- ---------------------------------------------------------------------------
DO $mutations$
DECLARE
    _def TEXT;
    _n BIGINT;
BEGIN
    PERFORM haf_stats_app.prepare_batch_authored_ops(6610, 6612);

    -- Signers without DISTINCT: an account in both auth lists signs its op twice.
    CREATE TEMP TABLE ci_authored_no_distinct ON COMMIT DROP AS
    SELECT a.* FROM haf_stats_batch_authored_ops AS a
    UNION ALL
    SELECT a.*
    FROM haf_stats_batch_authored_ops AS a
    JOIN haf_stats_batch_ops AS s ON s.op_id = a.op_id
    JOIN hive.accounts_view AS av ON av.id = a.account_id
    WHERE a.op_class = 5
      AND s.body_value -> 'required_auths' ? av.name
      AND s.body_value -> 'required_posting_auths' ? av.name;
    IF (SELECT count(*) FROM ci_authored_no_distinct) <= (SELECT count(*) FROM haf_stats_batch_authored_ops) THEN
        RAISE EXCEPTION 'FAIL: the fixture has no account in both auth lists, so the mutation is empty';
    END IF;

    _def := pg_get_functiondef('haf_stats_app.account_custom_json_rows(INT, INT)'::REGPROCEDURE);
    IF strpos(_def, 'FROM haf_stats_batch_authored_ops a') = 0 THEN
        RAISE EXCEPTION 'FAIL: account_custom_json_rows no longer reads haf_stats_batch_authored_ops a; update the mutation';
    END IF;
    EXECUTE replace(replace(_def, 'haf_stats_app.account_custom_json_rows(', 'pg_temp.acj_no_distinct('),
                    'FROM haf_stats_batch_authored_ops a', 'FROM ci_authored_no_distinct a');
    _n := pg_temp.ci_diff('SELECT * FROM pg_temp.acj_no_distinct(6610, 6612)',
                          'SELECT * FROM pg_temp.account_custom_json_rows_before(6610, 6612)');
    IF _n = 0 THEN
        RAISE EXCEPTION 'FAIL: the comparison did not see signers counted without DISTINCT';
    END IF;
    RAISE NOTICE 'mutation: signers without DISTINCT differ from the reference in % rows', _n;

    -- A group's rc_exact summed over the ops that have one, instead of NULL unless all do.
    _def := pg_get_functiondef('haf_stats_app.network_custom_json_rows(INT, INT)'::REGPROCEDURE);
    IF strpos(_def, 'CASE WHEN COUNT(cj.rc_exact) = COUNT(*) THEN SUM(cj.rc_exact) END') = 0 THEN
        RAISE EXCEPTION 'FAIL: network_custom_json_rows no longer has its NULL rule as written here; update the mutation';
    END IF;
    EXECUTE replace(replace(_def, 'haf_stats_app.network_custom_json_rows(', 'pg_temp.ncj_partial_rc('),
                    'CASE WHEN COUNT(cj.rc_exact) = COUNT(*) THEN SUM(cj.rc_exact) END', 'SUM(cj.rc_exact)');
    _n := pg_temp.ci_diff('SELECT * FROM pg_temp.ncj_partial_rc(6610, 6612)',
                          'SELECT * FROM pg_temp.network_custom_json_rows_before(6610, 6612)');
    IF _n = 0 THEN
        RAISE EXCEPTION 'FAIL: the comparison did not see a half-exact rc_exact';
    END IF;
    RAISE NOTICE 'mutation: a half-exact rc_exact differs from the reference in % rows', _n;

    -- The fixture's multi-signer ops are what an op counted once per signer (op_counts without
    -- its DISTINCT per op) would get wrong.
    _n := pg_temp.ci_diff(
        'SELECT day, op_class, COUNT(*) FROM haf_stats_batch_authored_ops WHERE op_class IS NOT NULL GROUP BY day, op_class',
        'SELECT day, op_class, COUNT(DISTINCT op_id) FROM haf_stats_batch_authored_ops WHERE op_class IS NOT NULL GROUP BY day, op_class');
    IF _n = 0 THEN
        RAISE EXCEPTION 'FAIL: the fixture has no multi-signer op, so op counts without DISTINCT go unseen';
    END IF;
    RAISE NOTICE 'mutation: op counts without DISTINCT per op differ in % rows', _n;
END
$mutations$;

RESET ROLE;
ROLLBACK;
