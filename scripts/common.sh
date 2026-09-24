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

# ---------------------------------------------------------------------------------------
# Live block-processor guard, shared by every destructive rebuild script (#98).
#
# Each rebuild script TRUNCATEs its tables and replays them -- from block 1 by default,
# or from haf_stats_app.community_start_block() in the community-registry case.
# Running that while the block processor appends head blocks corrupts the result: five
# replay through an ADDITIVE upsert (`col = tbl.col + EXCLUDED.col`), so the processor's
# writes are counted twice -- the #42 double-count -- and writes that land before the
# TRUNCATE are lost outright. The other three are not additive: what they lose is the
# writes the TRUNCATE ate, and -- for the two cohort scripts -- a retention summary
# computed from a membership set that was still moving. The community registry replays
# roles in order, so its hazard is grants applied out of sequence.
#
# THIS LIVES IN ONE PLACE ON PURPOSE. It used to be copy-pasted into the four scripts
# that had it, and #85 is what that costs: the generic HAF driver changed how a live
# processor looks, one predicate went stale, and it had to be fixed in four files at
# once -- with four more scripts carrying no guard at all to notice it. A predicate that
# decides whether a TRUNCATE is safe should have a single home.
#
# Detection is scoped to THIS database (pg_stat_activity is cluster-wide, so an unrelated
# HAF app running its own main() elsewhere must not block us), and excludes our own
# backend by pid. The query-text arms are anchored on a LEADING CALL for a second
# reason: this SELECT contains the strings `haf_stats_app.main` and
# `haf_stats_app.process_blocks` itself, and pg_backend_pid() only excludes THIS
# session -- unanchored, two operators running two rebuild scripts at once would each
# see the other and refuse.
#
# UNDER THE GENERIC HAF DRIVER (#85) THE PRE-#85 PREDICATE WAS FALSE IN BOTH HALVES
# whenever the processor was live, so it refused nothing:
#
#   * the backend runs `CALL haf_stats_app.process_blocks(...)`, never
#     `CALL haf_stats_app.main(...)`, so the query-text match could not fire;
#   * it idles on the client between ranges BY DESIGN -- that is the point of the
#     driver -- so `state <> 'idle'` skipped it for most of the wall clock.
#
# Both loops now tag themselves `haf_stats_block_processing` -- the driver through its
# connection URI, the legacy loop through PGAPPNAME (scripts/process_blocks.sh). The two
# query-text arms are belt-and-braces for a processor container still running an image
# from before that tag existed.
#
# WHAT A FOREIGN ROLE CAN SEE, since the fallback arms depend on it. For a backend owned
# by another role, pg_stat_activity shows `query` as the literal '<insufficient privilege>'
# and NULLs `state`, unless the reader holds pg_read_all_stats/pg_monitor or is superuser:
# pg_stat_get_activity assigns both below its permission check. `application_name` is
# assigned ABOVE that check and stays visible to every role, so the arm this guard leads
# with keeps working whoever runs the rebuild -- which matters, because POSTGRES_USER is
# operator-settable. The two query arms go dead for a foreign role, so the belt-and-braces
# for a processor image predating the tag only holds when the rebuild runs as the
# processor's own role (the default: both sides default to haf_stats_owner). An earlier
# draft of this comment said all three arms die and the count comes back 0; that was
# generalised from the manual's "many columns will be null" without reading
# pgstatfuncs.c, and it is wrong.
#
# The failure directions are NOT symmetric: a false positive costs an operator a retry, a
# false negative truncates under a live writer. So this over-matches on purpose, and there
# is no `state` filter -- scripts/uninstall_app.sh's session guard has always keyed this
# way and is the reason it still catches an idle driver backend.
_LIVE_PROCESSOR_MATCH="
          AND (
               application_name = 'haf_stats_block_processing'
            OR BTRIM(query) ILIKE 'CALL%haf_stats_app.main%'
            OR BTRIM(query) ILIKE 'CALL%haf_stats_app.process_blocks%'
          )"

count_live_processors() {
    psql_cmd -Atc "
        SELECT COUNT(*)
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND datname = current_database()
          ${_LIVE_PROCESSOR_MATCH}
    "
}

# WHAT is holding it, printed on refusal. Dropping the `state` filter bought correctness
# under the driver and cost this: a backend orphaned by an abrupt container loss stays in
# pg_stat_activity, still tagged and idle, until TCP keepalive reaps it -- and with
# postgres's default tcp_keepalives_idle = 0 that is the OS default, commonly two hours.
# The pre-#85 predicate excluded such a zombie; this one matches it. Without naming the
# session, an operator who HAS stopped the container is told to stop the container.
# scripts/uninstall_app.sh reports its blocking sessions for the same reason.
report_live_processors() {
    psql_cmd -Atc "
        SELECT '  pid ' || pid
               || '  user=' || coalesce(usename, '?')
               || '  application_name=' || coalesce(nullif(application_name, ''), '(none)')
               || '  state=' || coalesce(state, '(hidden from this role)')
               || '  since ' || coalesce(to_char(backend_start, 'YYYY-MM-DD HH24:MI:SS'), '?')
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND datname = current_database()
          ${_LIVE_PROCESSOR_MATCH}
    "
}

# The consumer is bash arithmetic, so the validator has to reject what `(( ))` chokes on:
# a leading zero is read as octal (`09` -> "value too great for base", which returns 1 and
# reads as FALSE inside an `if`, i.e. "no processor"), and a value past 2^63 wraps
# negative. Neither is reachable from `SELECT COUNT(*)`, but all eight rebuild scripts now
# pass the operator-settable BATCH_SIZE, FROM_BLOCK and TO_BLOCK through here as well --
# four of them did not until #98, and `TO_BLOCK=09` made them TRUNCATE, replay nothing and
# exit 0 reporting success.
#
# The rule is AT MOST 18 DIGITS rather than a numeric comparison against 2^63-1: shell has
# no bignum compare that is itself safe on the value being validated, and 10^18 is ten
# orders of magnitude above a Hive block number (~10^8) and further still above a session
# count, so the looser bound costs nothing real.
require_number() {
    local name="$1" value="$2"
    if [[ ! "${value}" =~ ^(0|[1-9][0-9]*)$ ]] || (( ${#value} > 18 )); then
        echo "${name} must be a non-negative integer of at most 18 digits, without leading zeros; got '${value}'." >&2
        exit 2
    fi
}

# Read the count into _LIVE_PROCESSOR_COUNT, refusing outright if it cannot be read.
#
# THREE fail-open traps, all of which end in a TRUNCATE under a live writer, and all of
# which look correct:
#
#   * `if (( $(count_live_processors) > 0 ))` -- an empty result (connection reset, server
#     restart) makes that `(( > 0 ))`, an arithmetic syntax error returning 1, and set -e
#     is suppressed inside an `if` condition. The guard concludes "no processor".
#   * `local live_procs="$(count_live_processors)"` -- `local` is itself a command, so ITS
#     exit status is what set -e sees, and psql's failure is discarded.
#   * a helper that ECHOES the count back to `n="$(helper)"`. Bash unsets errexit inside a
#     command substitution unless `shopt -s inherit_errexit`, which nothing here sets, so
#     psql's exit status is discarded again -- the substitution reports the status of the
#     last command inside it, which is the echo. That form shipped in the first draft of
#     this file and was measured: with a psql that prints the count and THEN exits 1 (a
#     failover, a postmaster restart, a PgBouncer drop), rebuild_witness_blocks.sh
#     TRUNCATEd and exited 0, where the same script on develop aborted before the
#     TRUNCATE. Hence a variable, not a return value.
#
# psql's failure is therefore handled HERE and explicitly, not left to `set -e`. That makes
# the two refuse_* functions behave the same from an `if`, a `||` chain, a pipeline, a
# subshell or a `set +e` region, where errexit is suppressed and a guard that leans on it
# passes silently. All measured.
#
# ONE CALLING FORM STILL FAILS OPEN, and no function can prevent it: `if out="$(guard)"`.
# The guard runs inside the substitution, refuses correctly and exits 2 -- but that ends the
# SUBSHELL, and `if` swallows the status, so the caller proceeds. CALL THESE AS PLAIN
# STATEMENTS. All sixteen call sites in scripts/ are. An earlier draft of this comment
# claimed `exit 2` "ends the script from any context"; that is not true of that form.
#
# _LIVE_PROCESSOR_COUNT is deliberately NOT initialised: every path through
# _read_live_processor_count assigns it or exits, so an unset read means a caller did
# something unexpected, and under `set -u` that aborts instead of silently comparing an
# empty string in `(( ))` -- which is an arithmetic syntax error, i.e. false, i.e. "no
# processor".
_read_live_processor_count() {
    local rc=0
    _LIVE_PROCESSOR_COUNT="$(count_live_processors)" || rc=$?
    if (( rc != 0 )); then
        echo "Could not read the live-processor count: psql exited ${rc}." >&2
        echo "Refusing to rebuild -- this check fails CLOSED." >&2
        exit 2
    fi
    require_number "live_processor_count" "${_LIVE_PROCESSOR_COUNT}"
}

# Pre-flight. Call immediately before the first TRUNCATE.
refuse_if_processor_live() {
    _read_live_processor_count
    if (( _LIVE_PROCESSOR_COUNT > 0 )); then
        echo "The haf_stats processor is still running; refusing to rebuild." >&2
        report_live_processors >&2 || true
        echo "Stop it first: stop the haf-stats-process container, then re-run." >&2
        echo "  If the container is ALREADY stopped, the session above is an orphaned backend" >&2
        echo "  left by an abrupt stop; it clears on TCP keepalive (often two hours) or at once" >&2
        echo "  with SELECT pg_terminate_backend(<pid>);" >&2
        echo "  Nothing else clears this check, and that is deliberate. It keys on the" >&2
        echo "  processor's CONNECTION, not on what the connection is doing, because under the" >&2
        echo "  HAF driver an idle connection is a working processor between ranges." >&2
        echo "  So: haf_stats_app.stop_processing() stops only the legacy CALL main() loop, and" >&2
        echo "  hive.app_pause('haf_stats') stops the driver taking new ranges but leaves it" >&2
        echo "  connected -- this check still refuses on both." >&2
        exit 2
    fi
}

# Post-replay. The pre-flight check is inherently TOCTOU over a multi-minute replay, so
# re-check before publishing: a processor started mid-rebuild has been writing head blocks
# into tables being rebuilt from block 1. (Under the legacy loop stop_processing() makes
# main() return, so process_blocks.sh exits and the container can restart under its restart
# policy, re-arming itself via allow_processing() -- this is a plausible race, not a
# theoretical one.)
#
# Each argument is one line of the caller's own consequence text, because the consequence
# differs: an additive upsert double-counts, while a membership set keyed ON CONFLICT DO
# NOTHING is merely rebuilt from a table that was still moving. A wrong sentence here would
# send an operator looking for corruption that is not there, or reassure one whose numbers
# are wrong.
#
# A call with nothing to say is refused rather than defaulted, and `set -u` does NOT make
# that check redundant: this reads "$@", not "$1", and "$@" with no positional parameters
# expands to nothing under `set -u` rather than erroring. No arguments, an empty one, or a
# whitespace-only one all produce the same blank consequence line followed by "Stop it and
# re-run this script." -- a refusal that fails to say what went wrong on the one path that
# matters. Note the rule is ANY argument with words in it, so a blank line MIXED with real
# ones still prints; what it prevents is a refusal that says nothing at all.
refuse_if_processor_started_during_rebuild() {
    local _line _said=0
    for _line in "$@"; do
        [[ -n "${_line//[[:space:]]/}" ]] && _said=1
    done
    if (( _said == 0 )); then
        echo "refuse_if_processor_started_during_rebuild needs a consequence line with words in it." >&2
        exit 2
    fi
    _read_live_processor_count
    if (( _LIVE_PROCESSOR_COUNT > 0 )); then
        echo "The haf_stats processor STARTED DURING the rebuild." >&2
        printf '%s\n' "$@" >&2
        report_live_processors >&2 || true
        echo "Stop it and re-run this script." >&2
        exit 2
    fi
}
