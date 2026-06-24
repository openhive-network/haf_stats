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

-- Minimal HAF operation relations used by process_account_cohorts.sql.
-- id: operations carry a monotonic op id (real HAF packs the block number into
-- the high bits). process_account_cohorts range-scans it via hafd.operation_id.
CREATE TABLE IF NOT EXISTS hive.operations_view (
    id BIGINT,
    block_num INT NOT NULL,
    op_type_id INT NOT NULL,
    body JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS hive.account_operations_view (
    account_id INT NOT NULL,
    transacting_account_id INT NOT NULL,
    block_num INT NOT NULL,
    op_type_id INT NOT NULL
);

-- Stubs of the HAF helpers process_account_cohorts (Step 2) and
-- process_active_users rely on. The real HAF schema provides these; the CI stub
-- stack reproduces just enough for the synthetic cohort fixture to exercise the
-- real processor path.

-- hafd.operation_id(block, op_in_block): a monotonic op id whose ordering tracks
-- block number, so the half-open [operation_id(first,0), operation_id(last+1,0))
-- range selects exactly a block range (mirrors real HAF's block-packed ids).
CREATE OR REPLACE FUNCTION hafd.operation_id(_block INT, _op INT)
RETURNS BIGINT LANGUAGE sql IMMUTABLE AS $$
    SELECT _block::BIGINT * 1000000 + _op
$$;

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

CREATE TABLE IF NOT EXISTS haf_stats_backend.rc_operation_log (
    id BIGSERIAL PRIMARY KEY,
    block_num INT NOT NULL,
    account_id INT NOT NULL,
    op_type_id SMALLINT,
    custom_json_id TEXT,
    rc_cost BIGINT NOT NULL,
    "timestamp" TIMESTAMP NOT NULL
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
    active_at_7d INT,
    active_at_30d INT,
    active_at_90d INT
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

CREATE OR REPLACE VIEW haf_stats_backend.rc_op_rate_latest AS
SELECT DISTINCT ON (op_type_id)
    op_type_id, base_rc, byte_rc, avg_cost_rc, avg_bytes, day
FROM haf_stats_backend.rc_op_stats_daily
ORDER BY op_type_id, day DESC;
GRANT SELECT ON haf_stats_backend.rc_op_rate_latest TO haf_stats_user;

-- Round test rate (custom_json, op_type 18): rc = op_count*1000 + op_bytes*100. Distinct
-- from the production calibration so the expected arithmetic is self-contained.
INSERT INTO haf_stats_backend.rc_op_stats_daily
(day, op_type_id, base_rc, byte_rc, avg_cost_rc, avg_bytes, sample_count)
VALUES (CURRENT_DATE, 18, 1000, 100, 167828015, 304, 1)
ON CONFLICT DO NOTHING;

-- Fixtures for the get_account_dapp_footprint exact-value tavern test (account
-- dapptester, id 2001), all resolved via the seeded registry: sm_claim_daily + sm_battle
-- -> Splinterlands/Gaming (two ids rolling up to one app), ssc-mainnet-hive ->
-- Hive Engine (SSC)/DeFi, follow -> Hivemind Follow/Social Graph, mystery_app ->
-- Uncategorized. The '2020-07-01' row is outside the test range, proving the day filter
-- excludes it. Op totals: Gaming 30, DeFi 20, Social Graph 10, Uncategorized 5 = 65.
-- op_bytes is set so estimated-RC shares differ from op shares (mystery_app is op-light but
-- byte-heavy): with rc = op_count*1000 + op_bytes*100, category RC is Gaming 60000, DeFi
-- 70000, Social Graph 15000, Uncategorized 85000 = 230000 - so Uncategorized is 7.69% of
-- ops but 36.96% of estimated RC, proving the RC lens is read-time and size-driven.
INSERT INTO haf_stats_backend.account_custom_json_daily (account_id, day, json_id, op_count, op_bytes)
VALUES
    (2001, '2020-06-01', 'sm_claim_daily', 25, 200),
    (2001, '2020-06-05', 'sm_battle', 5, 100),
    (2001, '2020-06-01', 'ssc-mainnet-hive', 20, 500),
    (2001, '2020-06-10', 'follow', 10, 50),
    (2001, '2020-06-10', 'mystery_app', 5, 800),
    (2001, '2020-07-01', 'sm_market', 999, 9990)
ON CONFLICT DO NOTHING;

RESET ROLE;
