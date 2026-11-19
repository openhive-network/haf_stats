#!/bin/bash
# install-skips-under-app-lock (#157): HAF's application lock against a real server.
#
# app-lock-holder holds the SHARED haf_stats lock, as a block processor does (the driver's
# --lock, or the legacy loop's own call). An install now must not run, and must change
# nothing, instead of racing it: it skips with exit 0, or, with a wrapper that detects
# upgrades, fails a blocked upgrade and skips a same-version rerun. Then this releases the
# holder, and the same install must take the exclusive lock and run.
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
set_sentinel() {
    q -c "UPDATE haf_stats_app.app_version SET git_hash = '${SENTINEL}'" >/dev/null ||
        fail "could not set the app_version sentinel"
}
log="$(mktemp)"

[ "$(holder_locks)" = "1" ] || fail "app-lock-holder does not hold the shared haf_stats lock"
set_sentinel

# 1. Under the processor's lock: the install must not run. The sentinel is not the version this
#    image installs, so this is an upgrade as far as the wrapper can tell. The psql:14-3 wrapper
#    skips it with exit 0. A wrapper with hive/common-ci-configuration#85's upgrade detection
#    (it reads HAF_APP_INSTALL_VERSION, which install_app.sh sets) must fail it instead, and
#    still skip a rerun of the installed version with exit 0 (1b).
detects_upgrades=0
grep -q HAF_APP_INSTALL_VERSION /usr/local/bin/install_with_app_lock.py && detects_upgrades=1
/app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [ "${detects_upgrades}" = "1" ]; then
    [ "$rc" = "1" ] || fail "install_app exited ${rc} on an upgrade blocked by the lock; it must fail (1)"
    grep -q "Cannot install haf_stats version" "$log" || fail "the wrapper did not report the blocked upgrade"
else
    [ "$rc" = "0" ] || fail "install_app exited ${rc} while a processor held the lock; a skip exits 0"
    grep -q "Skipping haf_stats install" "$log" || fail "the wrapper did not report a skip"
fi
if grep -q "Installing haf_stats schema" "$log"; then
    fail "the install ran while a processor held the shared haf_stats lock"
fi
[ "$(q -c 'SELECT git_hash FROM haf_stats_app.app_version')" = "${SENTINEL}" ] ||
    fail "app_version was rewritten: the install ran under the lock"
echo "install-skips-under-app-lock: ok - under a processor's shared lock the install did not run and changed nothing"

if [ "${detects_upgrades}" = "1" ]; then
    # 1b. The installed version is this image's (db/version.sql writes exactly what the install
    #     would): a rerun, which skips with exit 0.
    q -f /app/db/version.sql >/dev/null || fail "could not record this image's version"
    /app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    [ "$rc" = "0" ] || fail "install_app exited ${rc} rerunning the installed version under the lock; a skip exits 0"
    grep -q "Skipping haf_stats install — version" "$log" || fail "the wrapper did not report a same-version skip"
    if grep -q "Installing haf_stats schema" "$log"; then
        fail "the install ran while a processor held the shared haf_stats lock"
    fi
    echo "install-skips-under-app-lock: ok - a rerun of the installed version skipped"
fi

# 2. Holder gone: run.
q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'ci_app_lock_holder'" >/dev/null
for _ in $(seq 1 30); do
    [ "$(holder_locks)" = "0" ] && break
    sleep 1
done
[ "$(holder_locks)" = "0" ] || fail "app-lock-holder still holds the lock after it was terminated"
set_sentinel

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
