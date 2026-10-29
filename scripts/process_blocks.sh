#!/bin/bash
# Starts block processing, and blocks until stopped or killed.
#
# Two implementations: the generic HAF driver (haf_app_driver.py) when this HAF has the
# application registry and haf_stats is registered in it, otherwise the legacy
# haf_stats_app.main() loop. See the selection logic at the bottom of this file.
#
# OPTIONS:                                                      # --- help-start ---
#   --host=VALUE   PostgreSQL host (default: $POSTGRES_HOST, else haf)
#   --port=NUMBER  PostgreSQL port (default: $POSTGRES_PORT, else 5432)
#   --user=VALUE   PostgreSQL user (default: $POSTGRES_USER, else haf_stats_owner)
#                  --postgres-host=, --postgres-port= and --postgres-user= are
#                  accepted as synonyms (balance_tracker's spelling)
#   --postgres-url=URI  NOT SUPPORTED YET -- recognised and refused, with a
#                  message pointing at --host/--port/--user (--url= is the same)
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
        --host=*|--postgres-host=*) require_flag_value "$arg"; POSTGRES_HOST="${arg#*=}" ;;
        --port=*|--postgres-port=*) require_flag_value "$arg"; POSTGRES_PORT="${arg#*=}" ;;
        --user=*|--postgres-user=*) require_flag_value "$arg"; POSTGRES_USER="${arg#*=}" ;;

        # RECOGNISED AND REFUSED, deliberately -- not warn-and-continue like --schema,
        # and not "is not a valid option" either.
        #
        # An earlier revision of this MR HONOURED it, handing the URI to psql as a
        # conninfo. That was worse than rejecting it, because only psql moved: every
        # message, the confirmation banner and the typed-the-database-name gate still
        # read ${POSTGRES_HOST}/${POSTGRES_DB}. So `uninstall_app --postgres-url=...`
        # dropped schemas on the URI's host while printing the discrete host, and
        # accepted the discrete database name as confirmation -- in the one gate whose
        # stated purpose is catching "the right command against the wrong host".
        #
        # Honouring it properly means the banner, the healthcheck's application_name
        # tag (the uninstall session guard excludes the probe by that literal), passing
        # the conninfo through to the healthcheck, a redactor that survives
        # ?password= and keyword/value forms, and the other scripts. That is tracked
        # separately.
        #
        # Refusing is safe here, unlike for --schema: --postgres-url appears in exactly
        # one upstream module file (hivemind.yaml, on hivemind-uninstall) and that file
        # carries no `restart:` key, so this cannot crash-loop a service. One clear
        # error beats a silent connection to the wrong database.
        --postgres-url=*|--url=*)
            log "ERROR: --postgres-url is not supported yet."
            log "       Use --host=, --port= and --user= instead. Accepting the URI"
            log "       would move only the psql connection: this script's messages,"
            log "       and the teardown's confirmation prompt, still read POSTGRES_HOST"
            log "       and POSTGRES_DB -- so it could act on one database while"
            log "       reporting another. Refusing is the safe answer until that is"
            log "       fixed throughout."
            exit 2
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

log "Starting block processing loop..."

# The generic HAF block-processing driver (haf#341; on PATH from the psql:14-3 base
# image) calls hive.app_next_iteration itself and runs the registered
# haf_stats_app.process_blocks once per delivered range, committing between ranges and
# idling on its own connection in between -- so no transaction spans the wait for a new
# block, and the backend shows `idle` rather than `idle in transaction` holding context
# row locks (which is what the legacy path does: hive.app_next_block takes
# `FOR UPDATE` on hafd.contexts before the blocking wait inside it).
#
# exec'd, so the driver is PID 1 and receives SIGTERM directly; a bash parent swallows
# it until docker's kill (learned on reputation_tracker!223).
#
# --startup-marker= is empty on purpose: the startup timestamp written above is OURS and
# comes from the DATABASE clock, for the reasons in that block, while the driver's own
# marker would be the container clock. docker/block-processing-healthcheck.sh compares
# against the file we wrote.
#
# HAF_STATS_USE_LEGACY_LOOP=true forces the eternal CALL main() loop. The same fallback
# is taken automatically when the driver is absent from PATH, when this HAF has no
# application registry, or when the registered entry procedure no longer exists.
#
# THE REGISTRY PROBE IS NOT OPTIONAL. `command -v` alone is not a sufficient guard: the
# psql base image has shipped the driver since 14-3, so the test would be permanently
# true, and the driver's first act is to read hafd.applications with no handler for a
# missing table. On a HAF that predates haf#341 it would exit before its first range,
# and since it is exec'd as PID 1 that is a container that never processes a block --
# indefinitely, wherever a restart policy is set -- and one usually is: hive/haf_api_node's
# haf_stats.yaml declares `restart: on-failure`, while a node we run has the container on
# `unless-stopped`, which is neither compose file's value, because a deployment can
# override it. This repo's own docker/docker-compose.yml sets none, so there it stops dead
# instead. Either way the container never processes a block. The healthcheck hides it either way, because
# start_period restarts with the container. db/register_app.sql already warns and skips on such a HAF; this is the
# matching half. (hive/haf_fyp!51 shipped the binary-only guard and was corrected in
# review; this app inherits the corrected form rather than the bug.)
registry_has_haf_stats() {
    # Two statements, not one. PostgreSQL resolves every relation at plan time, so a
    # single query naming hafd.applications errors on a HAF without it whatever
    # to_regclass() says in the same statement. Any psql failure counts as "not ready".
    [ "$(psql_cmd -Atq -c "SELECT to_regclass('hafd.applications') IS NOT NULL" 2>/dev/null || true)" = "t" ] || return 1
    # `process_procedure IS NOT NULL`, not just a row: haf_app_driver.py has TWO fatal
    # exits before its first range -- "is not registered" and "is self-driven (no process
    # procedure registered)". A row registered without an entry procedure (app_register's
    # third argument defaults to NULL) satisfies a bare EXISTS and then reproduces exactly
    # the crash loop this probe exists to prevent.
    #
    # And the procedure must still EXIST (#97): a row outlives its schema when an
    # uninstall's context removal fails and DROP SCHEMA runs anyway, and the driver then
    # calls a procedure that is gone. This is hive.app_register's own resolution check,
    # to_regprocedure(<proc> || '( hive.blocks_range )'); NULL for a NULL procedure, so it
    # does not depend on the order the ANDs are evaluated in. Where it RAISES instead of
    # returning NULL -- on PostgreSQL <= 15 an unresolvable argument type does, and any
    # version raises for a schema the caller has no USAGE on -- the `|| true` below turns
    # that into "not ready", the same answer.
    #
    # This keeps the DRIVER away from a dropped schema; it does not make such a node
    # healthy. The legacy CALL below fails against the same missing schema, as it always
    # has on an uninstalled node. The fix for the stale row is scripts/uninstall_app.sh
    # step 3a; this is the second line of defence.
    [ "$(psql_cmd -Atq -c "SELECT EXISTS (SELECT 1 FROM hafd.applications WHERE name = 'haf_stats' AND process_procedure IS NOT NULL AND to_regprocedure(process_procedure || '( hive.blocks_range )') IS NOT NULL)" 2>/dev/null || true)" = "t" ]
}

# Accepts the spellings install_app.sh's own flags accept. A bare `!= "true"` test made
# TRUE/True/1/yes/on silently fail to enable the legacy loop -- i.e. a typo failed TOWARD
# the driver, the opposite of this repo's stated convention that a typo fails safe.
case "${HAF_STATS_USE_LEGACY_LOOP:-false}" in
    true|TRUE|True|1|yes|YES|Yes|on|ON|On) _haf_stats_force_legacy=1 ;;
    *)                                      _haf_stats_force_legacy=0 ;;
esac
if [ "${_haf_stats_force_legacy}" = "1" ]; then
    log "HAF_STATS_USE_LEGACY_LOOP is set; using the legacy CALL main() loop"
fi

if command -v haf_app_driver.py >/dev/null 2>&1 \
   && [ "${_haf_stats_force_legacy}" = "0" ]; then
    if registry_has_haf_stats; then
        log "haf_stats is registered in the HAF application registry; running haf_app_driver.py"
        exec haf_app_driver.py --app=haf_stats \
            --postgres-url="postgresql://${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?application_name=haf_stats_block_processing&options=-c%20haf_stats.processor_timings%3Don" \
            --startup-marker=
    fi
    # Deliberately does not name a cause. Every psql failure in the probe above is
    # swallowed, so "not registered" and "could not reach PostgreSQL" are indistinguishable
    # here, and an earlier wording asserted the former.
    log "WARNING: haf_app_driver.py is on PATH, but the HAF application registry does not"
    log "         list haf_stats with an entry procedure that exists -- HAF older than"
    log "         haf#341, registration skipped, the registered procedure is gone (e.g."
    log "         after an uninstall), or the probe could not query the database;"
    log "         falling back to the legacy CALL main() loop"
fi

# Tagged so ONE predicate finds either loop. scripts/rebuild_*.sh refuse to truncate
# while a processor is connected, and the driver sets this same application_name through
# its connection URI -- without it here, the legacy backend would be matched only by its
# query text. Exported rather than passed per-command because psql_cmd takes no conninfo,
# and set here rather than at the top of the script so the probe and the startup-timestamp
# queries above are NOT mistaken for a running block processor.
export PGAPPNAME="haf_stats_block_processing"
psql_cmd -c "CALL haf_stats_app.main('haf_stats');"

log "Block processing loop exited."
