-- haf_stats_app.prepare_batch_authored_ops when hive.get_required_authorities raises.
--
-- The batch's INSERT runs with plain hive.get_required_authorities and, only if that statement
-- fails, again through the per-row get_required_authorities_safe. On a real node the failure is
-- an FC_ASSERT on a few legacy ops (~block 23.5M), which the 5M-block lanes never reach, and
-- the stub function never throws, so nothing else exercises the second run. Here the stub is
-- replaced by one that raises for a marked op, as HAF does (SQLSTATE 22P02), and the authored
-- rows are checked against both their literal values and what the per-row wrapper gives for
-- the same ops: with the poisoned op in the batch, and without it.
--
-- Everything is inside a transaction that is rolled back, the replaced stub included.

BEGIN;

INSERT INTO hafd.blocks (num, created_at) VALUES
(9300, '2021-07-01 00:00:00'),
(9301, '2021-07-01 00:00:03');

INSERT INTO hafd.accounts (id, name) VALUES
(93001, 'fballice'),
(93002, 'fbbob');

-- Stub op types: 2 is transfer_operation, 18 custom_json_operation, both non-virtual.
INSERT INTO hafd.operations (id, op_type_id, body_value) VALUES
(hafd.operation_id(9300, 1), 2, '{"_signer": "fballice"}'),
(hafd.operation_id(9300, 2), 18, '{"_signer": "fbbob"}'),
(hafd.operation_id(9301, 1), 2, '{"_signer": "fbbob", "_poison": true}'),
(hafd.operation_id(9301, 2), 18, '{"_signer": "fballice"}'),
(hafd.operation_id(9301, 3), 2, '{"_signer": "fbnobody"}');

CREATE OR REPLACE FUNCTION hive.get_required_authorities(_body JSONB)
RETURNS TABLE (account_name TEXT)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF _body -> 'value' ? '_poison' THEN
        RAISE EXCEPTION 'Assert Exception:amountInt >= 0: Asset amount cannot be negative'
            USING ERRCODE = 'invalid_text_representation';
    END IF;
    RETURN QUERY SELECT _body -> 'value' ->> '_signer' WHERE _body -> 'value' ? '_signer';
END;
$$;

DO $fallback$
DECLARE
    _got TEXT;
    _want TEXT;
    _per_row TEXT;
    _first INT;
    _last INT;
BEGIN
    -- The poisoned op really makes the plain lookup raise, so a batch holding it cannot be
    -- answered by the plain statement.
    BEGIN
        PERFORM hive.get_required_authorities('{"type": "transfer_operation", "value": {"_signer": "fbbob", "_poison": true}}');
        RAISE EXCEPTION 'FAIL: the poisoned op did not make hive.get_required_authorities raise';
    EXCEPTION WHEN invalid_text_representation THEN
        NULL;
    END;

    FOREACH _last IN ARRAY ARRAY[9301, 9300] LOOP
        _first := 9300;

        PERFORM haf_stats_app.prepare_batch_authored_ops(_first, _last);

        SELECT string_agg(format('%s:%s:%s:%s', a.op_id, a.account_id, a.op_time, a.op_class), ','
                          ORDER BY a.op_id, a.account_id)
        INTO _got
        FROM haf_stats_batch_authored_ops AS a;

        -- The poisoned op contributes nothing, as the per-row wrapper makes it; fbnobody is
        -- no account, so its op is dropped by the name join either way.
        _want := CASE _last
            WHEN 9301 THEN '9300000001:93001:2021-07-01 00:00:00:4,9300000002:93002:2021-07-01 00:00:00:5,'
                           '9301000002:93001:2021-07-01 00:00:03:5'
            ELSE '9300000001:93001:2021-07-01 00:00:00:4,9300000002:93002:2021-07-01 00:00:00:5'
        END;
        IF _got IS DISTINCT FROM _want THEN
            RAISE EXCEPTION 'FAIL: blocks %..% gave authored rows %, expected %', _first, _last, _got, _want;
        END IF;

        -- The same ops through the per-row wrapper, the way every batch used to be computed.
        SELECT string_agg(format('%s:%s', x.op_id, x.account_id), ',' ORDER BY x.op_id, x.account_id)
        INTO _per_row
        FROM (
            SELECT DISTINCT ov.id AS op_id, av.id AS account_id
            FROM hive.operations_view AS ov
            CROSS JOIN LATERAL haf_stats_app.get_required_authorities_safe(ov.body) AS ra
            JOIN hive.accounts_view AS av ON av.name = ra.account_name
            WHERE ov.block_num BETWEEN _first AND _last
        ) AS x;

        SELECT string_agg(format('%s:%s', a.op_id, a.account_id), ',' ORDER BY a.op_id, a.account_id)
        INTO _got
        FROM haf_stats_batch_authored_ops AS a;
        IF _got IS DISTINCT FROM _per_row THEN
            RAISE EXCEPTION 'FAIL: blocks %..% gave authored (op, account) pairs %, the per-row wrapper %',
                _first, _last, _got, _per_row;
        END IF;

        RAISE NOTICE 'authored ops over blocks %..%: % (same as the per-row wrapper)', _first, _last, _got;
    END LOOP;
END;
$fallback$;

ROLLBACK;
