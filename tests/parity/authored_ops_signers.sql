-- =============================================================================
-- authored_ops_signers.sql — guard for issue #112.
--
-- haf_stats_app.prepare_batch_authored_ops reads the signers of vote, comment, transfer and
-- custom_json ops (ids 0, 1, 2, 18) from their bodies instead of asking
-- hive.get_required_authorities, which it still asks for every other non-virtual type. This
-- runs the real function over windows of the replayed chain and asserts that, for those four
-- types, its (op, account) pairs are exactly the ones hive.get_required_authorities gives for
-- the same ops, resolved to account ids the same way: nothing missing, nothing extra.
--
-- The windows are spread over the replay, and one holds the only custom_json ops below block
-- 5,000,000 with a non-empty required_auths (4,971,042..4,975,335); the guard also fails if
-- the windows stop holding ops of every one of the four types, or custom_json signed through
-- each of its two auth lists, so it cannot pass by comparing nothing.
--
-- Read-only: prepare_batch_authored_ops writes only ON COMMIT DROP temp tables, and the
-- transaction is rolled back.
-- =============================================================================
\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE haf_stats_owner;

DO $guard$
DECLARE
    _window INT4RANGE;
    _missing BIGINT;
    _extra BIGINT;
    _pairs BIGINT;
    _sample TEXT;
    _seen_types INT [] := '{}';
    _seen_active BOOLEAN := FALSE;
    _seen_posting BOOLEAN := FALSE;
    _total BIGINT := 0;
BEGIN
    FOREACH _window IN ARRAY ARRAY[
        INT4RANGE(1000001, 1010000, '[]'),
        INT4RANGE(2500001, 2510000, '[]'),
        INT4RANGE(3500001, 3510000, '[]'),
        INT4RANGE(4200001, 4210000, '[]'),
        INT4RANGE(4970001, 4980000, '[]'),
        INT4RANGE(4990001, 5000000, '[]')
    ] LOOP
        PERFORM haf_stats_app.prepare_batch_authored_ops(LOWER(_window), UPPER(_window) - 1);

        CREATE TEMP TABLE authored_expected ON COMMIT DROP AS
        SELECT DISTINCT o.id AS op_id, av.id AS account_id
        FROM hafd.operations AS o
        JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id
        CROSS JOIN LATERAL hive.get_required_authorities(jsonb_build_object(
            'type', replace(ot.name, 'hive::protocol::', ''),
            'value', o.body_value
        )) AS ra
        JOIN hive.accounts_view AS av ON av.name = ra.account_name
        WHERE o.id >= hafd.operation_id(LOWER(_window), 0)
          AND o.id < hafd.operation_id(UPPER(_window), 0)
          AND o.op_type_id IN (0, 1, 2, 18);

        CREATE TEMP TABLE authored_actual ON COMMIT DROP AS
        SELECT a.op_id, a.account_id
        FROM haf_stats_batch_authored_ops AS a
        JOIN haf_stats_batch_ops AS s ON s.op_id = a.op_id
        WHERE s.op_type_id IN (0, 1, 2, 18);

        SELECT COUNT(*) INTO _missing
        FROM (SELECT * FROM authored_expected EXCEPT SELECT * FROM authored_actual) AS x;
        SELECT COUNT(*) INTO _extra
        FROM (SELECT * FROM authored_actual EXCEPT SELECT * FROM authored_expected) AS x;
        SELECT COUNT(*) INTO _pairs FROM authored_expected;

        IF _missing > 0 OR _extra > 0 THEN
            SELECT string_agg(format('%s:%s:%s', d.side, d.op_id, d.account_id), ', ') INTO _sample
            FROM (
                (SELECT 'missing' AS side, * FROM authored_expected
                 EXCEPT SELECT 'missing', * FROM authored_actual LIMIT 5)
                UNION ALL
                (SELECT 'extra', * FROM authored_actual
                 EXCEPT SELECT 'extra', * FROM authored_expected LIMIT 5)
            ) AS d;
            RAISE EXCEPTION 'FAIL: blocks %..%: prepare_batch_authored_ops is missing % and adds % of the % (op, account) pairs hive.get_required_authorities gives vote/comment/transfer/custom_json ops (e.g. %)',
                LOWER(_window), UPPER(_window) - 1, _missing, _extra, _pairs, _sample;
        END IF;

        SELECT _seen_types || COALESCE(ARRAY_AGG(DISTINCT s.op_type_id::INT), '{}')
        INTO _seen_types
        FROM authored_actual AS a
        JOIN haf_stats_batch_ops AS s ON s.op_id = a.op_id;

        SELECT _seen_active OR COALESCE(BOOL_OR(jsonb_array_length(s.body_value -> 'required_auths') > 0), FALSE),
               _seen_posting OR COALESCE(BOOL_OR(jsonb_array_length(s.body_value -> 'required_posting_auths') > 0), FALSE)
        INTO _seen_active, _seen_posting
        FROM authored_actual AS a
        JOIN haf_stats_batch_ops AS s ON s.op_id = a.op_id
        WHERE s.op_type_id = 18;

        _total := _total + _pairs;
        RAISE NOTICE 'blocks %..%: % (op, account) pairs, same as hive.get_required_authorities',
            LOWER(_window), UPPER(_window) - 1, _pairs;

        DROP TABLE authored_expected;
        DROP TABLE authored_actual;
    END LOOP;

    IF NOT ('{0,1,2,18}'::INT [] <@ _seen_types) OR NOT _seen_active OR NOT _seen_posting THEN
        RAISE EXCEPTION 'FAIL: the windows no longer cover every fast-path signer (types seen %, custom_json required_auths %, required_posting_auths %)',
            _seen_types, _seen_active, _seen_posting;
    END IF;

    RAISE NOTICE 'OK: % (op, account) pairs of vote/comment/transfer/custom_json ops match hive.get_required_authorities', _total;
END;
$guard$;

ROLLBACK;
