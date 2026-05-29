#!/bin/bash
# One-time schema installation. Run once against a live HAF database.
# Safe to re-run: all DDL uses IF NOT EXISTS / ON CONFLICT DO NOTHING.
#
# OPTIONS:
#   --swagger-url=URL   Public hostname for Swagger UI example URLs (default: localhost)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SWAGGER_URL="localhost"

for arg in "$@"; do
    case "$arg" in
        --swagger-url=*) SWAGGER_URL="${arg#*=}" ;;
    esac
done

wait_for_postgres

log "Installing haf_stats schema..."

# 1. Roles (must run as postgres superuser or haf_admin)
run_sql_file "${SCRIPT_DIR}/../db/builtin_roles.sql"

# 2. Schemas, control tables, lifecycle functions, main loop
run_sql_file "${SCRIPT_DIR}/../db/haf_stats_app.sql"

# 3. Block processors
run_sql_file "${SCRIPT_DIR}/../db/process_block_range.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_financial.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_rc.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_account_cohorts.sql"

# 4. Seed lookup tables (app registry + financial op categories)
run_sql_file "${SCRIPT_DIR}/../db/seed_data.sql"

# 5. API endpoints
psql_cmd -c "SET custom.swagger_url = '${SWAGGER_URL}';" -f "${SCRIPT_DIR}/../endpoints/endpoint_schema.sql"

# 6. Register HAF context (idempotent) — must run as haf_stats_owner so that
#    hafd.contexts.owner = haf_stats_owner, satisfying the RLS policies in HAF.
psql_cmd -c "SET ROLE haf_stats_owner; SELECT haf_stats_app.create_context_if_not_exists(); RESET ROLE;"

# 6a. Reassign ownership of HAF-created schema objects to haf_stats_owner.
#     hive.app_create_context() runs as SECURITY DEFINER (haf_admin), so views
#     and the internal tracking table are created owned by haf_admin. The process
#     container connects as haf_stats_owner and needs to own them for CREATE OR
#     REPLACE VIEW to succeed during context attach.
psql_cmd -c "
DO \$\$
DECLARE obj RECORD;
BEGIN
  FOR obj IN
    SELECT c.relname, c.relkind::text AS kind
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'haf_stats_app'
      AND c.relkind IN ('r', 'v', 'S')
      AND c.relowner != (SELECT oid FROM pg_roles WHERE rolname = 'haf_stats_owner')
  LOOP
    IF obj.kind = 'v' THEN
      EXECUTE format('ALTER VIEW haf_stats_app.%I OWNER TO haf_stats_owner', obj.relname);
    ELSIF obj.kind = 'r' THEN
      EXECUTE format('ALTER TABLE haf_stats_app.%I OWNER TO haf_stats_owner', obj.relname);
    ELSE
      EXECUTE format('ALTER SEQUENCE haf_stats_app.%I OWNER TO haf_stats_owner', obj.relname);
    END IF;
  END LOOP;
END
\$\$;"

# 7. Grant read access on current and future objects to haf_stats_user
psql_cmd -c "
    ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_backend
        GRANT SELECT ON TABLES TO haf_stats_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_endpoints
        GRANT EXECUTE ON FUNCTIONS TO haf_stats_user;
"

log "Installation complete."

# PREREQUISITE (run by btracker_app schema owner, not this script):
#   GRANT SELECT ON btracker_app.current_account_balances TO haf_stats_user;
# Required for get_network_hp_distribution to return data.
# Verify with:
#   SELECT has_table_privilege('haf_stats_user',
#       'btracker_app.current_account_balances', 'SELECT');
