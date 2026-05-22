-- CI test setup for haf_stats — plain postgres (no HAF required).
-- Runs before seed_data.sql and endpoint_schema.sql.
-- Creates hafd stubs, roles, schemas, backend tables, and default privileges.

-- ---------------------------------------------------------------------------
-- hafd stub schema — minimal tables used by endpoint functions at runtime
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS hafd;

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
    name TEXT NOT NULL UNIQUE
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

-- Seed one known account so financial summary tests can JOIN without erroring.
INSERT INTO hafd.accounts (id, name) VALUES (1, 'hiveio') ON CONFLICT DO NOTHING;

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

SET ROLE haf_stats_owner;

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
-- process_account_cohorts.sql)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_backend.op_financial_categories (
    op_type_name TEXT NOT NULL PRIMARY KEY,
    direction TEXT NOT NULL CHECK (direction IN ('income', 'expense', 'neutral')),
    category TEXT NOT NULL,
    asset TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS haf_stats_backend.account_financial_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    category TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('income', 'expense')),
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

RESET ROLE;
