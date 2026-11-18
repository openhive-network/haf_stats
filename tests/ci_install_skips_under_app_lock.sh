#!/bin/bash
# install-skips-under-app-lock (#157): HAF's application lock against a real server.
#
# app-lock-holder holds the SHARED haf_stats lock, as a block processor does (the driver's
# --lock, or the legacy loop's own call). An install now must skip -- exit 0, and change
# nothing -- instead of racing it. Then this releases the holder, and the same install must
# take the exclusive lock and run.
#
# "Changed nothing" is read off haf_stats_app.app_version: every install that runs rewrites it
# (step 2b, db/version.sql, TRUNCATE + INSERT), so a sentinel set here survives only a skip.
#
# Negative control: the first half fails without the wrapper, or with an install that takes no
# lock, because the sentinel is rewritten.

set -uo pipefail

q() {
    psql -X -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -Atq "$@"
}

fail() {
    echo "install-skips-under-app-lock: FAIL - $*" >&2
    exit 1
}

holder_locks() {
    q -c "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
          WHERE l.locktype = 'advisory' AND l.granted AND a.application_name = 'ci_app_lock_holder'"
}

SENTINEL="ci-app-lock-sentinel"
log="$(mktemp)"

[ "$(holder_locks)" = "1" ] || fail "app-lock-holder does not hold the shared haf_stats lock"
q -c "UPDATE haf_stats_app.app_version SET git_hash = '${SENTINEL}'" >/dev/null ||
    fail "could not set the app_version sentinel"

# 1. Under the processor's lock: skip.
/app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
[ "$rc" = "0" ] || fail "install_app exited ${rc} while a processor held the lock; a skip exits 0"
grep -q "Skipping haf_stats install" "$log" || fail "the wrapper did not report a skip"
if grep -q "Installing haf_stats schema" "$log"; then
    fail "the install ran while a processor held the shared haf_stats lock"
fi
[ "$(q -c 'SELECT git_hash FROM haf_stats_app.app_version')" = "${SENTINEL}" ] ||
    fail "app_version was rewritten: the install ran under the lock"
echo "install-skips-under-app-lock: ok - under a processor's shared lock the install skipped and changed nothing"

# 2. Holder gone: run.
q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'ci_app_lock_holder'" >/dev/null
for _ in $(seq 1 30); do
    [ "$(holder_locks)" = "0" ] && break
    sleep 1
done
[ "$(holder_locks)" = "0" ] || fail "app-lock-holder still holds the lock after it was terminated"

/app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
[ "$rc" = "0" ] || fail "install_app exited ${rc} with the lock free"
grep -q "Acquired install lock for haf_stats" "$log" || fail "the install did not take the exclusive lock"
grep -q "Installing haf_stats schema" "$log" || fail "the install did not run with the lock free"
[ "$(q -c 'SELECT git_hash FROM haf_stats_app.app_version')" != "${SENTINEL}" ] ||
    fail "app_version still holds the sentinel: the install did not run"
echo "install-skips-under-app-lock: ok - with the lock free the install took it and ran"

# 3. The legacy loop's half, db/legacy_loop_lock.sql, as process_blocks.sh runs it: one session,
#    then a query in it. With HAF's lock functions (loaded here by app-lock-holder) the session
#    must hold exactly one shared lock and have the connection check on; without them (a HAF
#    before 1.28.8; here a fresh database) it must run cleanly and hold none, or the legacy loop
#    would never start on those HAFs.
LOCK_FILE=/app/db/legacy_loop_lock.sql
HELD_SQL="SELECT count(*) || ' ' || current_setting('client_connection_check_interval') FROM pg_locks
          WHERE locktype = 'advisory' AND mode = 'ShareLock' AND granted AND pid = pg_backend_pid()"
got="$(q -f "${LOCK_FILE}" -c "${HELD_SQL}" | tail -n 1)" ||
    fail "${LOCK_FILE} failed with the lock functions present"
[ "${got}" = "1 10s" ] || fail "${LOCK_FILE} with the lock functions: expected '1 10s' (one shared lock, check on), got '${got}'"

q -c "DROP DATABASE IF EXISTS ci_no_app_locks" -c "CREATE DATABASE ci_no_app_locks" >/dev/null ||
    fail "could not create a database without the lock functions"
got="$(psql -X -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d ci_no_app_locks -v ON_ERROR_STOP=1 -Atq \
        -f "${LOCK_FILE}" -c "${HELD_SQL}" | tail -n 1)" ||
    fail "${LOCK_FILE} failed on a HAF without the lock functions: the legacy loop would never start there"
q -c "DROP DATABASE ci_no_app_locks" >/dev/null
[ "${got}" = "0 10s" ] || fail "${LOCK_FILE} without the lock functions: expected '0 10s', got '${got}'"
echo "install-skips-under-app-lock: ok - the legacy loop's lock file holds the lock where HAF has it, and runs cleanly where it does not"
