SET ROLE haf_stats_owner;

-- Feature: per-account financial summary (get_account_financial_summary endpoint).
-- Creates the aggregation table and the block processor that populates it.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.op_financial_categories (
    op_type_name TEXT NOT NULL PRIMARY KEY,
    direction TEXT NOT NULL CHECK (direction IN ('income', 'expense', 'neutral')),
    category TEXT NOT NULL,
    asset TEXT NOT NULL
);

GRANT SELECT ON haf_stats_backend.op_financial_categories TO haf_stats_user;

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_financial_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    category TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('incoming', 'outgoing')),
    hive_nai BIGINT NOT NULL DEFAULT 0,
    hbd_nai BIGINT NOT NULL DEFAULT 0,
    vests_nai BIGINT NOT NULL DEFAULT 0,
    op_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, category, direction)
);

CREATE INDEX IF NOT EXISTS idx_afd_account_day
ON haf_stats_backend.account_financial_daily (account_id, day DESC);

-- Leaderboard access path (get_network_top_accounts): a category + direction +
-- day-range scan across ALL accounts, which the account_id-leading PK cannot
-- serve. Columns are a subset of the PK, so this index adds no new HOT-blocking
-- attributes to the additive nai/op_count upserts.
CREATE INDEX IF NOT EXISTS idx_afd_category_direction_day
ON haf_stats_backend.account_financial_daily (category, direction, day);

GRANT SELECT ON haf_stats_backend.account_financial_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- Single pass: one INSERT … SELECT over a UNION ALL of per-operation "legs".
-- Each leg emits one row per source operation in the normalized shape
-- (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, 1),
-- with 0 in the amount columns it doesn't touch. The outer GROUP BY does all
-- aggregation, collapsing every same-key row before the INSERT — so a single
-- uniform ON CONFLICT can sum the three amount columns, and the
-- "ON CONFLICT DO UPDATE cannot affect row a second time" error (which fires
-- when two source rows target the same conflict key) cannot occur.
--
-- category = canonical Hive operation type name; direction = incoming/outgoing
-- (aligns with the block explorer's ops vocabulary, haf_stats issue #26).
-- Op-type ids resolve via hive.get_op_type_id('<short_name>'), which handles
-- the 'hive::protocol::' prefix internally.
--
-- Asset NAI: HIVE = @@000000021, HBD = @@000000013 (split where an `amount`
-- field can be either). transfer and fill_order are multi-leg (sender/receiver,
-- maker/taker).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_financial(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN

INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    account_id,
    day,
    category,
    direction,
    SUM(hive_nai)::BIGINT,
    SUM(hbd_nai)::BIGINT,
    SUM(vests_nai)::BIGINT,
    SUM(op_count)::INT
FROM (

    -- 1. Author rewards: incoming for the post author.
    SELECT
        a.id AS account_id,
        bv.created_at::DATE AS day,
        'author_reward_operation' AS category,
        'incoming' AS direction,
        COALESCE((ov.body -> 'value' -> 'hive_payout'    ->> 'amount')::BIGINT, 0) AS hive_nai,
        COALESCE((ov.body -> 'value' -> 'hbd_payout'     ->> 'amount')::BIGINT, 0) AS hbd_nai,
        COALESCE((ov.body -> 'value' -> 'vesting_payout' ->> 'amount')::BIGINT, 0) AS vests_nai,
        1 AS op_count
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'author')
    WHERE ov.op_type_id = hive.get_op_type_id('author_reward_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 2. Comment benefactor rewards: incoming for the benefactor.
    SELECT
        a.id,
        bv.created_at::DATE,
        'comment_benefactor_reward_operation',
        'incoming',
        COALESCE((ov.body -> 'value' -> 'hive_payout'    ->> 'amount')::BIGINT, 0),
        COALESCE((ov.body -> 'value' -> 'hbd_payout'     ->> 'amount')::BIGINT, 0),
        COALESCE((ov.body -> 'value' -> 'vesting_payout' ->> 'amount')::BIGINT, 0),
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'benefactor')
    WHERE ov.op_type_id = hive.get_op_type_id('comment_benefactor_reward_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 3. Curation rewards: incoming for the curator (VESTS only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'curation_reward_operation',
        'incoming',
        0::BIGINT,
        0::BIGINT,
        COALESCE((ov.body -> 'value' -> 'reward' ->> 'amount')::BIGINT, 0),
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'curator')
    WHERE ov.op_type_id = hive.get_op_type_id('curation_reward_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 4. Claim reward balance: incoming for the claiming account.
    SELECT
        a.id,
        bv.created_at::DATE,
        'claim_reward_balance_operation',
        'incoming',
        COALESCE((ov.body -> 'value' -> 'reward_hive'  ->> 'amount')::BIGINT, 0),
        COALESCE((ov.body -> 'value' -> 'reward_hbd'   ->> 'amount')::BIGINT, 0),
        COALESCE((ov.body -> 'value' -> 'reward_vests' ->> 'amount')::BIGINT, 0),
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'account')
    WHERE ov.op_type_id = hive.get_op_type_id('claim_reward_balance_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 5. HBD savings interest: incoming for the account owner (HBD only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'interest_operation',
        'incoming',
        0::BIGINT,
        COALESCE((ov.body -> 'value' -> 'interest' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'owner')
    WHERE ov.op_type_id = hive.get_op_type_id('interest_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 6. Transfers: outgoing for the sender.
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_operation',
        'outgoing',
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'from')
    WHERE ov.op_type_id = hive.get_op_type_id('transfer_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 7. Transfers: incoming for the receiver.
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_operation',
        'incoming',
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'to')
    WHERE ov.op_type_id = hive.get_op_type_id('transfer_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 8. Transfer to savings: outgoing for the sender.
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_to_savings_operation',
        'outgoing',
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'from')
    WHERE ov.op_type_id = hive.get_op_type_id('transfer_to_savings_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 9. Transfer from savings (the request): outgoing for the sender.
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_from_savings_operation',
        'outgoing',
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'from')
    WHERE ov.op_type_id = hive.get_op_type_id('transfer_from_savings_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 10. Fill transfer from savings: incoming for the receiver.
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_transfer_from_savings_operation',
        'incoming',
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'to')
    WHERE ov.op_type_id = hive.get_op_type_id('fill_transfer_from_savings_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 11. Power up (transfer_to_vesting): outgoing for the initiator (HIVE spent).
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_to_vesting_operation',
        'outgoing',
        COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'from')
    WHERE ov.op_type_id = hive.get_op_type_id('transfer_to_vesting_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 12. Power down (fill_vesting_withdraw): incoming for the withdrawing account.
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_vesting_withdraw_operation',
        'incoming',
        COALESCE((ov.body -> 'value' -> 'deposited' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        COALESCE((ov.body -> 'value' -> 'withdrawn' ->> 'amount')::BIGINT, 0),
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'from_account')
    WHERE ov.op_type_id = hive.get_op_type_id('fill_vesting_withdraw_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 13. Witness pay (producer_reward): incoming for the block producer (VESTS only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'producer_reward_operation',
        'incoming',
        0::BIGINT,
        0::BIGINT,
        COALESCE((ov.body -> 'value' -> 'vesting_shares' ->> 'amount')::BIGINT, 0),
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'producer')
    WHERE ov.op_type_id = hive.get_op_type_id('producer_reward_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 14. Liquidity reward: incoming for the owner (HIVE only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'liquidity_reward_operation',
        'incoming',
        COALESCE((ov.body -> 'value' -> 'payout' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'owner')
    WHERE ov.op_type_id = hive.get_op_type_id('liquidity_reward_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 15. Proposal pay (DHF): incoming for the proposal receiver (HBD only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'proposal_pay_operation',
        'incoming',
        0::BIGINT,
        COALESCE((ov.body -> 'value' -> 'payment' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'receiver')
    WHERE ov.op_type_id = hive.get_op_type_id('proposal_pay_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 16. Fill order: outgoing for current_owner (what they paid).
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_order_operation',
        'outgoing',
        CASE WHEN (ov.body -> 'value' -> 'current_pays' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'current_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'current_pays' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'current_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'current_owner')
    WHERE ov.op_type_id = hive.get_op_type_id('fill_order_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 17. Fill order: incoming for current_owner (what they received).
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_order_operation',
        'incoming',
        CASE WHEN (ov.body -> 'value' -> 'open_pays' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'open_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'open_pays' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'open_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'current_owner')
    WHERE ov.op_type_id = hive.get_op_type_id('fill_order_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 18. Fill order: outgoing for open_owner (what they paid).
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_order_operation',
        'outgoing',
        CASE WHEN (ov.body -> 'value' -> 'open_pays' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'open_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'open_pays' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'open_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'open_owner')
    WHERE ov.op_type_id = hive.get_op_type_id('fill_order_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 19. Fill order: incoming for open_owner (what they received).
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_order_operation',
        'incoming',
        CASE WHEN (ov.body -> 'value' -> 'current_pays' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'current_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body -> 'value' -> 'current_pays' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body -> 'value' -> 'current_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'open_owner')
    WHERE ov.op_type_id = hive.get_op_type_id('fill_order_operation')
      AND ov.block_num BETWEEN _first_block AND _last_block

) impacts
GROUP BY account_id, day, category, direction
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai  = account_financial_daily.hive_nai  + EXCLUDED.hive_nai,
    hbd_nai   = account_financial_daily.hbd_nai   + EXCLUDED.hbd_nai,
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

END;
$$;

RESET ROLE;
