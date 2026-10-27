-- The json_id TEXT -> custom_json_type_id SMALLINT upgrade of both custom_json rollups, run by
-- loading the SHIPPED processor files over tables in the old shape (#120).
--
-- psql -v acj_file=<db/process_custom_json.sql> -v ncj_file=<db/process_network_custom_json.sql>:
-- the paths come from the command line, where the lane rewrites container paths.
--
--   1. Every id known to hafd.custom_json_types: both tables are rewritten in place, and each
--      (account, day, id) / (day, id) row keeps its op_count, op_bytes and rc_exact, now under
--      the id's custom_json_type_id; the keys and the network index are on the new column.
--   2. One id HAF has no entry for: the upgrade fails, and both tables are exactly as they were.
--
-- Autocommit, as install_app.sh loads these files: case 2 has to show that the failed statement
-- leaves nothing behind on its own, not that a test transaction rolled it back. The lane's own
-- tables are parked in a schema of their own meanwhile and put back at the end.
\set ON_ERROR_STOP on

CREATE SCHEMA ci_cjt_kept;
ALTER TABLE haf_stats_backend.account_custom_json_daily SET SCHEMA ci_cjt_kept;
ALTER TABLE haf_stats_backend.network_custom_json_daily SET SCHEMA ci_cjt_kept;

-- The old shape, as the processors created it before #120, written by haf_stats_owner as on a node.
CREATE FUNCTION pg_temp.ci_old_shape(_ids TEXT [])
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    SET LOCAL ROLE haf_stats_owner;
    CREATE TABLE haf_stats_backend.account_custom_json_daily (
        account_id INT NOT NULL,
        day DATE NOT NULL,
        json_id TEXT NOT NULL,
        op_count INT NOT NULL DEFAULT 0,
        op_bytes BIGINT NOT NULL DEFAULT 0,
        rc_exact BIGINT,
        PRIMARY KEY (account_id, day, json_id)
    );
    CREATE TABLE haf_stats_backend.network_custom_json_daily (
        day DATE NOT NULL,
        json_id TEXT NOT NULL,
        op_count BIGINT NOT NULL DEFAULT 0,
        op_bytes BIGINT NOT NULL DEFAULT 0,
        rc_exact BIGINT,
        PRIMARY KEY (day, json_id)
    );
    CREATE INDEX idx_ncj_json_id_day ON haf_stats_backend.network_custom_json_daily (json_id, day);

    -- Several ids per account and day, the same id on two days and for two accounts, rows with
    -- and without rc_exact. _ids[1..3] are spread over the rows; the last one gets a row of its own.
    INSERT INTO haf_stats_backend.account_custom_json_daily (account_id, day, json_id, op_count, op_bytes, rc_exact)
    VALUES
        (901001, '2021-01-01', _ids[1], 7, 700, 123456789),
        (901001, '2021-01-01', _ids[2], 2, 64, NULL),
        (901001, '2021-01-02', _ids[1], 1, 90, 5),
        (901002, '2021-01-01', _ids[1], 3, 330, NULL),
        (901002, '2021-01-02', _ids[3], 40, 4000, 9000000000),
        (901003, '2021-01-03', _ids[cardinality(_ids)], 1, 33, 1);
    INSERT INTO haf_stats_backend.network_custom_json_daily (day, json_id, op_count, op_bytes, rc_exact)
    VALUES
        ('2021-01-01', _ids[1], 10, 1030, NULL),
        ('2021-01-01', _ids[2], 2, 64, 77),
        ('2021-01-02', _ids[1], 1, 90, 5),
        ('2021-01-02', _ids[3], 40, 4000, 9000000000),
        ('2021-01-03', _ids[cardinality(_ids)], 1, 33, 1);
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Every id known: converted in place, every figure kept
-- ---------------------------------------------------------------------------
-- The dictionary is HAF's; the stub's helper only makes sure these ids are in it. The last one is
-- 32 bytes, the longest id HAF stores.
DO $known$
BEGIN
    PERFORM hafd.ci_custom_json_type_id(i)
    FROM unnest(ARRAY['follow', 'sm_claim_daily', 'ssc-mainnet-hive', 'ci-migration-id-of-32-bytes-long']) AS i;
END
$known$;
SELECT pg_temp.ci_old_shape(ARRAY['follow', 'sm_claim_daily', 'ssc-mainnet-hive', 'ci-migration-id-of-32-bytes-long']);

CREATE TEMP TABLE ci_acj_before AS SELECT * FROM haf_stats_backend.account_custom_json_daily;
CREATE TEMP TABLE ci_ncj_before AS SELECT * FROM haf_stats_backend.network_custom_json_daily;

\i :acj_file
\i :ncj_file

DO $converted$
DECLARE
    _bad TEXT := '';
    _n BIGINT;
BEGIN
    IF (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute AS a
        WHERE a.attrelid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS
          AND a.attname = 'custom_json_type_id' AND NOT a.attisdropped) IS DISTINCT FROM 'smallint'
       OR (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute AS a
           WHERE a.attrelid = 'haf_stats_backend.network_custom_json_daily'::REGCLASS
             AND a.attname = 'custom_json_type_id' AND NOT a.attisdropped) IS DISTINCT FROM 'smallint' THEN
        _bad := _bad || ' custom_json_type_id is not a smallint column of both tables;';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute AS a
               WHERE a.attrelid IN ('haf_stats_backend.account_custom_json_daily'::REGCLASS,
                                    'haf_stats_backend.network_custom_json_daily'::REGCLASS)
                 AND a.attname = 'json_id' AND NOT a.attisdropped) THEN
        _bad := _bad || ' json_id is still there;';
    END IF;

    -- Row for row, by the id's text: the converted rows mapped back through the dictionary are
    -- the rows before, and there are as many.
    SELECT count(*) INTO _n FROM (
        (SELECT a.account_id, a.day, t.custom_json_id::TEXT, a.op_count, a.op_bytes, a.rc_exact
         FROM haf_stats_backend.account_custom_json_daily AS a
         JOIN hafd.custom_json_types AS t ON t.id = a.custom_json_type_id
         EXCEPT ALL
         SELECT account_id, day, json_id, op_count, op_bytes, rc_exact FROM ci_acj_before)
        UNION ALL
        (SELECT account_id, day, json_id, op_count, op_bytes, rc_exact FROM ci_acj_before
         EXCEPT ALL
         SELECT a.account_id, a.day, t.custom_json_id::TEXT, a.op_count, a.op_bytes, a.rc_exact
         FROM haf_stats_backend.account_custom_json_daily AS a
         JOIN hafd.custom_json_types AS t ON t.id = a.custom_json_type_id)
    ) AS d;
    IF _n <> 0 OR (SELECT count(*) FROM haf_stats_backend.account_custom_json_daily) <> 6 THEN
        _bad := _bad || format(' account_custom_json_daily differs from the rows before in %s rows;', _n);
    END IF;
    SELECT count(*) INTO _n FROM (
        (SELECT n.day, t.custom_json_id::TEXT, n.op_count, n.op_bytes, n.rc_exact
         FROM haf_stats_backend.network_custom_json_daily AS n
         JOIN hafd.custom_json_types AS t ON t.id = n.custom_json_type_id
         EXCEPT ALL
         SELECT day, json_id, op_count, op_bytes, rc_exact FROM ci_ncj_before)
        UNION ALL
        (SELECT day, json_id, op_count, op_bytes, rc_exact FROM ci_ncj_before
         EXCEPT ALL
         SELECT n.day, t.custom_json_id::TEXT, n.op_count, n.op_bytes, n.rc_exact
         FROM haf_stats_backend.network_custom_json_daily AS n
         JOIN hafd.custom_json_types AS t ON t.id = n.custom_json_type_id)
    ) AS d;
    IF _n <> 0 OR (SELECT count(*) FROM haf_stats_backend.network_custom_json_daily) <> 5 THEN
        _bad := _bad || format(' network_custom_json_daily differs from the rows before in %s rows;', _n);
    END IF;

    IF (SELECT string_agg(pg_get_constraintdef(c.oid), ', ' ORDER BY c.conrelid::REGCLASS::TEXT)
        FROM pg_constraint AS c
        WHERE c.conrelid IN ('haf_stats_backend.account_custom_json_daily'::REGCLASS,
                             'haf_stats_backend.network_custom_json_daily'::REGCLASS)
          AND c.contype = 'p')
       IS DISTINCT FROM 'PRIMARY KEY (account_id, day, custom_json_type_id), PRIMARY KEY (day, custom_json_type_id)' THEN
        _bad := _bad || ' the primary keys are not on custom_json_type_id;';
    END IF;
    IF to_regclass('haf_stats_backend.idx_ncj_json_id_day') IS NOT NULL
       OR (SELECT pg_get_indexdef(to_regclass('haf_stats_backend.idx_ncj_custom_json_type_id_day')))
          IS DISTINCT FROM 'CREATE INDEX idx_ncj_custom_json_type_id_day ON haf_stats_backend.network_custom_json_daily USING btree (custom_json_type_id, day)' THEN
        _bad := _bad || ' the network table''s id-leading index is not idx_ncj_custom_json_type_id_day;';
    END IF;
    IF NOT has_table_privilege('haf_stats_user', 'haf_stats_backend.account_custom_json_daily', 'SELECT')
       OR NOT has_table_privilege('haf_stats_user', 'haf_stats_backend.network_custom_json_daily', 'SELECT') THEN
        _bad := _bad || ' haf_stats_user cannot read the converted tables;';
    END IF;

    IF _bad <> '' THEN
        RAISE EXCEPTION 'FAIL (#120): the upgrade over known ids:%', _bad;
    END IF;
    RAISE NOTICE 'custom_json_type_id upgrade: both rollups rewritten in place, every row kept under its id';
END
$converted$;

-- The helper the upgrade calls, on an id HAF has no entry for: the error the install shows.
DO $unknown$
BEGIN
    PERFORM haf_stats_app.custom_json_type_id_of('ci-no-such-custom-json-id');
    RAISE EXCEPTION 'FAIL (#120): custom_json_type_id_of returned for an id HAF has no entry for';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'haf_stats: custom_json id ''ci-no-such-custom-json-id'' has no entry in hafd.custom_json_types' THEN
        RAISE;
    END IF;
    RAISE NOTICE 'custom_json_type_id_of: an unknown id raises "%"', SQLERRM;
END
$unknown$;

DROP TABLE haf_stats_backend.account_custom_json_daily;
DROP TABLE haf_stats_backend.network_custom_json_daily;

-- ---------------------------------------------------------------------------
-- 2. One id HAF has no entry for: the upgrade fails, both tables untouched
-- ---------------------------------------------------------------------------
DO $absent$
BEGIN
    IF EXISTS (SELECT 1 FROM hafd.custom_json_types WHERE custom_json_id = 'ci-no-such-custom-json-id') THEN
        RAISE EXCEPTION 'FAIL (#120): the fixture''s unknown id is in hafd.custom_json_types';
    END IF;
END
$absent$;
SELECT pg_temp.ci_old_shape(ARRAY['follow', 'sm_claim_daily', 'ssc-mainnet-hive', 'ci-no-such-custom-json-id']);

DROP TABLE ci_acj_before;
DROP TABLE ci_ncj_before;
CREATE TEMP TABLE ci_acj_before AS SELECT * FROM haf_stats_backend.account_custom_json_daily;
CREATE TEMP TABLE ci_ncj_before AS SELECT * FROM haf_stats_backend.network_custom_json_daily;

\echo '== #120: the two loads below are expected to fail on ci-no-such-custom-json-id'
\set ON_ERROR_STOP off
\i :acj_file
\i :ncj_file
\set ON_ERROR_STOP on

DO $refused$
DECLARE
    _bad TEXT := '';
BEGIN
    IF (SELECT string_agg(format('%s %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' ORDER BY a.attnum)
        FROM pg_attribute AS a
        WHERE a.attrelid = 'haf_stats_backend.account_custom_json_daily'::REGCLASS
          AND a.attnum > 0 AND NOT a.attisdropped)
       IS DISTINCT FROM 'account_id integer, day date, json_id text, op_count integer, op_bytes bigint, rc_exact bigint' THEN
        _bad := _bad || ' account_custom_json_daily changed shape;';
    END IF;
    IF (SELECT string_agg(format('%s %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' ORDER BY a.attnum)
        FROM pg_attribute AS a
        WHERE a.attrelid = 'haf_stats_backend.network_custom_json_daily'::REGCLASS
          AND a.attnum > 0 AND NOT a.attisdropped)
       IS DISTINCT FROM 'day date, json_id text, op_count bigint, op_bytes bigint, rc_exact bigint' THEN
        _bad := _bad || ' network_custom_json_daily changed shape;';
    END IF;
    IF EXISTS (SELECT * FROM haf_stats_backend.account_custom_json_daily
               EXCEPT ALL SELECT * FROM ci_acj_before)
       OR EXISTS (SELECT * FROM ci_acj_before
                  EXCEPT ALL SELECT * FROM haf_stats_backend.account_custom_json_daily) THEN
        _bad := _bad || ' account_custom_json_daily rows changed;';
    END IF;
    IF EXISTS (SELECT * FROM haf_stats_backend.network_custom_json_daily
               EXCEPT ALL SELECT * FROM ci_ncj_before)
       OR EXISTS (SELECT * FROM ci_ncj_before
                  EXCEPT ALL SELECT * FROM haf_stats_backend.network_custom_json_daily) THEN
        _bad := _bad || ' network_custom_json_daily rows changed;';
    END IF;
    IF to_regclass('haf_stats_backend.idx_ncj_json_id_day') IS NULL
       OR to_regclass('haf_stats_backend.idx_ncj_custom_json_type_id_day') IS NOT NULL THEN
        _bad := _bad || ' the network table''s indexes changed;';
    END IF;
    IF _bad <> '' THEN
        RAISE EXCEPTION 'FAIL (#120): an upgrade over an unknown id changed the tables:%', _bad;
    END IF;
    RAISE NOTICE 'custom_json_type_id upgrade: an id HAF has no entry for fails it, and both tables are as they were';
END
$refused$;

-- ---------------------------------------------------------------------------
-- The lane's tables back, and the processor files loaded over them once more, as the lane had them.
-- ---------------------------------------------------------------------------
DROP TABLE haf_stats_backend.account_custom_json_daily;
DROP TABLE haf_stats_backend.network_custom_json_daily;
ALTER TABLE ci_cjt_kept.account_custom_json_daily SET SCHEMA haf_stats_backend;
ALTER TABLE ci_cjt_kept.network_custom_json_daily SET SCHEMA haf_stats_backend;
DROP SCHEMA ci_cjt_kept;
\i :acj_file
\i :ncj_file
