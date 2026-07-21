-- CI test setup for haf_stats — plain postgres (no HAF required).
-- Runs before seed_data.sql and endpoint_schema.sql.
-- Creates hafd stubs, roles, schemas, backend tables, and default privileges.

-- ---------------------------------------------------------------------------
-- hafd stub schema — minimal tables used by endpoint functions at runtime
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS hafd;
CREATE SCHEMA IF NOT EXISTS hive;

-- hafd.accounts: referenced by get_account_financial_summary and
-- get_account_rc_footprint (JOIN on account_id / filter on name).
CREATE TABLE IF NOT EXISTS hafd.accounts (
    id BIGINT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- hafd.operation_types: referenced by get_account_rc_footprint and
-- get_network_rc_utilization (LEFT JOIN for op type name).
CREATE TABLE IF NOT EXISTS hafd.operation_types (
    id INT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    is_virtual BOOLEAN NOT NULL DEFAULT FALSE
);

-- hafd.blocks: referenced by get_network_hp_distribution for VESTS/HP ratio.
-- total_vesting_shares and total_vesting_fund_hive must exist as columns even
-- though the table is empty (column resolution happens at call time in plpgsql).
CREATE TABLE IF NOT EXISTS hafd.blocks (
    num INT PRIMARY KEY,
    created_at TIMESTAMP NOT NULL,
    total_vesting_shares BIGINT NOT NULL DEFAULT 0,
    total_vesting_fund_hive BIGINT NOT NULL DEFAULT 0
);

-- hafd.operation_id(block, op_in_block): a monotonic op id whose ordering tracks
-- block number, so the half-open [operation_id(first,0), operation_id(last+1,0))
-- range selects exactly a block range (mirrors real HAF's block-packed ids).
CREATE OR REPLACE FUNCTION hafd.operation_id(_block INT, _op INT)
RETURNS BIGINT LANGUAGE sql IMMUTABLE AS $$
    SELECT _block::BIGINT * 1000000 + _op
$$;

-- Minimal HAF operation relations used by process_account_cohorts.sql.
-- Balance tracker mocks insert parsed operation values into hafd.operations.body_value;
-- keep the haf_stats stub shaped the same way and expose hive.operations_view as the
-- HAF-style read view that processors scan.
CREATE TABLE IF NOT EXISTS hafd.operations (
    id BIGINT PRIMARY KEY,
    op_type_id INT NOT NULL,
    body_value JSONB NOT NULL
);

CREATE OR REPLACE VIEW hive.operations_view AS
SELECT
    id,
    (id / 1000000)::INT AS block_num,
    op_type_id,
    JSONB_BUILD_OBJECT('value', body_value) AS body,
    body_value
FROM hafd.operations;

CREATE TABLE IF NOT EXISTS hive.account_operations_view (
    account_id INT NOT NULL,
    transacting_account_id INT NOT NULL,
    block_num INT NOT NULL,
    op_type_id SMALLINT NOT NULL,   -- SMALLINT in real HAF; rc_avg_cost(SMALLINT, DATE) needs it
    account_op_seq_no BIGINT,   -- nullable: existing stub rows (cohort/content) do not set it
    operation_id BIGINT   -- links to hive.operations_view.id; set only where a test needs the
                          -- op body (get_account_rc_footprint_timeline reads the custom_json id)
);

-- Stubs of the HAF helpers process_account_cohorts (Step 2) and
-- process_active_users rely on. The real HAF schema provides these; the CI stub
-- stack reproduces just enough for the synthetic cohort fixture to exercise the
-- real processor path.

-- hive.accounts_view: name -> id resolution (real HAF view over hafd.accounts).
CREATE OR REPLACE VIEW hive.accounts_view AS
    SELECT id, name FROM hafd.accounts;

-- hive.get_required_authorities(body): real HAF returns the accounts that had to
-- sign an operation. The stub resolves the synthetic '_signer' field the cohort
-- fixture sets on its operation bodies (authorless ops yield no row).
CREATE OR REPLACE FUNCTION hive.get_required_authorities(_body JSONB)
RETURNS TABLE(account_name TEXT) LANGUAGE sql IMMUTABLE AS $$
    SELECT _body -> 'value' ->> '_signer'
    WHERE _body -> 'value' ? '_signer'
$$;

-- Seed one known account so financial summary tests can JOIN without erroring.
INSERT INTO hafd.accounts (id, name) VALUES (1, 'hiveio') ON CONFLICT DO NOTHING;
INSERT INTO hafd.accounts (id, name) VALUES (2001, 'dapptester') ON CONFLICT DO NOTHING;
INSERT INTO hafd.accounts (id, name) VALUES (3001, 'rctester') ON CONFLICT DO NOTHING;
INSERT INTO hafd.accounts (id, name) VALUES (4001, 'cattester') ON CONFLICT DO NOTHING;

-- Op type names for the get_network_rc_utilization + get_account_rc_footprint synthetic tests
-- (seeded here, before SET ROLE haf_stats_owner, as the hafd.operation_types stub is not owned
-- by that role). vote_operation uses id 1 to match cohort_fixture.sql (which also seeds it);
-- ON CONFLICT (id) keeps both inserts idempotent regardless of load order. Op 64 is a virtual
-- op, present so the rc-footprint test proves virtual ops are excluded. transfer_operation (2) is
-- a NON-virtual type that no fixture account signs, so get_account_rc_footprint_timeline's
-- op_type_filter test can exercise the resolved-op-type + zero-rows path (a valid type the
-- account has no events of) rather than the unknown-type short-circuit.
INSERT INTO hafd.operation_types (id, name, is_virtual) VALUES
(1, 'hive::protocol::vote_operation', FALSE),
(2, 'hive::protocol::transfer_operation', FALSE),
(18, 'hive::protocol::custom_json_operation', FALSE),
(64, 'hive::protocol::producer_reward_operation', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Blocks for the get_account_rc_footprint synthetic test (March 2021; nums chosen above the
-- other fixtures' blocks). The endpoint maps the requested date range to a block range, then
-- maps each op's block back to its day. Vesting columns mirror block 2000 so these (now the
-- highest-num blocks) leave get_network_hp_distribution's VESTS/HP ratio unchanged.
INSERT INTO hafd.blocks (num, created_at, total_vesting_shares, total_vesting_fund_hive) VALUES
-- June 2020 block so get_account_rc_footprint can map the dapptester app-merge test's
-- date range to a block range (see the dapptester op-view rows below). Vesting mirrors
-- the others, so get_network_hp_distribution's ratio is unchanged.
(4000, '2020-06-01 00:00:00', 1000000000, 1000000000),
(5000, '2021-03-01 00:00:00', 1000000000, 1000000000),
(5001, '2021-03-01 00:01:00', 1000000000, 1000000000),
(6000, '2021-03-10 00:00:00', 1000000000, 1000000000)
ON CONFLICT (num) DO NOTHING;

-- Account-operations fixtures for get_account_rc_footprint + get_account_rc_footprint_timeline
-- (rctester, id 3001), in hive.account_operations_view (the global view the endpoints read). They
-- count ops the account SIGNED (account_id = transacting_account_id). vote (op 1) avg_cost =
-- 97,278,897, custom_json (op 18) avg_cost = 167,828,015 (latest rate on/before 2021-03 = the
-- 2020-06-08 row). Blocks 5000-6000 sit well outside the cohort fixture's 1000-1005 range, so
-- process_account_cohorts does not see them. account_op_seq_no must be dense AND monotonic with
-- block_num per account (real HAF assigns it in chain order): account_op_seq_range's binary search
-- and the timeline's seq-ordered paging both depend on that. operation_id is set on the two
-- custom_json rows so get_account_rc_footprint_timeline can resolve their app id from
-- hive.operations_view (see the hafd.operations seed below); it encodes block 5000 as
-- hafd.operation_id(5000, seq) = 5000*1e6 + seq. Other rows leave it NULL (the timeline only
-- body-joins op 18).
INSERT INTO hive.account_operations_view
(account_id, transacting_account_id, block_num, op_type_id, account_op_seq_no, operation_id)
VALUES
-- block 5000 (2021-03-01 00:00), in chain order: 2 signed votes, 2 signed custom_json,
-- then 1 received vote and 1 virtual producer_reward (both EXCLUDED by the endpoints)
(3001, 3001, 5000, 1, 1, NULL),
(3001, 3001, 5000, 1, 2, NULL),
(3001, 3001, 5000, 18, 3, 5000000003),
(3001, 3001, 5000, 18, 4, 5000000004),
(3001, 9999, 5000, 1, 5, NULL),    -- received vote (transacting <> account) -> EXCLUDED
(3001, 3001, 5000, 64, 6, NULL),   -- virtual producer_reward (op 64) -> EXCLUDED
-- block 5001 (2021-03-01 00:01): 1 signed vote
(3001, 3001, 5001, 1, 7, NULL),
-- block 6000 (2021-03-10): 1 signed vote
(3001, 3001, 6000, 1, 8, NULL)
ON CONFLICT DO NOTHING;
-- Signed window totals (unchanged; only the seq numbering changed): 4 votes -> 4*97278897 =
-- 389115588, 2 custom_json -> 2*167828015 = 335656030.

-- Operation bodies for rctester's two custom_json events, so get_account_rc_footprint_timeline can
-- read their json id from hive.operations_view (body -> 'value' ->> 'id') = 'sm_claim_daily'. The
-- timeline exposes both the resolved DApp name (app: 'sm_' -> 'Splinterlands' via seed_data's
-- custom_json_app_registry, matching the aggregate group_by=app) and the raw id (custom_json_id).
INSERT INTO hafd.operations (id, op_type_id, body_value) VALUES
(5000000003, 18, '{"id": "sm_claim_daily"}'),
(5000000004, 18, '{"id": "sm_claim_daily"}')
ON CONFLICT (id) DO NOTHING;

-- dapptester (2001) needs a valid signed-op window or get_account_rc_footprint short-circuits
-- to [] (it RETURNs early when the account has no ops in account_operations_view). Two op-18
-- (custom_json) rows in the June 2020 block establish the seq range; op 18 is excluded from the
-- non-custom_json bucket, so the group_by=app result is purely the resolved custom_json apps
-- from dapptester's account_custom_json_daily seed (the merge/fallback fixture). These rows only
-- bound the read window; the per-app op/RC totals come from account_custom_json_daily.
INSERT INTO hive.account_operations_view
(account_id, transacting_account_id, block_num, op_type_id, account_op_seq_no)
VALUES
(2001, 2001, 4000, 18, 1),
(2001, 2001, 4000, 18, 2)
ON CONFLICT DO NOTHING;

-- cattester (4001) drives get_account_rc_footprint_timeline's category_filter drill-down where a
-- single category spans MULTIPLE DApps (so app must be resolved PER ROW, not held constant) and
-- the Uncategorized fallback. Three signed custom_json events in block 4000 (2020-06-01), each a
-- different json_id: sm_claim_daily -> Splinterlands and risingstar -> Rising Star (BOTH Gaming),
-- and mystery_cat -> Uncategorized. account_op_seq_no is dense + monotonic with block; the timeline
-- orders by it DESC, so the resolved-app assertions ride seq 3 (mystery_cat) > 2 (risingstar) > 1
-- (sm_claim_daily). operation_id encodes block 4000: hafd.operation_id(4000, seq) = 4000*1e6 + seq.
INSERT INTO hive.account_operations_view
(account_id, transacting_account_id, block_num, op_type_id, account_op_seq_no, operation_id)
VALUES
(4001, 4001, 4000, 18, 1, 4000000001),
(4001, 4001, 4000, 18, 2, 4000000002),
(4001, 4001, 4000, 18, 3, 4000000003)
ON CONFLICT DO NOTHING;

INSERT INTO hafd.operations (id, op_type_id, body_value) VALUES
(4000000001, 18, '{"id": "sm_claim_daily"}'),
(4000000002, 18, '{"id": "risingstar"}'),
(4000000003, 18, '{"id": "mystery_cat"}')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Roles (simplified — no haf_admin / HAF group dependencies)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_owner') THEN
        CREATE ROLE haf_stats_owner NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_user') THEN
        CREATE ROLE haf_stats_user NOLOGIN NOINHERIT;
    END IF;
END
$$;
GRANT haf_stats_user TO haf_stats_owner;

-- hafd stub access for the anon role (endpoint functions read from hafd.*)
GRANT USAGE ON SCHEMA hafd TO haf_stats_user;
GRANT SELECT ON ALL TABLES IN SCHEMA hafd TO haf_stats_user;

-- haf_stats_owner needs USAGE+SELECT on hafd so LANGUAGE sql function bodies
-- that reference hafd.* can be validated at creation time. plpgsql defers
-- validation to call time; sql validates immediately and fails without access.
GRANT USAGE ON SCHEMA hafd TO haf_stats_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA hafd TO haf_stats_owner;
GRANT USAGE ON SCHEMA hive TO haf_stats_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA hive TO haf_stats_owner;
-- get_account_rc_footprint reads hive.account_operations_view on-demand as haf_stats_user;
-- get_account_rc_footprint_timeline additionally body-joins hive.operations_view for the
-- custom_json app id. In production HAF grants haf_stats_user SELECT on these hive views; the
-- stub has no HAF framework, so grant them here (the aggregate needed only the first).
GRANT USAGE ON SCHEMA hive TO haf_stats_user;
GRANT SELECT ON hive.account_operations_view TO haf_stats_user;
GRANT SELECT ON hive.operations_view TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Schemas
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS haf_stats_app AUTHORIZATION haf_stats_owner;
CREATE SCHEMA IF NOT EXISTS haf_stats_backend AUTHORIZATION haf_stats_owner;
CREATE SCHEMA IF NOT EXISTS haf_stats_endpoints AUTHORIZATION haf_stats_owner;
GRANT USAGE ON SCHEMA haf_stats_app TO haf_stats_user;
GRANT USAGE ON SCHEMA haf_stats_backend TO haf_stats_user;
GRANT USAGE ON SCHEMA haf_stats_endpoints TO haf_stats_user;

-- Default privileges cover objects created by haf_stats_owner after this point.
ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_app
    GRANT SELECT ON TABLES TO haf_stats_user;
ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_backend
    GRANT SELECT ON TABLES TO haf_stats_user;
ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_endpoints
    GRANT EXECUTE ON FUNCTIONS TO haf_stats_user;

-- Fixtures for the get_network_hp_distribution exact-value tavern test (#28). The
-- endpoint auto-detects the first readable balance relation and converts VESTS to HP
-- via the LATEST hafd.blocks ratio: r = total_vesting_shares * 1000 / total_vesting_fund_hive.
-- With shares=1e9 and fund=1e9, r = 1000 (1 HP = 1000 VESTS). Created as superuser and
-- granted to haf_stats_user so the endpoint (run via PostgREST as that role) resolves it.
-- num must exceed cohort_fixture.sql's blocks (1000-1005, loaded into the stub AFTER this
-- file with vesting columns defaulting to 0); otherwise the ratio CTE's
-- "ORDER BY num DESC LIMIT 1" would pick a cohort block and the ratio would be NULL.
INSERT INTO hafd.blocks (num, created_at, total_vesting_shares, total_vesting_fund_hive)
VALUES (2000, '2020-05-01 00:00:00', 1000000000, 1000000000)
ON CONFLICT (num) DO NOTHING;

CREATE SCHEMA IF NOT EXISTS btracker_app;
CREATE TABLE IF NOT EXISTS btracker_app.current_account_balances (
    account TEXT     NOT NULL,
    nai     SMALLINT NOT NULL,
    balance BIGINT   NOT NULL,
    PRIMARY KEY (account, nai)
);
GRANT USAGE ON SCHEMA btracker_app TO haf_stats_user;
GRANT SELECT ON btracker_app.current_account_balances TO haf_stats_user;

-- VESTS balances (nai 37). r=1000 so HP = balance / 1000. Two accounts land in the
-- unbounded 1M+ bucket with DIFFERENT sizes, so its total_hp (5,000,000 = 2M + 3M) can
-- only be the exact sum, proving no midpoint estimate (#28).
INSERT INTO btracker_app.current_account_balances (account, nai, balance)
VALUES
    ('small1',  37,         50000),  -- 50 HP        -> 10-100 HP
    ('mid1',    37,       4950000),  -- 4,950 HP     -> 1K-10K HP
    ('whale1',  37,    2000000000),  -- 2,000,000 HP -> 1M+ HP
    ('whale2',  37,    3000000000),  -- 3,000,000 HP -> 1M+ HP
    ('hbd1',    13,    9999999999)   -- non-VESTS (nai 13) -> ignored by the WHERE nai = 37
ON CONFLICT DO NOTHING;

SET ROLE haf_stats_owner;

-- Crash-safe authority wrapper (mirrors db/haf_stats_app.sql). The stub stack does
-- not load haf_stats_app.sql, but process_account_cohorts now calls this wrapper, so
-- it must exist here too. The stub hive.get_required_authorities above never throws,
-- so in CI this is a transparent pass-through.
CREATE OR REPLACE FUNCTION haf_stats_app.get_required_authorities_safe(_body JSONB)
RETURNS TABLE (account_name TEXT)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY SELECT ra.account_name FROM hive.get_required_authorities(_body) ra;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$;

-- ---------------------------------------------------------------------------
-- App control tables (from haf_stats_app.sql, minus HAF lifecycle calls)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_app.app_status (
    continue_processing BOOL NOT NULL DEFAULT TRUE,
    last_processed_block INT NOT NULL DEFAULT 0
);
INSERT INTO haf_stats_app.app_status VALUES (TRUE, 0);

CREATE TABLE IF NOT EXISTS haf_stats_app.app_version (
    git_hash TEXT NOT NULL
);
INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('ci-test');

-- ---------------------------------------------------------------------------
-- Backend tables (from process_financial.sql, process_rc.sql,
-- process_account_cohorts.sql, process_content_stats.sql)
-- ---------------------------------------------------------------------------

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

CREATE TABLE IF NOT EXISTS haf_stats_backend.custom_json_app_registry (
    app_id_pattern TEXT NOT NULL PRIMARY KEY,
    app_name TEXT NOT NULL,
    category TEXT NOT NULL,
    homepage TEXT
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_cohort_members (
    account_id INT PRIMARY KEY,
    cohort_month DATE NOT NULL,
    created_at TIMESTAMP NOT NULL,
    active_7d BOOLEAN NOT NULL DEFAULT FALSE,
    active_30d BOOLEAN NOT NULL DEFAULT FALSE,
    active_90d BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_cohort_retention (
    cohort_month DATE PRIMARY KEY,
    new_accounts INT NOT NULL DEFAULT 0,
    eligible_at_7d INT,
    active_at_7d INT,
    eligible_at_30d INT,
    active_at_30d INT,
    eligible_at_90d INT,
    active_at_90d INT
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.author_cohort_retention (
    cohort_month DATE PRIMARY KEY,
    first_post_accounts INT NOT NULL DEFAULT 0,
    eligible_at_30d INT,
    active_at_30d INT,
    eligible_at_90d INT,
    active_at_90d INT,
    eligible_at_180d INT,
    active_at_180d INT
);

-- Daily active users (process_active_users.sql)
CREATE TABLE IF NOT EXISTS haf_stats_backend.active_users_daily (
    day DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    account_id INT NOT NULL,
    ops INT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_class, account_id)
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.active_user_ops_daily (
    day DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    operations BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_class)
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.active_users_period_counts (
    period_type TEXT NOT NULL,
    period DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    active_accounts BIGINT NOT NULL DEFAULT 0,
    operations BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (period_type, op_class, period)
);

-- Fixtures for the get_daily_active_users exact-value tavern tests.
-- Fast path (ALL / single class) reads active_users_period_counts directly.
INSERT INTO haf_stats_backend.active_users_period_counts (period_type, period, op_class, active_accounts, operations)
VALUES
    ('month', '2020-01-01', -1, 100, 5000),
    ('month', '2020-02-01', -1, 150, 6000)
ON CONFLICT DO NOTHING;

-- Fallback fixture (multi-class re-aggregation): a post+vote query with to_date mid-February
-- must still return the FULL February - accounts active after the 15th are included and an
-- account active in both classes counts once. op_class 1 = post, 3 = vote.
INSERT INTO haf_stats_backend.active_users_daily (day, op_class, account_id, ops)
VALUES
    ('2020-02-10', 1, 1001, 1), ('2020-02-10', 3, 1001, 1),
    ('2020-02-20', 1, 1002, 1),
    ('2020-02-20', 3, 1003, 1)
ON CONFLICT DO NOTHING;
INSERT INTO haf_stats_backend.active_user_ops_daily (day, op_class, operations)
VALUES
    ('2020-02-10', 1, 1), ('2020-02-10', 3, 1), ('2020-02-20', 1, 1), ('2020-02-20', 3, 1)
ON CONFLICT DO NOTHING;

-- get_network_top_accounts source tables (mirror db/process_*.sql + process_top_accounts_alltime.sql,
-- not loaded by the stub). The monthly rollups are created EMPTY: they must exist so the endpoint's
-- bounded-range (NOT _alltime) arms plan, but the no-date default test hits the all-time fast path,
-- which reads the two all-time tables seeded below. Value tests for bounded ranges are patterntest-
-- only (real replay); the synthetic gate exercises only the no-filter all-time path (#38).
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

CREATE TABLE IF NOT EXISTS haf_stats_backend.active_users_account_monthly (
    month DATE NOT NULL,
    op_class SMALLINT NOT NULL,
    account_id INT NOT NULL,
    ops BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (month, op_class, account_id)
);

-- All-time per-account aggregates (#38): the no-filter (genesis..today) leaderboard reads these
-- pre-summed tables. Seeded as refresh_top_accounts_alltime() would produce, over accounts that
-- exist in hafd.accounts above (1 hiveio, 2001 dapptester, 3001 rctester).
CREATE TABLE IF NOT EXISTS haf_stats_backend.account_txn_alltime (
    account_id INT NOT NULL PRIMARY KEY,
    ops BIGINT NOT NULL DEFAULT 0
);
INSERT INTO haf_stats_backend.account_txn_alltime (account_id, ops)
VALUES (1, 100), (2001, 250), (3001, 50)
ON CONFLICT DO NOTHING;

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
INSERT INTO haf_stats_backend.account_financial_alltime
    (account_id, category, direction, hive_nai, hbd_nai, vests_nai, op_count)
VALUES
    (1,    'author_reward_operation', 'incoming', 0, 100, 5000, 10),
    (2001, 'author_reward_operation', 'incoming', 0, 200, 3000, 20),
    (3001, 'author_reward_operation', 'incoming', 0, 300, 8000, 30)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_content_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    posts INT NOT NULL DEFAULT 0,
    comments INT NOT NULL DEFAULT 0,
    votes_cast INT NOT NULL DEFAULT 0,
    votes_received INT NOT NULL DEFAULT 0,
    replies_received INT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day)
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.comment_registry (
    author_id INT  NOT NULL,
    permlink  TEXT NOT NULL,
    PRIMARY KEY (author_id, permlink)
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_content_daily (
    day      DATE NOT NULL,
    posts    INT  NOT NULL DEFAULT 0,
    comments INT  NOT NULL DEFAULT 0,
    edits    INT  NOT NULL DEFAULT 0,
    PRIMARY KEY (day)
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_author_daily (
    day       DATE NOT NULL,
    author_id INT  NOT NULL,
    PRIMARY KEY (day, author_id)
);

-- get_network_content_volume reads this rollup directly (mirrors process_content_stats.sql,
-- not loaded by the stub). Value tests stay patterntest-only (real replay); the fast stub gate
-- exercises its param/negative paths plus the #35 no-date default test, which needs one
-- historical period seeded below so a genesis default returns it while the old NOW()-30d
-- default would not.
CREATE TABLE IF NOT EXISTS haf_stats_backend.network_content_period_counts (
    period_type    TEXT   NOT NULL,
    period         DATE   NOT NULL,
    posts          BIGINT NOT NULL DEFAULT 0,
    comments       BIGINT NOT NULL DEFAULT 0,
    unique_authors BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (period_type, period)
);

-- One historical month (+ its days) for the get_network_content_volume no-date default test
-- (#35): a genesis default rolls 2016-03 in; the old last-30-days default returns []. Mirrors the
-- engagement_period_counts / post_engagement 2016-03 fixture below. unique_authors = 1 across the
-- 3 days shows the non-additive author count (hiveio active 3 days = 1 unique in the month).
INSERT INTO haf_stats_backend.network_content_period_counts
    (period_type, period, posts, comments, unique_authors)
VALUES
    ('day',   '2016-03-15', 1, 2, 1),
    ('day',   '2016-03-16', 1, 1, 1),
    ('day',   '2016-03-17', 1, 2, 1),
    ('month', '2016-03-01', 3, 5, 1)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_vote_daily (
    day        DATE NOT NULL,
    upvotes    INT  NOT NULL DEFAULT 0,
    downvotes  INT  NOT NULL DEFAULT 0,
    unvotes    INT  NOT NULL DEFAULT 0,
    self_votes INT  NOT NULL DEFAULT 0,
    PRIMARY KEY (day)
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_voter_daily (
    day      DATE NOT NULL,
    voter_id INT  NOT NULL,
    PRIMARY KEY (day, voter_id)
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.network_vote_period_counts (
    period_type   TEXT   NOT NULL,
    period        DATE   NOT NULL,
    upvotes       BIGINT NOT NULL DEFAULT 0,
    downvotes     BIGINT NOT NULL DEFAULT 0,
    unvotes       BIGINT NOT NULL DEFAULT 0,
    self_votes    BIGINT NOT NULL DEFAULT 0,
    unique_voters BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (period_type, period)
);

-- Fixtures for the get_network_vote_stats exact-value tavern test. The endpoint reads
-- network_vote_period_counts directly; full-month values for Jan/Feb 2020 let a to_date
-- mid-February still return the FULL February (full-period bucketing). downvote_pct is
-- derived: 200 / (1000 + 200) * 100 = 16.67.
INSERT INTO haf_stats_backend.network_vote_period_counts
    (period_type, period, upvotes, downvotes, unvotes, self_votes, unique_voters)
VALUES
    ('month', '2020-01-01', 1000, 200, 50, 30, 400),
    ('month', '2020-02-01', 1500, 300, 60, 45, 550)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS haf_stats_backend.post_engagement (
    author_id   INT  NOT NULL,
    permlink    TEXT NOT NULL,
    post_day    DATE NOT NULL,
    vote_count  INT  NOT NULL DEFAULT 0,
    reply_count INT  NOT NULL DEFAULT 0,
    PRIMARY KEY (author_id, permlink)
);

-- Seed 3 posts for hiveio (id=1): mix of engaged and zero-engagement posts.
INSERT INTO haf_stats_backend.post_engagement
    (author_id, permlink, post_day, vote_count, reply_count)
VALUES
    (1, 'first-post',  '2016-03-15', 5, 2),
    (1, 'second-post', '2016-03-16', 0, 0),
    (1, 'third-post',  '2016-03-17', 3, 1)
ON CONFLICT DO NOTHING;

-- Engagement rollup (mirrors process_content_stats.sql, which the stub does not load, exactly
-- like network_vote_period_counts above). get_network_engagement reads engagement_period_counts
-- directly; the processor does not run here, so seed it as refresh_engagement_full() would from
-- the 3 posts: day rows (each post's creation day) + the 2016-03 month rollup (sums: votes
-- 5+0+3=8, replies 2+0+1=3; one zero-vote and one zero-reply post). Only this table is needed -
-- the endpoint reads nothing else (engagement_daily was removed; engagement_touched_days is
-- processor-internal), so no other engagement stubs are created here.
CREATE TABLE IF NOT EXISTS haf_stats_backend.engagement_period_counts (
    period_type        TEXT   NOT NULL,
    period             DATE   NOT NULL,
    total_posts        BIGINT NOT NULL DEFAULT 0,
    sum_votes          BIGINT NOT NULL DEFAULT 0,
    sum_replies        BIGINT NOT NULL DEFAULT 0,
    zero_vote_posts    BIGINT NOT NULL DEFAULT 0,
    zero_comment_posts BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (period_type, period)
);

INSERT INTO haf_stats_backend.engagement_period_counts
    (period_type, period, total_posts, sum_votes, sum_replies, zero_vote_posts, zero_comment_posts)
VALUES
    ('day',   '2016-03-15', 1, 5, 2, 0, 0),
    ('day',   '2016-03-16', 1, 0, 0, 1, 1),
    ('day',   '2016-03-17', 1, 3, 1, 0, 0),
    ('month', '2016-03-01', 3, 8, 3, 1, 1)
ON CONFLICT DO NOTHING;

-- DApp footprint stub: account_custom_json_daily + rc_op_stats_daily (mirror
-- db/process_custom_json.sql + db/process_rc.sql, which the stub does not load). The
-- endpoint stores RC inputs (op_count + op_bytes) and applies the rc_op_stats_daily rate at
-- read time (issue #32); app names + categories resolve from custom_json_app_registry.
CREATE TABLE IF NOT EXISTS haf_stats_backend.account_custom_json_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    json_id TEXT NOT NULL,
    op_count INT NOT NULL DEFAULT 0,
    op_bytes BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, json_id)
);
GRANT SELECT ON haf_stats_backend.account_custom_json_daily TO haf_stats_user;

CREATE TABLE IF NOT EXISTS haf_stats_backend.rc_op_stats_daily (
    day DATE NOT NULL,
    op_type_id SMALLINT NOT NULL,
    base_rc BIGINT NOT NULL,
    byte_rc NUMERIC NOT NULL,
    avg_cost_rc BIGINT,
    avg_bytes INTEGER,
    sample_count BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_type_id)
);
GRANT SELECT ON haf_stats_backend.rc_op_stats_daily TO haf_stats_user;

-- Per-day rate accessors (mirror db/process_rc.sql, which the stub does not load) - used by
-- get_account_rc_footprint on-demand.
CREATE OR REPLACE FUNCTION haf_stats_app.rc_avg_cost(_op_type_id SMALLINT, _day DATE)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT r.avg_cost_rc FROM haf_stats_backend.rc_op_stats_daily r
        WHERE r.op_type_id = _op_type_id
        ORDER BY (r.day <= _day) DESC, CASE WHEN r.day <= _day THEN r.day END DESC, r.day ASC
        LIMIT 1
    ), 120000000::BIGINT)
$$;
GRANT EXECUTE ON FUNCTION haf_stats_app.rc_avg_cost(SMALLINT, DATE) TO haf_stats_user;

CREATE OR REPLACE FUNCTION haf_stats_app.rc_rate(_op_type_id SMALLINT, _day DATE)
RETURNS TABLE (base_rc BIGINT, byte_rc NUMERIC) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(r.base_rc, 23428456::BIGINT), COALESCE(r.byte_rc, 475000::NUMERIC)
    FROM (SELECT 1) z(x)
    LEFT JOIN LATERAL (
        SELECT rr.base_rc, rr.byte_rc FROM haf_stats_backend.rc_op_stats_daily rr
        WHERE rr.op_type_id = _op_type_id
        ORDER BY (rr.day <= _day) DESC, CASE WHEN rr.day <= _day THEN rr.day END DESC, rr.day ASC
        LIMIT 1
    ) r ON TRUE
$$;
GRANT EXECUTE ON FUNCTION haf_stats_app.rc_rate(SMALLINT, DATE) TO haf_stats_user;

-- Block-range -> account_op_seq_no-range binary search (mirrors db/process_rc.sql) used by
-- get_account_rc_footprint. References hive.account_operations_view, seeded before SET ROLE.
CREATE OR REPLACE FUNCTION haf_stats_app.account_op_seq_range(_account_id INT, _from_block INT, _to_block INT)
RETURNS TABLE (lo_seq BIGINT, hi_seq BIGINT) LANGUAGE plpgsql STABLE AS $$
DECLARE _min BIGINT; _max BIGINT; _l BIGINT; _r BIGINT; _mid BIGINT; _blk INT; _lo BIGINT; _hi BIGINT;
BEGIN
    -- Two single-row index probes (not combined MIN+MAX, which degrades to a full per-account
    -- scan through the view's join filter on real data); mirrors db/process_rc.sql. (#40 review)
    SELECT account_op_seq_no INTO _min FROM hive.account_operations_view
        WHERE account_id = _account_id ORDER BY account_op_seq_no ASC LIMIT 1;
    SELECT account_op_seq_no INTO _max FROM hive.account_operations_view
        WHERE account_id = _account_id ORDER BY account_op_seq_no DESC LIMIT 1;
    IF _max IS NULL THEN RETURN; END IF;
    _l := _min; _r := _max;
    WHILE _l <= _r LOOP _mid := (_l + _r) / 2;
        SELECT block_num INTO _blk FROM hive.account_operations_view WHERE account_id = _account_id AND account_op_seq_no = _mid;
        IF _blk >= _from_block THEN _lo := _mid; _r := _mid - 1; ELSE _l := _mid + 1; END IF; END LOOP;
    _l := _min; _r := _max;
    WHILE _l <= _r LOOP _mid := (_l + _r) / 2;
        SELECT block_num INTO _blk FROM hive.account_operations_view WHERE account_id = _account_id AND account_op_seq_no = _mid;
        IF _blk <= _to_block THEN _hi := _mid; _l := _mid + 1; ELSE _r := _mid - 1; END IF; END LOOP;
    lo_seq := _lo; hi_seq := _hi; RETURN NEXT;
END; $$;
GRANT EXECUTE ON FUNCTION haf_stats_app.account_op_seq_range(INT, INT, INT) TO haf_stats_user;

-- Two dated test rates (custom_json, op_type 18) so the per-day read path is exercised:
-- a cheap early rate from 2020-06-01 (rc = op_count*100 + op_bytes*10) and a pricier one
-- from 2020-06-08 (rc = op_count*1000 + op_bytes*100). The endpoint prices each activity day
-- at the rate effective on/before it, so 06-01/06-05 ops use the early rate and 06-10 ops the
-- later one. Round numbers, distinct from production, so the expected arithmetic is explicit.
INSERT INTO haf_stats_backend.rc_op_stats_daily
(day, op_type_id, base_rc, byte_rc, avg_cost_rc, avg_bytes, sample_count)
VALUES
('2020-06-01', 18, 100, 10, 167828015, 304, 1),
('2020-06-08', 18, 1000, 100, 167828015, 304, 1)
ON CONFLICT DO NOTHING;

-- Fixtures for the get_account_dapp_footprint exact-value tavern test (account
-- dapptester, id 2001), all resolved via the seeded registry: sm_claim_daily + sm_battle
-- -> Splinterlands/Gaming (two ids rolling up to one app), ssc-mainnet-hive ->
-- Hive Engine (SSC)/DeFi, follow -> Hivemind Follow/Social Graph, mystery_app ->
-- Uncategorized. The '2020-07-01' row is outside the test range, proving the day filter
-- excludes it. Op totals: Gaming 30, DeFi 20, Social Graph 10, Uncategorized 5 = 65.
-- With the two dated rates above, RC shares diverge from op shares by BOTH payload size and
-- activity era: Gaming (06-01/06-05, cheap rate) = 25*100+200*10 + 5*100+100*10 = 6000; DeFi
-- (06-01, cheap) = 20*100+500*10 = 7000; Social Graph (06-10, pricey) = 10*1000+50*100 =
-- 15000; Uncategorized (06-10, pricey + big payload) = 5*1000+800*100 = 85000. Total 113000,
-- so Uncategorized is 7.69% of ops but 75.22% of estimated RC - proving per-day pricing.
INSERT INTO haf_stats_backend.account_custom_json_daily (account_id, day, json_id, op_count, op_bytes)
VALUES
    (2001, '2020-06-01', 'sm_claim_daily', 25, 200),
    (2001, '2020-06-05', 'sm_battle', 5, 100),
    (2001, '2020-06-01', 'ssc-mainnet-hive', 20, 500),
    (2001, '2020-06-10', 'follow', 10, 50),
    (2001, '2020-06-10', 'mystery_app', 5, 800),
    (2001, '2020-07-01', 'sm_market', 999, 9990)
ON CONFLICT DO NOTHING;

-- Network RC utilization stub: network_op_daily (mirrors db/process_network_ops.sql) + per-op
-- rates. Op type names are seeded into the hafd.operation_types stub earlier (before SET ROLE,
-- as that stub is not owned by haf_stats_owner). The endpoint prices each (op_type, day) at the
-- rate effective on/before that day and rolls up per period (issue #33).
CREATE TABLE IF NOT EXISTS haf_stats_backend.network_op_daily (
    day DATE NOT NULL,
    op_type_id SMALLINT NOT NULL,
    op_count BIGINT NOT NULL DEFAULT 0,
    op_bytes BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, op_type_id)
);
GRANT SELECT ON haf_stats_backend.network_op_daily TO haf_stats_user;

-- Vote (op 1) rates, two dated rows like the custom_json (op 18) rates above:
-- cheap from 2020-06-01 (rc = op_count*50 + op_bytes*5), pricey from 2020-06-08 (500 / 50).
INSERT INTO haf_stats_backend.rc_op_stats_daily
(day, op_type_id, base_rc, byte_rc, avg_cost_rc, avg_bytes, sample_count)
VALUES
('2020-06-01', 1, 50, 5, 97278897, 100, 1),
('2020-06-08', 1, 500, 50, 97278897, 100, 1)
ON CONFLICT DO NOTHING;

-- Network activity on two days spanning the rate boundary: 06-05 ops use the cheap rate,
-- 06-10 the pricey one. Per day, vote rc = count*base + bytes*byte, custom_json likewise.
--   06-05: vote 100*50+1000*5=10000, custom_json 20*100+200*10=4000 -> total 14000
--   06-10: vote  50*500+500*50=50000, custom_json 10*1000+100*100=20000 -> total 70000
INSERT INTO haf_stats_backend.network_op_daily (day, op_type_id, op_count, op_bytes)
VALUES
('2020-06-05', 1, 100, 1000),
('2020-06-05', 18, 20, 200),
('2020-06-10', 1, 50, 500),
('2020-06-10', 18, 10, 100)
ON CONFLICT DO NOTHING;

-- Network custom_json usage stub: network_custom_json_daily (mirrors
-- db/process_network_custom_json.sql), read by get_network_custom_json_usage and
-- get_network_top_custom_json. Keyed by the raw custom_json id, priced at read time by the
-- op-18 rc_op_stats_daily rates seeded above (2020-06-01: 100/10, 2020-06-08: 1000/100).
-- Rows are chosen so each day's (op_count, op_bytes) total equals the op-18 network_op_daily
-- row above (06-05 -> 20/200, 06-10 -> 10/100), demonstrating the cross-rollup invariant
-- SUM(network_custom_json_daily) == network_op_daily[op_type_id=18] per day. Ids resolve via
-- the seeded registry: follow -> Hivemind Follow/Social Graph, sm_claim_daily -> Splinterlands
-- (prefix sm_)/Gaming - so group_by=id/app/category all return distinct, deterministic rows.
CREATE TABLE IF NOT EXISTS haf_stats_backend.network_custom_json_daily (
    day DATE NOT NULL,
    json_id TEXT NOT NULL,
    op_count BIGINT NOT NULL DEFAULT 0,
    op_bytes BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (day, json_id)
);
GRANT SELECT ON haf_stats_backend.network_custom_json_daily TO haf_stats_user;

INSERT INTO haf_stats_backend.network_custom_json_daily (day, json_id, op_count, op_bytes)
VALUES
('2020-06-05', 'follow', 12, 120),
('2020-06-05', 'sm_claim_daily', 8, 80),
('2020-06-10', 'follow', 10, 100)
ON CONFLICT DO NOTHING;

-- (account-operations fixtures for rctester are seeded into hive.account_operations_view
-- before SET ROLE - that is the global view the endpoint reads.)

-- rctester custom_json for the group_by=app test: 2 sm_claim_daily ops on 2021-03-01,
-- priced by the op-18 base+byte rate effective then (2020-06-08: 1000/100) = 2*1000+200*100 = 22000.
INSERT INTO haf_stats_backend.account_custom_json_daily (account_id, day, json_id, op_count, op_bytes)
VALUES (3001, '2021-03-01', 'sm_claim_daily', 2, 200)
ON CONFLICT DO NOTHING;

-- cattester (4001) custom_json rollup: the per-json_id candidate set the timeline's
-- category_filter/app_filter resolve against (one row per json_id it signed in block 4000).
-- sm_claim_daily + risingstar both resolve to the Gaming category (two distinct DApps);
-- mystery_cat resolves to no registered app -> Uncategorized. Counts mirror the one op-18 event
-- each in account_operations_view; the timeline prices per event via rc_avg_cost, so these
-- op_count/op_bytes only gate the candidate-id fast path, not the returned rc_consumed.
INSERT INTO haf_stats_backend.account_custom_json_daily (account_id, day, json_id, op_count, op_bytes)
VALUES
    (4001, '2020-06-01', 'sm_claim_daily', 1, 100),
    (4001, '2020-06-01', 'risingstar', 1, 100),
    (4001, '2020-06-01', 'mystery_cat', 1, 100)
ON CONFLICT DO NOTHING;

RESET ROLE;
