-- process_account_cohorts' activity update and process_content_stats_range's network_voter_daily
-- insert, run for real over one synthetic batch and compared with the statements they replaced,
-- which are kept below verbatim as the reference.
--
-- Members sit on each edge of the rolling windows: an op exactly at day 7, one minute before
-- it, exactly at day 180 (outside the window) and one minute before it (inside), members
-- already partly or fully active, a member the batch does not touch and an author that is no
-- member. Votes cross midnight, repeat a voter, name no account or no voter at all, and hit a
-- (day, voter) row already present. Both results are also checked against fixed expectations,
-- so a derivation that agreed with a broken reference would still fail.
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
(9601, '2021-09-01 23:59:00'),
(9602, '2021-09-02 00:01:00'),
(9603, '2021-09-02 12:00:00');

INSERT INTO hafd.accounts (id, name) VALUES
(96001, 'cbat-d7'),
(96002, 'cbat-early'),
(96003, 'cbat-d30'),
(96004, 'cbat-d90'),
(96005, 'cbat-d180'),
(96006, 'cbat-d179'),
(96007, 'cbat-partial'),
(96008, 'cbat-done'),
(96009, 'cbat-idle'),
(96010, 'cbat-outsider'),
(96011, 'cbat-mixed');

INSERT INTO haf_stats_backend.account_cohort_members
    (account_id, cohort_month, created_at, active_7d, active_30d, active_90d)
SELECT m.id, DATE_TRUNC('month', m.created_at)::DATE, m.created_at, m.a7, m.a30, m.a90
FROM (VALUES
    (96001, TIMESTAMP '2021-09-01 23:59:00' - INTERVAL '7 days', FALSE, FALSE, FALSE),
    (96002, TIMESTAMP '2021-09-01 23:59:00' - INTERVAL '7 days' + INTERVAL '1 minute', FALSE, FALSE, FALSE),
    (96003, TIMESTAMP '2021-09-02 12:00:00' - INTERVAL '30 days', FALSE, FALSE, FALSE),
    (96004, TIMESTAMP '2021-09-02 12:00:00' - INTERVAL '90 days', FALSE, FALSE, FALSE),
    (96005, TIMESTAMP '2021-09-01 23:59:00' - INTERVAL '180 days', FALSE, FALSE, FALSE),
    (96006, TIMESTAMP '2021-09-01 23:59:00' - INTERVAL '180 days' + INTERVAL '1 minute', FALSE, FALSE, FALSE),
    (96007, TIMESTAMP '2021-09-02 12:00:00' - INTERVAL '35 days', TRUE, FALSE, FALSE),
    (96008, TIMESTAMP '2021-09-02 12:00:00' - INTERVAL '100 days', TRUE, TRUE, TRUE),
    (96009, TIMESTAMP '2021-09-02 12:00:00' - INTERVAL '100 days', FALSE, FALSE, FALSE),
    (96011, TIMESTAMP '2021-09-02 00:01:00' - INTERVAL '7 days', FALSE, FALSE, FALSE)
) AS m (id, created_at, a7, a30, a90);

-- Transfers (signed by 'from') carry the cohort activity; votes (signed by 'voter') feed both.
INSERT INTO hafd.operations (id, op_type_id, body_value) VALUES
(hafd.operation_id(9601, 1), 2, '{"from": "cbat-d7", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9601, 2), 2, '{"from": "cbat-early", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9601, 3), 2, '{"from": "cbat-d180", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9601, 4), 2, '{"from": "cbat-d179", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9601, 5), 2, '{"from": "cbat-mixed", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9601, 6), 0, '{"voter": "cbat-d7", "author": "cbat-outsider", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9601, 7), 0, '{"voter": "cbat-early", "author": "cbat-outsider", "permlink": "p", "weight": -10000}'),
(hafd.operation_id(9601, 8), 0, '{"voter": "cbat-nobody", "author": "cbat-outsider", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9601, 9), 0, '{"author": "cbat-outsider", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9602, 1), 2, '{"from": "cbat-mixed", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9602, 2), 2, '{"from": "cbat-mixed", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9602, 3), 0, '{"voter": "cbat-d7", "author": "cbat-outsider", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9602, 4), 0, '{"voter": "cbat-d30", "author": "cbat-outsider", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9602, 5), 0, '{"voter": "cbat-d30", "author": "cbat-outsider", "permlink": "q", "weight": 5000}'),
(hafd.operation_id(9603, 1), 2, '{"from": "cbat-d30", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9603, 2), 2, '{"from": "cbat-d90", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9603, 3), 2, '{"from": "cbat-partial", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9603, 4), 2, '{"from": "cbat-done", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9603, 5), 2, '{"from": "cbat-outsider", "to": "cbat-idle", "memo": ""}'),
(hafd.operation_id(9603, 6), 0, '{"voter": "cbat-d90", "author": "cbat-outsider", "permlink": "p", "weight": 10000}'),
(hafd.operation_id(9603, 7), 0, '{"voter": "cbat-outsider", "author": "cbat-outsider", "permlink": "p", "weight": 0}');

DELETE FROM haf_stats_backend.network_voter_daily WHERE day IN (DATE '2021-09-01', DATE '2021-09-02');
INSERT INTO haf_stats_backend.network_voter_daily (day, voter_id) VALUES
(DATE '2021-09-02', 96004);

SET ROLE haf_stats_owner;

-- ---------------------------------------------------------------------------
-- 1. account_cohort_members flags
-- ---------------------------------------------------------------------------
DO $cohorts$
DECLARE
    _old TEXT;
    _new TEXT;
    _want TEXT := '96001:t:f:f,'   -- exactly day 7
                  '96002:f:f:f,'   -- one minute before day 7
                  '96003:t:t:f,'   -- exactly day 30
                  '96004:t:t:t,'   -- exactly day 90
                  '96005:f:f:f,'   -- exactly day 180: outside the window
                  '96006:t:t:t,'   -- one minute before day 180
                  '96007:t:t:f,'   -- day 35, day 7 already set
                  '96008:t:t:t,'   -- fully active already
                  '96009:f:f:f,'   -- no op in the batch
                  '96011:t:f:f';   -- before day 7, then twice at it
BEGIN
    PERFORM haf_stats_app.prepare_batch_authored_ops(9601, 9603);

    CREATE TEMP TABLE ci_acm_old ON COMMIT DROP AS
    SELECT * FROM haf_stats_backend.account_cohort_members
    WHERE account_id BETWEEN 96001 AND 96011;
    ALTER TABLE ci_acm_old ADD PRIMARY KEY (account_id);

    -- The replaced statement.
    WITH batch_authored AS MATERIALIZED (
        SELECT DISTINCT account_id, op_time
        FROM haf_stats_batch_authored_ops
    )
    UPDATE ci_acm_old acm
    SET
        active_7d  = acm.active_7d  OR ra.active_7d,
        active_30d = acm.active_30d OR ra.active_30d,
        active_90d = acm.active_90d OR ra.active_90d
    FROM (
        SELECT
            m.account_id,
            BOOL_OR(ba.op_time >= m.created_at + INTERVAL '7 days') AS active_7d,
            BOOL_OR(ba.op_time >= m.created_at + INTERVAL '30 days') AS active_30d,
            BOOL_OR(ba.op_time >= m.created_at + INTERVAL '90 days') AS active_90d
        FROM batch_authored ba
        JOIN ci_acm_old m ON m.account_id = ba.account_id
        WHERE NOT (m.active_7d AND m.active_30d AND m.active_90d)
          AND ba.op_time >= m.created_at + INTERVAL '7 days'
          AND ba.op_time <  m.created_at + INTERVAL '180 days'
        GROUP BY m.account_id
    ) ra
    WHERE acm.account_id = ra.account_id
      AND (ra.active_7d OR ra.active_30d OR ra.active_90d);

    PERFORM haf_stats_app.process_account_cohorts(9601, 9603);

    SELECT string_agg(format('%s:%s:%s:%s', account_id, active_7d, active_30d, active_90d), ','
                      ORDER BY account_id)
    INTO _old
    FROM ci_acm_old;

    SELECT string_agg(format('%s:%s:%s:%s', account_id, active_7d, active_30d, active_90d), ','
                      ORDER BY account_id)
    INTO _new
    FROM haf_stats_backend.account_cohort_members
    WHERE account_id BETWEEN 96001 AND 96011;

    IF _new IS DISTINCT FROM _old THEN
        RAISE EXCEPTION 'FAIL: cohort flags % differ from the replaced statement''s %', _new, _old;
    END IF;
    IF _new IS DISTINCT FROM _want THEN
        RAISE EXCEPTION 'FAIL: cohort flags %, expected %', _new, _want;
    END IF;

    RAISE NOTICE 'cohort activity update matches the replaced statement: %', _new;
END
$cohorts$;

-- ---------------------------------------------------------------------------
-- 2. network_voter_daily rows
-- ---------------------------------------------------------------------------
DO $voters$
DECLARE
    _old TEXT;
    _new TEXT;
    _want TEXT := '2021-09-01:96001,'
                  '2021-09-01:96002,'
                  '2021-09-02:96001,'
                  '2021-09-02:96003,'
                  '2021-09-02:96004,'   -- present before the batch, voted again
                  '2021-09-02:96010';   -- an unvote
BEGIN
    PERFORM haf_stats_app.prepare_batch_ops(9601, 9603, ARRAY[0, 1, 17, 73]);

    -- What was there, plus what the replaced statement inserted.
    CREATE TEMP TABLE ci_voters_old ON COMMIT DROP AS
    SELECT day, voter_id
    FROM haf_stats_backend.network_voter_daily
    WHERE day IN (DATE '2021-09-01', DATE '2021-09-02')
    UNION
    SELECT DISTINCT vo.day, a.id
    FROM (
        SELECT ov.body_value ->> 'voter' AS voter, ov.day
        FROM haf_stats_batch_ops ov
        WHERE ov.op_type_id = 0
    ) vo
    JOIN hafd.accounts a ON a.name = vo.voter;

    PERFORM haf_stats_app.process_content_stats_range(9601, 9603, FALSE);

    SELECT string_agg(format('%s:%s', day, voter_id), ',' ORDER BY day, voter_id)
    INTO _old
    FROM ci_voters_old;

    SELECT string_agg(format('%s:%s', day, voter_id), ',' ORDER BY day, voter_id)
    INTO _new
    FROM haf_stats_backend.network_voter_daily
    WHERE day IN (DATE '2021-09-01', DATE '2021-09-02');

    IF _new IS DISTINCT FROM _old THEN
        RAISE EXCEPTION 'FAIL: network_voter_daily % differs from the replaced statement''s %', _new, _old;
    END IF;
    IF _new IS DISTINCT FROM _want THEN
        RAISE EXCEPTION 'FAIL: network_voter_daily %, expected %', _new, _want;
    END IF;

    RAISE NOTICE 'network_voter_daily matches the replaced statement: %', _new;
END
$voters$;

RESET ROLE;

ROLLBACK;
