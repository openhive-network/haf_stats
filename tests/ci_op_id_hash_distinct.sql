-- Deduplicating HAF operation ids without hashing them.
--
-- A HAF op id is (block_num << 32) | (position << 8) | op type, and hashint8 XOR-folds its two
-- 32-bit halves, so the block number and the position largely cancel: the ids of a 10k-block
-- batch fall on a few tens of thousands of hash values. A HashAggregate (DISTINCT or GROUP BY)
-- keyed on op ids alone runs for minutes on that; a sort, or a Unique over an index that leads
-- with op_id, takes a fraction of a second. This file stages such a batch, at the scale of a
-- massive-sync batch, and checks:
--   * that batch_op (process_active_users) and the asked-for ids of exact_rc_for_ops are planned
--     without a hashed node even with sorting disabled, i.e. that neither can be hashed;
--   * that the plan check flags each statement's hashed form, or it proves nothing;
--   * process_active_users' counts against COUNT(DISTINCT op_id), the logic it replaced, and
--     its time within a bound the hashed DISTINCT is far beyond.
--
-- One transaction, rolled back.
\set ON_ERROR_STOP on

BEGIN;

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

-- Whether the plan of _sql, with $1 bound to _ids, has a hashed aggregate, DISTINCT or set
-- operation. Sorting is disabled while it plans, so a statement that can be hashed is.
CREATE FUNCTION pg_temp.ci_plan_hashes(_sql TEXT, _ids BIGINT [] DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SET enable_sort = off
AS $$
DECLARE
    _plan JSON;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || _sql INTO _plan USING _ids;
    RETURN jsonb_path_exists(_plan::JSONB, '$.**."Strategy" ? (@ == "Hashed" || @ == "Mixed")');
END;
$$;

-- The batch: blocks 18,650,001-18,660,000 (where steem-20's batches slowed down), 54 ops each
-- of five types, every seventh op signed by two accounts. The ids are built as HAF builds them.
-- process_active_users reads only the staged table, so it is staged here directly under the range
-- key prepare_batch_authored_ops checks; that range lies within one 1200-block refresh bucket, so
-- the call does not refresh the rollups, which this lane does not load.
DELETE FROM haf_stats_backend.active_users_daily WHERE day IN (DATE '2017-12-30', DATE '2017-12-31');
DELETE FROM haf_stats_backend.active_user_ops_daily WHERE day IN (DATE '2017-12-30', DATE '2017-12-31');

SET ROLE haf_stats_owner;

CREATE TEMP TABLE haf_stats_batch_authored_ops (
    op_id BIGINT NOT NULL,
    account_id INT NOT NULL,
    op_time TIMESTAMP NOT NULL,
    day DATE NOT NULL,
    op_class SMALLINT
) ON COMMIT DROP;

INSERT INTO haf_stats_batch_authored_ops (op_id, account_id, op_time, day, op_class)
SELECT (b.num::BIGINT << 32) | (p.pos << 8) | t.op_type, s.account_id, b.ts, b.ts::DATE, t.op_class
FROM generate_series(18650001, 18660000) AS g (num)
CROSS JOIN LATERAL (
    SELECT g.num, TIMESTAMP '2017-12-30 12:00:00' + (g.num - 18650001) * INTERVAL '3 seconds' AS ts
) AS b
CROSS JOIN generate_series(0, 53) AS p (pos)
CROSS JOIN LATERAL (
    SELECT v.op_type, v.op_class
    FROM (VALUES (0, 3::SMALLINT), (1, 2::SMALLINT), (2, 4::SMALLINT), (18, 5::SMALLINT), (10, NULL::SMALLINT))
         AS v (op_type, op_class)
    OFFSET (b.num + p.pos) % 5 LIMIT 1
) AS t
CROSS JOIN LATERAL (
    SELECT DISTINCT 6620000 + (hashint4((b.num - 18650000) * 64 + p.pos * 2 + k) & 65535) AS account_id
    FROM generate_series(0, ((b.num + p.pos) % 7 = 0)::INT) AS k
) AS s;

ALTER TABLE haf_stats_batch_authored_ops
    ADD CONSTRAINT haf_stats_batch_authored_ops_pkey PRIMARY KEY (op_id, account_id);
ANALYZE haf_stats_batch_authored_ops;
SELECT set_config('haf_stats.batch_authored_ops_range', '18650401:18651599', TRUE);

DO $collide$
DECLARE
    _ops BIGINT;
    _hashes BIGINT;
BEGIN
    SELECT count(DISTINCT op_id), count(DISTINCT hashint8(op_id)) INTO _ops, _hashes
    FROM haf_stats_batch_authored_ops;
    IF _ops < 500000 OR _ops < 20 * _hashes THEN
        RAISE EXCEPTION 'FAIL: the batch has % ops on % hash values, not the collisions it is for', _ops, _hashes;
    END IF;
    RAISE NOTICE 'batch: % ops on % hashint8 values', _ops, _hashes;
END
$collide$;

-- ---------------------------------------------------------------------------
-- 1. Plans: no hashed node on op ids, and the check sees one when there is
--    (first, so a hashed batch_op fails here rather than after minutes in the step below)
-- ---------------------------------------------------------------------------
DO $plans$
DECLARE
    _m TEXT [];
    _ids BIGINT [];
BEGIN
    _m := regexp_match(
        pg_get_functiondef('haf_stats_app.process_active_users(INT, INT)'::REGPROCEDURE),
        'batch_op AS MATERIALIZED \(([^;]*?)\n    \),');
    IF _m IS NULL THEN
        RAISE EXCEPTION 'FAIL: process_active_users no longer has batch_op AS MATERIALIZED as written here; update the check';
    END IF;
    IF pg_temp.ci_plan_hashes(_m[1]) THEN
        RAISE EXCEPTION 'FAIL: batch_op can be planned as a hash over op ids: %', _m[1];
    END IF;
    IF NOT pg_temp.ci_plan_hashes('SELECT DISTINCT day, op_class, op_id FROM haf_stats_batch_authored_ops') THEN
        RAISE EXCEPTION 'FAIL: the plan check does not see the hashed DISTINCT batch_op replaced';
    END IF;

    -- 15,000 ids (exact_rc_op_cap) from as many colliding hash values as possible, each twice.
    SELECT array_agg(op_id) INTO _ids
    FROM (
        SELECT op_id FROM haf_stats_batch_authored_ops ORDER BY hashint8(op_id), op_id LIMIT 7500
    ) AS s, generate_series(1, 2);
    _m := regexp_match(
        pg_get_functiondef('haf_stats_app.exact_rc_for_ops(BIGINT [])'::REGPROCEDURE),
        '\(\s*(SELECT [^\n]*unnest\(_op_ids\)[^\n]*?)\s*\) AS want');
    IF _m IS NULL THEN
        RAISE EXCEPTION 'FAIL: exact_rc_for_ops no longer has its asked-for ids as written here; update the check';
    END IF;
    IF pg_temp.ci_plan_hashes(replace(_m[1], '_op_ids', '$1::BIGINT []'), _ids) THEN
        RAISE EXCEPTION 'FAIL: exact_rc_for_ops'' asked-for ids can be planned as a hash: %', _m[1];
    END IF;
    IF NOT pg_temp.ci_plan_hashes('SELECT DISTINCT u.id FROM unnest($1::BIGINT []) AS u(id)', _ids) THEN
        RAISE EXCEPTION 'FAIL: the plan check does not see the hashed DISTINCT exact_rc_for_ops replaced';
    END IF;
    RAISE NOTICE 'plans: batch_op and exact_rc_for_ops'' ids are not hashed; their hashed forms are seen';
END
$plans$;

-- ---------------------------------------------------------------------------
-- 2. process_active_users: the replaced logic's rows, within the bound
-- ---------------------------------------------------------------------------
DO $active$
DECLARE
    _t TIMESTAMPTZ;
    _s NUMERIC;
    _n BIGINT;
BEGIN
    _t := clock_timestamp();
    PERFORM haf_stats_app.process_active_users(18650401, 18651599);
    _s := EXTRACT(EPOCH FROM clock_timestamp() - _t);
    -- The hashed DISTINCT runs past 90 s on this batch; the sorted one takes well under 1 s.
    IF _s > 30 THEN
        RAISE EXCEPTION 'FAIL: process_active_users took % s over the colliding batch', round(_s, 1);
    END IF;

    _n := pg_temp.ci_diff(
        $q$SELECT day, op_class, account_id, ops::BIGINT FROM haf_stats_backend.active_users_daily
           WHERE day IN (DATE '2017-12-30', DATE '2017-12-31')$q$,
        $q$SELECT * FROM (
               SELECT day, op_class, account_id, COUNT(DISTINCT op_id) FROM haf_stats_batch_authored_ops
               WHERE op_class IS NOT NULL GROUP BY day, op_class, account_id
               UNION ALL
               SELECT day, -1::SMALLINT, account_id, COUNT(DISTINCT op_id) FROM haf_stats_batch_authored_ops
               GROUP BY day, account_id
           ) AS r$q$);
    IF _n <> 0 THEN
        RAISE EXCEPTION 'FAIL: active_users_daily differs from the replaced statement in % rows', _n;
    END IF;
    _n := pg_temp.ci_diff(
        $q$SELECT day, op_class, operations FROM haf_stats_backend.active_user_ops_daily
           WHERE day IN (DATE '2017-12-30', DATE '2017-12-31')$q$,
        $q$SELECT * FROM (
               SELECT day, op_class, COUNT(DISTINCT op_id) FROM haf_stats_batch_authored_ops
               WHERE op_class IS NOT NULL GROUP BY day, op_class
               UNION ALL
               SELECT day, -1::SMALLINT, COUNT(DISTINCT op_id) FROM haf_stats_batch_authored_ops
               GROUP BY day
           ) AS r$q$);
    IF _n <> 0 THEN
        RAISE EXCEPTION 'FAIL: active_user_ops_daily differs from the replaced statement in % rows', _n;
    END IF;

    -- By value: the batch is 540,000 ops over two days, 108,000 of each op type.
    IF (SELECT string_agg(op_class || '=' || total, ',' ORDER BY op_class)
        FROM (SELECT op_class, SUM(operations) AS total FROM haf_stats_backend.active_user_ops_daily
              WHERE day IN (DATE '2017-12-30', DATE '2017-12-31') GROUP BY op_class) AS c)
       IS DISTINCT FROM '-1=540000,2=108000,3=108000,4=108000,5=108000' THEN
        RAISE EXCEPTION 'FAIL: active_user_ops_daily for the batch is not the expected counts';
    END IF;
    RAISE NOTICE 'process_active_users: the replaced logic''s rows, in % s', round(_s, 2);
END
$active$;

RESET ROLE;
ROLLBACK;
