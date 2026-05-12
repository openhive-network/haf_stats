-- Feature: per-account financial summary (get_account_financial_summary endpoint).
-- Creates the aggregation table and the block processor that populates it.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_financial_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    category TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('income', 'expense')),
    hive_nai BIGINT NOT NULL DEFAULT 0,
    hbd_nai BIGINT NOT NULL DEFAULT 0,
    vests_nai BIGINT NOT NULL DEFAULT 0,
    op_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, category, direction)
);

CREATE INDEX IF NOT EXISTS idx_afd_account_day
ON haf_stats_backend.account_financial_daily (account_id, day DESC);

GRANT SELECT ON haf_stats_backend.account_financial_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.process_financial(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN

-- Author rewards: income for the post author.
-- Amounts: hive_payout (HIVE), hbd_payout (HBD), vesting_payout (VESTS).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'Author Reward',
    'income',
    COALESCE((ov.body -> 'value' -> 'hive_payout'    ->> 'amount')::BIGINT, 0),
    COALESCE((ov.body -> 'value' -> 'hbd_payout'     ->> 'amount')::BIGINT, 0),
    COALESCE((ov.body -> 'value' -> 'vesting_payout' ->> 'amount')::BIGINT, 0),
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'author')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'author_reward_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai  = account_financial_daily.hive_nai  + EXCLUDED.hive_nai,
    hbd_nai   = account_financial_daily.hbd_nai   + EXCLUDED.hbd_nai,
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

-- Curation rewards: income for the curator (VESTS only).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'Curation Reward',
    'income',
    0,
    0,
    COALESCE((ov.body -> 'value' -> 'reward' ->> 'amount')::BIGINT, 0),
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'curator')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'curation_reward_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

-- HBD savings interest: income for the account owner (HBD only).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'HBD Interest',
    'income',
    0,
    COALESCE((ov.body -> 'value' -> 'interest' ->> 'amount')::BIGINT, 0),
    0,
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'owner')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'interest_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hbd_nai  = account_financial_daily.hbd_nai + EXCLUDED.hbd_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

-- Transfers: expense for the sender.
-- NAI @@000000021 = HIVE, @@000000013 = HBD.
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'Transfer',
    'expense',
    CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000021'
         THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0)
         ELSE 0 END,
    CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000013'
         THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0)
         ELSE 0 END,
    0,
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'from')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'transfer_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai = account_financial_daily.hive_nai + EXCLUDED.hive_nai,
    hbd_nai  = account_financial_daily.hbd_nai  + EXCLUDED.hbd_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

-- Transfers: income for the receiver.
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'Transfer',
    'income',
    CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000021'
         THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0)
         ELSE 0 END,
    CASE WHEN (ov.body -> 'value' -> 'amount' ->> 'nai') = '@@000000013'
         THEN COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0)
         ELSE 0 END,
    0,
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'to')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'transfer_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai = account_financial_daily.hive_nai + EXCLUDED.hive_nai,
    hbd_nai  = account_financial_daily.hbd_nai  + EXCLUDED.hbd_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

-- Power Up (transfer_to_vesting): expense for the initiating account (HIVE spent).
-- "from" is the sender; "to" is the beneficiary (often the same account).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'Power Up',
    'expense',
    COALESCE((ov.body -> 'value' -> 'amount' ->> 'amount')::BIGINT, 0),
    0,
    0,
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'from')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'transfer_to_vesting_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai = account_financial_daily.hive_nai + EXCLUDED.hive_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

-- Power Down (fill_vesting_withdraw): income for the withdrawing account.
-- withdrawn = VESTS consumed, deposited = HIVE received.
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'Power Down',
    'income',
    COALESCE((ov.body -> 'value' -> 'deposited'  ->> 'amount')::BIGINT, 0),
    0,
    COALESCE((ov.body -> 'value' -> 'withdrawn'  ->> 'amount')::BIGINT, 0),
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'from_account')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'fill_vesting_withdraw_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai  = account_financial_daily.hive_nai  + EXCLUDED.hive_nai,
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

-- Witness Pay (producer_reward_operation): income for the block producer (VESTS only).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'Witness Pay',
    'income',
    0,
    0,
    COALESCE((ov.body -> 'value' -> 'vesting_shares' ->> 'amount')::BIGINT, 0),
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'producer')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'producer_reward_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

-- Proposal Pay (proposal_pay_operation): income for DHF proposal receiver (HBD only).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    ov.timestamp::DATE,
    'Proposal Pay',
    'income',
    0,
    COALESCE((ov.body -> 'value' -> 'payment' ->> 'amount')::BIGINT, 0),
    0,
    1
FROM hive.operations_view ov
JOIN hafd.accounts a ON a.name = (ov.body -> 'value' ->> 'receiver')
WHERE ov.op_type_id = (SELECT id FROM hive.operation_types WHERE name = 'proposal_pay_operation' LIMIT 1)
  AND ov.block_num BETWEEN _first_block AND _last_block
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hbd_nai  = account_financial_daily.hbd_nai  + EXCLUDED.hbd_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

END;
$$;
