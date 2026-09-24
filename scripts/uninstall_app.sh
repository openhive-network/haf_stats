#!/bin/bash
# Remove haf_stats from a HAF database (#57).
#
# There was previously no supported way to uninstall this app: the schemas, roles and
# HAF context stayed behind forever, and an operator evaluating haf_stats as a
# haf_api_node module had no way back out. balance_tracker, haf_block_explorer and
# hivesense all ship one of these; this completes the
# install_app / process_blocks / uninstall_app verb set module files assume.
#
# THIS IS DESTRUCTIVE AND HAS NO UNDO. It drops all three schemas CASCADE, taking every
# table with them -- including haf_stats_backend, which holds the rollups that take
# hours to rebuild from a genesis replay. There is no backup step.
#
# A port of hive/haf_fyp's equivalent (!50) after four review rounds; the non-obvious
# decisions below are the survivors of those rounds.
#
# OPTIONS:                                                      # --- help-start ---
#   --force        Skip the interactive confirmation. Required to run without a TTY.
#   --host=VALUE   PostgreSQL host (default: $POSTGRES_HOST, else haf)
#   --port=NUMBER  PostgreSQL port (default: $POSTGRES_PORT, else 5432)
#   --user=VALUE   PostgreSQL user (default: $POSTGRES_USER, else haf_admin)
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

# MUST precede the source. scripts/common.sh defaults POSTGRES_USER to haf_stats_owner
# with `: "${POSTGRES_USER:=...}"`, so a default applied afterwards would never take
# effect. haf_stats_owner cannot do this job: dropping roles needs CREATEROLE or
# superuser, and a role cannot drop itself.
: "${POSTGRES_USER:=haf_admin}"
export POSTGRES_USER

# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# NOTE the naming asymmetry, which is the trap this file exists to get right. The HAF
# CONTEXT is named 'haf_stats'; the SCHEMAS are haf_stats_app / _backend / _endpoints.
# Upstream apps use one name for both (btracker_app is context and schema), so a copy of
# their script with a schema substituted calls app_remove_context('haf_stats_app') --
# and because that call is guarded by app_context_exists(), it silently does nothing and
# orphans the context with no error to notice.
#
# Honours the environment, matching docker/block-processing-healthcheck.sh: hardcoded,
# a node running a renamed context would get a healthcheck that followed it and an
# uninstall that silently targeted "haf_stats".
HAF_STATS_CONTEXT="${HAF_STATS_CONTEXT:-haf_stats}"
HAF_STATS_SCHEMAS="haf_stats_app haf_stats_backend haf_stats_endpoints"
HAF_STATS_ROLES="haf_stats_user haf_stats_owner"

FORCE=0

print_help() {
    # See scripts/install_app.sh for why the markers carry a character class.
    sed -n '/--- help-sta[r]t ---/,/--- help-en[d] ---/p' "$0" | sed 's/^# //; s/^#$//; s/ *# --- help-[a-z]* ---//'
}

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --host=*|--postgres-host=*) require_flag_value "$arg"; POSTGRES_HOST="${arg#*=}" ;;
        --port=*|--postgres-port=*) require_flag_value "$arg"; POSTGRES_PORT="${arg#*=}" ;;
        --user=*|--postgres-user=*) require_flag_value "$arg"; POSTGRES_USER="${arg#*=}" ;;

        # RECOGNISED AND REFUSED, deliberately -- not warn-and-continue like --schema,
        # and not "is not a valid option" either.
        #
        # An earlier revision of this MR HONOURED it, handing the URI to psql as a
        # conninfo. That was worse than rejecting it, because only psql moved: every
        # message read ${POSTGRES_HOST}/${POSTGRES_DB}, so `uninstall_app
        # --postgres-url=...` dropped schemas on the URI's host while printing the
        # discrete one.
        #
        # Section 0 now reports the server that ANSWERED, and the confirmation compares
        # against the database the server names, so that particular blindness is gone
        # (#75). The flag stays refused because honouring it still means the healthcheck's
        # application_name tag, passing the conninfo through, and a redactor that survives
        # ?password= -- none of which this script does.
        #
        # Honouring it properly means the healthcheck's application_name
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
            log "       would move only the psql connection: the healthcheck's"
            log "       application_name tag, the conninfo passed through to it, and a"
            log "       redactor that survives ?password= are all still missing, and the"
            log "       other scripts read POSTGRES_HOST. Refusing is the safe answer"
            log "       until that is fixed throughout."
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
        # A typo in a flag to a script that drops schemas must not be shrugged off --
        # least of all a mistyped --force, which would then fall through to a prompt that
        # a compose run cannot answer.
        *) log "ERROR: '${arg}' is not a valid option"; print_help; exit 2 ;;
    esac
done

wait_for_postgres

# WHICH SERVER THIS ACTUALLY REACHED, asked of the server rather than echoed back from
# our own variables. This is the whole of #75: every message here used to name
# ${POSTGRES_HOST}, which is what was REQUESTED, and three things make the requested and
# the reached target diverge without any flag being wrong.
#
#   1. PGHOSTADDR. libpq connects to `hostaddr` when both are given and uses `host` only
#      for authentication and TLS matching -- and -h sets `host`. REPRODUCED against two
#      live servers: `PGHOSTADDR=<B> psql -h <A>` reached B, saw B's tables and reported
#      B's inet_server_addr(), while every message this script prints said A. Both
#      reviewers of !81 could only mark that PLAUSIBLE from the documentation; it is not
#      plausible, it is what happens.
#   2. PGOPTIONS can carry `-c role=...`, so current_user is not necessarily the role
#      whose privileges the operator thinks apply. Measured: current_user became `decoy`
#      while session_user stayed `postgres`, which is why both are reported below.
#   3. A socket path is a legal --host value, so the flag guard added by !81 (#67) cannot
#      tell "a network host" from "the local socket".
#
# inet_server_addr() returns NULL over a Unix socket, which is exactly the signal that
# matters: it describes the connection that was MADE. No amount of flag validation can
# produce that, because none of these arrive through a flag.
_server_identity() {
    # host(), not ::text: inet's CAST to text keeps a /32 that means nothing here (the
    # type's own output suppresses it; text(inet) does not). That is the whole argument --
    # an earlier revision also claimed ::text made IPv6 ambiguous, which is backwards:
    # `::1/128:5432` marks where the address ends, while host() gives `::1:5432`, where
    # `:5432` is indistinguishable from a hextet. IPv6 is the one case ::text reads
    # better; the /32 noise on every IPv4 node is the case that actually occurs.
    #
    # The cluster id is what actually identifies the server. Over a Unix socket
    # inet_server_addr() is NULL, so without it the line degrades to
    # "LOCAL SOCKET:-/haf_block_log" -- identical for two clusters on one box, which is
    # exactly where #67's empty-host failure lands. pg_control_system() is executable by
    # PUBLIC; verified on the live node as haf_admin, haf_stats_owner and haf_stats_user.
    #
    # tr, because a database named with an embedded newline would otherwise emit an
    # unprefixed second line into the log.
    # No `|| true`: the caller tests the STATUS. An earlier revision swallowed it and
    # made emptiness the only signal, which is not the same thing -- a failing psql still
    # writes to stdout if anything already has, and a ~/.psqlrc `\echo` or `\timing` does
    # exactly that at connection time. Nothing in this repo passes --no-psqlrc. The
    # refusal then never fired and the `reached:` line printed that noise as an identity.
    psql_cmd -Atq -c "
        SELECT coalesce(host(inet_server_addr()), 'LOCAL SOCKET')
            || ':' || coalesce(inet_server_port()::text, '-')
            || '/' || current_database()
            || ' as ' || current_user
            || CASE WHEN current_user <> session_user
                    THEN ' (current_user differs from session_user ' || session_user || ')'
                    ELSE '' END
            || ' [cluster ' || (SELECT system_identifier FROM pg_control_system()) || ']'
    " | tr '\n' ' '
}

# The reached target, plus a note when the environment is what redirected us. Printed on
# both paths -- see the banner below.
# Resolved ONCE, into _reached, and reused by every later line. An earlier revision
# asked the server again from the refusal path, which issued the same query twice.
_resolve_target() {
    # The STATUS, then the shape. psql failing is the branch the refusal exists for, and
    # stdout noise on a SUCCESSFUL query corrupts the line just as badly -- so anything
    # that does not end in the cluster id this query always appends is not an identity.
    if ! _reached="$(_server_identity)"; then _reached=""; fi
    _reached="${_reached% }"
    case "${_reached}" in
        *"[cluster "*"]") : ;;
        *) _reached="" ;;
    esac

    log "  requested: ${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB} as ${POSTGRES_USER}"
    if [ -n "${_reached}" ]; then
        log "  reached  : ${_reached}"
    else
        log "  reached  : COULD NOT ASK THE SERVER."
    fi

    # ANY hostaddr channel, not just PGHOSTADDR. A pg_service.conf carrying `hostaddr=`
    # beats an explicit -h and leaves no environment variable behind: measured on two
    # servers, `PGSERVICE=decoy psql -h A` reached B with PGHOSTADDR unset. #75 said
    # service files "lose to explicit parameters"; they do not -- `host` and `hostaddr`
    # are different keywords and -h overrides only the former. Corrected on #75.
    # PGSERVICEFILE alone is inert: libpq reads a service file only when a service NAME
    # is given, through PGSERVICE or `service=` in a conninfo. Warning on it by itself
    # meant a destructive run printed a redirect warning for a variable that redirects
    # nothing, so it is reported only alongside PGSERVICE -- where it says WHICH file to
    # go and read.
    _redirect=""
    [ -n "${PGHOSTADDR:-}" ] && _redirect="${_redirect} PGHOSTADDR=${PGHOSTADDR}"
    [ -n "${PGSERVICE:-}" ]  && _redirect="${_redirect} PGSERVICE=${PGSERVICE}"
    if [ -n "${PGSERVICE:-}" ] && [ -n "${PGSERVICEFILE:-}" ]; then
        _redirect="${_redirect} PGSERVICEFILE=${PGSERVICEFILE}"
    fi
    if [ -n "${_redirect}" ]; then
        # One per line. Run together they read as a single ungrammatical value, and with
        # all of them set the first line ran ~140 columns while its own continuations
        # wrapped at 85.
        for _var in ${_redirect}; do
            log "  NOTE     : ${_var}"
        done
        log "             Any of PGHOSTADDR, PGSERVICE or PGSERVICEFILE can carry a"
        log "             hostaddr, which libpq connects to INSTEAD of the --host /"
        log "             POSTGRES_HOST above; those then apply only to authentication"
        log "             and TLS. The 'reached' line is the server being destroyed."
    fi

    # What the reached line is NOT. Measured: a pooler that reaches PostgreSQL over the
    # Unix socket reports LOCAL SOCKET to a client that connected over TCP from another
    # machine, so this describes the SERVER's end of the connection, not yours. PgBouncer
    # sits in the haf_api_node stack this app ships a module for.
    case "${_reached}" in
        "LOCAL SOCKET"*)
            log "  NOTE     : 'LOCAL SOCKET' is the SERVER's end of the connection, not"
            log "             yours. A pooler that reaches PostgreSQL over the socket"
            log "             reports it to a remote client too, so the cluster id is the"
            log "             reliable identity here." ;;
    esac

    # FAIL CLOSED, like every other probe in this script. If the server cannot say what
    # it is, this run cannot name what it would destroy -- and --force would otherwise
    # have gone ahead on nothing but the host that was typed.
    #
    # exit 1, not 2. In this file 2 means "invoked wrong" (unknown flag, --postgres-url,
    # an empty flag value, no TTY without --force) and 1 means "refused, or a probe could
    # not answer" -- the session guard, the catalog probe and both privilege guards all
    # exit 1. An earlier revision used 2 here and claimed it matched "every other probe",
    # which was the opposite of what the file does.
    if [ -z "${_reached}" ]; then
        log "ERROR: refusing to continue without knowing which server answered."
        log "       Every other probe here fails closed; so does this one."
        exit 1
    fi
}

# Report the role the database actually sees. ${POSTGRES_USER} is what was REQUESTED;
# every probe above correctly asks about current_user, and the two can differ (a
# PGUSER/PGSERVICE in the environment, a .pgpass-driven fallback, a service file). A
# refusal that names the wrong role sends the operator to change the wrong thing -- and
# now names the wrong SERVER too, which is worse.
_report_connected_identity() {
    if [ -n "${_reached:-}" ]; then
        log "       (connected to ${_reached})"
    fi
}

# ---------------------------------------------------------------------------
# 0. Which server actually answered.
# ---------------------------------------------------------------------------
# BEFORE every guard, because each of them sends the operator somewhere -- "stop these
# containers", "grant this role" -- and under a redirected connection that is the wrong
# machine, while the only host in the log is the one they typed. The session guard below
# is the one an operator hits routinely, and it named nothing at all.
log "Target:"
_resolve_target

# ---------------------------------------------------------------------------
# 1. Refuse while anything is connected as a haf_stats role.
# ---------------------------------------------------------------------------
# Not just the block processor: PostgREST and any rewriter hold sessions against these
# schemas, and DROP SCHEMA ... CASCADE needs an AccessExclusiveLock -- with any of them
# live, step 4 does not fail, it BLOCKS, after the context has already been removed.
#
# Keyed on usename, not on `query`. pg_stat_activity hides `query` for other roles'
# backends from anyone who is not superuser or a member of pg_read_all_stats, so a guard
# that pattern-matched the query text would return zero rows for a non-superuser
# operator and wave the uninstall through while the processor was running. usename is
# visible to everyone.
#
# The one exclusion is this app's own healthcheck, which connects as haf_stats_owner
# every 60s (docker/block-processing-healthcheck.sh sets application_name for exactly
# this). It holds no lock and lives milliseconds. Whether application_name is masked for
# a non-superuser caller the way `query` is has NOT been verified; if it is, the
# exclusion stops matching and the probe gets counted -- a spurious REFUSAL, never a
# spurious proceed, so the failure direction is safe either way.
check_active_sessions() {
    psql_cmd -Atq -c "
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database()
          AND pid <> pg_backend_pid()
          AND usename IN ('haf_stats_owner', 'haf_stats_user')
          AND coalesce(application_name, '') <> 'haf_stats_health_check'"
}

report_active_sessions() {
    psql_cmd -Atq -c "
        SELECT usename || ' x' || count(*) || coalesce(' (' || string_agg(DISTINCT application_name, ', ')
               FILTER (WHERE application_name <> '') || ')', '')
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND pid <> pg_backend_pid()
          AND usename IN ('haf_stats_owner', 'haf_stats_user')
          AND coalesce(application_name, '') <> 'haf_stats_health_check'
        GROUP BY usename" || true
}

# Fail CLOSED on anything that is not a plain number. `[ "${x}" -ne 0 ]` with x empty is
# a syntax error returning 2 -- and because that would be an `if` CONDITION, set -e does
# not fire and the false branch is taken, so a psql that answered with nothing would read
# as "no sessions" and the script would drop everything.
assert_no_active_sessions() {
    local _active
    _active="$(check_active_sessions)" || {
        log "ERROR: could not query pg_stat_activity; refusing to continue."
        exit 1
    }
    case "${_active}" in
        ''|*[!0-9]*)
            log "ERROR: unexpected session count '${_active}'; refusing to continue."
            exit 1
            ;;
    esac
    if [ "${_active}" -ne 0 ]; then
        log "ERROR: ${_active} session(s) are still connected as a haf_stats role:"
        report_active_sessions | while read -r line; do log "         ${line}"; done
        log "       Stop everything that talks to haf_stats first, e.g.:"
        log "           docker compose -f docker/docker-compose.yml stop \\"
        log "               haf-stats-process haf-stats-api"
        log "       then re-run this script."
        exit 1
    fi
}

assert_no_active_sessions

# ---------------------------------------------------------------------------
# 2. Confirmation -- moved BELOW the read-only guards, see section 2 after GUARD 3.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 3-5. Teardown.
# ---------------------------------------------------------------------------
_destructive_errors=0

_psql_destructive() {
    # `|| _destructive_errors=...`, NOT a bare call. ON_ERROR_STOP alone does NOT do
    # what this design needs, which was verified against a live PostgreSQL 14 rather
    # than assumed:
    #
    #   -c failing LAST,  ON_ERROR_STOP=off -> exit 1
    #   -c failing FIRST, ON_ERROR_STOP=off -> exit 0
    #   -f  failing,      ON_ERROR_STOP=off -> exit 0
    #   -f  failing,      ON_ERROR_STOP=on  -> exit 3
    #
    # ON_ERROR_STOP controls whether psql CONTINUES to later actions; the exit status is
    # the LAST action's result. Here the failing statement is the last -c, so psql exits
    # 1 -- and as a bare top-level command under `set -e` that kills the script at the
    # first destructive error, before step 6 can report anything, leaving context gone,
    # some schemas gone, roles alive and no log line.
    #
    # balance_tracker and hivesense both put `|| true` on their destructive psql for this
    # reason. Counting rather than `|| true` so step 6 can tell "a statement errored"
    # from "the verification found survivors".
    if ! psql_cmd -v ON_ERROR_STOP=off -c "SET lock_timeout = '30s';" -c "$1"; then
        _destructive_errors=$((_destructive_errors + 1))
        log "  (statement failed; continuing -- step 6 reports what survived)"
    fi
}

# hive.context_remove is NOT SECURITY DEFINER and hafd.contexts has RLS whose DELETE
# policy is USING (hive.can_impersonate(current_user, owner)). A caller who is neither
# superuser nor able to impersonate haf_stats_owner therefore deletes ZERO ROWS WITHOUT
# ERROR: app_remove_context returns success, this script logs "removed context", and the
# context survives while the schemas are dropped. --user is an advertised flag, so that
# is reachable by an operator following the help text.
# ASK THE QUESTION THE POLICY ASKS. An earlier revision of this guard tested
# pg_has_role(current_user, 'haf_stats_owner', 'MEMBER') -- membership of a hardcoded
# role literal. The policy is
#
#     CREATE POLICY sp_applications_delete_hive_context ON hafd.contexts
#       FOR DELETE TO hive_applications_group USING( hive.can_impersonate(current_user, owner) );
#       -- hive/haf: src/hive_fork_manager/authorization.sql
#
# and `owner` is the ROW's column, not that literal. The sibling app's uninstall cites
# "install_app.sh's step 10" for the case where they differ -- a context registered by an
# older build owned by haf_admin rather than the app owner. CORRECTED FOR THIS REPO: that
# is haf_fyp's step 0, which RAISEs on an owner mismatch. haf_stats registers its context
# in install_app.sh STEP 5 and has no equivalent precondition, so here that state is
# undetected at install time and this guard is the only thing that catches it. Membership of the literal is therefore the wrong
# question, and it answers TRUE in a case where the DELETE still matches nothing --
# including for --user=haf_stats_owner, since a role is always a member of itself.
#
# Reading the row also removes the need for the to_regrole dance (pg_has_role RAISES
# 42704 on an unknown role, which mattered because this script advertises idempotent
# re-runs) and covers the two other states in one predicate: no context row left, and
# no hafd.contexts at all.

# GUARD 1 -- is this a HAF database at all?
#
# pg_class/pg_namespace, NOT to_regclass('hafd.contexts'). to_regclass RESOLVES THE
# SCHEMA, and aclcheck_error fires even under missing_ok, so it raises
# `permission denied for schema hafd` for any caller without USAGE on it -- verified on
# postgres:14 and postgres:17. That made the script announce "this is not a HAF
# instance" about a database that plainly is one, sending the operator to diagnose the
# wrong problem. This is the same trap step 6 already documents and works around for
# `cron`; it was left in the pre-flight. A catalog join needs no aclcheck.
_has_contexts="$(psql_cmd -Atq -c "
    SELECT EXISTS (SELECT 1 FROM pg_class c
                   JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'hafd' AND c.relname = 'contexts')")" || {
    log "ERROR: could not query the catalog to check whether this is a HAF instance."
    log "       Nothing has been changed. See the psql error above."
    exit 1
}

# GUARD 2 -- may this role delete the context row?
_can_remove="t"
if [ "${_has_contexts}" = "t" ]; then
    # A separate statement, not an OR arm: a WHERE cannot protect a FROM, because
    # PostgreSQL resolves relation names at parse analysis. Step 6 splits its probes for
    # the same reason.
    #
    # POSITIVE PROOF OF VISIBILITY, not inference from absence. An earlier revision was
    # `superuser OR NOT EXISTS(row) OR EXISTS(row AND can_impersonate)`, and the middle
    # arm cannot tell "the context is gone" from "the context is INVISIBLE TO ME under
    # RLS" -- it reads the row through the very policy in question. A role holding
    # SELECT on hafd but outside hive_applications_group (which is exactly what
    # db/builtin_roles.sql creates) saw zero rows and passed vacuously; then
    # hive.app_context_exists() read through the same filter and reported nothing to
    # remove, the schemas were dropped, and step 6's probe -- same filter again --
    # printed success while the context survived. Requiring group membership first turns
    # that state into a refusal.
    #
    # to_regrole guard: pg_has_role RAISES 42704 on an unknown role. The group exists on
    # any real HAF database, and this branch only runs when hafd.contexts does, but the
    # guard costs nothing and this script advertises idempotent re-runs.
    #
    # NOT wrapped in `2>/dev/null || echo ""`: that collapsed a connection reset, a
    # permission error and a genuine "no" into one confident and possibly wrong message.
    if ! _can_remove="$(psql_cmd -Atq -c "
        SELECT current_setting('is_superuser') = 'on'
            OR (to_regrole('hive_applications_group') IS NOT NULL
                AND pg_has_role(current_user, 'hive_applications_group', 'USAGE')
                AND (NOT EXISTS (SELECT 1 FROM hafd.contexts WHERE name = '${HAF_STATS_CONTEXT}')
                     OR EXISTS (SELECT 1 FROM hafd.contexts
                                WHERE name = '${HAF_STATS_CONTEXT}'
                                  AND hive.can_impersonate(current_user, owner))))")"; then
        log "ERROR: could not determine whether this role may remove the HAF context."
        log "       That query needs SELECT on hafd.contexts and EXECUTE on"
        log "       hive.can_impersonate, both of which come with hive_applications_group."
        log "       Nothing has been changed. See the psql error above."
        exit 1
    fi
fi

if [ "${_can_remove}" != "t" ]; then
    # REFUSE. hive.app_remove_context drops the context's views and its state table
    # BEFORE the DELETE (hive/haf app_api.sql, context_rewind/rewind_api.sql), so a
    # caller the DELETE policy filters out still destroys objects and then deletes zero
    # rows without error.
    #
    # BE ACCURATE ABOUT WHAT FOLLOWS. Step 6 DOES catch this: SELECT on hafd.contexts is
    # a separate policy, USING (TRUE) (authorization.sql), so the verification sees the
    # surviving row and exits 1 with INCOMPLETE. An earlier revision claimed it "reads
    # through the same filter and reports success"; that was wrong. The reason to refuse
    # is that the alternative is not a silent success but A LOUD FAILURE THAT ARRIVES
    # AFTER all three schemas have been dropped.
    log "ERROR: this role cannot remove the HAF context '${HAF_STATS_CONTEXT}'."
    log "       hafd.contexts' DELETE policy is hive.can_impersonate(current_user, owner),"
    log "       and it also requires membership of hive_applications_group to see the row"
    log "       at all -- so the delete would affect zero rows without error, and the"
    log "       teardown would drop all three schemas before step 6 reported the orphan."
    log "       Re-run as haf_admin. Nothing has been changed."
    _report_connected_identity
    exit 1
fi

# GUARD 3 -- may this role complete step 5?
#
# Step 5 runs DROP OWNED BY and then DROP ROLE, and CREATEROLE is NOT the question
# either of them asks. Verified on postgres:14 and postgres:17, as a non-superuser
# CREATEROLE role that is not a member of the target:
#
#     DROP OWNED BY haf_stats_owner CASCADE;
#       ERROR: permission denied to drop objects
#       DETAIL: Only roles with privileges of role "haf_stats_owner" may drop objects owned by it.
#     DROP ROLE haf_stats_user;
#       ERROR: permission denied to drop role
#       DETAIL: Only roles with the CREATEROLE attribute and the ADMIN option on role
#               "haf_stats_user" may drop this role.
#
# The second rule is PG16+, and HAF's own Dockerfile pins POSTGRES_VERSION=17, so it is
# the live rule -- not a hypothetical. An earlier revision of this guard tested
# rolcreaterole alone, which answered TRUE for exactly the role that then destroyed
# everything and failed at step 5's first statement: the outcome this guard was added to
# prevent. Its error message also asserted that CREATEROLE was sufficient, which is
# false on both versions.
#
# So ask for what step 5 needs, per role it will drop: USAGE (has_privs_of_role, which
# is what DROP OWNED BY checks) and MEMBER WITH ADMIN OPTION (what DROP ROLE checks).
# Requiring the admin option is slightly stricter than PG14 demands; that costs nothing,
# because the documented and supported connection is haf_admin, which HAF creates as a
# superuser and short-circuits the first arm.
_can_drop_roles="$(psql_cmd -Atq -c "
    SELECT current_setting('is_superuser') = 'on'
        OR (COALESCE((SELECT rolcreaterole FROM pg_roles WHERE rolname = current_user), false)
            AND NOT EXISTS (
                SELECT 1 FROM pg_roles r
                WHERE r.rolname IN ('haf_stats_user', 'haf_stats_owner')
                  AND NOT (pg_has_role(current_user, r.oid, 'USAGE')
                           AND pg_has_role(current_user, r.oid, 'MEMBER WITH ADMIN OPTION'))))")" || {
    log "ERROR: could not determine whether this role may drop haf_stats's roles."
    log "       Nothing has been changed. See the psql error above."
    exit 1
}
if [ "${_can_drop_roles}" != "t" ]; then
    log "ERROR: this role cannot complete the teardown's final step, so the teardown is"
    log "       refused before anything is dropped."
    log "       Step 5 runs DROP OWNED BY -- which needs the PRIVILEGES OF haf_stats_user and"
    log "       haf_stats_owner, not CREATEROLE -- and DROP ROLE, which on PostgreSQL 16+ needs"
    log "       CREATEROLE *and* the ADMIN option on each role. Without both, the context"
    log "       and all three schemas would be dropped and step 5 would then fail."
    log "       Re-run as haf_admin (a superuser), or grant this role ADMIN option on"
    log "       haf_stats_user and haf_stats_owner. Nothing has been changed."
    _report_connected_identity
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Confirmation, and the record of what is about to go.
# ---------------------------------------------------------------------------
# BELOW the guards, which is a change from where this used to live. All three are
# read-only, and printing "About to PERMANENTLY remove" above them meant the phrase --
# the thing an operator greps a log for -- fired on runs that changed nothing: both guard
# refusals, and every probe that could not answer. (NOT the no-TTY refusal: on develop
# that check sits inside `if [ "$FORCE" -ne 1 ]` and above the banner, so it never printed
# it. An earlier revision of this comment said it did. Guard 1 has no refusal either -- a
# non-HAF database completes.) The target block at section 0 already anchors
# those to a server; this block means destruction is actually next.
#
# The TTY check comes FIRST for the same reason: no inventory ahead of a refusal.
if [ "$FORCE" -ne 1 ] && [ ! -t 0 ]; then
    log "ERROR: refusing to run without a TTY and without --force."
    log "       This drops schemas ${HAF_STATS_SCHEMAS} CASCADE and cannot be undone."
    exit 2
fi

log "About to PERMANENTLY remove haf_stats:"
log "  server   : ${_reached}"
log "  context  : ${HAF_STATS_CONTEXT}"
log "  schemas  : ${HAF_STATS_SCHEMAS} (CASCADE -- all tables and all data)"
log "  roles    : ${HAF_STATS_ROLES}"

if [ "$FORCE" -ne 1 ]; then
    # Typing the database name rather than 'yes': the mistake this guards against is the
    # right command against the wrong host. Compared against what the SERVER answered,
    # not against ${POSTGRES_DB} -- the old form compared the reply with this script's own
    # variable, so it could only ever confirm that the operator can read. It still cannot
    # distinguish two servers holding databases of the same name, which is what the
    # `server` line above is for.
    #
    # haf_fyp's uninstall_app.sh has NOT taken this step: its !56 did, and was closed, so
    # its develop still compares against ${POSTGRES_DB}. Filed there as haf_fyp#69.
    _target_db="$(psql_cmd -Atq -c "SELECT current_database()" | tr -d '\n' || true)"
    if [ -z "${_target_db}" ]; then
        log "ERROR: could not ask the server which database this is; refusing to prompt."
        exit 1
    fi
    printf '[haf_stats] Type the database name to confirm: '
    read -r _reply
    if [ "${_reply}" != "${_target_db}" ]; then
        log "Aborted -- nothing was changed."
        exit 1
    fi
    # Re-checked AFTER the prompt: an operator can start the stack from another shell
    # while this one waits for input, and upstream module files carry restart policies
    # on their app services. (This repo's own compose has no `restart:` key -- an
    # earlier revision of this comment claimed haf-stats-process was
    # `restart: unless-stopped`, which is the sibling app's compose, not this one.)
    assert_no_active_sessions
fi

# ---------------------------------------------------------------------------
# 3-5. Teardown.
# ---------------------------------------------------------------------------
# 3. The HAF context, FIRST -- while its schema still exists. hive.app_remove_context
#    drops the context's own table and views, which live in the application schema, so
#    doing this after DROP SCHEMA CASCADE would leave hafd.contexts pointing at objects
#    that are already gone. It does not detach first, but it does not need to:
#    hive.context_remove deletes the hafd.contexts_attachment row itself.
log "Removing HAF context '${HAF_STATS_CONTEXT}'..."
_psql_destructive "
DO \$\$
BEGIN
    IF to_regclass('hafd.contexts') IS NULL THEN
        RAISE NOTICE 'not a HAF database (no hafd.contexts) - skipping context removal';
        RETURN;
    END IF;
    IF hive.app_context_exists('${HAF_STATS_CONTEXT}') THEN
        PERFORM hive.app_remove_context('${HAF_STATS_CONTEXT}');
        RAISE NOTICE 'removed context ${HAF_STATS_CONTEXT}';
    ELSE
        RAISE NOTICE 'no context named ${HAF_STATS_CONTEXT} - nothing to remove';
    END IF;
END\$\$;"

# 3b. pg_cron jobs. These live in cron.job -- the `cron` schema, OUTSIDE the three
#     schemas step 4 drops -- so dropping the schemas leaves them behind, firing nightly
#     against haf_stats_app functions that no longer exist and logging an error every
#     time, forever.
#
#     install_app.sh step 8d schedules exactly these four names. Unscheduled BEFORE the
#     schemas go, so no job can fire against a half-removed app in between.
#
#     Guarded the same way the installer guards scheduling them: pg_cron is absent in CI
#     and on plenty of nodes, and cron.schedule/unschedule are only callable from the
#     database pg_cron is installed in. Never fail the teardown over it -- step 6 reports
#     any that survive.
log "Unscheduling pg_cron jobs (if any)..."
_psql_destructive "
DO \$\$
DECLARE _job text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        RAISE NOTICE 'pg_cron not installed; nothing to unschedule';
        RETURN;
    END IF;
    FOREACH _job IN ARRAY ARRAY[
        'haf_stats_governance_concentration',
        'haf_stats_hp_distribution',
        'haf_stats_rc_rates',
        'haf_stats_top_accounts_alltime'
    ] LOOP
        BEGIN
            IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = _job) THEN
                PERFORM cron.unschedule(_job);
                RAISE NOTICE 'unscheduled %', _job;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'could not unschedule % (%) - remove it manually', _job, SQLERRM;
        END;
    END LOOP;
END\$\$;"

# 4. Schemas.
for _schema in ${HAF_STATS_SCHEMAS}; do
    log "Dropping schema ${_schema} CASCADE..."
    _psql_destructive "DROP SCHEMA IF EXISTS ${_schema} CASCADE;"
done

# 5. Roles, last and conditionally. The guard reads hafd.contexts rather than assuming:
#    if any context is still owned by haf_stats_owner, dropping the role would break that
#    instead of this one. DROP OWNED BY is still needed after DROP SCHEMA -- it clears
#    the grants these roles hold on hafd and hive (db/builtin_roles.sql), and DROP ROLE
#    fails while any remain.
log "Dropping roles ${HAF_STATS_ROLES}..."
_psql_destructive "
DO \$\$
BEGIN
    -- NESTED, not a single condition of the form
    --     to_regclass(...) IS NOT NULL AND EXISTS (SELECT ... FROM hafd.contexts)
    -- PL/pgSQL plans an IF condition as one SQL expression, so the sub-select's FROM
    -- clause is resolved at parse time and the AND does not protect it -- name
    -- resolution is not short-circuited by runtime operators. An outer IF whose body is
    -- a separate statement is: plpgsql plans statements lazily, so the inner query is
    -- never planned when the outer test fails. Verified against a live PostgreSQL: the
    -- flat form errors on a missing relation, the nested form does not.
    IF to_regclass('hafd.contexts') IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM hafd.contexts WHERE owner = 'haf_stats_owner') THEN
            RAISE NOTICE 'haf_stats_owner still owns a HAF context - leaving both roles in place';
            RETURN;
        END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'haf_stats_user') THEN
        DROP OWNED BY haf_stats_user CASCADE;
        DROP ROLE haf_stats_user;
        RAISE NOTICE 'dropped role haf_stats_user';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'haf_stats_owner') THEN
        DROP OWNED BY haf_stats_owner CASCADE;
        DROP ROLE haf_stats_owner;
        RAISE NOTICE 'dropped role haf_stats_owner';
    END IF;
END\$\$;"

# ---------------------------------------------------------------------------
# 6. Verify, and say exactly what is left.
# ---------------------------------------------------------------------------
# The whole reason steps 3-5 can push past an error.
#
# Every probe captures its own failure. A command substitution inside an `if` CONDITION
# is exempt from `set -e`, so `if [ "$(psql ...)" = "t" ]` on a psql that failed yields
# "" -- not "t" -- and the context branch is skipped SILENTLY, leaving a registered
# context while the script prints "haf_stats removed" and exits 0.
log "Verifying..."
_probe_failed=0

_remaining="$(psql_cmd -Atq -f "${SCRIPT_DIR}/uninstall_verify.sql")" || _probe_failed=1
# Same catalog join as guard 1, for the same reason: to_regclass raises rather than
# returning NULL when the caller lacks USAGE on hafd.
_has_contexts="$(psql_cmd -Atq -c "
    SELECT EXISTS (SELECT 1 FROM pg_class c
                   JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'hafd' AND c.relname = 'contexts')")" || _probe_failed=1

if [ "${_has_contexts}" = "t" ]; then
    _context_left="$(psql_cmd -Atq -c \
        "SELECT 'context ' || c.name FROM hafd.contexts AS c WHERE c.name = '${HAF_STATS_CONTEXT}'")" \
        || _probe_failed=1
    if [ -n "${_context_left}" ]; then
        _remaining="${_context_left}${_remaining:+, }${_remaining}"
    fi
fi

# Surviving cron jobs, probed separately for the same reason as the context: cron.job
# only exists where pg_cron does, and a WHERE cannot protect a FROM.
#
# pg_extension, NOT to_regclass('cron.job'): to_regclass resolves the schema first and
# raises `permission denied for schema cron` -- aclcheck_error fires even under
# missing_ok -- for any caller without USAGE on it, which pg_cron does not grant by
# default. That would set _probe_failed and print "could not verify the teardown ... Do
# NOT assume it succeeded" forever, after a teardown that in fact completed. Reading
# pg_extension is a catalog lookup every role may do.
_has_cron="$(psql_cmd -Atq -c \
    "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')")" || _probe_failed=1
if [ "${_has_cron}" = "t" ]; then
    _cron_left="$(psql_cmd -Atq -c "
        SELECT string_agg('cron job ' || jobname, ', ' ORDER BY jobname)
        FROM cron.job WHERE jobname LIKE 'haf_stats\\_%'")" || _probe_failed=1
    if [ -n "${_cron_left}" ]; then
        _remaining="${_remaining:+${_remaining}, }${_cron_left}"
    fi
fi

if [ "${_probe_failed}" -ne 0 ]; then
    log "ERROR: could not verify the teardown -- a probe query failed."
    log "       Do NOT assume it succeeded. Re-run this script; it is idempotent."
    exit 1
fi

if [ -n "${_remaining}" ]; then
    log "INCOMPLETE: the following still exist: ${_remaining}"
    log "            Re-running this script is safe and will retry them. If a role"
    log "            survives, something outside this database still owns objects it"
    log "            holds privileges on; see the psql errors above."
    exit 1
fi

if [ "${_destructive_errors}" -ne 0 ]; then
    log "NOTE: ${_destructive_errors} statement(s) errored during teardown, but nothing"
    log "      remains. See the psql errors above."
fi

log "haf_stats removed. scripts/install_app.sh recreates it from scratch."
log "ALSO REVOKED, and NOT restored by a re-install: the balance-tracker grants that"
log "install_app.sh documents as a PREREQUISITE --"
log "    GRANT USAGE  ON SCHEMA btracker_backend TO haf_stats_user;"
log "    GRANT SELECT ON btracker_backend.current_account_balances_view TO haf_stats_user;"
log "They are made by the balance_tracker schema owner, not by this app, so DROP OWNED"
log "BY took them and install_app.sh will not put them back. Re-apply them after"
log "re-installing, or hp-distribution and governance-concentration return [] with"
log "nothing in the logs to say why (that is their documented empty-input contract)."
log ""
log "The grants on hafd and hive went with the roles: db/builtin_roles.sql grants them"
log "TO haf_stats_user/haf_stats_owner, so DROP OWNED BY ... CASCADE revoked them --"
log "which is why step 5 needs it at all."
log "NOT removed, because it is global and may be shared: the plpython3u extension,"
log "which db/refresh_rc_op_stats.sql creates for the RC-rate sampler."
