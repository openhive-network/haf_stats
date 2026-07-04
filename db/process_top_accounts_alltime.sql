SET ROLE haf_stats_owner;

-- Feature: all-time per-account aggregates for get_network_top_accounts' no-filter leaderboard
-- (#38, follow-up to #35).
--
-- get_network_top_accounts serves a bounded [from,to] window from the daily/monthly hybrid (#37).
-- The "No Filter / all history" case (from = genesis, to = today) instead has to sum EVERY account
-- across all ~125 months on every request: for transaction_count that is a seq scan of the whole
-- active_users_account_monthly rollup (~18.4M rows / 1.8GB) hash-aggregated into ~2M accounts
-- (~11s), and the reward/transfer metrics do the same over account_financial_monthly (~2-5s). Too
-- slow to be a no-param default without risking the gateway timeout.
--
-- These two tables collapse the monthly rollups to ONE row per account (per category/direction for
-- financials), so the all-history leaderboard becomes a top-N over a compact table instead of a
-- genesis->now re-aggregation. They are CURRENT-STATE snapshots (no time dimension), derived
-- entirely from the fork-safe *_monthly rollups, so they are fork-safe and live OFF both the
-- request path and the per-block processor. The endpoint reads them only when the requested window
-- is the whole history up to now; every bounded range keeps the exact hybrid.
--
-- Scheduling is a deploy step (pg_cron, like the governance / hp-distribution snapshots). The
-- all-time leaderboard moves slowly, so a daily refresh is plenty (result is as-of the last
-- refresh, same contract as hp_balance / hp_distribution). Run once as haf_stats_owner:
--   SELECT cron.schedule('haf_stats_top_accounts_alltime', '30 3 * * *',
--       $cron$ SELECT haf_stats_app.refresh_top_accounts_alltime() $cron$);
-- install_app.sh also calls it once at install so the endpoint is populated on an already-synced
-- node.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- All-time op count per account (op_class = -1, the "every authored op once per signer" rollup),
-- one row per account. Feeds the transaction_count leaderboard.
CREATE TABLE IF NOT EXISTS haf_stats_backend.account_txn_alltime (
    account_id INT NOT NULL PRIMARY KEY,
    ops BIGINT NOT NULL DEFAULT 0
);

-- Index the leaderboard sort so top-N is an index scan, not a sort of ~2M rows.
CREATE INDEX IF NOT EXISTS idx_account_txn_alltime_ops
ON haf_stats_backend.account_txn_alltime (ops DESC, account_id);

GRANT SELECT ON haf_stats_backend.account_txn_alltime TO haf_stats_user;

-- All-time financial totals per account, one row per (account, category, direction). Feeds the
-- author_rewards / curation_rewards (direction 'incoming') and transfer_volume_in/out leaderboards.
CREATE TABLE IF NOT EXISTS haf_stats_backend.account_financial_alltime (
    account_id INT NOT NULL,
    category TEXT NOT NULL,
    direction TEXT NOT NULL,
    hive_nai BIGINT NOT NULL DEFAULT 0,
    hbd_nai BIGINT NOT NULL DEFAULT 0,
    vests_nai BIGINT NOT NULL DEFAULT 0,
    op_count BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, category, direction)
);

-- Two leaderboard orderings, one per metric family (rewards lead on VESTS, transfers on HIVE), so
-- each slice's top-N is served from an index prefixed by (category, direction).
CREATE INDEX IF NOT EXISTS idx_afa_reward_rank
ON haf_stats_backend.account_financial_alltime
(category, direction, vests_nai DESC, hbd_nai DESC, hive_nai DESC, account_id);

CREATE INDEX IF NOT EXISTS idx_afa_transfer_rank
ON haf_stats_backend.account_financial_alltime
(category, direction, hive_nai DESC, hbd_nai DESC, account_id);

GRANT SELECT ON haf_stats_backend.account_financial_alltime TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Refresh
--
-- Recompute both tables from the monthly rollups in one call (REPLACE semantics via
-- TRUNCATE + INSERT inside the function's single transaction, so readers never see a partial
-- state). Summing all monthly rows == genesis..(last monthly refresh), i.e. as-of the last
-- ~1200-block boundary. Runs daily via pg_cron + once at install.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.refresh_top_accounts_alltime()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE haf_stats_backend.account_txn_alltime;
    INSERT INTO haf_stats_backend.account_txn_alltime (account_id, ops)
    SELECT m.account_id, SUM(m.ops)
    FROM haf_stats_backend.active_users_account_monthly m
    WHERE m.op_class = -1
    GROUP BY m.account_id;

    TRUNCATE haf_stats_backend.account_financial_alltime;
    INSERT INTO haf_stats_backend.account_financial_alltime
        (account_id, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
    SELECT m.account_id, m.category, m.direction,
           SUM(m.hive_nai), SUM(m.hbd_nai), SUM(m.vests_nai), SUM(m.op_count)
    FROM haf_stats_backend.account_financial_monthly m
    GROUP BY m.account_id, m.category, m.direction;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.refresh_top_accounts_alltime() TO haf_stats_owner;

RESET ROLE;
