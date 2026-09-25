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
    # -X: never read ~/.psqlrc. These scripts parse psql's stdout, and an interactive
    # dotfile writes to it -- `\echo` at connection time, `\timing` after every command.
    # haf_stats#75 put -X on two call sites and claimed it removed the class at source;
    # it did not, because this function is the source. With a `\timing` in ~/.psqlrc the
    # session count read as "Timing is on.\n0" and the teardown died on a message naming
    # neither psqlrc nor the fix. A scripted psql has no business reading an interactive
    # dotfile, so it belongs here rather than on whichever call site was noticed last.
    psql \
        -X \
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

# Load a file as ONE transaction, so a re-install never exposes a half-applied schema
# and a failure leaves the previous one intact. (#79)
#
# NOT usable on every file. Two disqualifiers, both silent if ignored:
#
#   * A statement PostgreSQL refuses inside a transaction block. Four files use
#     CREATE/DROP INDEX CONCURRENTLY (process_account_cohorts, process_active_users,
#     process_content_stats, process_financial) and would abort outright.
#   * A file that manages its OWN transaction. db/sync_status.sql opens with BEGIN and
#     ends with COMMIT, so under this flag its COMMIT would end psql's transaction
#     early -- the load would still succeed and the atomicity would quietly be gone.
#     Note `END;` is a synonym for COMMIT, so a bare top-level END; counts too.
#
# tests/unit/test_install_atomicity.py enforces both conditions for every file loaded
# this way, so adding a CONCURRENTLY index to one of them fails in CI rather than in an
# operator's install.
#
# Two further traps, both of which make the flag do NOTHING while looking correct:
#
#   * It requires -c or -f. psql documents it as wrapping the *action list*, so SQL fed
#     on stdin with neither is not wrapped and the flag is silently ignored. Note
#     install_app.sh already feeds one statement on a heredoc (it has to -- psql -c does
#     not substitute :'var'), so "unify these two idioms" is a real temptation that
#     would quietly drop atomicity. Hence -f here, always.
#   * It is married to ON_ERROR_STOP, set in psql_cmd above. Without it psql sends
#     COMMIT on an already-aborted transaction, the server turns that into a rollback,
#     and psql exits 0 -- an install that did nothing and reported success.
run_sql_file_atomic() {
    local file="$1"
    log "Executing ${file} (single transaction)..."
    psql_cmd --single-transaction -f "${file}"
}
