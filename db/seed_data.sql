SET ROLE haf_stats_owner;

-- Seed data: DApp registry.
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

RESET ROLE;
