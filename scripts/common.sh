#!/bin/bash
set -euo pipefail

# Shared variables and helpers for all haf_stats scripts.

: "${POSTGRES_HOST:=haf}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_DB:=haf_block_log}"
: "${POSTGRES_USER:=haf_stats_owner}"

export HAF_STATS_SCHEMA="haf_stats_app"

log() {
    echo "[haf_stats $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

wait_for_postgres() {
    log "Waiting for PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT}..."
    until pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -q; do
        sleep 2
    done
    log "PostgreSQL is ready."
}

psql_cmd() {
    psql \
        -h "${POSTGRES_HOST}" \
        -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DB}" \
        -v ON_ERROR_STOP=on \
        "$@"
}

run_sql_file() {
    local file="$1"
    log "Executing ${file}..."
    psql_cmd -f "${file}"
}

# --------------------------------------------------------------------------------------
# Rebuild-script helpers. Shared by every scripts/rebuild_*.sh: they were duplicated
# verbatim across them, so a fix to the live-processor heuristic below had to be made in
# each copy (and missed in the next script someone added).
# --------------------------------------------------------------------------------------

require_number() {
    local name="$1" value="$2"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "${name} must be a non-negative integer; got '${value}'." >&2
        exit 2
    fi
}

# Detect a live processor. Scoped to THIS database (pg_stat_activity is cluster-wide, so
# an unrelated HAF app running its own main() elsewhere must not block us). Matching on a
# leading CALL keeps this from matching its own SELECT.
count_live_processors() {
    psql_cmd -Atc "
        SELECT COUNT(*)
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND datname = current_database()
          AND state <> 'idle'
          AND BTRIM(query) ILIKE 'CALL%haf_stats_app.main%'
    "
}

# Refuse to proceed while the block processor is live. ASSIGN, then validate: a bare
# `if (( $(count_live_processors) > 0 ))` FAILS OPEN when psql returns an empty string
# (connection reset) — `(( > 0 ))` is a syntax error returning 1, and set -e is suppressed
# inside an `if` condition, so the guard would silently conclude "no processor" and
# TRUNCATE while one is running. Callers use this both pre-flight and again afterwards,
# since the pre-flight check is TOCTOU over a multi-minute replay.
assert_no_live_processor() {
    local context="${1:-The haf_stats processor is still running; refusing to rebuild.}"
    local live_procs
    live_procs="$(count_live_processors)"
    require_number "live_processor_count" "${live_procs}"
    if (( live_procs > 0 )); then
        echo "${context}" >&2
        echo "Stop it first: SELECT haf_stats_app.stop_processing();  (or stop the haf-stats-process container), then re-run." >&2
        exit 2
    fi
}
