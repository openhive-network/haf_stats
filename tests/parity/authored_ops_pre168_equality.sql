-- =============================================================================
-- authored_ops_pre168_equality.sql — guard for issue #170.
--
-- haf_stats_app.fill_batch_authored_ops was rewritten by #168 (signers read as one array per
-- op, DISTINCT on the final insert in key order, the name join hashed). This stages the
-- authored ops of the replay's last 120,000 blocks the way backfill_rc_exact does, through
-- account_custom_json_rows, which disables hash joins for its own join and so is the caller
-- under which the rewrite planned its name join as a nested loop, quadratic in the range's
-- rows (1345 s for one day at block 27.42M). The staging's statement timeout fails the guard
-- if that returns: on steem-20 this range stages in 1.3 s with the hash join and in 119 s with
-- the nested loop.
--
-- The rows staged are then compared with the ones the query before #168 gives over the same
-- batch ops, all columns: nothing missing, nothing extra, nothing staged twice. The reference
-- resolves the other types' signers through get_required_authorities_safe alone, which is what
-- either of fill_batch_authored_ops' attempts gives.
--
-- Read-only: the staging writes only ON COMMIT DROP temp tables, and the transaction is rolled
-- back.
-- =============================================================================
\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE haf_stats_owner;
SET LOCAL haf_stats_test.first_block = '4880001';
SET LOCAL haf_stats_test.last_block = '5000000';

SET LOCAL statement_timeout = '60s';
SELECT COUNT(*) AS account_custom_json_rows
FROM haf_stats_app.account_custom_json_rows(
    current_setting('haf_stats_test.first_block')::INT,
    current_setting('haf_stats_test.last_block')::INT
);
SET LOCAL statement_timeout = 0;

DO $guard$
DECLARE
    _first INT := current_setting('haf_stats_test.first_block')::INT;
    _last INT := current_setting('haf_stats_test.last_block')::INT;
    _missing BIGINT;
    _extra BIGINT;
    _rows BIGINT;
    _classes INT;
BEGIN
    CREATE TEMP TABLE authored_reference ON COMMIT DROP AS
    WITH authored AS MATERIALIZED (
        SELECT DISTINCT
            s.op_id,
            ra.account_name AS actor_name,
            s.op_time,
            s.day,
            (CASE
                WHEN s.op_type_id = 0 THEN 3::SMALLINT
                WHEN s.op_type_id = 1
                 AND COALESCE(s.body_value ->> 'parent_author', '') = '' THEN 1::SMALLINT
                WHEN s.op_type_id = 1 THEN 2::SMALLINT
                WHEN s.op_type_id = 2 THEN 4::SMALLINT
                WHEN s.op_type_id = 18 THEN 5::SMALLINT
                ELSE NULL::SMALLINT
             END) AS op_class
        FROM haf_stats_batch_ops AS s
        JOIN hafd.operation_types AS ot ON ot.id = s.op_type_id AND NOT ot.is_virtual
        CROSS JOIN LATERAL (
            SELECT s.body_value ->> 'voter' WHERE s.op_type_id = 0
            UNION ALL
            SELECT s.body_value ->> 'author' WHERE s.op_type_id = 1
            UNION ALL
            SELECT s.body_value ->> 'from' WHERE s.op_type_id = 2
            UNION ALL
            SELECT auth.name
            FROM jsonb_array_elements_text(
                CASE WHEN jsonb_typeof(s.body_value -> 'required_auths') = 'array'
                     THEN s.body_value -> 'required_auths' END
            ) AS auth (name)
            WHERE s.op_type_id = 18
            UNION ALL
            SELECT auth.name
            FROM jsonb_array_elements_text(
                CASE WHEN jsonb_typeof(s.body_value -> 'required_posting_auths') = 'array'
                     THEN s.body_value -> 'required_posting_auths' END
            ) AS auth (name)
            WHERE s.op_type_id = 18
            UNION ALL
            SELECT r.account_name
            FROM haf_stats_app.get_required_authorities_safe(jsonb_build_object(
                'type', replace(ot.name, 'hive::protocol::', ''),
                'value', s.body_value
            )) AS r
            WHERE s.op_type_id NOT IN (0, 1, 2, 18)
        ) AS ra (account_name)
        WHERE ra.account_name IS NOT NULL
    ),
    name_ids AS MATERIALIZED (
        SELECT av.name, av.id
        FROM hive.accounts_view AS av
        WHERE av.name IN (SELECT DISTINCT actor_name FROM authored)
    )
    SELECT a.op_id, ni.id AS account_id, a.op_time, a.day, a.op_class
    FROM authored AS a
    JOIN name_ids AS ni ON ni.name = a.actor_name;

    SELECT COUNT(*) INTO _missing
    FROM (SELECT * FROM authored_reference
          EXCEPT ALL SELECT op_id, account_id, op_time, day, op_class FROM haf_stats_batch_authored_ops) AS x;
    SELECT COUNT(*) INTO _extra
    FROM (SELECT op_id, account_id, op_time, day, op_class FROM haf_stats_batch_authored_ops
          EXCEPT ALL SELECT * FROM authored_reference) AS x;
    SELECT COUNT(*), COUNT(DISTINCT op_class) INTO _rows, _classes FROM authored_reference;

    IF _missing > 0 OR _extra > 0 THEN
        RAISE EXCEPTION 'FAIL: blocks %..%: fill_batch_authored_ops is missing % and adds % of the % rows the query before #168 gives',
            _first, _last, _missing, _extra, _rows;
    END IF;

    -- Posts, comments, votes, transfers and custom_json: the range must hold every class.
    IF _classes < 5 THEN
        RAISE EXCEPTION 'FAIL: blocks %..% hold only % op classes, so the comparison covers too little', _first, _last, _classes;
    END IF;

    RAISE NOTICE 'OK: blocks %..%: % authored rows, the same as before #168', _first, _last, _rows;
END;
$guard$;

ROLLBACK;
