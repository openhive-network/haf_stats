-- =============================================================================
-- haf_stats Regression Comparison  (mirrors balance_tracker compare_accounts())
-- =============================================================================
-- For each account in expected_account_metrics, compute the live haf_stats
-- endpoint values for the 2016-04 window and record every field that differs
-- from the external hived ground truth. run_test.sh fails iff differing_metrics
-- is non-empty.
--
-- The fixed 2016-04 window matches generate_fixture.py and the tavern suite; the
-- figures are window-closed (~block 1.06M) so they are stable at any replay
-- depth >= ~1.1M, the same depth-robustness the tavern assertions rely on.
-- =============================================================================

SET ROLE haf_stats_owner;

CREATE OR REPLACE FUNCTION haf_stats_test.compare_account_metrics()
RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    e   RECORD;
    cs  RECORD;
    inc_hive  BIGINT; inc_ops  BIGINT;
    exp_hive  BIGINT; exp_ops  BIGINT;
BEGIN
    TRUNCATE haf_stats_test.differing_metrics;

    FOR e IN SELECT * FROM haf_stats_test.expected_account_metrics LOOP
        -- Content endpoint (one row for the month, or no row if inactive).
        SELECT posts, comments, votes_cast
          INTO cs
          FROM haf_stats_endpoints.get_account_content_stats(e.account, '2016-04-01', '2016-04-30', 'month')
         LIMIT 1;

        INSERT INTO haf_stats_test.differing_metrics(account, field, expected, actual)
        SELECT * FROM (VALUES
            (e.account, 'posts',      e.posts::NUMERIC,      COALESCE(cs.posts,      0)::NUMERIC),
            (e.account, 'comments',   e.comments::NUMERIC,   COALESCE(cs.comments,   0)::NUMERIC),
            (e.account, 'votes_cast', e.votes_cast::NUMERIC, COALESCE(cs.votes_cast, 0)::NUMERIC)
        ) v(account, field, expected, actual)
        WHERE expected IS DISTINCT FROM actual;

        -- Financial endpoint: transfer_operation incoming / outgoing for the month.
        SELECT COALESCE(SUM(hive_nai) FILTER (WHERE direction='incoming' AND category='transfer_operation'), 0),
               COALESCE(SUM(op_count) FILTER (WHERE direction='incoming' AND category='transfer_operation'), 0),
               COALESCE(SUM(hive_nai) FILTER (WHERE direction='outgoing' AND category='transfer_operation'), 0),
               COALESCE(SUM(op_count) FILTER (WHERE direction='outgoing' AND category='transfer_operation'), 0)
          INTO inc_hive, inc_ops, exp_hive, exp_ops
          FROM haf_stats_endpoints.get_account_financial_summary(e.account, '2016-04-01', '2016-04-30', 'month');

        INSERT INTO haf_stats_test.differing_metrics(account, field, expected, actual)
        SELECT * FROM (VALUES
            (e.account, 'transfer_income_hive_nai',  e.transfer_income_hive_nai::NUMERIC,  inc_hive::NUMERIC),
            (e.account, 'transfer_income_ops',       e.transfer_income_ops::NUMERIC,       inc_ops::NUMERIC),
            (e.account, 'transfer_expense_hive_nai', e.transfer_expense_hive_nai::NUMERIC, exp_hive::NUMERIC),
            (e.account, 'transfer_expense_ops',      e.transfer_expense_ops::NUMERIC,      exp_ops::NUMERIC)
        ) v(account, field, expected, actual)
        WHERE expected IS DISTINCT FROM actual;
    END LOOP;
END;
$$;

RESET ROLE;
