/*
 * mainnet_metrics_parity.sql
 * ==========================
 * Correctness guard for the EXACT values asserted in endpoint-local JSON
 * pattern files under tests/tavern, plus critical financial operation mappings
 * that need independent semantic coverage.
 *
 * Mirrors balance_tracker's tests/parity/impacted_balances_parity.sql: for each
 * metric it computes the value TWICE by independent means and asserts they agree,
 * raising an exception on any divergence (run under `psql -v ON_ERROR_STOP=on`).
 *
 *   - "endpoint"    = the haf_stats_endpoints.* function output (i.e. what the
 *                     processor produced into haf_stats_backend).
 *   - "independent" = re-derived FROM SCRATCH off the raw operation stream
 *                     (hafd.operations / hafd.blocks), sharing NONE of the
 *                     processor's code or its haf_stats_backend tables.
 *
 * The tavern suite proves endpoint == hardcoded constants; this proves
 * endpoint == an independent derivation. Together they prove the constants are
 * CORRECT, not merely self-consistent — closing the oracle-circularity gap
 * ("what if we miscalculated the expected value?").
 *
 * Primary window: the 2016-04 month, the same cohort the Tavern suite asserts.
 * Expanded financial checks also use 2016-07 and full available history, when
 * fill_order/liquidity/re-vesting operations exist. Exact D90 retention requires
 * the 5,000,000-block reference replay.
 *
 * Run:  psql "$DB" -v ON_ERROR_STOP=on -f tests/parity/mainnet_metrics_parity.sql
 *
 * NOTE on independence of the edit-vs-create rule: a naive COUNT of every
 * comment_operation gives 819 posts / 732 comments for April; the correct
 * figures (489 / 616) require counting only the FIRST-EVER occurrence of each
 * (author, permlink) — i.e. excluding edits. The independent derivation below
 * does this with a window function (ROW_NUMBER), a completely different method
 * from the processor's stateful comment_registry, yet must reach the same
 * numbers. new_accounts counts ALL account creations (incl. pow-mined, dominant in
 * 2016): the processor reads the account_created virtual op, the check below reads
 * hafd.accounts.block_num — two independent canonical signals that must agree.
 */

\set ON_ERROR_STOP on

-- The container's /dev/shm is small; the full-history first-occurrence scan trips
-- parallel-worker shared memory. Single-threaded is plenty fast here.
SET max_parallel_workers_per_gather = 0;
SET work_mem = '256MB';

\echo '== building independent first-occurrence table (excludes edits) =='
DROP TABLE IF EXISTS _firsts;
CREATE TEMP TABLE _firsts AS
SELECT x.author, x.permlink, x.parent_author, x.parent_permlink,
       b.created_at::DATE AS day
FROM (
    SELECT o.body_value->>'author'        AS author,
           o.body_value->>'permlink'      AS permlink,
           o.body_value->>'parent_author' AS parent_author,
           o.body_value->>'parent_permlink' AS parent_permlink,
           hafd.operation_id_to_block_num(o.id) AS blk,
           ROW_NUMBER() OVER (PARTITION BY o.body_value->>'author',
                                           o.body_value->>'permlink'
                              ORDER BY o.id) AS rn
    FROM hafd.operations o
    WHERE o.op_type_id = 1            -- comment_operation
) x
JOIN hafd.blocks b ON b.num = x.blk
WHERE x.rn = 1;                       -- first occurrence only => creates, not edits
CREATE INDEX ON _firsts (day);

\echo '== collecting endpoint vs independent values =='
DROP TABLE IF EXISTS _parity;
CREATE TEMP TABLE _parity (metric TEXT, field TEXT, endpoint_val NUMERIC, independent_val NUMERIC);

-- 1) get_network_content_volume (2016-04 month)
INSERT INTO _parity VALUES
('content_volume','posts',
 (SELECT posts          FROM haf_stats_endpoints.get_network_content_volume('2016-04-01','2016-04-30','month')),
 (SELECT COUNT(*) FROM _firsts WHERE parent_author='' AND day>='2016-04-01' AND day<'2016-05-01')),
('content_volume','comments',
 (SELECT comments       FROM haf_stats_endpoints.get_network_content_volume('2016-04-01','2016-04-30','month')),
 (SELECT COUNT(*) FROM _firsts WHERE parent_author<>'' AND day>='2016-04-01' AND day<'2016-05-01')),
('content_volume','unique_authors',
 (SELECT unique_authors FROM haf_stats_endpoints.get_network_content_volume('2016-04-01','2016-04-30','month')),
 (SELECT COUNT(DISTINCT author) FROM _firsts WHERE day>='2016-04-01' AND day<'2016-05-01'));

-- 2) get_network_vote_stats (2016-04 month) — independent classification of vote_operation
WITH v AS (
    SELECT (o.body_value->>'weight')::INT AS weight,
           o.body_value->>'voter' AS voter, o.body_value->>'author' AS author
    FROM hafd.operations o JOIN hafd.blocks b ON b.num = hafd.operation_id_to_block_num(o.id)
    WHERE o.op_type_id=0 AND b.created_at>='2016-04-01' AND b.created_at<'2016-05-01'
)
INSERT INTO _parity
SELECT 'vote_stats', f.field, f.ev, f.iv FROM (
  VALUES
   ('total_votes',  (SELECT total_votes   FROM haf_stats_endpoints.get_network_vote_stats('2016-04-01','2016-04-30','month'))::NUMERIC, (SELECT COUNT(*)::NUMERIC FROM v)),
   ('upvotes',      (SELECT upvotes        FROM haf_stats_endpoints.get_network_vote_stats('2016-04-01','2016-04-30','month'))::NUMERIC, (SELECT COUNT(*) FILTER (WHERE weight>0) FROM v)),
   ('downvotes',    (SELECT downvotes      FROM haf_stats_endpoints.get_network_vote_stats('2016-04-01','2016-04-30','month'))::NUMERIC, (SELECT COUNT(*) FILTER (WHERE weight<0) FROM v)),
   ('unvotes',      (SELECT unvotes        FROM haf_stats_endpoints.get_network_vote_stats('2016-04-01','2016-04-30','month'))::NUMERIC, (SELECT COUNT(*) FILTER (WHERE weight=0) FROM v)),
   ('self_votes',   (SELECT self_votes     FROM haf_stats_endpoints.get_network_vote_stats('2016-04-01','2016-04-30','month'))::NUMERIC, (SELECT COUNT(*) FILTER (WHERE voter=author) FROM v)),
   ('unique_voters',(SELECT unique_voters  FROM haf_stats_endpoints.get_network_vote_stats('2016-04-01','2016-04-30','month'))::NUMERIC, (SELECT COUNT(DISTINCT voter) FROM v)),
   ('downvote_pct', (SELECT downvote_pct   FROM haf_stats_endpoints.get_network_vote_stats('2016-04-01','2016-04-30','month'))::NUMERIC,
                    (SELECT ROUND(COUNT(*) FILTER (WHERE weight<0)*100.0/NULLIF(COUNT(*) FILTER (WHERE weight<>0),0),2) FROM v))
) AS f(field, ev, iv);

-- 3) get_daily_active_users (2016-04 month, all) — independent via HAF core get_required_authorities
INSERT INTO _parity VALUES
('daily_active_users','active_accounts',
 (SELECT active_accounts FROM haf_stats_endpoints.get_daily_active_users('2016-04-01','2016-04-30','month','all')),
 (SELECT COUNT(DISTINCT ra.account_name)
    FROM hive.operations_view ov CROSS JOIN LATERAL hive.get_required_authorities(ov.body) ra
   WHERE ov.block_num BETWEEN 209769 AND 1052190
     AND ov.op_type_id IN (SELECT id FROM hafd.operation_types WHERE NOT is_virtual))),
('daily_active_users','operations',
 (SELECT operations FROM haf_stats_endpoints.get_daily_active_users('2016-04-01','2016-04-30','month','all')),
 (SELECT COUNT(DISTINCT ov.id)
    FROM hive.operations_view ov CROSS JOIN LATERAL hive.get_required_authorities(ov.body) ra
   WHERE ov.block_num BETWEEN 209769 AND 1052190
     AND ov.op_type_id IN (SELECT id FROM hafd.operation_types WHERE NOT is_virtual)));

-- 4) get_network_top_accounts transfer_volume_in (2016-04) — rank 1 (bittrex)
INSERT INTO _parity VALUES
('top_accounts.transfer_in_rank1','value_hive_nai',
 (SELECT value_hive_nai FROM haf_stats_endpoints.get_network_top_accounts('transfer_volume_in','2016-04-01','2016-04-30',5) WHERE rank=1),
 (SELECT SUM((body_value->'amount'->>'amount')::BIGINT) FROM hafd.operations o JOIN hafd.blocks b ON b.num=hafd.operation_id_to_block_num(o.id)
   WHERE o.op_type_id=2 AND body_value->>'to'='bittrex' AND body_value->'amount'->>'nai'='@@000000021'
     AND b.created_at>='2016-04-01' AND b.created_at<'2016-05-01')),
('top_accounts.transfer_in_rank1','op_count',
 (SELECT op_count FROM haf_stats_endpoints.get_network_top_accounts('transfer_volume_in','2016-04-01','2016-04-30',5) WHERE rank=1),
 (SELECT COUNT(*) FROM hafd.operations o JOIN hafd.blocks b ON b.num=hafd.operation_id_to_block_num(o.id)
   WHERE o.op_type_id=2 AND body_value->>'to'='bittrex' AND body_value->'amount'->>'nai'='@@000000021'
     AND b.created_at>='2016-04-01' AND b.created_at<'2016-05-01'));

-- 5) get_account_content_stats (tuck-fheman, 2016-04 month)
INSERT INTO _parity VALUES
('account_content_stats.tuck-fheman','posts',
 (SELECT posts    FROM haf_stats_endpoints.get_account_content_stats('tuck-fheman','2016-04-01','2016-04-30','month')),
 (SELECT COUNT(*) FROM _firsts WHERE author='tuck-fheman' AND parent_author='' AND day>='2016-04-01' AND day<'2016-05-01')),
('account_content_stats.tuck-fheman','comments',
 (SELECT comments FROM haf_stats_endpoints.get_account_content_stats('tuck-fheman','2016-04-01','2016-04-30','month')),
 (SELECT COUNT(*) FROM _firsts WHERE author='tuck-fheman' AND parent_author<>'' AND day>='2016-04-01' AND day<'2016-05-01')),
('account_content_stats.tuck-fheman','replies_received',
 (SELECT replies_received FROM haf_stats_endpoints.get_account_content_stats('tuck-fheman','2016-04-01','2016-04-30','month')),
 (SELECT COUNT(*) FROM _firsts WHERE parent_author='tuck-fheman' AND day>='2016-04-01' AND day<'2016-05-01')),
('account_content_stats.tuck-fheman','votes_cast',
 (SELECT votes_cast     FROM haf_stats_endpoints.get_account_content_stats('tuck-fheman','2016-04-01','2016-04-30','month')),
 (SELECT COUNT(*) FROM hafd.operations o JOIN hafd.blocks b ON b.num=hafd.operation_id_to_block_num(o.id)
   WHERE o.op_type_id=0 AND body_value->>'voter'='tuck-fheman' AND b.created_at>='2016-04-01' AND b.created_at<'2016-05-01')),
('account_content_stats.tuck-fheman','votes_received',
 (SELECT votes_received FROM haf_stats_endpoints.get_account_content_stats('tuck-fheman','2016-04-01','2016-04-30','month')),
 (SELECT COUNT(*) FROM hafd.operations o JOIN hafd.blocks b ON b.num=hafd.operation_id_to_block_num(o.id)
   WHERE o.op_type_id=0 AND body_value->>'author'='tuck-fheman' AND b.created_at>='2016-04-01' AND b.created_at<'2016-05-01'));

-- 6) get_account_financial_summary (bittrex, 2016-04 month) — transfer_operation incoming/outgoing
INSERT INTO _parity VALUES
('account_financial_summary.bittrex','incoming_hive_nai',
 (SELECT hive_nai FROM haf_stats_endpoints.get_account_financial_summary('bittrex','2016-04-01','2016-04-30','month') WHERE direction='incoming' AND category='transfer_operation'),
 (SELECT SUM((body_value->'amount'->>'amount')::BIGINT) FROM hafd.operations o JOIN hafd.blocks b ON b.num=hafd.operation_id_to_block_num(o.id)
   WHERE o.op_type_id=2 AND body_value->>'to'='bittrex' AND body_value->'amount'->>'nai'='@@000000021' AND b.created_at>='2016-04-01' AND b.created_at<'2016-05-01')),
('account_financial_summary.bittrex','outgoing_hive_nai',
 (SELECT hive_nai FROM haf_stats_endpoints.get_account_financial_summary('bittrex','2016-04-01','2016-04-30','month') WHERE direction='outgoing' AND category='transfer_operation'),
 (SELECT SUM((body_value->'amount'->>'amount')::BIGINT) FROM hafd.operations o JOIN hafd.blocks b ON b.num=hafd.operation_id_to_block_num(o.id)
   WHERE o.op_type_id=2 AND body_value->>'from'='bittrex' AND body_value->'amount'->>'nai'='@@000000021' AND b.created_at>='2016-04-01' AND b.created_at<'2016-05-01'));

-- 7) Expanded financial coverage. These checks exercise the multi-leg order
-- mapping, routed/re-vested power-down deposits, and liquidity rewards directly
-- from raw operation bodies.
WITH fill_order_independent AS (
    SELECT
        SUM(CASE WHEN leg.incoming ->> 'nai' = '@@000000021'
                 THEN (leg.incoming ->> 'amount')::BIGINT ELSE 0 END)::NUMERIC AS incoming_hive,
        SUM(CASE WHEN leg.incoming ->> 'nai' = '@@000000013'
                 THEN (leg.incoming ->> 'amount')::BIGINT ELSE 0 END)::NUMERIC AS incoming_hbd,
        SUM(CASE WHEN leg.outgoing ->> 'nai' = '@@000000021'
                 THEN (leg.outgoing ->> 'amount')::BIGINT ELSE 0 END)::NUMERIC AS outgoing_hive,
        SUM(CASE WHEN leg.outgoing ->> 'nai' = '@@000000013'
                 THEN (leg.outgoing ->> 'amount')::BIGINT ELSE 0 END)::NUMERIC AS outgoing_hbd,
        COUNT(*)::NUMERIC AS op_count
    FROM (
        SELECT
            o.body_value ->> 'current_owner' AS account,
            o.body_value -> 'open_pays' AS incoming,
            o.body_value -> 'current_pays' AS outgoing
        FROM hafd.operations o
        JOIN hafd.blocks b ON b.num = hafd.operation_id_to_block_num(o.id)
        WHERE o.op_type_id = 57
          AND b.created_at >= TIMESTAMP '2016-07-01'
          AND b.created_at < TIMESTAMP '2016-08-01'

        UNION ALL

        SELECT
            o.body_value ->> 'open_owner',
            o.body_value -> 'current_pays',
            o.body_value -> 'open_pays'
        FROM hafd.operations o
        JOIN hafd.blocks b ON b.num = hafd.operation_id_to_block_num(o.id)
        WHERE o.op_type_id = 57
          AND b.created_at >= TIMESTAMP '2016-07-01'
          AND b.created_at < TIMESTAMP '2016-08-01'
    ) leg
    WHERE leg.account = 'abit'
),
fill_order_endpoint AS (
    SELECT
        SUM(hive_nai) FILTER (WHERE direction = 'incoming')::NUMERIC AS incoming_hive,
        SUM(hbd_nai) FILTER (WHERE direction = 'incoming')::NUMERIC AS incoming_hbd,
        SUM(hive_nai) FILTER (WHERE direction = 'outgoing')::NUMERIC AS outgoing_hive,
        SUM(hbd_nai) FILTER (WHERE direction = 'outgoing')::NUMERIC AS outgoing_hbd,
        SUM(op_count) FILTER (WHERE direction = 'incoming')::NUMERIC AS incoming_ops,
        SUM(op_count) FILTER (WHERE direction = 'outgoing')::NUMERIC AS outgoing_ops
    FROM haf_stats_endpoints.get_account_financial_summary(
        'abit', '2016-07-01', '2016-07-31', 'month'
    )
    WHERE category = 'fill_order_operation'
)
INSERT INTO _parity
SELECT 'financial.fill_order.abit', field, endpoint_val, independent_val
FROM fill_order_endpoint e
CROSS JOIN fill_order_independent i
CROSS JOIN LATERAL (
    VALUES
        ('incoming_hive_nai', e.incoming_hive, i.incoming_hive),
        ('incoming_hbd_nai', e.incoming_hbd, i.incoming_hbd),
        ('outgoing_hive_nai', e.outgoing_hive, i.outgoing_hive),
        ('outgoing_hbd_nai', e.outgoing_hbd, i.outgoing_hbd),
        ('incoming_op_count', e.incoming_ops, i.op_count),
        ('outgoing_op_count', e.outgoing_ops, i.op_count)
) AS fields(field, endpoint_val, independent_val);

WITH vesting_withdraw_independent AS (
    SELECT
        SUM(CASE WHEN o.body_value -> 'deposited' ->> 'nai' = '@@000000021'
                 THEN (o.body_value -> 'deposited' ->> 'amount')::BIGINT ELSE 0 END)::NUMERIC AS hive,
        SUM(CASE WHEN o.body_value -> 'deposited' ->> 'nai' = '@@000000037'
                 THEN (o.body_value -> 'deposited' ->> 'amount')::BIGINT ELSE 0 END)::NUMERIC AS vests,
        COUNT(*)::NUMERIC AS ops
    FROM hafd.operations o
    JOIN hafd.blocks b ON b.num = hafd.operation_id_to_block_num(o.id)
    WHERE o.op_type_id = 56
      AND o.body_value ->> 'to_account' = 'pharesim'
      AND b.created_at >= TIMESTAMP '2016-03-01'
      AND b.created_at < TIMESTAMP '2016-10-01'
),
vesting_withdraw_endpoint AS (
    SELECT
        SUM(hive_nai)::NUMERIC AS hive,
        SUM(vests_nai)::NUMERIC AS vests,
        SUM(op_count)::NUMERIC AS ops
    FROM haf_stats_endpoints.get_account_financial_summary(
        'pharesim', '2016-03-01', '2016-09-30', 'month'
    )
    WHERE category = 'fill_vesting_withdraw_operation'
      AND direction = 'incoming'
)
INSERT INTO _parity
SELECT 'financial.fill_vesting_withdraw.pharesim', field, endpoint_val, independent_val
FROM vesting_withdraw_endpoint e
CROSS JOIN vesting_withdraw_independent i
CROSS JOIN LATERAL (
    VALUES
        ('hive_nai', e.hive, i.hive),
        ('vests_nai', e.vests, i.vests),
        ('op_count', e.ops, i.ops)
) AS fields(field, endpoint_val, independent_val);

WITH liquidity_independent AS (
    SELECT
        SUM((o.body_value -> 'payout' ->> 'amount')::BIGINT)::NUMERIC AS hive,
        COUNT(*)::NUMERIC AS ops
    FROM hafd.operations o
    JOIN hafd.blocks b ON b.num = hafd.operation_id_to_block_num(o.id)
    WHERE o.op_type_id = 54
      AND o.body_value ->> 'owner' = 'adm'
      AND b.created_at >= TIMESTAMP '2016-07-01'
      AND b.created_at < TIMESTAMP '2016-08-01'
),
liquidity_endpoint AS (
    SELECT
        SUM(hive_nai)::NUMERIC AS hive,
        SUM(op_count)::NUMERIC AS ops
    FROM haf_stats_endpoints.get_account_financial_summary(
        'adm', '2016-07-01', '2016-07-31', 'month'
    )
    WHERE category = 'liquidity_reward_operation'
      AND direction = 'incoming'
)
INSERT INTO _parity
SELECT 'financial.liquidity_reward.adm', field, endpoint_val, independent_val
FROM liquidity_endpoint e
CROSS JOIN liquidity_independent i
CROSS JOIN LATERAL (
    VALUES
        ('hive_nai', e.hive, i.hive),
        ('op_count', e.ops, i.ops)
) AS fields(field, endpoint_val, independent_val);

-- 8) get_network_engagement (April-created post cohort, lifetime engagement)
WITH april_posts AS MATERIALIZED (
    SELECT author, permlink
    FROM _firsts
    WHERE parent_author = ''
      AND day >= DATE '2016-04-01'
      AND day < DATE '2016-05-01'
),
vote_counts AS MATERIALIZED (
    SELECT o.body_value->>'author' AS author,
           o.body_value->>'permlink' AS permlink,
           COUNT(*)::NUMERIC AS cnt
    FROM hafd.operations o
    JOIN april_posts p
      ON p.author = o.body_value->>'author'
     AND p.permlink = o.body_value->>'permlink'
    WHERE o.op_type_id = 0
      AND (o.body_value->>'weight')::INT <> 0
    GROUP BY 1, 2
),
reply_counts AS MATERIALIZED (
    SELECT f.parent_author AS author,
           f.parent_permlink AS permlink,
           COUNT(*)::NUMERIC AS cnt
    FROM _firsts f
    JOIN april_posts p
      ON p.author = f.parent_author
     AND p.permlink = f.parent_permlink
    WHERE f.parent_author <> ''
    GROUP BY 1, 2
),
per_post AS (
    SELECT p.author, p.permlink,
           COALESCE(v.cnt, 0) AS vote_count,
           COALESCE(r.cnt, 0) AS reply_count
    FROM april_posts p
    LEFT JOIN vote_counts v USING (author, permlink)
    LEFT JOIN reply_counts r USING (author, permlink)
),
independent AS (
    SELECT COUNT(*)::NUMERIC AS total_posts,
           ROUND(AVG(vote_count), 2) AS avg_votes_per_post,
           ROUND(AVG(reply_count), 2) AS avg_comments_per_post,
           ROUND(COUNT(*) FILTER (WHERE vote_count = 0) * 100.0 / COUNT(*), 2)
               AS zero_vote_post_pct,
           ROUND(COUNT(*) FILTER (WHERE reply_count = 0) * 100.0 / COUNT(*), 2)
               AS zero_comment_post_pct
    FROM per_post
),
endpoint AS (
    SELECT *
    FROM haf_stats_endpoints.get_network_engagement(
        '2016-04-01', '2016-04-30', 'month'
    )
)
INSERT INTO _parity
SELECT 'network_engagement', field, endpoint_val, independent_val
FROM endpoint e CROSS JOIN independent i CROSS JOIN LATERAL (
    VALUES
        ('total_posts', e.total_posts::NUMERIC, i.total_posts),
        ('avg_votes_per_post', e.avg_votes_per_post, i.avg_votes_per_post),
        ('avg_comments_per_post', e.avg_comments_per_post, i.avg_comments_per_post),
        ('zero_vote_post_pct', e.zero_vote_post_pct, i.zero_vote_post_pct),
        ('zero_comment_post_pct', e.zero_comment_post_pct, i.zero_comment_post_pct)
) AS fields(field, endpoint_val, independent_val);

-- 9) get_network_account_funnel (2016-04 cohort). New accounts use
-- hafd.accounts.block_num, while D7/D30/D90 independently probe signed,
-- non-virtual activity in the exact [N,N+1 day) windows.
WITH members AS MATERIALIZED (
    SELECT a.id AS account_id, b.created_at
    FROM hafd.accounts a
    JOIN hafd.blocks b ON b.num = a.block_num
    WHERE b.created_at >= TIMESTAMP '2016-04-01'
      AND b.created_at < TIMESTAMP '2016-05-01'
),
-- Re-derive "authored a non-virtual op" (was a required signing authority) in a
-- single direct pass over the operation stream — the same definition the
-- endpoint's incremental processor uses, computed here independently. This is
-- authored activity: pow/pow2 mining is authorless and excluded. Bound the scan
-- to the block range spanning every D7..D91 window of the 2016-04 cohort
-- ([created+7d) earliest .. [created+91d) latest) so it is an operations PK
-- range scan, not a full-stream scan.
authored AS MATERIALIZED (
    SELECT ni.id AS account_id, b.created_at AS op_time
    FROM hive.operations_view ov
    JOIN hafd.blocks b ON b.num = ov.block_num
    CROSS JOIN LATERAL hive.get_required_authorities(ov.body) ra
    JOIN hive.accounts_view ni ON ni.name = ra.account_name
    WHERE ov.block_num >= (SELECT MIN(num) FROM hafd.blocks WHERE created_at >= TIMESTAMP '2016-04-08')
      AND ov.block_num <  (SELECT MIN(num) FROM hafd.blocks WHERE created_at >= TIMESTAMP '2016-08-01')
      AND ov.op_type_id IN (SELECT id FROM hafd.operation_types WHERE NOT is_virtual)
),
flags AS (
    SELECT m.account_id,
           BOOL_OR(au.op_time >= m.created_at + INTERVAL '7 days'
                   AND au.op_time < m.created_at + INTERVAL '8 days')  AS d7,
           BOOL_OR(au.op_time >= m.created_at + INTERVAL '30 days'
                   AND au.op_time < m.created_at + INTERVAL '31 days') AS d30,
           BOOL_OR(au.op_time >= m.created_at + INTERVAL '90 days'
                   AND au.op_time < m.created_at + INTERVAL '91 days') AS d90
    FROM members m
    LEFT JOIN authored au ON au.account_id = m.account_id
    GROUP BY m.account_id
),
independent AS (
    SELECT COUNT(*)::NUMERIC AS new_accounts,
           COUNT(*) FILTER (WHERE d7)::NUMERIC AS active_at_7d,
           COUNT(*) FILTER (WHERE d30)::NUMERIC AS active_at_30d,
           COUNT(*) FILTER (WHERE d90)::NUMERIC AS active_at_90d
    FROM flags
),
endpoint AS (
    SELECT *
    FROM haf_stats_endpoints.get_network_account_funnel(
        '2016-04-01', '2016-04-30'
    )
)
INSERT INTO _parity
SELECT 'account_funnel', field, endpoint_val, independent_val
FROM endpoint e CROSS JOIN independent i CROSS JOIN LATERAL (
    VALUES
        ('new_accounts', e.new_accounts::NUMERIC, i.new_accounts),
        ('active_at_7d', e.active_at_7d::NUMERIC, i.active_at_7d),
        ('active_at_30d', e.active_at_30d::NUMERIC, i.active_at_30d),
        ('active_at_90d', e.active_at_90d::NUMERIC, i.active_at_90d)
) AS fields(field, endpoint_val, independent_val);

\echo '== parity result =='
SELECT metric, field, endpoint_val, independent_val,
       CASE WHEN endpoint_val IS NOT DISTINCT FROM independent_val THEN 'OK' ELSE 'MISMATCH' END AS status
FROM _parity ORDER BY metric, field;

DO $$
DECLARE _n INT;
BEGIN
    SELECT COUNT(*) INTO _n FROM _parity WHERE endpoint_val IS DISTINCT FROM independent_val;
    IF _n > 0 THEN
        RAISE EXCEPTION 'PARITY FAILED: % field(s) where the endpoint value is NOT independently reproducible — an expected value may be miscalculated', _n;
    END IF;
    RAISE NOTICE 'PARITY OK: all % asserted fields independently reproduced from the raw operation stream', (SELECT COUNT(*) FROM _parity);
END $$;
