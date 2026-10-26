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

-- category and direction as compact codes: the category is the op type's own id
-- (hafd.operation_types.id -- every one used is pinned by name in db/op_type_registry.sql) and
-- the direction a boolean. As TEXT they repeated in every row, in the primary key and in the
-- leaderboard index, ~30 bytes a row. The endpoints still serve and accept the canonical names
-- ('author_reward_operation', ...) and 'incoming'/'outgoing'.
--
-- A table in the earlier TEXT shape (category TEXT, direction TEXT -- including the
-- income/expense vocabulary of 4a915dd) is dropped and created again empty: deployments are
-- replayed, so no row is converted. The DDL runs through apply_schema_migration's lock-safe
-- retries (db/schema_migration.sql) and only while the table still has a category column, so
-- every later install takes no lock here. Repopulating it is scripts/rebuild_financial.sh, or
-- a replay.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = to_regclass('haf_stats_backend.account_financial_daily')
            AND a.attname = 'category'
            AND NOT a.attisdropped
    ) THEN
        PERFORM haf_stats_app.apply_schema_migration(
            TRUE,
            'DROP TABLE haf_stats_backend.account_financial_daily',
            'account_financial_daily: the TEXT category/direction shape, recreated empty in the compact shape'
        );
        RAISE WARNING 'haf_stats: account_financial_daily was in the old TEXT category/direction shape and has been recreated EMPTY. Stop the processor and run scripts/rebuild_financial.sh (or replay) to repopulate it; until then the financial endpoints report nothing for history.';
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_financial_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    op_type_id SMALLINT NOT NULL,
    is_outgoing BOOLEAN NOT NULL,
    hive_nai BIGINT NOT NULL DEFAULT 0,
    hbd_nai BIGINT NOT NULL DEFAULT 0,
    vests_nai BIGINT NOT NULL DEFAULT 0,
    op_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, op_type_id, is_outgoing)
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
CREATE INDEX IF NOT EXISTS idx_afd_op_type_outgoing_day
ON haf_stats_backend.account_financial_daily (op_type_id, is_outgoing, day);

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
-- materialised (see the table comment above). This small rollup keeps the categories' names
-- and the direction words, which the daily table stores as codes.
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
    _author_reward_id   SMALLINT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::author_reward_operation');
    _curation_reward_id SMALLINT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::curation_reward_operation');
    _transfer_id        SMALLINT := (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_operation');
BEGIN
    INSERT INTO haf_stats_backend.account_financial_monthly
        (account_id, month, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
    SELECT
        m.account_id,
        m.month,
        CASE m.op_type_id
            WHEN _author_reward_id   THEN 'author_reward_operation'
            WHEN _curation_reward_id THEN 'curation_reward_operation'
            ELSE 'transfer_operation'
        END,
        CASE WHEN m.is_outgoing THEN 'outgoing' ELSE 'incoming' END,
        m.hive_nai,
        m.hbd_nai,
        m.vests_nai,
        m.op_count
    FROM (
        SELECT
            f.account_id,
            DATE_TRUNC('month', f.day)::DATE AS month,
            f.op_type_id,
            f.is_outgoing,
            SUM(f.hive_nai)::BIGINT  AS hive_nai,
            SUM(f.hbd_nai)::BIGINT   AS hbd_nai,
            SUM(f.vests_nai)::BIGINT AS vests_nai,
            SUM(f.op_count)::BIGINT  AS op_count
        FROM haf_stats_backend.account_financial_daily f
        WHERE f.op_type_id IN (_author_reward_id, _curation_reward_id, _transfer_id)
          AND f.day >= _month_lo
          AND (_hi IS NULL OR f.day <= _hi)
        GROUP BY f.account_id, DATE_TRUNC('month', f.day)::DATE, f.op_type_id, f.is_outgoing
    ) m
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
-- Single pass: one INSERT … SELECT over the batch's staged financial ops
-- (prepare_batch_ops, db/process_block_range.sql), joined to a VALUES list of impact rules
-- that fans each op out into one row per affected account and direction, in the normalized
-- shape (account_id, day, op_type_id, is_outgoing, hive_nai, hbd_nai, vests_nai, 1), with 0 in
-- the amount columns it doesn't touch. The outer GROUP BY does all
-- aggregation, collapsing every same-key row before the INSERT — so a single
-- uniform ON CONFLICT can sum the three amount columns, and the
-- "ON CONFLICT DO UPDATE cannot affect row a second time" error (which fires
-- when two source rows target the same conflict key) cannot occur.
--
-- category = the op's type (served as its canonical Hive operation type name, stored as its
-- id); direction = incoming/outgoing (stored as is_outgoing). Aligns with the block explorer's
-- ops vocabulary, haf_stats issue #26.
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
-- SCAN SOURCE: the staged rows, which prepare_batch_ops reads from hafd.operations by
-- operation-id range once per batch for every processor. A direct call (rebuild_financial.sh)
-- stages only the fifteen types below.
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

PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block, ARRAY[
    _author_reward_id, _comment_benefactor_reward_id, _curation_reward_id, _claim_reward_balance_id,
    _interest_id, _transfer_id, _transfer_to_savings_id, _transfer_from_savings_id,
    _fill_transfer_from_savings_id, _transfer_to_vesting_id, _fill_vesting_withdraw_id,
    _producer_reward_id, _liquidity_reward_id, _proposal_pay_id, _fill_order_id
]);

INSERT INTO haf_stats_backend.account_financial_daily
    (account_id, day, op_type_id, is_outgoing, hive_nai, hbd_nai, vests_nai, op_count)
SELECT
    account_id,
    day,
    op_type_id,
    is_outgoing,
    SUM(hive_nai)::BIGINT,
    SUM(hbd_nai)::BIGINT,
    SUM(vests_nai)::BIGINT,
    SUM(op_count)::INT
FROM (
    SELECT
        a.id AS account_id,
        o.day,
        o.op_type_id,
        r.is_outgoing,
        COALESCE((o.body_value -> r.hive_field  ->> 'amount')::BIGINT, 0)
        + CASE WHEN (o.body_value -> r.split_field ->> 'nai') = '@@000000021'
               THEN COALESCE((o.body_value -> r.split_field ->> 'amount')::BIGINT, 0) ELSE 0 END AS hive_nai,
        COALESCE((o.body_value -> r.hbd_field   ->> 'amount')::BIGINT, 0)
        + CASE WHEN (o.body_value -> r.split_field ->> 'nai') = '@@000000013'
               THEN COALESCE((o.body_value -> r.split_field ->> 'amount')::BIGINT, 0) ELSE 0 END AS hbd_nai,
        COALESCE((o.body_value -> r.vests_field ->> 'amount')::BIGINT, 0)
        + CASE WHEN (o.body_value -> r.split_field ->> 'nai') = '@@000000037'
               THEN COALESCE((o.body_value -> r.split_field ->> 'amount')::BIGINT, 0) ELSE 0 END AS vests_nai,
        1 AS op_count
    FROM haf_stats_batch_ops o
    JOIN (VALUES
        -- One row per impact. An op fans out into every row of its type: transfer into two,
        -- fill_order into four. party_field names the account; hive/hbd/vests_field the asset
        -- that column takes whatever its NAI; split_field the asset whose NAI picks the column
        -- (@@000000021 HIVE, @@000000013 HBD, @@000000037 VESTS). A split asset only ever
        -- carries two of the three: transfers, savings and the internal market move HIVE or
        -- HBD, and a vesting withdrawal deposits HIVE or VESTS.
        -- 1. Author rewards: incoming for the post author.
        (_author_reward_id,              FALSE, 'author',        'hive_payout',  'hbd_payout', 'vesting_payout', NULL),
        -- 2. Comment benefactor rewards: incoming for the benefactor.
        (_comment_benefactor_reward_id,  FALSE, 'benefactor',    'hive_payout',  'hbd_payout', 'vesting_payout', NULL),
        -- 3. Curation rewards: incoming for the curator (VESTS only).
        (_curation_reward_id,            FALSE, 'curator',       NULL,           NULL,         'reward',         NULL),
        -- 4. Claim reward balance: incoming for the claiming account.
        (_claim_reward_balance_id,       FALSE, 'account',       'reward_hive',  'reward_hbd', 'reward_vests',   NULL),
        -- 5. HBD savings interest: incoming for the account owner (HBD only).
        (_interest_id,                   FALSE, 'owner',         NULL,           'interest',   NULL,             NULL),
        -- 6-7. Transfers: outgoing for the sender, incoming for the receiver.
        (_transfer_id,                   TRUE,  'from',          NULL,           NULL,         NULL,             'amount'),
        (_transfer_id,                   FALSE, 'to',            NULL,           NULL,         NULL,             'amount'),
        -- 8. Transfer to savings: outgoing for the sender.
        (_transfer_to_savings_id,        TRUE,  'from',          NULL,           NULL,         NULL,             'amount'),
        -- 9. Transfer from savings (the request): outgoing for the sender.
        (_transfer_from_savings_id,      TRUE,  'from',          NULL,           NULL,         NULL,             'amount'),
        -- 10. Fill transfer from savings: incoming for the receiver.
        (_fill_transfer_from_savings_id, FALSE, 'to',            NULL,           NULL,         NULL,             'amount'),
        -- 11. Power up (transfer_to_vesting): outgoing for the initiator (HIVE spent).
        (_transfer_to_vesting_id,        TRUE,  'from',          'amount',       NULL,         NULL,             NULL),
        -- 12. Power down (fill_vesting_withdraw): incoming for the deposit recipient.
        -- `deposited` is credited to to_account (usually == from_account, but a
        -- withdrawal route can send it elsewhere) and may be HIVE (normal power-down)
        -- or VESTS (route that re-vests). `withdrawn` is the from_account's own VESTS
        -- leaving its vesting balance, not a value inflow, so it is not recorded here.
        (_fill_vesting_withdraw_id,      FALSE, 'to_account',    NULL,           NULL,         NULL,             'deposited'),
        -- 13. Witness pay (producer_reward): incoming for the block producer (VESTS only).
        (_producer_reward_id,            FALSE, 'producer',      NULL,           NULL,         'vesting_shares', NULL),
        -- 14. Liquidity reward: incoming for the owner (HIVE only).
        (_liquidity_reward_id,           FALSE, 'owner',         'payout',       NULL,         NULL,             NULL),
        -- 15. Proposal pay (DHF): incoming for the proposal receiver (HBD only).
        (_proposal_pay_id,               FALSE, 'receiver',      NULL,           'payment',    NULL,             NULL),
        -- 16-19. Fill order: each owner pays one side and receives the other.
        (_fill_order_id,                 TRUE,  'current_owner', NULL,           NULL,         NULL,             'current_pays'),
        (_fill_order_id,                 FALSE, 'current_owner', NULL,           NULL,         NULL,             'open_pays'),
        (_fill_order_id,                 TRUE,  'open_owner',    NULL,           NULL,         NULL,             'open_pays'),
        (_fill_order_id,                 FALSE, 'open_owner',    NULL,           NULL,         NULL,             'current_pays')
    ) AS r (op_type_id, is_outgoing, party_field, hive_field, hbd_field, vests_field, split_field)
        ON r.op_type_id = o.op_type_id
    JOIN hafd.accounts a ON a.name = (o.body_value ->> r.party_field)

) impacts
GROUP BY account_id, day, op_type_id, is_outgoing
ON CONFLICT (account_id, day, op_type_id, is_outgoing) DO UPDATE SET
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

    -- During massive sync, recorded instead (see defer_rollup_refresh, db/haf_stats_app.sql).
    IF NOT haf_stats_app.defer_rollup_refresh('process_financial', _first_day) THEN
        -- Timed when haf_stats.processor_timings is on (db/process_block_range.sql).
        _timed := current_setting('haf_stats.processor_timings', TRUE) = 'on';
        IF _timed THEN _t := clock_timestamp(); END IF;
        PERFORM haf_stats_app.refresh_financial_monthly(_first_day, _last_day);
        IF _timed THEN _t := haf_stats_app.report_processor_timing('refresh_financial_monthly', _first_block, _last_block, _t, '{}', 'process_financial'); END IF;
    END IF;
END IF;

END;
$$;

RESET ROLE;
