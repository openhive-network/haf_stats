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

-- ---------------------------------------------------------------------------
-- rc_op_stats_daily: calibrated RC rates (read-time model, issue #32)
--
-- Seed the custom_json rate from a live rc_api.get_rc_operation_stats sample so the
-- estimated-RC endpoints are calibrated from first install, before any auto-refresh runs:
--   avg_cost_rc 167,828,015 = history_rc 144,399,559 + non-history 23,428,456 over 304 bytes
--   base_rc = avg_cost_rc - history_rc = 23,428,456    (size-independent RC per op)
--   byte_rc = history_rc / history_bytes = 475,000     (RC per payload byte)
-- A 304-byte op then estimates 23,428,456 + 475,000*304 = 167.8M, matching rc_api. Seeded
-- for the current day; DO NOTHING so a refreshed same-day rate is never clobbered.
-- ---------------------------------------------------------------------------

INSERT INTO haf_stats_backend.rc_op_stats_daily
(day, op_type_id, base_rc, byte_rc, avg_cost_rc, avg_bytes, sample_count)
VALUES
(CURRENT_DATE, 18, 23428456, 475000, 167828015, 304, 260051)
ON CONFLICT (day, op_type_id) DO NOTHING;

RESET ROLE;
