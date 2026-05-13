-- Seed data: DApp registry and financial operation category map.
-- Re-running this file is safe (INSERT ... ON CONFLICT DO NOTHING).

-- ---------------------------------------------------------------------------
-- custom_json_app_registry
-- ---------------------------------------------------------------------------

INSERT INTO haf_stats_backend.custom_json_app_registry
(app_id_pattern, app_name, category, homepage)
VALUES
-- Social Graph
('follow', 'Hivemind Follow', 'Social Graph', 'https://hive.blog'),
('reblog', 'Hivemind Reblog', 'Social Graph', 'https://hive.blog'),
('community', 'Hivemind Communities', 'Social Graph', 'https://hive.blog'),
('notify', 'Hivemind Notify', 'Social Graph', 'https://hive.blog'),
('peakd', 'PeakD', 'Social Graph', 'https://peakd.com'),
('ecency', 'Ecency', 'Social Graph', 'https://ecency.com'),
('inleo', 'InLeo', 'Social Graph', 'https://inleo.io'),
('threads', 'InLeo Threads', 'Social Graph', 'https://inleo.io'),
-- Gaming
('sm_', 'Splinterlands', 'Gaming', 'https://splinterlands.com'),
('splinterlands', 'Splinterlands', 'Gaming', 'https://splinterlands.com'),
('holozing', 'Holozing', 'Gaming', 'https://holozing.com'),
('dcity', 'dCity', 'Gaming', 'https://dcity.io'),
('exode', 'Exode', 'Gaming', 'https://exodegame.com'),
('dlux', 'DLUX', 'Gaming', 'https://dlux.io'),
-- DeFi / Finance
('he_', 'Hive Engine', 'DeFi', 'https://hive-engine.com'),
('ssc-', 'Hive Engine (SSC)', 'DeFi', 'https://hive-engine.com'),
('hivedex', 'HiveDex', 'DeFi', NULL),
('swap', 'Hive Swap', 'DeFi', NULL),
-- Governance
('dao_post', 'DHF Governance', 'Governance', NULL)
ON CONFLICT (app_id_pattern) DO NOTHING;

-- ---------------------------------------------------------------------------
-- op_financial_categories
-- ---------------------------------------------------------------------------

INSERT INTO haf_stats_backend.op_financial_categories
(op_type_name, direction, category, asset)
VALUES
-- Income
('author_reward_operation', 'income', 'author_rewards', 'MIXED'),
('comment_reward_operation', 'income', 'author_rewards', 'MIXED'),
('comment_benefactor_reward_operation', 'income', 'author_rewards', 'MIXED'),
('curation_reward_operation', 'income', 'curation_rewards', 'VESTS'),
('producer_reward_operation', 'income', 'witness_rewards', 'VESTS'),
('interest_operation', 'income', 'hbd_interest', 'HBD'),
('fill_convert_request_operation', 'income', 'conversions', 'HIVE'),
('fill_collateralized_convert_request_operation', 'income', 'conversions', 'HIVE'),
('claim_reward_balance_operation', 'income', 'claimed_rewards', 'MIXED'),
('fill_vesting_withdraw_operation', 'income', 'power_downs', 'MIXED'),
('fill_transfer_from_savings_operation', 'income', 'savings', 'MIXED'),
-- Expense / outflow
('transfer_operation', 'expense', 'transfers', 'MIXED'),
('transfer_to_savings_operation', 'expense', 'savings', 'MIXED'),
('transfer_to_vesting_operation', 'expense', 'power_ups', 'HIVE'),
('withdraw_vesting_operation', 'neutral', 'power_downs', 'VESTS'),
('delegate_vesting_shares_operation', 'neutral', 'delegations', 'VESTS'),
('delegate_rc_operation', 'neutral', 'rc_delegations', 'MIXED'),
-- Governance
('account_witness_vote_operation', 'neutral', 'governance', 'MIXED'),
('update_proposal_votes_operation', 'neutral', 'governance', 'MIXED'),
('account_witness_proxy_operation', 'neutral', 'governance', 'MIXED'),
-- Custom JSON
('custom_json_operation', 'neutral', 'app_activity', 'MIXED')
ON CONFLICT (op_type_name) DO NOTHING;
