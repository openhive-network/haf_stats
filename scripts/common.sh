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

# shellcheck source=arg_guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/arg_guard.sh"

# The same values reach these variables through the ENVIRONMENT, where the flag guard
# never runs. Empty is already handled: the `:=` above is the COLON form, which
# substitutes on unset OR null, so POSTGRES_HOST="" becomes haf. Whitespace-only is not,
# and without this the identical value would be refused as --host=" " and accepted as
# POSTGRES_HOST=" " -- the same operator error, opposite verdicts, depending only on
# which channel it arrived through.
for _var in POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER; do
    case "${!_var}" in
        *[![:space:]]*) : ;;
        *)  log "ERROR: ${_var} is set to a whitespace-only value."
            log "       Refused for the same reason as the equivalent flag: it cannot"
            log "       be what the caller meant."
            exit 2
            ;;
    esac
done
unset _var

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
