#!/bin/bash
# Starts the infinite block-processing loop.
# Calls haf_stats_app.main() which blocks until stopped or killed.
#
# OPTIONS:                                                      # --- help-start ---
#   --host=VALUE   PostgreSQL host (default: $POSTGRES_HOST, else haf)
#   --port=NUMBER  PostgreSQL port (default: $POSTGRES_PORT, else 5432)
#   --user=VALUE   PostgreSQL user (default: $POSTGRES_USER, else haf_stats_owner)
#                  --postgres-host=, --postgres-port= and --postgres-user= are
#                  accepted as synonyms (balance_tracker's spelling)
#   --postgres-url=URI  Full libpq conninfo; REPLACES --host/--port/--user
#                  (--url= is the same flag; an empty value is an error)
#   --schema=NAME  Accepted for module-file compatibility; ignored with a warning
#                  unless it names haf_stats_app
#   --is_forking=  Accepted likewise; this app's context is always non-forking
#   --help,-h,-?   Show this and exit                           # --- help-end ---

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

print_help() {
    # See scripts/install_app.sh for why the markers carry a character class.
    sed -n '/--- help-sta[r]t ---/,/--- help-en[d] ---/p' "$0" | sed 's/^# //; s/^#$//; s/ *# --- help-[a-z]* ---//'
}

# This loop exists because docker/docker_entrypoint.sh forwards --host here, as
# balance_tracker's entrypoint does. Without it the flag would be accepted by the
# entrypoint and then silently dropped by this script -- the same "looks like it worked
# while doing nothing" failure that install_app.sh's fallthrough was added to remove,
# and which a module file copied from an upstream app would hit.
for arg in "$@"; do
    case "$arg" in
        --host=*|--postgres-host=*) POSTGRES_HOST="${arg#*=}" ;;
        --port=*|--postgres-port=*) POSTGRES_PORT="${arg#*=}" ;;
        --user=*|--postgres-user=*) POSTGRES_USER="${arg#*=}" ;;

        # ACCEPTED, and honoured in exactly one place: common.sh's pg_conn_args, which
        # both psql and pg_isready go through. An earlier revision of this flag moved
        # only the psql connection and left every message, and the teardown's
        # type-the-database-name gate, reading POSTGRES_HOST/POSTGRES_DB -- so the
        # script could act on one database while reporting another. That is why the
        # rule here is one connection path and one description of it.
        #
        # An EMPTY value is an error, not a fallback. A module file writing
        # --postgres-url=${DB_URL} with DB_URL unset would otherwise connect silently to
        # $POSTGRES_HOST instead -- and for uninstall_app that is a destructive command
        # quietly retargeted.
        --postgres-url=*|--url=*)
            POSTGRES_URL="${arg#*=}"
            if [ -z "${POSTGRES_URL}" ]; then
                log "ERROR: ${arg%%=*}= was given an empty value."
                log "       Refusing rather than falling back to POSTGRES_HOST: an empty"
                log "       expansion is a mistake, and falling back would hide it."
                exit 2
            fi
            ;;

        # No upstream module file passes this to a verb other than install_app --
        # checked in balance_tracker.yaml, haf_block_explorer.yaml and
        # reputation_tracker.yaml, where --is_forking appears only on install services.
        # Accepted here anyway, for symmetry with install_app.sh and so that a
        # hand-written module file that does pass it cannot crash-loop the service.
        --is_forking=*)
            case "${arg#*=}" in
                FALSE|false|False)
                    log "--is_forking=FALSE matches this app's context; nothing to do."
                    ;;
                *)
                    log "WARNING: --is_forking=${arg#*=} is ignored; haf_stats registers a"
                    log "         NON-forking HAF context by design. Continuing."
                    ;;
            esac
            ;;
        # haf_api_node's module files pass --schema= on EVERY verb -- balance_tracker.yaml
        # ships `process_blocks --schema=btracker_app` on a service that is
        # `restart: on-failure`. A hard failure here is therefore a permanent crash-loop
        # that blocks the whole stack, over a flag this app cannot act on either way:
        # its schema names are fixed in the SQL.
        #
        # So WARN and continue, as the --is_forking arm below does. An earlier revision
        # MR exited 2, justified by a claim that `restart: on-failure` sat on the INSTALL
        # service -- it does not, in this repo or upstream; it sits on block-processing,
        # which is precisely where the hard failure landed.
        --schema=*)
            if [ "${arg#*=}" != "haf_stats_app" ]; then
                log "WARNING: --schema=${arg#*=} is ignored."
                log "         haf_stats owns three fixed schemas: haf_stats_app,"
                log "         haf_stats_backend and haf_stats_endpoints. Continuing."
            fi
            ;;
        --help|-h|-\?) print_help; exit 0 ;;
        *) log "ERROR: '${arg}' is not a valid option"; print_help; exit 2 ;;
    esac
done

wait_for_postgres

# When block processing started, for docker/block-processing-healthcheck.sh (#57).
# That check reports healthy only if hafd.contexts.last_active_at is BOTH recent and
# later than this timestamp; without the second half, a container that has just
# restarted is judged by a heartbeat the previous process wrote.
#
# Taken from the DATABASE clock, not from `date`. Two reasons, and the first is not a
# preference:
#
#   1. hafd.contexts.last_active_at is `timestamp WITHOUT time zone`, written by
#      hive.app_next_iteration as `__now TIMESTAMP := NOW()` -- rendered in the SERVER
#      session's time zone. A timestamp produced here, in the container, is only
#      comparable to it if container and server agree on the zone. They usually do, and
#      upstream relies on that; when they do not the comparison is wrong in the
#      FAIL-OPEN direction -- a server ahead of the container makes
#      `now() - last_active_at` negative, so the freshness test passes forever and a
#      dead loop reports healthy. Reading the clock from the same server that writes
#      last_active_at removes that mismatch.
#   2. `date --utc --iso-8601=seconds` is a GNU long option. The image is Alpine (the
#      base adds packages with apk), so `date` is BusyBox, which has no --iso-8601 --
#      it would exit non-zero here, under `set -e`, before the loop ever started.
#      balance_tracker, haf_block_explorer and hivesense all write `date -uIseconds`
#      for exactly this reason. hive/haf_fyp shipped the GNU form in review and it
#      would have crash-looped the container on every deployment.
#
# Written via a temp file and mv, not `psql > file`: a redirect truncates BEFORE psql
# runs, so a psql that fails after pg_isready succeeded leaves a zero-byte file, which
# passes an existence check and then makes the reader cast '' to a timestamp. mv within
# one directory is atomic, so the reader sees either the old content or a complete new
# value, never an empty one.
#
# Runs after wait_for_postgres because it needs a connection. That also sharpens what
# the file's absence means: not "the container started" but "block processing has not
# begun".
STARTUP_TIME_FILE="${HAF_STATS_STARTUP_TIME_FILE:-/tmp/block_processing_startup_time.txt}"
_startup_tmp="${STARTUP_TIME_FILE}.tmp.$$"
psql_cmd -Atq -c "SELECT now()::timestamp" > "${_startup_tmp}"
mv "${_startup_tmp}" "${STARTUP_TIME_FILE}"
log "Block processing start time recorded: $(cat "${STARTUP_TIME_FILE}")"

# The EFFECTIVE connection, written next to the startup time and by the same atomic
# rename, so the healthcheck probes the database this loop is actually processing.
#
# It cannot simply read $POSTGRES_URL: Docker runs a container healthcheck as a FRESH
# process with the container's configured environment, not with PID 1's. A
# --postgres-url passed on this service's command line is therefore invisible to it, and
# the probe would silently report on $POSTGRES_HOST while the loop worked elsewhere.
# `export` does not fix that either. A file does.
CONN_FILE="${HAF_STATS_CONNINFO_FILE:-/tmp/block_processing_conninfo.txt}"
_conn_tmp="${CONN_FILE}.tmp.$$"
printf '%s' "${POSTGRES_URL}" > "${_conn_tmp}"
mv "${_conn_tmp}" "${CONN_FILE}"
if [ -n "${POSTGRES_URL}" ]; then
    log "Block processing connection recorded: $(redacted_target)"
fi

log "Starting block processing loop..."

psql_cmd -c "CALL haf_stats_app.main('haf_stats');"

log "Block processing loop exited."
