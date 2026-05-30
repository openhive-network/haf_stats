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
-- Each INSERT pre-aggregates with GROUP BY so that a single account can
-- have multiple operations of the same type on the same day within one batch
-- without hitting the "ON CONFLICT DO UPDATE cannot affect row a second time"
-- error (which fires when two source rows target the same conflict key).
--
-- Uses hafd.operations + hafd.blocks directly (not hive.*_view) because the
-- UNION-based views produce catastrophically bad query plans against the
-- 6B-row operations table, causing multi-minute runtimes for small block ranges.
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
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    bv.created_at::DATE,
    'Author Reward',
    'income',
    SUM(COALESCE((ov.body_value -> 'hive_payout'    ->> 'amount')::BIGINT, 0)),
    SUM(COALESCE((ov.body_value -> 'hbd_payout'     ->> 'amount')::BIGINT, 0)),
    SUM(COALESCE((ov.body_value -> 'vesting_payout' ->> 'amount')::BIGINT, 0)),
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'author')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::author_reward_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
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
    bv.created_at::DATE,
    'Curation Reward',
    'income',
    0,
    0,
    SUM(COALESCE((ov.body_value -> 'reward' ->> 'amount')::BIGINT, 0)),
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'curator')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::curation_reward_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

-- HBD savings interest: income for the account owner (HBD only).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    bv.created_at::DATE,
    'HBD Interest',
    'income',
    0,
    SUM(COALESCE((ov.body_value -> 'interest' ->> 'amount')::BIGINT, 0)),
    0,
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'owner')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::interest_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hbd_nai  = account_financial_daily.hbd_nai + EXCLUDED.hbd_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

-- Transfers: expense for the sender.
-- NAI @@000000021 = HIVE, @@000000013 = HBD.
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    bv.created_at::DATE,
    'Transfer',
    'expense',
    SUM(CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0)
             ELSE 0 END),
    SUM(CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0)
             ELSE 0 END),
    0,
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'from')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai = account_financial_daily.hive_nai + EXCLUDED.hive_nai,
    hbd_nai  = account_financial_daily.hbd_nai  + EXCLUDED.hbd_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

-- Transfers: income for the receiver.
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    bv.created_at::DATE,
    'Transfer',
    'income',
    SUM(CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0)
             ELSE 0 END),
    SUM(CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0)
             ELSE 0 END),
    0,
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'to')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai = account_financial_daily.hive_nai + EXCLUDED.hive_nai,
    hbd_nai  = account_financial_daily.hbd_nai  + EXCLUDED.hbd_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

-- Power Up (transfer_to_vesting): expense for the initiating account (HIVE spent).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    bv.created_at::DATE,
    'Power Up',
    'expense',
    SUM(COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0)),
    0,
    0,
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'from')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_to_vesting_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai = account_financial_daily.hive_nai + EXCLUDED.hive_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

-- Power Down (fill_vesting_withdraw): income for the withdrawing account.
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    bv.created_at::DATE,
    'Power Down',
    'income',
    SUM(COALESCE((ov.body_value -> 'deposited' ->> 'amount')::BIGINT, 0)),
    0,
    SUM(COALESCE((ov.body_value -> 'withdrawn' ->> 'amount')::BIGINT, 0)),
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'from_account')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::fill_vesting_withdraw_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai  = account_financial_daily.hive_nai  + EXCLUDED.hive_nai,
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

-- Witness Pay (producer_reward_operation): income for the block producer (VESTS only).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    bv.created_at::DATE,
    'Witness Pay',
    'income',
    0,
    0,
    SUM(COALESCE((ov.body_value -> 'vesting_shares' ->> 'amount')::BIGINT, 0)),
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'producer')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_reward_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

-- Proposal Pay (proposal_pay_operation): income for DHF proposal receiver (HBD only).
INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    a.id,
    bv.created_at::DATE,
    'Proposal Pay',
    'income',
    0,
    SUM(COALESCE((ov.body_value -> 'payment' ->> 'amount')::BIGINT, 0)),
    0,
    COUNT(*)
FROM hafd.operations ov
JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'receiver')
WHERE ov.op_type_id = (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::proposal_pay_operation' LIMIT 1)
  AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block
GROUP BY a.id, bv.created_at::DATE
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hbd_nai  = account_financial_daily.hbd_nai  + EXCLUDED.hbd_nai,
    op_count = account_financial_daily.op_count + EXCLUDED.op_count;

END;
$$;

RESET ROLE;
