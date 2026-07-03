SET ROLE haf_stats_owner;

-- Feature: network HP stake distribution (get_network_hp_distribution endpoint, #29 item 5).
--
-- Bucketed distribution of Hive Power across all accounts (8 buckets, with account counts and
-- the total HP held per bucket). Like the governance-concentration snapshot, this is a
-- CURRENT-STATE snapshot (no block-range/time dimension): it is computed from the balance_tracker
-- current-VESTS balances (~1.8M rows), so each run recomputes the whole thing from scratch and it
-- is NOT hooked into process_block_range (a full balance scan on every batch during sync would be
-- wasteful - only the latest value matters). The whole-table scan lives here, off the request
-- path; the endpoint just reads the 8 precomputed rows.
--
-- Scheduling is a deploy step (pg_cron, like the governance snapshot and the rc_op_stats sampler).
-- The distribution moves slowly, so a daily run is plenty. Run once as haf_stats_owner:
--   SELECT cron.schedule('haf_stats_hp_distribution', '0 3 * * *',
--       $cron$ SELECT haf_stats_app.refresh_hp_distribution_snapshot() $cron$);
-- install_app.sh also calls it once at install so the endpoint is populated immediately on an
-- already-synced node.

-- ---------------------------------------------------------------------------
-- Table (at most 8 rows, one per non-empty HP bucket; sort_order gives the display order)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.hp_distribution_snapshot (
    bucket TEXT NOT NULL PRIMARY KEY,
    sort_order INT NOT NULL,
    account_count BIGINT NOT NULL,
    pct_accounts NUMERIC,
    total_hp NUMERIC,
    pct_hp NUMERIC,
    computed_block BIGINT,
    computed_at TIMESTAMP NOT NULL DEFAULT now()
);

GRANT SELECT ON haf_stats_backend.hp_distribution_snapshot TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Refresh
--
-- Resolves the first current-balances relation this role can read (standalone btracker_app vs.
-- the block-explorer btracker_backend view / hafbe_bal base table - same allowlist probe as
-- get_network_hp_distribution and the governance snapshot), then recomputes the 8-bucket
-- distribution in a single scan. Bucket boundaries and total_hp/pct_hp are computed exactly as
-- the endpoint used to inline them (VESTS/HP ratio from the latest block; total_hp = VESTS/ratio;
-- pct_hp = bucket VESTS / total VESTS, the ratio cancels). Empty buckets are omitted (GROUP BY),
-- matching the previous inline behaviour. No readable relation (or an empty hafd.blocks on a fresh
-- node) -> snapshot left empty -> endpoint returns [] (the documented contract). Returns the
-- number of snapshot rows written (0..8).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.refresh_hp_distribution_snapshot()
RETURNS INTEGER
LANGUAGE plpgsql
SET jit = OFF
AS $_$
DECLARE
    _balance_rel TEXT;
    _rows        INTEGER;
BEGIN
    SELECT format('%I.%I', t.table_schema, t.table_name)
      INTO _balance_rel
      FROM (VALUES
                ('btracker_app',     'current_account_balances',      1),
                ('btracker_backend', 'current_account_balances_view',  2),
                ('hafbe_bal',        'current_account_balances',      3)
            ) AS cand (sch, rel, prio)
      JOIN information_schema.tables t
        ON t.table_schema = cand.sch AND t.table_name = cand.rel
     ORDER BY cand.prio
     LIMIT 1;

    -- Always reflect current state: clear first, then (if a balance relation exists) recompute.
    DELETE FROM haf_stats_backend.hp_distribution_snapshot;

    IF _balance_rel IS NULL THEN
        RETURN 0;  -- no readable balance relation on this deployment
    END IF;

    -- _balance_rel is built from format('%I.%I', ...) over a fixed allowlist, so interpolating
    -- it (%s) into the dynamic query is injection-safe.
    EXECUTE format($q$
        INSERT INTO haf_stats_backend.hp_distribution_snapshot
            (bucket, sort_order, account_count, pct_accounts, total_hp, pct_hp, computed_block)
        WITH ratio AS (
            SELECT (total_vesting_shares::NUMERIC * 1000)
                   / NULLIF(total_vesting_fund_hive, 0) AS r
            FROM hafd.blocks
            ORDER BY num DESC
            LIMIT 1
        ),
        bucketed AS (
            SELECT
                CASE
                    WHEN b.balance < 1       * r.r THEN 1
                    WHEN b.balance < 10      * r.r THEN 2
                    WHEN b.balance < 100     * r.r THEN 3
                    WHEN b.balance < 1000    * r.r THEN 4
                    WHEN b.balance < 10000   * r.r THEN 5
                    WHEN b.balance < 100000  * r.r THEN 6
                    WHEN b.balance < 1000000 * r.r THEN 7
                    ELSE                               8
                END            AS sort_order,
                b.balance      AS vests
            FROM %s b, ratio r
            WHERE b.nai = 37   -- VESTS (btracker nai smallint code: 13=HBD, 21=HIVE, 37=VESTS)
              AND b.balance > 0
        ),
        per_bucket AS (
            SELECT sort_order, COUNT(*) AS cnt, SUM(vests) AS vests
            FROM bucketed
            GROUP BY sort_order
        ),
        -- sort_order -> label defined once as data (the inverse of the boundary CASE above), so
        -- the two mappings cannot drift out of sync.
        labels (sort_order, bucket) AS (
            VALUES (1, '0-1 HP'), (2, '1-10 HP'), (3, '10-100 HP'), (4, '100-1K HP'),
                   (5, '1K-10K HP'), (6, '10K-100K HP'), (7, '100K-1M HP'), (8, '1M+ HP')
        ),
        total AS (SELECT SUM(cnt) AS n, SUM(vests) AS v FROM per_bucket)
        SELECT
            l.bucket                                              AS bucket,
            pb.sort_order,
            pb.cnt::BIGINT                                         AS account_count,
            ROUND(pb.cnt * 100.0 / NULLIF(total.n, 0), 2)         AS pct_accounts,
            -- HP = VESTS / ratio (same conversion the bucket boundaries use). For the unbounded
            -- 1M+ bucket this is the real total, not a midpoint estimate (#28).
            ROUND(pb.vests / NULLIF(ratio.r, 0), 2)               AS total_hp,
            -- Bucket's share of total HP; the ratio cancels, so this is its share of total VESTS.
            ROUND(pb.vests * 100.0 / NULLIF(total.v, 0), 2)       AS pct_hp,
            (SELECT MAX(num) FROM hafd.blocks)                     AS computed_block
        FROM per_bucket pb
        JOIN labels l ON l.sort_order = pb.sort_order
        CROSS JOIN total
        CROSS JOIN ratio
    $q$, _balance_rel);

    GET DIAGNOSTICS _rows = ROW_COUNT;
    RETURN _rows;
END
$_$;

GRANT EXECUTE ON FUNCTION haf_stats_app.refresh_hp_distribution_snapshot() TO haf_stats_owner;

RESET ROLE;
