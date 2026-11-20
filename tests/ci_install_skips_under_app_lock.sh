#!/bin/bash
# install-skips-under-app-lock (#157): HAF's application lock against a real server.
#
# app-lock-holder holds the SHARED haf_stats lock, as a block processor does (the driver's
# --lock, or the legacy loop's own call). An install now must not run, and must change
# nothing, instead of racing it: it fails a blocked upgrade (exit 1) and skips a same-version
# rerun (exit 0). Then this releases the
# holder, and the same install must take the exclusive lock and run.
#
# "Changed nothing" is read off haf_stats_app.app_version: every install that runs rewrites it
# (step 2b, db/version.sql, TRUNCATE + INSERT), so a sentinel set here survives only a skip.
#
# Negative control: the first half fails without the wrapper, or with an install that takes no
# lock, because the sentinel is rewritten.
#
# Step 4 then runs the processor's driver path itself, as the processor container does, and
# checks the same against the lock haf_app_driver.py's --lock holds.

set -uo pipefail

q() {
    psql -X -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -Atq "$@"
}

fail() {
    echo "install-skips-under-app-lock: FAIL - $*" >&2
    exit 1
}

# Shared locks on haf_stats, under hive._try_app_lock's key (the one the install tries), held by
# the backends named APPLICATION_NAME.
shared_locks() {
    q -c "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
          WHERE l.locktype = 'advisory' AND l.mode = 'ShareLock' AND l.granted
            AND l.classid = hashtext('hive_fork_manager_app_lock')::oid AND l.objid = hashtext('haf_stats')::oid
            AND a.application_name = '$1'"
}

holder_locks() {
    shared_locks ci_app_lock_holder
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
#    image installs, so this is an upgrade. install_app.sh waits HAF_STATS_INSTALL_LOCK_WAIT
#    seconds for the holder, then fails the blocked upgrade (exit 1) rather than skip it with
#    exit 0, whichever wrapper the image has: the psql:14-3 wrapper skips and install_app.sh's
#    own check fails it ("was NOT installed"); a wrapper with hive/common-ci-configuration#85's
#    upgrade detection (it reads HAF_APP_INSTALL_VERSION) fails it itself. An image built
#    without a usable GIT_HASH ("unspecified") cannot tell an upgrade from a rerun and skips.
#    1b: a rerun of the installed version skips with exit 0.
detects_upgrades=0
grep -q HAF_APP_INSTALL_VERSION /usr/local/bin/install_with_app_lock.py && detects_upgrades=1
image_version="$(sed -n "s/.*VALUES ('\([A-Za-z0-9._-]*\)').*/\1/p" /app/db/version.sql)"
/app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [ "${image_version}" = "unspecified" ] || [ -z "${image_version}" ]; then
    [ "$rc" = "0" ] || fail "install_app exited ${rc} under the lock with an unversioned image; a skip exits 0"
    grep -q "Skipping haf_stats install" "$log" || fail "the wrapper did not report a skip"
else
    [ "$rc" = "1" ] || fail "install_app exited ${rc} on an upgrade blocked by the lock; it must fail (1)"
    grep -q "waiting up to ${HAF_STATS_INSTALL_LOCK_WAIT:-60}s for the block processor" "$log" ||
        fail "install_app did not wait for the holder before giving up"
    if [ "${detects_upgrades}" = "1" ]; then
        grep -q "Cannot install haf_stats version" "$log" || fail "the wrapper did not report the blocked upgrade"
    else
        grep -q "Skipping haf_stats install" "$log" || fail "the wrapper did not report a skip"
        grep -q "version ${image_version} was NOT installed" "$log" ||
            fail "install_app did not fail the upgrade the wrapper skipped"
    fi
fi
if grep -q "Installing haf_stats schema" "$log"; then
    fail "the install ran while a processor held the shared haf_stats lock"
fi
[ "$(q -c 'SELECT git_hash FROM haf_stats_app.app_version')" = "${SENTINEL}" ] ||
    fail "app_version was rewritten: the install ran under the lock"
echo "install-skips-under-app-lock: ok - under a processor's shared lock the install did not run and changed nothing"

# 1b. The installed version is this image's (db/version.sql writes exactly what the install
#     would): a rerun, which skips with exit 0 and does not wait.
q -f /app/db/version.sql >/dev/null || fail "could not record this image's version"
/app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
[ "$rc" = "0" ] || fail "install_app exited ${rc} rerunning the installed version under the lock; a skip exits 0"
grep -q "Skipping haf_stats install" "$log" || fail "the wrapper did not report a same-version skip"
if grep -q "waiting up to" "$log"; then
    fail "install_app waited for the holder on a rerun of the installed version"
fi
if grep -q "Installing haf_stats schema" "$log"; then
    fail "the install ran while a processor held the shared haf_stats lock"
fi
echo "install-skips-under-app-lock: ok - a rerun of the installed version skipped"

# 1c. HAF_INSTALL_LOCK_HELD is shared with six other apps' installers, which set it to 1. One
#     exported here must not pass for install_app.sh's own re-run: the install still goes
#     through the wrapper, and skips.
HAF_INSTALL_LOCK_HELD=1 /app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
[ "$rc" = "0" ] || fail "install_app exited ${rc} under the lock with another app's HAF_INSTALL_LOCK_HELD; a skip exits 0"
grep -q "Skipping haf_stats install" "$log" ||
    fail "with another app's HAF_INSTALL_LOCK_HELD the install did not go through the lock wrapper"
if grep -q "Installing haf_stats schema" "$log"; then
    fail "with another app's HAF_INSTALL_LOCK_HELD the install ran under the shared haf_stats lock"
fi
echo "install-skips-under-app-lock: ok - another app's HAF_INSTALL_LOCK_HELD did not bypass the lock"

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
#    would never start on those HAFs. Only the haf_stats lock counts, under hive._try_app_lock's
#    key, the one the install tries and app_lock_holders (scripts/common.sh) waits on: a lock
#    under any other key or app name would let an install run over the loop.
LOCK_FILE=/app/db/legacy_loop_lock.sql
HELD_SQL="SELECT count(*) || ' ' || current_setting('client_connection_check_interval') FROM pg_locks
          WHERE locktype = 'advisory' AND mode = 'ShareLock' AND granted AND pid = pg_backend_pid()
            AND classid = hashtext('hive_fork_manager_app_lock')::oid AND objid = hashtext('haf_stats')::oid"
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

# 4. The driver's half: scripts/process_blocks.sh run as the processor container runs it, down
#    its haf_app_driver.py path, with the --lock=haf_stats it passes. The stub has no
#    application registry and streams no blocks, so for this step it gets stand-ins: a
#    hafd.applications listing haf_stats with its entry procedure, and the three hive functions
#    the driver calls while it idles. hive.app_next_iteration delivers no range, unless
#    ci163_driver.busy is set: then it sleeps, as a range being processed keeps the backend
#    busy. Created only where the stub has none, and dropped before the install that ends this.
#
#    a. While the driver runs, a rerun of the installed version skips with exit 0 and leaves
#       app_version as it was (its row's xmin: every install that runs rewrites it, step 2b).
#    b. SIGKILLed in the middle of a range, its backend lets go of the lock within 15 s: the
#       client_connection_check_interval process_blocks.sh gives the driver's connection. A
#       backend without it holds the lock until the range ends, here 120 s.
#    c. Driver gone, the install takes the lock and runs.
DRIVER_APP=haf_stats_block_processing
driver_pid=""
cleanup_driver() {
    [ -z "${driver_pid}" ] || kill -9 "${driver_pid}" 2>/dev/null
    q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '${DRIVER_APP}'" >/dev/null 2>&1
}
trap cleanup_driver EXIT

[ "$(q -c "SELECT to_regclass('hafd.applications') IS NULL
              AND to_regprocedure('hive.app_is_paused(hive.contexts_group)') IS NULL
              AND to_regprocedure('hive.app_dependencies_block_limit(hive.contexts_group)') IS NULL
              AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                              WHERE n.nspname = 'hive' AND p.proname = 'app_next_iteration')")" = "t" ] ||
    fail "the stub now has an application registry or block streaming of its own; step 4's stand-ins would replace it"
q <<'SQL' >/dev/null || fail "could not set up the driver's stand-ins"
CREATE TABLE public.ci163_driver (busy BOOLEAN NOT NULL);
INSERT INTO public.ci163_driver VALUES (FALSE);
CREATE TABLE hafd.applications (
    name TEXT PRIMARY KEY, contexts TEXT[] NOT NULL, process_procedure TEXT, paused BOOLEAN NOT NULL);
INSERT INTO hafd.applications VALUES ('haf_stats', ARRAY['haf_stats'], 'haf_stats_app.process_blocks', FALSE);
CREATE PROCEDURE hive.app_next_iteration(
    _contexts hive.contexts_group, _blocks_range OUT hive.blocks_range,
    _override_max_batch INT = NULL, _limit INT = NULL, _wait BOOLEAN = TRUE)
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT busy FROM public.ci163_driver) THEN
        PERFORM pg_sleep(120);
    END IF;
    _blocks_range := NULL;
END;
$$;
CREATE FUNCTION hive.app_is_paused(_contexts hive.contexts_group)
RETURNS BOOLEAN LANGUAGE sql AS $$ SELECT FALSE $$;
CREATE FUNCTION hive.app_dependencies_block_limit(_contexts hive.contexts_group)
RETURNS INT LANGUAGE sql AS $$ SELECT NULL::INT $$;
SQL
drop_driver_stand_ins() {
    q -c "DROP PROCEDURE hive.app_next_iteration(hive.contexts_group, hive.blocks_range, INT, INT, BOOLEAN)" \
      -c "DROP FUNCTION hive.app_is_paused(hive.contexts_group)" \
      -c "DROP FUNCTION hive.app_dependencies_block_limit(hive.contexts_group)" \
      -c "DROP TABLE hafd.applications" -c "DROP TABLE public.ci163_driver" >/dev/null
}

plog="$(mktemp)"
HAF_STATS_STARTUP_TIME_FILE="$(mktemp)" /app/docker_entrypoint.sh process_blocks >"$plog" 2>&1 &
driver_pid=$!
for _ in $(seq 1 30); do
    [ "$(shared_locks "${DRIVER_APP}")" = "1" ] && break
    kill -0 "${driver_pid}" 2>/dev/null || break
    sleep 1
done
if [ "$(shared_locks "${DRIVER_APP}")" != "1" ]; then
    cat "$plog"
    fail "the driver does not hold the shared haf_stats lock"
fi
grep -q "running haf_app_driver.py" "$plog" || { cat "$plog"; fail "process_blocks.sh did not take the driver path"; }

# a.
q -f /app/db/version.sql >/dev/null || fail "could not record this image's version"
version_row="$(q -c 'SELECT xmin FROM haf_stats_app.app_version')"
/app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
[ "$rc" = "0" ] || fail "install_app exited ${rc} rerunning the installed version under the driver; a skip exits 0"
grep -q "Skipping haf_stats install" "$log" || fail "the wrapper did not report a skip under the driver's lock"
if grep -q "Installing haf_stats schema" "$log"; then
    fail "the install ran while the driver held the shared haf_stats lock"
fi
[ "$(q -c 'SELECT xmin FROM haf_stats_app.app_version')" = "${version_row}" ] ||
    fail "app_version was rewritten: the install ran under the driver's lock"
echo "install-skips-under-app-lock: ok - under the driver's lock a rerun of the installed version skipped and changed nothing"

# b.
if [ "$(q -c "SELECT current_setting('server_version_num')::INT >= 140000")" = "t" ]; then
    q -c "UPDATE public.ci163_driver SET busy = TRUE" -c "NOTIFY haf_new_block" >/dev/null ||
        fail "could not start the driver's range"
    for _ in $(seq 1 60); do
        [ "$(q -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '${DRIVER_APP}' AND wait_event = 'PgSleep'")" = "1" ] && break
        sleep 0.5
    done
    [ "$(q -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '${DRIVER_APP}' AND wait_event = 'PgSleep'")" = "1" ] ||
        { cat "$plog"; fail "the driver's backend never got busy in a range"; }
    kill -9 "${driver_pid}"
    wait "${driver_pid}" 2>/dev/null
    driver_pid=""
    killed_at=${SECONDS}
    while [ "$(shared_locks "${DRIVER_APP}")" != "0" ] && [ $((SECONDS - killed_at)) -le 40 ]; do
        sleep 0.5
    done
    released_in=$((SECONDS - killed_at))
    [ "$(shared_locks "${DRIVER_APP}")" = "0" ] ||
        fail "the SIGKILLed driver's backend still holds the shared haf_stats lock after ${released_in} s"
    [ "${released_in}" -le 15 ] ||
        fail "the SIGKILLed driver's backend held the shared haf_stats lock for ${released_in} s; expected 15 s at most"
    echo "install-skips-under-app-lock: ok - SIGKILLed mid-range, the driver's backend released the lock within ${released_in} s"
else
    echo "install-skips-under-app-lock: note - PostgreSQL before 14 has no client_connection_check_interval; the SIGKILL check is skipped"
    kill -9 "${driver_pid}"
    wait "${driver_pid}" 2>/dev/null
    driver_pid=""
    q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '${DRIVER_APP}'" >/dev/null
fi

# c.
drop_driver_stand_ins || fail "could not drop the driver's stand-ins"
set_sentinel
/app/docker_entrypoint.sh install_app "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
[ "$rc" = "0" ] || fail "install_app exited ${rc} with the driver stopped"
grep -q "Acquired install lock for haf_stats" "$log" || fail "the install did not take the exclusive lock once the driver stopped"
grep -q "Installing haf_stats schema" "$log" || fail "the install did not run once the driver stopped"
[ "$(q -c 'SELECT git_hash FROM haf_stats_app.app_version')" != "${SENTINEL}" ] ||
    fail "app_version still holds the sentinel: the install did not run once the driver stopped"
echo "install-skips-under-app-lock: ok - with the driver stopped the install took the lock and ran"
