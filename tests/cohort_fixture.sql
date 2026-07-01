-- Deterministic account-cohort processor fixture.
--
-- Five accounts are created through the canonical account_created virtual op:
-- one returns on each of D7/D30/D90, one acts only on D2, and one is inactive.
-- Under rolling-to-180 retention the flags nest, so the closed-cohort result is
-- new_accounts=5 with active 7d=3 (D7,D30,D90), 30d=2 (D30,D90), 90d=1 (D90).
-- The whole cohort has passed day 90 by _as_of, so eligible is 5/5/5.

INSERT INTO hafd.operation_types (id, name, is_virtual)
VALUES
    (1, 'hive::protocol::vote_operation', FALSE),
    (100, 'hive::protocol::account_created_operation', TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO hafd.accounts (id, name)
VALUES
    (10, 'retained-d7'),
    (11, 'retained-d30'),
    (12, 'retained-d90'),
    (13, 'early-only'),
    (14, 'inactive')
ON CONFLICT (id) DO NOTHING;

INSERT INTO hafd.blocks (num, created_at)
VALUES
    (1000, '2020-01-01 12:00:00'),
    (1001, '2020-01-03 12:00:00'),
    (1002, '2020-01-08 18:00:00'),
    (1003, '2020-01-31 18:00:00'),
    (1004, '2020-03-31 18:00:00'),
    (1005, '2020-04-02 13:00:00')
ON CONFLICT (num) DO NOTHING;

-- Step 1 source: the account_created virtual op (one per new account at block 1000).
INSERT INTO hafd.operations (id, op_type_id, body_value)
SELECT
    hafd.operation_id(1000, (ROW_NUMBER() OVER ())::INT),
    100,
    JSONB_BUILD_OBJECT('new_account_name', account_name)
FROM (
    VALUES
        ('retained-d7'),
        ('retained-d30'),
        ('retained-d90'),
        ('early-only'),
        ('inactive')
) AS created(account_name)
ON CONFLICT (id) DO NOTHING;

-- Step 2 source: retention activity is now AUTHORED ops in operations_view; the
-- get_required_authorities stub resolves the synthetic '_signer' field. Each is a
-- non-virtual vote_operation (op_type 1) the account signed in a given window.
INSERT INTO hafd.operations (id, op_type_id, body_value)
VALUES
    (hafd.operation_id(1001, 1), 1, JSONB_BUILD_OBJECT('_signer', 'early-only')),  -- D2: before day 7, no rolling flag
    (hafd.operation_id(1002, 1), 1, JSONB_BUILD_OBJECT('_signer', 'retained-d7')), -- D7
    (hafd.operation_id(1003, 1), 1, JSONB_BUILD_OBJECT('_signer', 'retained-d30')),-- D30
    (hafd.operation_id(1004, 1), 1, JSONB_BUILD_OBJECT('_signer', 'retained-d90')) -- D90
ON CONFLICT (id) DO NOTHING;

SET ROLE haf_stats_owner;

SELECT haf_stats_app.process_account_cohorts(1000, 1005);
SELECT haf_stats_app.refresh_account_cohort_retention(
    '2020-04-02 13:00:00',
    NULL,
    NULL
);

DO $$
DECLARE
    _actual RECORD;
BEGIN
    SELECT *
    INTO _actual
    FROM haf_stats_backend.account_cohort_retention
    WHERE cohort_month = DATE '2020-01-01';

    IF _actual.new_accounts IS DISTINCT FROM 5
       OR _actual.eligible_at_7d IS DISTINCT FROM 5
       OR _actual.active_at_7d IS DISTINCT FROM 3
       OR _actual.eligible_at_30d IS DISTINCT FROM 5
       OR _actual.active_at_30d IS DISTINCT FROM 2
       OR _actual.eligible_at_90d IS DISTINCT FROM 5
       OR _actual.active_at_90d IS DISTINCT FROM 1
    THEN
        RAISE EXCEPTION
            'cohort fixture mismatch: expected new=5 elig(5,5,5) active(3,2,1), '
            'got new=% elig(%,%,%) active(%,%,%)',
            _actual.new_accounts,
            _actual.eligible_at_7d,
            _actual.eligible_at_30d,
            _actual.eligible_at_90d,
            _actual.active_at_7d,
            _actual.active_at_30d,
            _actual.active_at_90d;
    END IF;
END
$$;

RESET ROLE;
