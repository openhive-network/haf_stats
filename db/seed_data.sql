SET ROLE haf_stats_owner;

-- Seed data: DApp registry.
-- Re-running this file is safe: the registry upserts (ON CONFLICT DO UPDATE) so the
-- table is reconciled to this file on every install (category/app-name edits take effect),
-- while the rate seed stays add-only (DO NOTHING) so a refreshed rate is never clobbered.

-- ---------------------------------------------------------------------------
-- custom_json_app_registry
--
-- A custom_json id is attributed to a DApp by a longest-prefix starts_with match
-- against app_id_pattern (see get_account_dapp_footprint / get_account_rc_footprint);
-- an id matching no pattern falls back to the 'Uncategorized' category with its raw
-- id as the app name. Categories follow the 9-category system (8 assigned + the
-- Uncategorized fallback) shared with the block_explorer_ui RC Footprint dashboard:
--   Social Graph, Social Front-Ends, Gaming, DeFi & Tokens, NFTs, Media & Content,
--   Community & Social DApps, Governance & Infrastructure  (+ Uncategorized).
-- ---------------------------------------------------------------------------

INSERT INTO haf_stats_backend.custom_json_app_registry
(app_id_pattern, app_name, category, homepage)
VALUES
-- Social Graph (core, protocol-level social actions)
('follow', 'Hivemind Follow', 'Social Graph', 'https://hive.blog'),
('reblog', 'Hivemind Reblog', 'Social Graph', 'https://hive.blog'),
('community', 'Hivemind Communities', 'Social Graph', 'https://hive.blog'),
-- Social Front-Ends (platform-specific actions from social interfaces)
('notify', 'Hivemind Notify', 'Social Front-Ends', 'https://hive.blog'),
('peakd', 'PeakD', 'Social Front-Ends', 'https://peakd.com'),
('ecency', 'Ecency', 'Social Front-Ends', 'https://ecency.com'),
('liketu', 'Liketu', 'Social Front-Ends', 'https://liketu.com'),
('dapplr', 'Dapplr', 'Social Front-Ends', NULL),
('inleo', 'InLeo', 'Social Front-Ends', 'https://inleo.io'),
('threads', 'InLeo Threads', 'Social Front-Ends', 'https://inleo.io'),
-- Gaming (Hive-based games and their token/asset ecosystems)
('sm_', 'Splinterlands', 'Gaming', 'https://splinterlands.com'),
('splinterlands', 'Splinterlands', 'Gaming', 'https://splinterlands.com'),
('risingstar', 'Rising Star', 'Gaming', 'https://www.risingstargame.com'),
('dcity', 'dCity', 'Gaming', 'https://dcity.io'),
('rabona', 'Rabona', 'Gaming', 'https://rabona.io'),
('dcrops', 'dCrops', 'Gaming', 'https://www.dcrops.com'),
('terracore', 'TerraCore', 'Gaming', 'https://terracore.io'),
('hashkings', 'HashKings', 'Gaming', 'https://www.hashkings.app'),
('psyberx', 'PsyberX', 'Gaming', 'https://psyberx.io'),
('cryptoshots', 'Crypto Shots', 'Gaming', NULL),
('ragnarok', 'Ragnarok', 'Gaming', 'https://ragnarok.game'),
('holybread', 'Holybread', 'Gaming', NULL),
('holozing', 'Holozing', 'Gaming', 'https://holozing.com'),
('exode', 'Exode', 'Gaming', 'https://exodegame.com'),
-- DeFi & Tokens (Hive Engine, tribe tokens, leasing, liquidity, bridges)
('ssc-', 'Hive Engine (SSC)', 'DeFi & Tokens', 'https://hive-engine.com'),
('hive-engine', 'Hive Engine', 'DeFi & Tokens', 'https://hive-engine.com'),
('he_', 'Hive Engine', 'DeFi & Tokens', 'https://hive-engine.com'),
('scot_', 'Hive Engine (SCOT)', 'DeFi & Tokens', 'https://hive-engine.com'),
('leodex', 'LeoDex', 'DeFi & Tokens', 'https://leodex.io'),
('dlease', 'dLease', 'DeFi & Tokens', 'https://dlease.io'),
('beeswap', 'BeeSwap', 'DeFi & Tokens', NULL),
('tribaldex', 'TribalDex', 'DeFi & Tokens', 'https://tribaldex.com'),
('archon', 'Archon', 'DeFi & Tokens', NULL),
('hbdstabilizer', 'HBD Stabilizer', 'DeFi & Tokens', NULL),
('cinetv', 'CineTV', 'DeFi & Tokens', NULL),
('pimp', 'PIMP', 'DeFi & Tokens', NULL),
('neoxag', 'NeoxAG', 'DeFi & Tokens', NULL),
('waiv', 'WAIV', 'DeFi & Tokens', NULL),
('hivedex', 'HiveDex', 'DeFi & Tokens', NULL),
('swap', 'Hive Swap', 'DeFi & Tokens', NULL),
-- NFTs (marketplaces, minting, VR/AR assets)
('nftshowroom', 'NFT Showroom', 'NFTs', 'https://nftshowroom.com'),
('nftmart', 'NFTMart', 'NFTs', NULL),
('nftt', 'NFT Tunz', 'NFTs', NULL),
('nft', 'NFT (generic)', 'NFTs', NULL),
('dlux', 'DLUX', 'NFTs', 'https://dlux.io'),
-- Media & Content (video, microblogging, blogging front-ends)
('3speak', '3Speak', 'Media & Content', 'https://3speak.tv'),
('dbuzz', 'D.Buzz', 'Media & Content', 'https://d.buzz'),
('engrave', 'Engrave', 'Media & Content', NULL),
-- Community & Social DApps (curation services, community tools)
('curangel', 'Curangel', 'Community & Social DApps', 'https://curangel.io'),
('posh', 'POSH', 'Community & Social DApps', NULL),
('actifit', 'Actifit', 'Community & Social DApps', 'https://actifit.io'),
('ocd', 'OCD', 'Community & Social DApps', NULL),
('travelfeed', 'TravelFeed', 'Community & Social DApps', 'https://travelfeed.io'),
('hivetasks', 'HiveTasks', 'Community & Social DApps', NULL),
-- Governance & Infrastructure (resource management, dev tools, core protocols)
('rc', 'RC Delegations', 'Governance & Infrastructure', 'https://hive.blog'),
('spk', 'SPK Network', 'Governance & Infrastructure', 'https://spk.network'),
('hive-keychain', 'Hive Keychain', 'Governance & Infrastructure', 'https://hive-keychain.com'),
('keychain', 'Hive Keychain', 'Governance & Infrastructure', 'https://hive-keychain.com'),
('hiveonboard', 'HiveOnboard', 'Governance & Infrastructure', 'https://hiveonboard.com'),
('vsc', 'VSC Network', 'Governance & Infrastructure', 'https://vsc.network'),
('podping', 'Podping', 'Governance & Infrastructure', 'https://podping.org'),
('inji', 'Inji', 'Governance & Infrastructure', NULL),
('dao_post', 'DHF Governance', 'Governance & Infrastructure', NULL)
ON CONFLICT (app_id_pattern) DO UPDATE SET
app_name = excluded.app_name,
category = excluded.category,
homepage = excluded.homepage;

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
