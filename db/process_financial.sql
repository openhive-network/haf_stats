SET ROLE haf_stats_owner;

-- Feature: per-account financial summary (get_account_financial_summary endpoint).
-- Creates the aggregation table and the block processor that populates it.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

-- Legacy op-category registry: the processor below inlines all category/
-- direction logic and never reads this table, and it was seeded with the old
-- income/expense vocabulary. Drop it (haf_stats issue #26).
DROP TABLE IF EXISTS haf_stats_backend.op_financial_categories;

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

-- Migrate already-deployed tables created with the old income/expense CHECK:
-- CREATE TABLE IF NOT EXISTS is a no-op when the table exists, so the stale
-- constraint would otherwise reject the new incoming/outgoing inserts. NOT VALID
-- skips re-checking existing rows; the DELETE below removes them outright so the
-- constraint holds for everything that remains.
ALTER TABLE haf_stats_backend.account_financial_daily
DROP CONSTRAINT IF EXISTS account_financial_daily_direction_check;
ALTER TABLE haf_stats_backend.account_financial_daily
ADD CONSTRAINT account_financial_daily_direction_check
CHECK (direction IN ('incoming', 'outgoing')) NOT VALID;

-- Production resumes block processing immediately after install, and the new
-- canonical-keyed upserts never overwrite rows written under the old
-- income/expense + display-name vocabulary. Delete those stale rows here so the
-- endpoint can never serve a mix of both vocabularies. Idempotent: a no-op once
-- only canonical rows remain (and on fresh installs). Historical coverage is
-- restored by scripts/rebuild_financial.sh (forward processing only fills new
-- blocks).
DELETE FROM haf_stats_backend.account_financial_daily
WHERE direction NOT IN ('incoming', 'outgoing');

ALTER TABLE haf_stats_backend.account_financial_daily
VALIDATE CONSTRAINT account_financial_daily_direction_check;

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
-- Op-type ids are resolved once into locals from hafd.operation_types, whose
-- names are fully qualified with the 'hive::protocol::' prefix (same lookup
-- pattern as process_rc.sql / process_account_cohorts.sql).
--
-- DOUBLE COUNT (intentional): reward *accrual* (author_reward,
-- comment_benefactor_reward, curation_reward) and reward *claim*
-- (claim_reward_balance) are both 'incoming', so the same funds appear under the
-- accrual and the claim category. Consumers must not sum across both as a net
-- inflow.
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
DECLARE
    _author_reward_id              INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::author_reward_operation');
    _comment_benefactor_reward_id  INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::comment_benefactor_reward_operation');
    _curation_reward_id            INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::curation_reward_operation');
    _claim_reward_balance_id       INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::claim_reward_balance_operation');
    _interest_id                   INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::interest_operation');
    _transfer_id                   INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_operation');
    _transfer_to_savings_id        INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_to_savings_operation');
    _transfer_from_savings_id      INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_from_savings_operation');
    _fill_transfer_from_savings_id INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::fill_transfer_from_savings_operation');
    _transfer_to_vesting_id        INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_to_vesting_operation');
    _fill_vesting_withdraw_id      INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::fill_vesting_withdraw_operation');
    _producer_reward_id            INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_reward_operation');
    _liquidity_reward_id           INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::liquidity_reward_operation');
    _proposal_pay_id               INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::proposal_pay_operation');
    _fill_order_id                 INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::fill_order_operation');
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
    WHERE ov.op_type_id = _author_reward_id
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
    WHERE ov.op_type_id = _comment_benefactor_reward_id
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
    WHERE ov.op_type_id = _curation_reward_id
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
    WHERE ov.op_type_id = _claim_reward_balance_id
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
    WHERE ov.op_type_id = _interest_id
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
    WHERE ov.op_type_id = _transfer_id
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
    WHERE ov.op_type_id = _transfer_id
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
    WHERE ov.op_type_id = _transfer_to_savings_id
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
    WHERE ov.op_type_id = _transfer_from_savings_id
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
    WHERE ov.op_type_id = _fill_transfer_from_savings_id
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
    WHERE ov.op_type_id = _transfer_to_vesting_id
      AND ov.block_num BETWEEN _first_block AND _last_block

    UNION ALL

    -- 12. Power down (fill_vesting_withdraw): incoming for the deposit recipient.
    -- `deposited` is credited to to_account (usually == from_account, but a
    -- withdrawal route can send it elsewhere) and may be HIVE (normal power-down)
    -- or VESTS (route that re-vests). `withdrawn` is the from_account's own VESTS
    -- leaving its vesting balance, not a value inflow, so it is not recorded here.
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_vesting_withdraw_operation',
        'incoming',
        CASE WHEN (ov.body -> 'value' -> 'deposited' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body -> 'value' -> 'deposited' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        CASE WHEN (ov.body -> 'value' -> 'deposited' ->> 'nai') = '@@000000037'
             THEN COALESCE((ov.body -> 'value' -> 'deposited' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        1
    FROM hive.operations_view ov
    JOIN hafd.blocks bv ON bv.num = ov.block_num
    JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'to_account')
    WHERE ov.op_type_id = _fill_vesting_withdraw_id
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
    WHERE ov.op_type_id = _producer_reward_id
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
    WHERE ov.op_type_id = _liquidity_reward_id
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
    WHERE ov.op_type_id = _proposal_pay_id
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
    WHERE ov.op_type_id = _fill_order_id
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
    WHERE ov.op_type_id = _fill_order_id
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
    WHERE ov.op_type_id = _fill_order_id
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
    WHERE ov.op_type_id = _fill_order_id
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
