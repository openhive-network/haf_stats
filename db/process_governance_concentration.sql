SET ROLE haf_stats_owner;

-- Feature: governance influence concentration (get_governance_influence_concentration endpoint, #11).
--
-- Network-wide stake-concentration snapshot - Gini coefficient, top-1%/top-10% HP share,
-- total HP holders, median and mean HP - computed from current VESTS balances. Unlike the
-- per-block rollups, this is a CURRENT-STATE snapshot (no block-range/time dimension): each
-- run recomputes the whole thing from scratch, so it is NOT hooked into process_block_range
-- (a full balance scan+sort on every batch during sync would be wasteful and pointless - only
-- the latest value matters). The expensive scan+sort lives here, off the request path; the
-- endpoint just reads the single precomputed row.
--
-- Scheduling is a deploy step (pg_cron, like the other haf_stats cron jobs - e.g. the rc_op_stats
-- sampler). Network concentration moves slowly, so a daily run is plenty. Run once as
-- haf_stats_owner:
--   SELECT cron.schedule('haf_stats_governance_concentration', '0 3 * * *',
--       $cron$ SELECT haf_stats_app.refresh_governance_concentration() $cron$);
-- install_app.sh also calls it once at install so the endpoint is populated immediately on an
-- already-synced node.

-- ---------------------------------------------------------------------------
-- Table (singleton: a BOOLEAN PRIMARY KEY pinned TRUE allows at most one row)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.governance_concentration_snapshot (
    singleton BOOLEAN NOT NULL DEFAULT TRUE PRIMARY KEY,
    gini NUMERIC,
    top_1pct_hp_share NUMERIC,
    top_10pct_hp_share NUMERIC,
    total_hp_holders BIGINT,
    median_hp NUMERIC,
    mean_hp NUMERIC,
    computed_block BIGINT,
    computed_at TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT governance_concentration_snapshot_singleton CHECK (singleton)
);

GRANT SELECT ON haf_stats_backend.governance_concentration_snapshot TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Refresh
--
-- Resolves the first current-balances relation this role can read (standalone btracker_app vs.
-- the block-explorer btracker_backend view / hafbe_bal base table - same allowlist probe as
-- get_network_hp_distribution), then recomputes the snapshot in a single scan + single sort.
-- No readable relation (or an empty hafd.blocks on a fresh node) -> snapshot left empty ->
-- endpoint returns [] (the documented hp-distribution-style contract). Returns the number of
-- snapshot rows written (1 when balances exist, else 0).
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.refresh_governance_concentration;
CREATE OR REPLACE FUNCTION haf_stats_app.refresh_governance_concentration()
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
    DELETE FROM haf_stats_backend.governance_concentration_snapshot;

    IF _balance_rel IS NULL THEN
        RETURN 0;  -- no readable balance relation on this deployment
    END IF;

    -- _balance_rel is built from format('%I.%I', ...) over a fixed allowlist, so interpolating
    -- it (%s) into the dynamic query is injection-safe.
    EXECUTE format($q$
        INSERT INTO haf_stats_backend.governance_concentration_snapshot
            (gini, top_1pct_hp_share, top_10pct_hp_share, total_hp_holders,
             median_hp, mean_hp, computed_block)
        WITH ratio AS (
            SELECT (total_vesting_shares::NUMERIC * 1000)
                   / NULLIF(total_vesting_fund_hive, 0) AS r
            FROM hafd.blocks
            ORDER BY num DESC
            LIMIT 1
        ),
        holders AS (
            SELECT (b.balance::NUMERIC / r.r) AS hp
            FROM %s b, ratio r
            WHERE b.nai = 37   -- VESTS (btracker nai smallint code: 13=HBD, 21=HIVE, 37=VESTS)
              AND b.balance > 0
        ),
        ranked AS (
            SELECT hp,
                   ROW_NUMBER() OVER (ORDER BY hp DESC) AS rnk,
                   COUNT(*)     OVER () AS total_n,
                   SUM(hp)      OVER () AS total_hp
            FROM holders
        )
        SELECT
            -- Gini for descending rank (rnk = 1 is the largest holder):
            --   SUM((n + 1 - 2*rnk) * hp) / (n * total_hp)
            -- (the canonical SUM((2i - n - 1) * x_asc) / (n * S) Gini, rewritten for desc rank).
            ROUND(SUM((total_n + 1 - 2 * rnk) * hp)
                  / NULLIF(total_n * total_hp, 0), 4),
            -- Richest 1pct / 10pct share of total HP. CEIL keeps the band non-empty (>= the
            -- single richest account) when there are fewer than 100 / 10 holders.
            ROUND(SUM(hp) FILTER (WHERE rnk <= CEIL(total_n * 0.01))
                  / NULLIF(total_hp, 0) * 100, 2),
            ROUND(SUM(hp) FILTER (WHERE rnk <= CEIL(total_n * 0.10))
                  / NULLIF(total_hp, 0) * 100, 2),
            total_n::BIGINT,
            -- Median from the already-ranked rows (central order statistic(s)), so the refresh
            -- needs a single sort (the ROW_NUMBER ordering) rather than a separate
            -- PERCENTILE_CONT pass. For odd n both indexes coincide; for even n they are the two
            -- middle ranks and AVG interpolates between them - matching PERCENTILE_CONT(0.5).
            ROUND(AVG(hp) FILTER (
                WHERE rnk IN (FLOOR((total_n + 1) / 2.0)::INT,
                              CEIL((total_n + 1) / 2.0)::INT)), 3),
            ROUND(AVG(hp), 3),
            (SELECT MAX(num) FROM hafd.blocks)
        FROM ranked
        GROUP BY total_n, total_hp
    $q$, _balance_rel);

    GET DIAGNOSTICS _rows = ROW_COUNT;
    RETURN _rows;
END
$_$;

GRANT EXECUTE ON FUNCTION haf_stats_app.refresh_governance_concentration() TO haf_stats_owner;

RESET ROLE;
