#! /bin/sh
# Docker healthcheck for the haf_stats block-processing container (#57).
#
# Modelled on balance_tracker/docker/scripts/block-processing-healthcheck.sh, and a port
# of hive/haf_fyp's equivalent (!50) after four review rounds. Parts that look
# incidental are not:
#
#   - No 2>&1 anywhere. The verdict is a single 't'/'f' on stdout; psql's stderr goes to
#     the container log where an operator can read it. Folding stderr into the compared
#     value turns any diagnostic byte -- a locale warning, say -- into a permanent
#     verdict.
#   - `exec [ "$(...)" = t ]` as the last statement. If psql fails the substitution is
#     empty, the comparison is false, and the check fails CLOSED. No path through this
#     script reports healthy without the database having said 't'.
#   - LC_ALL=C, because a container usually has no locale and psql warns on stderr when
#     it cannot set one.
#   - The trap kills a psql still waiting on the server when Docker times the check out,
#     instead of leaving a backend behind per probe.
#
# WHAT IT REPLACES. The compose healthcheck was `psql ... -c 'SELECT 1'`, which proves
# PostgreSQL answers and says nothing about the container's job. haf_stats_app.main() is
# an infinite loop; when it wedges the process stays up, psql keeps answering, and the
# statistics silently stop advancing.
#
# THE SIGNAL is hafd.contexts.last_active_at, a HAF CORE column updated by
# hive.app_next_iteration (haf:application_loop/loop.sql).
#
# BE PRECISE ABOUT WHAT IT IS. It is written once per iteration, with a clock that is
# ALREADY ONE ITERATION OLD: `__now TIMESTAMP := NOW()` is a DECLARE initializer,
# evaluated at procedure entry, and NOW() is transaction_timestamp() -- the start of the
# caller's still-open transaction, i.e. the one that just did the PREVIOUS batch. The
# COMMIT comes after. HAF's own SLOW_PROCESSING alarm computes
# __now - __previous_active_at_time and calls it "the time since the previous call",
# which only makes sense this way.
#
# Two consequences:
#   - the value committed at the end of iteration k carries iteration k-1's start, so
#     the age this check observes spans up to TWO iteration durations. A 300s window
#     therefore tolerates iterations of about 150s, not 300s.
#   - it is NOT a sub-batch heartbeat: during one MASSIVE iteration it does not move.
#
# What it buys over the block pointer is the other case: at the chain tip the loop keeps
# calling app_next_iteration while waiting for a block, so the heartbeat ticks even
# though no block was processed. That distinguishes "idle, waiting for the chain" from
# "wedged", which a block pointer cannot.
#
# BE HONEST ABOUT THE CONVERSE. This proves the loop is ITERATING, not ADVANCING. The
# heartbeat UPDATE and its COMMIT sit BEFORE every early return in app_next_iteration
# (loop.sql: the app_is_paused and NOT is_instance_ready branches both pg_sleep and
# RETURN afterwards). So with hived down, or the app paused by hive.app_pause, the loop
# spins twice a second writing a fresh heartbeat and this check reports HEALTHY while
# zero blocks are processed. The `OR is_app_in_sync` arm has the same blindness for a
# frozen chain.
#
# Chain staleness is the agent-check's job -- hive.get_app_current_block_age. That check
# lives in haf_api_node's healthchecks image, NOT in this repo (an earlier revision of
# this comment cited a deployment/healthchecks/ path, which is a directory in the
# operator's node repo and does not exist here). It is tracked as #58. This check and
# that one are complementary, not substitutes, and this one does NOT subsume the compose
# check it replaces in that respect.
#
# The consequence, stated rather than hidden: during a long MASSIVE batch this check CAN
# report unhealthy on a perfectly healthy replay. See MAX_AGE.

set -e

# Kill a pending healthcheck SQL query if the script is interrupted (Docker timeout).
trap 'trap - 2 15 && kill -- -$$' 2 15

# Whatever the container runs as. In practice that is haf_stats_owner, because
# docker/docker-compose.yml sets POSTGRES_USER on haf-stats-process -- the haf_admin
# below is only a fallback for running this by hand. (balance_tracker is the same: its
# compose sets btracker_owner on the service carrying its healthcheck.)
#
# haf_stats_owner works because db/builtin_roles.sql puts it in
# hive_applications_owner_group -> hive_applications_group, which holds both the
# hafd.contexts RLS SELECT policy and EXECUTE on hive.*. haf_stats_user is kept out of
# that group (builtin_roles.sql removes it where an earlier install left it, #88). Note
# the mechanism: db/builtin_roles.sql grants SELECT on hafd DIRECTLY, so what hides the
# rows is RLS on a role outside hive_applications_group, not the NOINHERIT flag -- which
# is only set where builtin_roles.sql creates the role. A deployment that points this at haf_stats_user
# gets an empty result and a permanently unhealthy container with no error. The compose
# healthcheck this replaces did exactly that (`psql -U haf_stats_user -c 'SELECT 1'`),
# so it is a live foot-gun rather than a hypothetical one.
postgres_user=${POSTGRES_USER:-"haf_admin"}
postgres_host=${POSTGRES_HOST:-"haf"}
postgres_port=${POSTGRES_PORT:-5432}
postgres_db=${POSTGRES_DB:-"haf_block_log"}
# NO ${POSTGRES_URL:-...} FALLBACK. `:-` substitutes the WHOLE string, so setting
# POSTGRES_URL replaced the ?application_name= tag along with the rest -- and the
# uninstall session guard excludes this probe by exactly that literal
# (`coalesce(application_name, '') <> 'haf_stats_health_check'`). With the tag gone the
# 60-second probe counts itself, and the teardown intermittently refuses with
# "N session(s) are still connected" on a race the operator cannot reason about.
#
# Nothing else in this app honours POSTGRES_URL either: --postgres-url is
# recognised and refused by all three scripts, because honouring it moves only the
# psql connection -- this healthcheck's application_name tag, the conninfo it would
# have to be given, and a password redactor all still assume the discrete variables.
# (The teardown's own messages no longer do: since #75 it reports the server that
# answered. That half is fixed; the rest is not.) One connection path, one
# description of it.
POSTGRES_ACCESS="postgresql://$postgres_user@$postgres_host:$postgres_port/$postgres_db?application_name=haf_stats_health_check"

CONTEXT=${HAF_STATS_CONTEXT:-"haf_stats"}

# Seconds the loop may go without iterating before this reports unhealthy.
#
# Upstream hard-codes 1 minute. This is 5 minutes and configurable, and the honest
# reason is that the bound is NOT KNOWN for this app. In live sync the gap is small --
# one block per iteration, and app_next_block waits at most ~4s. The open question is
# MASSIVE, where one iteration covers a large block batch of this app's aggregation
# work. That duration has never been measured on a live node, and because of the
# one-iteration lag described above the window has to cover TWO of them: 300s here
# tolerates iterations of roughly 150s.
#
# It errs wide deliberately: too generous delays detection of a wedged loop, too tight
# reports a healthy replay as unhealthy. Narrow it once a MASSIVE batch has been timed.
MAX_AGE=${HAF_STATS_HEALTHCHECK_MAX_AGE_SECONDS:-300}

# Interpolated into SQL, so it is validated rather than trusted. Digits only.
case "${MAX_AGE}" in
    ''|*[!0-9]*)
        echo "HAF_STATS_HEALTHCHECK_MAX_AGE_SECONDS must be a whole number of seconds, got '${MAX_AGE}'" >&2
        exit 1
        ;;
esac

# Written by scripts/process_blocks.sh once the database is reachable. Absence means
# block processing has not started in this container -- a different statement from "the
# app is behind", and not healthy.
#
# -s, not -f: the writer uses a temp file and mv so it is never seen half-written, but an
# empty file is still reachable (an older image, an interrupted hand-run). Treating empty
# as "not started" reports the true state instead of feeding '' into a timestamp cast.
STARTUP_TIME_FILE=${HAF_STATS_STARTUP_TIME_FILE:-/tmp/block_processing_startup_time.txt}

if [ ! -s "${STARTUP_TIME_FILE}" ]; then
    echo "file ${STARTUP_TIME_FILE} is missing or empty, which means block"
    echo "processing hasn't started yet"
    exit 1
fi
STARTUP_TIME="$(cat "${STARTUP_TIME_FILE}")"

# The predicate lives beside this file, passed with -f and -v rather than assembled
# here. See the header of that file for why.
SQL_FILE=${HAF_STATS_HEALTHCHECK_SQL:-"$(dirname "$0")/block-processing-healthcheck.sql"}

if [ ! -r "${SQL_FILE}" ]; then
    echo "healthcheck SQL not found at ${SQL_FILE}" >&2
    exit 1
fi

# The docker container probably won't have a locale set, do this to suppress the warning
export LC_ALL=C
exec [ "$(psql "$POSTGRES_ACCESS" --quiet --no-align --tuples-only \
              -v context="${CONTEXT}" \
              -v max_age="${MAX_AGE}" \
              -v startup_time="${STARTUP_TIME}" \
              --file="${SQL_FILE}")" = t ]
