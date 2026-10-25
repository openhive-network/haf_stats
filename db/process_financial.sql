SET ROLE haf_stats_owner;

-- Feature: per-account financial summary (get_account_financial_summary endpoint).
-- Creates the aggregation table and the block processor that populates it.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

-- Legacy op-category registry: the processor below inlines all category/
-- direction logic and never reads this table, and it was seeded with the old
-- income/expense vocabulary. Drop it (haf_stats issue #26).
DROP TABLE IF EXISTS haf_stats_backend.op_financial_categories;

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_financial_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    category TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('incoming', 'outgoing')),
    hive_nai BIGINT NOT NULL DEFAULT 0,
    hbd_nai BIGINT NOT NULL DEFAULT 0,
    vests_nai BIGINT NOT NULL DEFAULT 0,
    op_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, category, direction)
);

-- Migrate already-deployed tables created with the old income/expense CHECK:
-- CREATE TABLE IF NOT EXISTS is a no-op when the table exists, so the stale
-- constraint would otherwise reject the new incoming/outgoing inserts. NOT VALID
-- skips re-checking existing rows; the DELETE below removes them outright so the
-- constraint holds for everything that remains.
-- Guarded so a node that already carries the canonical constraint runs none of this (#96):
-- ALTER TABLE takes ACCESS EXCLUSIVE before it evaluates IF [NOT] EXISTS, ADD CONSTRAINT and
-- VALIDATE have no IF clause at all, and this table is named by get_network_top_accounts' four
-- reward and transfer metrics -- bounded ranges and the all-time default alike, since a skipped
-- UNION arm is still locked (#95). The only lock left on the normal path is the instant ACCESS
-- SHARE pg_get_constraintdef() takes below, which is a reader's own lock.
--
-- "Canonical" below means: the definition names exactly two literals, 'incoming' then
-- 'outgoing'. The DELETE and VALIDATE guards rely on that classification. No shipped revision
-- had any other shape containing those two literals (4a915dd: income/expense; since then: the
-- canonical IN list), so it holds for every deployment this upgrade can meet.
SELECT haf_stats_app.apply_schema_migration(
    EXISTS (
        SELECT 1
        FROM pg_constraint AS c
        WHERE
            c.conrelid = 'haf_stats_backend.account_financial_daily'::REGCLASS
            AND c.conname = 'account_financial_daily_direction_check'
            AND (
                pg_get_constraintdef(c.oid) NOT LIKE '%''incoming''%''outgoing''%'
                -- ... and nothing else: a definition listing a third value contains both
                -- literals too, and develop replaced such a constraint unconditionally.
                OR (
                    SELECT count(*)
                    FROM regexp_matches(pg_get_constraintdef(c.oid), '''[^'']*''', 'g')
                ) <> 2
            )
    ),
    'ALTER TABLE haf_stats_backend.account_financial_daily
     DROP CONSTRAINT IF EXISTS account_financial_daily_direction_check',
    'account_financial_daily: drop the pre-canonical direction CHECK'
);

SELECT haf_stats_app.apply_schema_migration(
    NOT EXISTS (
        SELECT 1
        FROM pg_constraint AS c
        WHERE
            c.conrelid = 'haf_stats_backend.account_financial_daily'::REGCLASS
            AND c.conname = 'account_financial_daily_direction_check'
    ),
    'ALTER TABLE haf_stats_backend.account_financial_daily
     ADD CONSTRAINT account_financial_daily_direction_check
     CHECK (direction IN (''incoming'', ''outgoing'')) NOT VALID',
    'account_financial_daily.direction CHECK'
);

-- Production resumes block processing immediately after install, and the new
-- canonical-keyed upserts never overwrite rows written under the old
-- income/expense + display-name vocabulary. Delete those stale rows here so the
-- endpoint can never serve a mix of both vocabularies. Idempotent: a no-op once
-- only canonical rows remain (and on fresh installs). Historical coverage is
-- restored by scripts/rebuild_financial.sh (forward processing only fills new
-- blocks).
-- Guarded like the statements around it (#96): a VALIDATED canonical CHECK proves no row
-- violates it, so this scan has nothing to find. It takes only ROW EXCLUSIVE, which readers
-- pass, but it is a full scan of the largest table in this file on every install.
SELECT haf_stats_app.apply_schema_migration(
    NOT EXISTS (
        SELECT 1
        FROM pg_constraint AS c
        WHERE
            c.conrelid = 'haf_stats_backend.account_financial_daily'::REGCLASS
            AND c.conname = 'account_financial_daily_direction_check'
            AND c.convalidated
    ),
    'DELETE FROM haf_stats_backend.account_financial_daily
     WHERE direction NOT IN (''incoming'', ''outgoing'')',
    'account_financial_daily: delete pre-canonical rows'
);

-- VALIDATE takes SHARE UPDATE EXCLUSIVE, which readers pass -- but it scans the whole table,
-- so skip it once the constraint is validated (#96).
SELECT haf_stats_app.apply_schema_migration(
    EXISTS (
        SELECT 1
        FROM pg_constraint AS c
        WHERE
            c.conrelid = 'haf_stats_backend.account_financial_daily'::REGCLASS
            AND c.conname = 'account_financial_daily_direction_check'
            AND NOT c.convalidated
    ),
    'ALTER TABLE haf_stats_backend.account_financial_daily
     VALIDATE CONSTRAINT account_financial_daily_direction_check',
    'account_financial_daily.direction CHECK: validate'
);

-- No (account_id, day) index: the primary key leads with exactly that, so it serves
-- both per-account reads on its own (get_account_financial_summary, the rewards CTE
-- of get_account_content_stats); refresh_financial_monthly has no account_id
-- predicate and rides the index below instead. Nothing orders these rows by day, so
-- the DESC on the old idx_afd_account_day bought nothing. Dropped rather than just
-- deleted so deployed nodes reclaim its 3.8 GB on the next install (issue #53);
-- CONCURRENTLY is permitted here for the same reason as idx_acm_created_at in
-- process_account_cohorts.sql. Re-running this finishes an interrupted drop.
DROP INDEX CONCURRENTLY IF EXISTS haf_stats_backend.idx_afd_account_day;

-- Leaderboard access path (get_network_top_accounts): a category + direction +
-- day-range scan across ALL accounts, which the account_id-leading PK cannot
-- serve. Two dependants, not one: refresh_financial_monthly below drives its
-- account-wide category scan off this index too.
-- Columns are a subset of the PK, so this index adds no new HOT-blocking
-- attributes to the additive nai/op_count upserts.
CREATE INDEX IF NOT EXISTS idx_afd_category_direction_day
ON haf_stats_backend.account_financial_daily (category, direction, day);

GRANT SELECT ON haf_stats_backend.account_financial_daily TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Monthly leaderboard rollup (get_network_top_accounts performance, issue #37)
--
-- get_network_top_accounts aggregates account_financial_daily over the requested
-- [from_date, to_date] window. Latency scales with the window width (a 365-day
-- curation_rewards leaderboard scans ~2.9M daily rows / gigabytes of heap, ~20s
-- cold), because it sums DAILY rows at request time. This table pre-aggregates the
-- same amounts to one row per (account, month) so a wide window reads ~12 monthly
-- rows per account instead of ~365 daily ones. The endpoint reads full interior
-- months from here and the partial edge months (including the always-in-progress
-- current month) straight from account_financial_daily, so results stay byte-exact
-- and the current month is never stale.
--
-- Scope: only the categories/directions the leaderboard exposes (author/curation
-- rewards incoming, transfers in/out). Adding a new metric to the endpoint that
-- reads a category NOT listed here would silently undercount its interior months —
-- extend refresh_financial_monthly's category filter in lockstep (guarded by the
-- multi-month parity case in tests/parity).
CREATE TABLE IF NOT EXISTS haf_stats_backend.account_financial_monthly (
    account_id INT NOT NULL,
    month DATE NOT NULL,
    category TEXT NOT NULL,
    direction TEXT NOT NULL,
    hive_nai BIGINT NOT NULL DEFAULT 0,
    hbd_nai BIGINT NOT NULL DEFAULT 0,
    vests_nai BIGINT NOT NULL DEFAULT 0,
    op_count BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, month, category, direction)
);

-- Same leaderboard access path as the daily index, one grain up: a
-- (category, direction, month)-range scan across all accounts.
CREATE INDEX IF NOT EXISTS idx_afm_category_direction_month
ON haf_stats_backend.account_financial_monthly (category, direction, month);

GRANT SELECT ON haf_stats_backend.account_financial_monthly TO haf_stats_user;

-- Recompute every month touched by [_lo, _hi] exactly from the daily table. A whole
-- month is always recomputed from its first day (the scan starts at _month_lo, never
-- mid-month) so a month's totals are complete; the in-progress current month is
-- recomputed month-to-date on each run, which is harmless because the endpoint serves
-- the current/partial month from account_financial_daily and never from this rollup.
-- REPLACE semantics (DO UPDATE SET = EXCLUDED): each run fully restates the months it
-- covers from daily, matching refresh_active_users_periods. Passing NULL _hi restates
-- from _lo forward (one-time genesis backfill). Only the leaderboard categories are
-- materialised (see the table comment above).
DROP FUNCTION IF EXISTS haf_stats_app.refresh_financial_monthly;
CREATE OR REPLACE FUNCTION haf_stats_app.refresh_financial_monthly(
    _lo DATE,
    _hi DATE DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _month_lo DATE := DATE_TRUNC('month', _lo)::DATE;
BEGIN
    INSERT INTO haf_stats_backend.account_financial_monthly
        (account_id, month, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
    SELECT
        f.account_id,
        DATE_TRUNC('month', f.day)::DATE,
        f.category,
        f.direction,
        SUM(f.hive_nai)::BIGINT,
        SUM(f.hbd_nai)::BIGINT,
        SUM(f.vests_nai)::BIGINT,
        SUM(f.op_count)::BIGINT
    FROM haf_stats_backend.account_financial_daily f
    WHERE f.category IN ('author_reward_operation', 'curation_reward_operation', 'transfer_operation')
      AND f.day >= _month_lo
      AND (_hi IS NULL OR f.day <= _hi)
    GROUP BY f.account_id, DATE_TRUNC('month', f.day)::DATE, f.category, f.direction
    ON CONFLICT (account_id, month, category, direction) DO UPDATE SET
        hive_nai  = EXCLUDED.hive_nai,
        hbd_nai   = EXCLUDED.hbd_nai,
        vests_nai = EXCLUDED.vests_nai,
        op_count  = EXCLUDED.op_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- Processor
--
-- Single pass: one INSERT … SELECT over a UNION ALL of per-operation "legs".
-- Each leg emits one row per source operation in the normalized shape
-- (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, 1),
-- with 0 in the amount columns it doesn't touch. The outer GROUP BY does all
-- aggregation, collapsing every same-key row before the INSERT — so a single
-- uniform ON CONFLICT can sum the three amount columns, and the
-- "ON CONFLICT DO UPDATE cannot affect row a second time" error (which fires
-- when two source rows target the same conflict key) cannot occur.
--
-- category = canonical Hive operation type name; direction = incoming/outgoing
-- (aligns with the block explorer's ops vocabulary, haf_stats issue #26).
-- Op-type ids are resolved once into locals from hafd.operation_types, whose
-- names are fully qualified with the 'hive::protocol::' prefix (same lookup
-- pattern as process_account_cohorts.sql / process_witness_blocks.sql; the
-- unprefixed form silently resolves to NULL, see docs/VERIFICATION.md D5).
-- Every name below is declared in db/op_type_registry.sql, which fails the
-- install if hived ever renames one - otherwise these lookups would return
-- NULL and every category here would silently report zero.
--
-- DOUBLE COUNT (intentional): reward *accrual* (author_reward,
-- comment_benefactor_reward, curation_reward) and reward *claim*
-- (claim_reward_balance) are both 'incoming', so the same funds appear under the
-- accrual and the claim category. Consumers must not sum across both as a net
-- inflow.
--
-- Asset NAI: HIVE = @@000000021, HBD = @@000000013 (split where an `amount`
-- field can be either). transfer and fill_order are multi-leg (sender/receiver,
-- maker/taker).
--
-- SCAN SOURCE: each leg reads hafd.operations directly (not hive.operations_view),
-- filtered by op_type_id + hafd.operation_id_to_block_num(id) BETWEEN the batch
-- bounds, which the hive_operations_op_type_id_block_num index serves as a tight
-- range scan. operations_view is a UNION ALL of operations + reversible_operations
-- and adds large per-query overhead over wide ranges; its reversible half is moot
-- here because the haf_stats context is non-forking (is_forking = false), so every
-- block this function processes is already irreversible and present in
-- hafd.operations. Same idiom as the haf_block_explorer / balance_tracker processors;
-- a full-history financial rebuild drops from ~tens of hours to ~1-2h.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.process_financial;
CREATE OR REPLACE FUNCTION haf_stats_app.process_financial(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _author_reward_id              INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::author_reward_operation');
    _comment_benefactor_reward_id  INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::comment_benefactor_reward_operation');
    _curation_reward_id            INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::curation_reward_operation');
    _claim_reward_balance_id       INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::claim_reward_balance_operation');
    _interest_id                   INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::interest_operation');
    _transfer_id                   INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_operation');
    _transfer_to_savings_id        INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_to_savings_operation');
    _transfer_from_savings_id      INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_from_savings_operation');
    _fill_transfer_from_savings_id INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::fill_transfer_from_savings_operation');
    _transfer_to_vesting_id        INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_to_vesting_operation');
    _fill_vesting_withdraw_id      INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::fill_vesting_withdraw_operation');
    _producer_reward_id            INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_reward_operation');
    _liquidity_reward_id           INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::liquidity_reward_operation');
    _proposal_pay_id               INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::proposal_pay_operation');
    _fill_order_id                 INT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::fill_order_operation');
    _first_day DATE;
    _last_day DATE;
    _refresh_lo_block INT;
    _timed BOOLEAN;
    _t TIMESTAMPTZ;
BEGIN

INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    account_id,
    day,
    category,
    direction,
    SUM(hive_nai)::BIGINT,
    SUM(hbd_nai)::BIGINT,
    SUM(vests_nai)::BIGINT,
    SUM(op_count)::INT
FROM (

    -- 1. Author rewards: incoming for the post author.
    SELECT
        a.id AS account_id,
        bv.created_at::DATE AS day,
        'author_reward_operation' AS category,
        'incoming' AS direction,
        COALESCE((ov.body_value -> 'hive_payout'    ->> 'amount')::BIGINT, 0) AS hive_nai,
        COALESCE((ov.body_value -> 'hbd_payout'     ->> 'amount')::BIGINT, 0) AS hbd_nai,
        COALESCE((ov.body_value -> 'vesting_payout' ->> 'amount')::BIGINT, 0) AS vests_nai,
        1 AS op_count
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'author')
    WHERE ov.op_type_id = _author_reward_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 2. Comment benefactor rewards: incoming for the benefactor.
    SELECT
        a.id,
        bv.created_at::DATE,
        'comment_benefactor_reward_operation',
        'incoming',
        COALESCE((ov.body_value -> 'hive_payout'    ->> 'amount')::BIGINT, 0),
        COALESCE((ov.body_value -> 'hbd_payout'     ->> 'amount')::BIGINT, 0),
        COALESCE((ov.body_value -> 'vesting_payout' ->> 'amount')::BIGINT, 0),
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'benefactor')
    WHERE ov.op_type_id = _comment_benefactor_reward_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 3. Curation rewards: incoming for the curator (VESTS only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'curation_reward_operation',
        'incoming',
        0::BIGINT,
        0::BIGINT,
        COALESCE((ov.body_value -> 'reward' ->> 'amount')::BIGINT, 0),
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'curator')
    WHERE ov.op_type_id = _curation_reward_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 4. Claim reward balance: incoming for the claiming account.
    SELECT
        a.id,
        bv.created_at::DATE,
        'claim_reward_balance_operation',
        'incoming',
        COALESCE((ov.body_value -> 'reward_hive'  ->> 'amount')::BIGINT, 0),
        COALESCE((ov.body_value -> 'reward_hbd'   ->> 'amount')::BIGINT, 0),
        COALESCE((ov.body_value -> 'reward_vests' ->> 'amount')::BIGINT, 0),
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'account')
    WHERE ov.op_type_id = _claim_reward_balance_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 5. HBD savings interest: incoming for the account owner (HBD only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'interest_operation',
        'incoming',
        0::BIGINT,
        COALESCE((ov.body_value -> 'interest' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'owner')
    WHERE ov.op_type_id = _interest_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 6. Transfers: outgoing for the sender.
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_operation',
        'outgoing',
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'from')
    WHERE ov.op_type_id = _transfer_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 7. Transfers: incoming for the receiver.
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_operation',
        'incoming',
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'to')
    WHERE ov.op_type_id = _transfer_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 8. Transfer to savings: outgoing for the sender.
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_to_savings_operation',
        'outgoing',
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'from')
    WHERE ov.op_type_id = _transfer_to_savings_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 9. Transfer from savings (the request): outgoing for the sender.
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_from_savings_operation',
        'outgoing',
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'from')
    WHERE ov.op_type_id = _transfer_from_savings_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 10. Fill transfer from savings: incoming for the receiver.
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_transfer_from_savings_operation',
        'incoming',
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'amount' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'to')
    WHERE ov.op_type_id = _fill_transfer_from_savings_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 11. Power up (transfer_to_vesting): outgoing for the initiator (HIVE spent).
    SELECT
        a.id,
        bv.created_at::DATE,
        'transfer_to_vesting_operation',
        'outgoing',
        COALESCE((ov.body_value -> 'amount' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'from')
    WHERE ov.op_type_id = _transfer_to_vesting_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 12. Power down (fill_vesting_withdraw): incoming for the deposit recipient.
    -- `deposited` is credited to to_account (usually == from_account, but a
    -- withdrawal route can send it elsewhere) and may be HIVE (normal power-down)
    -- or VESTS (route that re-vests). `withdrawn` is the from_account's own VESTS
    -- leaving its vesting balance, not a value inflow, so it is not recorded here.
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_vesting_withdraw_operation',
        'incoming',
        CASE WHEN (ov.body_value -> 'deposited' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'deposited' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        CASE WHEN (ov.body_value -> 'deposited' ->> 'nai') = '@@000000037'
             THEN COALESCE((ov.body_value -> 'deposited' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'to_account')
    WHERE ov.op_type_id = _fill_vesting_withdraw_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 13. Witness pay (producer_reward): incoming for the block producer (VESTS only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'producer_reward_operation',
        'incoming',
        0::BIGINT,
        0::BIGINT,
        COALESCE((ov.body_value -> 'vesting_shares' ->> 'amount')::BIGINT, 0),
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'producer')
    WHERE ov.op_type_id = _producer_reward_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 14. Liquidity reward: incoming for the owner (HIVE only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'liquidity_reward_operation',
        'incoming',
        COALESCE((ov.body_value -> 'payout' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'owner')
    WHERE ov.op_type_id = _liquidity_reward_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 15. Proposal pay (DHF): incoming for the proposal receiver (HBD only).
    SELECT
        a.id,
        bv.created_at::DATE,
        'proposal_pay_operation',
        'incoming',
        0::BIGINT,
        COALESCE((ov.body_value -> 'payment' ->> 'amount')::BIGINT, 0),
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'receiver')
    WHERE ov.op_type_id = _proposal_pay_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 16. Fill order: outgoing for current_owner (what they paid).
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_order_operation',
        'outgoing',
        CASE WHEN (ov.body_value -> 'current_pays' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'current_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'current_pays' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'current_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'current_owner')
    WHERE ov.op_type_id = _fill_order_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 17. Fill order: incoming for current_owner (what they received).
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_order_operation',
        'incoming',
        CASE WHEN (ov.body_value -> 'open_pays' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'open_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'open_pays' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'open_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'current_owner')
    WHERE ov.op_type_id = _fill_order_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 18. Fill order: outgoing for open_owner (what they paid).
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_order_operation',
        'outgoing',
        CASE WHEN (ov.body_value -> 'open_pays' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'open_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'open_pays' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'open_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'open_owner')
    WHERE ov.op_type_id = _fill_order_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

    UNION ALL

    -- 19. Fill order: incoming for open_owner (what they received).
    SELECT
        a.id,
        bv.created_at::DATE,
        'fill_order_operation',
        'incoming',
        CASE WHEN (ov.body_value -> 'current_pays' ->> 'nai') = '@@000000021'
             THEN COALESCE((ov.body_value -> 'current_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        CASE WHEN (ov.body_value -> 'current_pays' ->> 'nai') = '@@000000013'
             THEN COALESCE((ov.body_value -> 'current_pays' ->> 'amount')::BIGINT, 0) ELSE 0 END,
        0::BIGINT,
        1
    FROM hafd.operations ov
    JOIN hafd.blocks bv ON bv.num = hafd.operation_id_to_block_num(ov.id)
    JOIN hafd.accounts a ON a.name = (ov.body_value ->> 'open_owner')
    WHERE ov.op_type_id = _fill_order_id
      AND hafd.operation_id_to_block_num(ov.id) BETWEEN _first_block AND _last_block

) impacts
GROUP BY account_id, day, category, direction
ON CONFLICT (account_id, day, category, direction) DO UPDATE SET
    hive_nai  = account_financial_daily.hive_nai  + EXCLUDED.hive_nai,
    hbd_nai   = account_financial_daily.hbd_nai   + EXCLUDED.hbd_nai,
    vests_nai = account_financial_daily.vests_nai + EXCLUDED.vests_nai,
    op_count  = account_financial_daily.op_count  + EXCLUDED.op_count;

-- Refresh the get_network_top_accounts monthly rollup (issue #37). Same gated
-- pattern as process_active_users' period refresh: only fire when the batch crosses
-- a ~1200-block (~1 hour) boundary, and recompute every month that received data
-- since the previous fire. The lower bound reaches back to that bucket's start
-- ((_first_block - 1) / 1200 * 1200) so LIVE batches that accumulated in the bucket
-- without crossing it are still covered; _month_lo inside the refresh rounds it down
-- to the month start so partial-day lower bounds always restate a whole month. A
-- one-time full backfill is available via
-- SELECT haf_stats_app.refresh_financial_monthly(<genesis day>, NULL).
IF (_last_block / 1200) <> ((_first_block - 1) / 1200) THEN
    _refresh_lo_block := GREATEST(((_first_block - 1) / 1200) * 1200, 1);
    SELECT created_at::DATE INTO _first_day FROM hafd.blocks WHERE num = _refresh_lo_block;
    SELECT created_at::DATE INTO _last_day  FROM hafd.blocks WHERE num = _last_block;
    IF _first_day IS NULL THEN
        SELECT created_at::DATE INTO _first_day FROM hafd.blocks WHERE num = _first_block;
    END IF;

    -- Timed when haf_stats.processor_timings is on (db/process_block_range.sql).
    _timed := current_setting('haf_stats.processor_timings', TRUE) = 'on';
    IF _timed THEN _t := clock_timestamp(); END IF;
    PERFORM haf_stats_app.refresh_financial_monthly(_first_day, _last_day);
    IF _timed THEN _t := haf_stats_app.report_processor_timing('refresh_financial_monthly', _first_block, _last_block, _t, '{}', 'process_financial'); END IF;
END IF;

END;
$$;

RESET ROLE;
