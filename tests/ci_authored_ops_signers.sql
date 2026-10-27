-- haf_stats_app.prepare_batch_authored_ops over vote, comment, transfer and custom_json ops,
-- whose signers it reads from their bodies rather than through hive.get_required_authorities.
--
-- Well-formed ops give their signer field's account, and custom_json each account of both its
-- auth lists, once. An op whose body lacks the field, or holds something that is no account
-- list, gives no row and no error, which is what HAF gives too: for a body without the field
-- hive.get_required_authorities returns '' (no account has that name), and for a null or
-- non-string/non-array field it raises, which leaves the op no account through the per-row
-- wrapper. tests/parity/authored_ops_signers.sql checks the same derivation against
-- hive.get_required_authorities on the replayed chain.
--
-- The stub lookup is replaced by one that raises for these four types, so a row that came from
-- the lookup instead of the body would be lost to the per-row wrapper and fail the comparison.
-- Within the transaction, which is rolled back, the stub's op types get their real ids: the
-- stub names id 1 vote_operation, which on the chain is comment_operation.

BEGIN;

UPDATE hafd.operation_types SET name = 'hive::protocol::comment_operation' WHERE id = 1;
INSERT INTO hafd.operation_types (id, name, is_virtual) VALUES
(0, 'hive::protocol::vote_operation', FALSE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO hafd.blocks (num, created_at) VALUES
(9400, '2021-08-01 00:00:00');

INSERT INTO hafd.accounts (id, name) VALUES
(94001, 'fsalice'),
(94002, 'fsbob');

INSERT INTO hafd.operations (id, op_type_id, body_value) VALUES
(hafd.operation_id(9400, 1), 0, '{"voter": "fsalice", "author": "fsbob", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9400, 2), 0, '{"author": "fsbob", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9400, 3), 0, '{"voter": null, "author": "fsbob", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9400, 4), 1, '{"author": "fsbob", "parent_author": "", "permlink": "p"}'),
(hafd.operation_id(9400, 5), 1, '{"author": "fsalice", "parent_author": "fsbob", "permlink": "r"}'),
(hafd.operation_id(9400, 6), 1, '{"parent_author": "", "permlink": "q"}'),
(hafd.operation_id(9400, 7), 2, '{"from": "fsbob", "to": "fsalice", "memo": ""}'),
(hafd.operation_id(9400, 8), 2, '{"to": "fsalice", "memo": ""}'),
(hafd.operation_id(9400, 9), 18, '{"required_auths": ["fsalice"], "required_posting_auths": ["fsalice", "fsbob", "fsbob"], "id": "x", "json": "{}"}'),
(hafd.operation_id(9400, 10), 18, '{"required_auths": [], "required_posting_auths": ["fsbob", "fsnobody"], "id": "x", "json": "{}"}'),
(hafd.operation_id(9400, 11), 18, '{"id": "x", "json": "{}"}'),
(hafd.operation_id(9400, 12), 18, '{"required_auths": null, "required_posting_auths": "fsbob", "id": "x", "json": "{}"}');

CREATE OR REPLACE FUNCTION hive.get_required_authorities(_body JSONB)
RETURNS TABLE (account_name TEXT)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF _body ->> 'type' IN ('vote_operation', 'comment_operation', 'transfer_operation', 'custom_json_operation') THEN
        RAISE EXCEPTION 'the signers of a % are read from its body', _body ->> 'type'
            USING ERRCODE = 'invalid_text_representation';
    END IF;
    RETURN QUERY SELECT _body -> 'value' ->> '_signer' WHERE _body -> 'value' ? '_signer';
END;
$$;

DO $signers$
DECLARE
    _got TEXT;
    _want TEXT := '9400000001:94001:3,'      -- vote: voter
                  '9400000004:94002:1,'      -- comment, a post: author
                  '9400000005:94001:2,'      -- comment, a reply: author
                  '9400000007:94002:4,'      -- transfer: from
                  '9400000009:94001:5,'      -- custom_json: active and posting, once
                  '9400000009:94002:5,'      -- custom_json: posting, listed twice
                  '9400000010:94002:5';      -- custom_json: posting; fsnobody is no account
BEGIN
    PERFORM haf_stats_app.prepare_batch_authored_ops(9400, 9400);

    SELECT string_agg(format('%s:%s:%s', a.op_id, a.account_id, a.op_class), ','
                      ORDER BY a.op_id, a.account_id)
    INTO _got
    FROM haf_stats_batch_authored_ops AS a;

    IF _got IS DISTINCT FROM _want THEN
        RAISE EXCEPTION 'FAIL: authored rows %, expected %', _got, _want;
    END IF;

    RAISE NOTICE 'authored ops of vote/comment/transfer/custom_json over block 9400: %', _got;
END;
$signers$;

ROLLBACK;
