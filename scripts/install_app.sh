#!/bin/bash
# One-time schema installation. Run once against a live HAF database.
# Safe to re-run: all DDL uses IF NOT EXISTS / ON CONFLICT DO NOTHING.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

wait_for_postgres

log "Installing haf_stats schema..."

# 1. Roles (must run as postgres superuser or haf_admin)
run_sql_file "${SCRIPT_DIR}/../db/builtin_roles.sql"

# 2. Schemas, control tables, lifecycle functions, main loop
run_sql_file "${SCRIPT_DIR}/../db/haf_stats_app.sql"

# 3. Block processor stub (processors added here as features are implemented)
run_sql_file "${SCRIPT_DIR}/../db/process_block_range.sql"

# 4. API endpoints
run_sql_file "${SCRIPT_DIR}/../endpoints/endpoint_schema.sql"

# 5. Register HAF context (idempotent)
psql_cmd -c "SELECT haf_stats_app.create_context_if_not_exists();"

# 6. Grant read access on current and future objects to haf_stats_user
psql_cmd -c "
    ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_backend
        GRANT SELECT ON TABLES TO haf_stats_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_endpoints
        GRANT EXECUTE ON FUNCTIONS TO haf_stats_user;
"

log "Installation complete."
