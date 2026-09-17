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
-- Recompute both tables from the monthly rollups in one call, inside the function's single
-- transaction, so readers never see a partial state. Summing all monthly rows ==
-- genesis..(last monthly refresh), i.e. as-of the last ~1200-block boundary. Runs daily via
-- pg_cron + once at every install.
--
-- MERGE THE DIFFERENCE, NEVER TRUNCATE. (#95) This used to be TRUNCATE + INSERT, and TRUNCATE
-- takes ACCESS EXCLUSIVE until commit. A reader arriving during the refresh waited for the
-- commit: transaction_count from the first TRUNCATE (up to ~67-68 s nightly on testapi, and 81 s
-- during the 2026-09-16 install, which runs the same refresh), the financial metrics from the
-- second (on testapi one waited 48.4 s for the lock). That is every get_network_top_accounts
-- metric except hp_balance, bounded date ranges included -- their queries name the all-time
-- table in an arm a one-time filter skips, and a skipped arm is still locked. Since #94 gave
-- haf_stats_user a 30 s statement_timeout, a request whose wait plus run time passes 30 s is
-- cancelled (HTTP 500).
--
-- Now one statement per table computes the fresh totals and applies only what differs:
-- UPDATE the keys whose values changed, INSERT the new keys, DELETE the keys the rollups no
-- longer have. Row changes take ROW EXCLUSIVE, which does not conflict with a reader's
-- ACCESS SHARE, so readers do not wait for it; they see the previous totals until commit.
--
-- Why not DELETE everything + INSERT, which would not block readers either: few keys change
-- between refreshes (on 2026-09-15, 16,133 of account_txn_alltime's 2.04M accounts were active,
-- 0.79%, and 12,832 of account_financial_alltime's 1.85M keys, 0.69%). A/B on PostgreSQL 14 at
-- 1/4 of testapi's size with 1% of keys changed, starting from a vacuumed table, on a server with
-- shared_buffers 512MB, work_mem 64MB and synchronous_commit off (so refresh times will not carry
-- over to testapi as-is); "worst read" is the slowest of a top-25 account_id read of
-- account_financial_alltime repeated every 0.25 s through the refresh, and dead tuples and size
-- are that table's:
--
--                          refresh        worst read   dead tuples after   size after
--   TRUNCATE + INSERT      13.2 s         8.3 s        0                   165 MB
--   DELETE all + INSERT    16.6 s         2 ms         100 %               254 MB
--   this merge             7.8-8.4 s      2-4 ms       1 %                 166 MB
--
-- At default autovacuum settings (a vacuum once dead rows exceed 20% of live rows + 50) that ~1%
-- a day accumulates for weeks before a vacuum, so expect these tables to carry up to ~20% dead
-- rows. After a rollup repair that changes most totals, the merge rewrites most rows like
-- DELETE + INSERT does; VACUUM both tables afterwards.
--
-- All sub-statements of a data-modifying WITH run against one snapshot: the INSERT's
-- NOT EXISTS sees the table as it was before the statement, and the three arms touch
-- disjoint keys.
--
-- SHARE ROW EXCLUSIVE conflicts with itself and with every writer, and with VACUUM/ANALYZE
-- (SHARE UPDATE EXCLUSIVE) and CREATE INDEX (SHARE, so a reinstall's CREATE INDEX IF NOT EXISTS
-- above waits for a running refresh) -- but not with readers. Without it, two refreshes that
-- overlap (pg_cron's 03:30 run and an install) can both INSERT the same new key, and one fails
-- on the primary key. With it, the second one waits for the first -- and, for callers in READ
-- COMMITTED (pg_cron and install_app.sh are), its WITH statements then see the first one's commit.
--
-- Readers only queue behind a lock that conflicts with theirs, i.e. ACCESS EXCLUSIVE. Any DDL
-- added to this file that takes it on these tables (most ALTER TABLE forms, even with IF NOT
-- EXISTS) would wait for a running refresh with every reader queued behind it. Route it through
-- haf_stats_app.apply_schema_migration (db/schema_migration.sql), which gives it a catalog test
-- and a lock_timeout; tests/unit/test_ddl_lock_guard.py rejects an ALTER TABLE anywhere else.
-- (Such a call also has to run BEFORE this file: tests/ci_lock_holder.sql uses the re-creation
-- of refresh_top_accounts_alltime() below as its "past every migration" marker.)
--
-- SUM(...)::BIGINT is the column type; the old INSERT cast the numeric sum implicitly, and an
-- out-of-range total still raises the same error.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.refresh_top_accounts_alltime;
CREATE OR REPLACE FUNCTION haf_stats_app.refresh_top_accounts_alltime()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _txn_changed BIGINT;
    _txn_added BIGINT;
    _txn_removed BIGINT;
    _fin_changed BIGINT;
    _fin_added BIGINT;
    _fin_removed BIGINT;
BEGIN
    LOCK TABLE haf_stats_backend.account_txn_alltime, haf_stats_backend.account_financial_alltime
    IN SHARE ROW EXCLUSIVE MODE;

    WITH fresh AS MATERIALIZED (
        SELECT
            m.account_id,
            SUM(m.ops)::BIGINT AS ops
        FROM haf_stats_backend.active_users_account_monthly AS m
        WHERE m.op_class = -1
        GROUP BY m.account_id
    ),

    changed AS (
        UPDATE haf_stats_backend.account_txn_alltime AS t
        SET ops = f.ops
        FROM fresh AS f
        WHERE
            t.account_id = f.account_id
            AND t.ops IS DISTINCT FROM f.ops
        RETURNING 1
    ),

    added AS (
        INSERT INTO haf_stats_backend.account_txn_alltime (account_id, ops)
        SELECT
            f.account_id,
            f.ops
        FROM fresh AS f
        WHERE NOT EXISTS (
            SELECT 1
            FROM haf_stats_backend.account_txn_alltime AS t
            WHERE t.account_id = f.account_id
        )
        RETURNING 1
    ),

    removed AS (
        DELETE FROM haf_stats_backend.account_txn_alltime AS t
        WHERE NOT EXISTS (
            SELECT 1
            FROM fresh AS f
            WHERE f.account_id = t.account_id
        )
        RETURNING 1
    )

    SELECT
        (SELECT COUNT(*) FROM changed),
        (SELECT COUNT(*) FROM added),
        (SELECT COUNT(*) FROM removed)
    INTO _txn_changed, _txn_added, _txn_removed;

    WITH fresh AS MATERIALIZED (
        SELECT
            m.account_id,
            m.category,
            m.direction,
            SUM(m.hive_nai)::BIGINT AS hive_nai,
            SUM(m.hbd_nai)::BIGINT AS hbd_nai,
            SUM(m.vests_nai)::BIGINT AS vests_nai,
            SUM(m.op_count)::BIGINT AS op_count
        FROM haf_stats_backend.account_financial_monthly AS m
        GROUP BY m.account_id, m.category, m.direction
    ),

    changed AS (
        UPDATE haf_stats_backend.account_financial_alltime AS t
        SET
            hive_nai = f.hive_nai,
            hbd_nai = f.hbd_nai,
            vests_nai = f.vests_nai,
            op_count = f.op_count
        FROM fresh AS f
        WHERE
            t.account_id = f.account_id
            AND t.category = f.category
            AND t.direction = f.direction
            AND (t.hive_nai, t.hbd_nai, t.vests_nai, t.op_count)
            IS DISTINCT FROM (f.hive_nai, f.hbd_nai, f.vests_nai, f.op_count)
        RETURNING 1
    ),

    added AS (
        INSERT INTO haf_stats_backend.account_financial_alltime
        (account_id, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
        SELECT
            f.account_id,
            f.category,
            f.direction,
            f.hive_nai,
            f.hbd_nai,
            f.vests_nai,
            f.op_count
        FROM fresh AS f
        WHERE NOT EXISTS (
            SELECT 1
            FROM haf_stats_backend.account_financial_alltime AS t
            WHERE
                t.account_id = f.account_id
                AND t.category = f.category
                AND t.direction = f.direction
        )
        RETURNING 1
    ),

    removed AS (
        DELETE FROM haf_stats_backend.account_financial_alltime AS t
        WHERE NOT EXISTS (
            SELECT 1
            FROM fresh AS f
            WHERE
                f.account_id = t.account_id
                AND f.category = t.category
                AND f.direction = t.direction
        )
        RETURNING 1
    )

    SELECT
        (SELECT COUNT(*) FROM changed),
        (SELECT COUNT(*) FROM added),
        (SELECT COUNT(*) FROM removed)
    INTO _fin_changed, _fin_added, _fin_removed;

    RAISE NOTICE 'haf_stats: all-time top accounts refreshed - account_txn_alltime % changed, % added, % removed; account_financial_alltime % changed, % added, % removed',
        _txn_changed, _txn_added, _txn_removed, _fin_changed, _fin_added, _fin_removed;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.refresh_top_accounts_alltime() TO haf_stats_owner;

RESET ROLE;
