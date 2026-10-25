#!/usr/bin/env bash
# The step functions are called indirectly, through `step`.
# shellcheck disable=SC2317,SC2329
# The checks AIDEV's verification slots run (.aidev/project.yaml), as junit reports
# per suite: each named step is a test case, its log the failure body.
#
#   .aidev/run-checks.sh <suite> <step>...
#
# Each step is one of the project's own CI jobs, run as .gitlab-ci.yml runs it:
#   - shellcheck      shell-lint: shellcheck --severity=warning on scripts/ and
#                     docker/ (and at the default severity on .aidev/'s own scripts)
#   - ci-shell-lint   ci-shell-lint: the shell blocks of .gitlab-ci.yml, extracted by
#                     scripts/ci-helpers/extract_ci_shell.py, through shellcheck
#   - unit            shell-tests: pytest tests/unit/ (one junit case per test, unit.xml)
#   - sql-lint        sql-lint: sqlfluff 3.3.0 over db/ endpoints/, scripts/, docker/
#   - hadolint        hadolint: hadolint --ignore DL3006 Dockerfile
#   - compose-validate compose-validate: `docker compose config` on the six compose
#                     files, with that job's placeholder variables (no daemon)
#   - openapi-drift   openapi-drift: scripts/openapi_rewrite.sh (its COMMON_CI_OFFLINE
#                     mode, over the generator and venv baked into the runtime image)
#                     on a copy of the tree must reproduce endpoints/; the served
#                     OpenAPI document must validate
#   - stack-pins      the images .aidev/ runs stand in for the ones CI names: the
#                     stack's postgres tag is the CI compose files' one, the runtime's
#                     postgrest and openresty bases are docker-compose-ci.yml's and
#                     Dockerfile.rewriter's (reads only the tree)
#   - endpoint        endpoint-tests: docker/docker-compose-ci.yml (mock hafd, the
#                     real processors over fixtures, parity and oracle checks, postgrest,
#                     the shipped rewriter, tavern -m 'negative or synthetic'), replayed
#                     by .aidev/compose_lane.py; endpoint.xml per service, tavern.xml
#                     per tavern test
#   - install         install-test: docker/docker-compose-ci-install.yml (baseline
#                     install from .baseline/, upgrade, reset, install, seed repair,
#                     break-schema + install-again, install under a lock holder,
#                     verify, uninstall --force, verify-gone), replayed the same way;
#                     install.xml per service
#
# CI's synced lane, over this run's copy-on-write clone of the shared 5M-block HAF
# (haf_shared.clone_run_database on AIDEV_EXTERNAL_HAF_HOST:_PORT, as
# haf_shared_consumer, which is a member of haf_stats_owner there):
#   - sync            sync: scripts/install_app.sh into the clone, then the block
#                     processing (haf_app_driver.py, as scripts/process_blocks.sh runs
#                     it, as haf_stats_owner) to block 5,000,000, with
#                     haf_stats.processor_timings on. The context is still in massive
#                     sync at 5,000,000, which defers the rollup refreshes to its first
#                     live batch, and the lane never reaches one: so, with the driver
#                     gone between two batches as a crash would leave it,
#                     tests/ci_deferred_refresh_recorded.sql; then, timed apart from the
#                     sync, the call that batch makes,
#                     haf_stats_app.prepare_rollup_refreshes(FALSE) (deferred-refresh.log);
#                     then tests/ci_deferred_refresh_complete.sql (.gitlab-ci.yml's
#                     sync job runs the same three steps; keep them in step); then
#                     scripts/processor_timings_report.py over both logs:
#                     processor-timings.json and its table
#   - pattern         pattern-test: tavern -m 'not negative and not synthetic' against
#                     PostgREST over the clone (anon role haf_stats_user); one junit
#                     case per tavern test, pattern.xml
#   - regression      regression-test: scripts/run_verification.sh over the clone
#   - reinstall       reinstall-test: scripts/install_app.sh again; the three schemas'
#                     definitions (.aidev/schema_snapshot.sql) unchanged, the synced
#                     block unchanged, and both installs' privileges
#                     (tests/privileges.sql) tests/expected_privileges.txt
#
# endpoint and install need the stack (.aidev/test-stack.compose.yml): its
# `postgres` service is the one both CI compose files start. Each lane starts on a
# freshly created haf_block_log with the app's roles dropped, as a fresh container
# gives CI. pattern, regression and reinstall need sync; the clone is dropped when
# the script exits, pass or fail. Reports go to test-results/<suite>/.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

suite="${1:?usage: $0 <suite> <step>...}"; shift
out="test-results/$suite"
rm -rf "$out"; mkdir -p "$out"
cases="$out/cases.tsv"; : > "$cases"
py=/opt/venv/bin/python3

STOP_AT_BLOCK=5000000
# The shared HAF trusts haf_shared_consumer from the fleet LAN: no password.
consumer_url="postgresql://haf_shared_consumer@${AIDEV_EXTERNAL_HAF_HOST:-}:${AIDEV_EXTERNAL_HAF_PORT:-5432}"
clone=""; clone_id=""; clone_url=""; stage=""; synced=""
# The script's own stderr, which a step's redirected output does not reach: where
# the clone's name and its drop are reported.
exec 3>&2

status=0
# record CASES_FILE NAME RC SECONDS LOG
record() {
    if [ "$3" -eq 0 ]; then
        printf 'case\t%s\tpass\t%s\t\n' "$2" "$4" >> "$1"
    else
        printf 'case\t%s\tfail\t%s\texit %s\t%s\n' "$2" "$4" "$3" "$5" >> "$1"
    fi
}

step() {
    local name="$1"; shift
    local log="$out/$name.log" t0=$SECONDS rc=0
    echo "== $name" >&2
    "$@" > "$log" 2>&1 < /dev/null || rc=$?
    [ "$rc" -eq 0 ] || { status=1; tail -40 "$log" >&2; }
    record "$cases" "$name" "$rc" "$((SECONDS - t0))" "$log"
}

run_shellcheck() {
    shellcheck --version | head -2
    find scripts/ docker/ -name "*.sh" -exec shellcheck --severity=warning {} + || return 1
    shellcheck .aidev/*.sh .aidev/runtime/*.sh
}

ci_shell_lint() {
    local d
    d="$(mktemp -d)"
    python3 scripts/ci-helpers/extract_ci_shell.py .gitlab-ci.yml "$d" || return 1
    shellcheck --severity=warning "$d"/*.sh
}

unit() {
    PYTHONPATH=. pytest tests/unit/ -q -p no:cacheprovider --junitxml="$1"
}

sql_lint() {
    sqlfluff lint db/ endpoints/ --dialect postgres || return 1
    sqlfluff lint scripts/ --dialect postgres || return 1
    sqlfluff lint docker/ --dialect postgres --exclude-rules LT01,LT02,LT14
}

run_hadolint() {
    hadolint --version
    hadolint --ignore DL3006 Dockerfile
}

# compose-validate's variables, verbatim.
compose_validate() {
    (
        cd docker || exit 1
        export HAF_IMAGE_NAME="registry.example.com/haf/instance:latest" \
            HAF_STATS_IMAGE="registry.example.com/haf_stats:latest" \
            POSTGREST_IMAGE="registry.example.com/postgrest:latest" \
            HAF_REGISTRY="registry.example.com" HAF_VERSION="latest" \
            HAF_STATS_REGISTRY="registry.example.com" HAF_STATS_VERSION="latest" \
            POSTGREST_VERSION="latest" HAF_DATA_DIRECTORY="/tmp/haf_data" \
            HAF_SHM_DIRECTORY="/tmp/haf_shm"
        docker compose -f docker-compose.yml -f overrides/ci.yml config --quiet &&
            docker compose -f docker-compose-ci-test.yml config --quiet &&
            docker compose -f docker-compose-ci-install.yml config --quiet &&
            env -u HAF_STATS_IMAGE docker compose -f docker-compose-ci-test.yml config --quiet &&
            docker compose -f docker-compose-ci.yml config --quiet &&
            docker compose --env-file .env -f docker-compose-test.yml config --quiet
    )
}

# CI regenerates in its checkout and asks git whether endpoints/ moved; here the
# generator runs on a copy, so a candidate's uncommitted edits are compared too.
openapi_drift() {
    local ref want copy
    ref="$(sed -n 's/^ *COMMON_CI_REF: *"\([0-9a-f]*\)" *$/\1/p' .gitlab-ci.yml)"
    want="96889a650b3f45244cecc4bb3f250af439a71900"
    if [ "$ref" != "$want" ]; then
        echo "STALE: .gitlab-ci.yml COMMON_CI_REF is '$ref'; the runtime image bakes process_openapi.py at $want: rebuild it (.aidev/README.md)"
        return 1
    fi
    copy="$(mktemp -d)"
    tar --exclude=./.git --exclude=./test-results -cf - . | tar -xf - -C "$copy" || return 1
    cp /opt/openapi/process_openapi.py "$copy/scripts/process_openapi.py"
    rm -rf "$copy/.openapi_venv"; ln -s /opt/openapi-venv "$copy/.openapi_venv"
    (cd "$copy" && COMMON_CI_OFFLINE=1 COMMON_CI_REF="$ref" bash scripts/openapi_rewrite.sh) || return 1
    if ! diff -ru endpoints "$copy/endpoints"; then
        echo "ERROR: endpoints/ is not what scripts/openapi_rewrite.sh generates."
        echo "Run it locally and commit the result."
        return 1
    fi
    echo "endpoints/ matches the generator."
    "$py" .aidev/openapi_valid.py endpoints/endpoint_schema.sql
}

stack_pins() {
    local stale=0 tag f
    tag="$(sed -n 's/^ *image: *\(postgres:[^@ ]*\)@sha256:[0-9a-f]\{64\} *$/\1/p' .aidev/test-stack.compose.yml)"
    [ -n "$tag" ] || { echo ".aidev/test-stack.compose.yml pins no postgres:<tag>@sha256:<digest>"; return 1; }
    echo "stack: $tag"
    for f in docker/docker-compose-ci.yml docker/docker-compose-ci-install.yml; do
        if grep -q "image: *postgres:" "$f" && grep "image: *postgres:" "$f" | grep -vq "image: *$tag *$"; then
            echo "STALE: $f runs $(grep -o 'image: *postgres:[^ ]*' "$f" | sort -u | tr '\n' ' ')- the stack pins $tag"
            stale=1
        fi
    done
    tag="$(sed -n 's/^ *image: *postgrest\/postgrest:\([^ ]*\) *$/\1/p' docker/docker-compose-ci.yml)"
    if ! grep -q "^FROM postgrest/postgrest:$tag@sha256:" .aidev/runtime/Dockerfile; then
        echo "STALE: docker/docker-compose-ci.yml runs postgrest $tag; .aidev/runtime/Dockerfile copies another"
        stale=1
    else
        echo "postgrest: $tag"
    fi
    tag="$(sed -n 's/^FROM \(registry.gitlab.syncad.com\/hive\/common-ci-configuration\/nginx:[0-9a-f]*\) *$/\1/p' Dockerfile.rewriter)"
    if [ -z "$tag" ] || ! grep -q "^FROM $tag@sha256:" .aidev/runtime/Dockerfile; then
        echo "STALE: Dockerfile.rewriter is FROM '$tag'; .aidev/runtime/Dockerfile's base is another"
        stale=1
    else
        echo "rewriter base: $tag"
    fi
    return "$stale"
}

# A fresh haf_block_log and none of the roles a lane creates: what a new postgres
# container gives each CI lane.
reset_db() {
    local admin="postgresql://postgres:postgres@postgres:5432/postgres"
    psql "$admin" -X -v ON_ERROR_STOP=1 -q <<'SQL'
DROP DATABASE IF EXISTS haf_block_log WITH (FORCE);
DO $$
DECLARE r text;
BEGIN
  FOR r IN SELECT rolname FROM pg_roles WHERE rolname <> 'postgres' AND rolname NOT LIKE 'pg\_%' LOOP
    EXECUTE format('DROP ROLE %I', r);
  END LOOP;
END $$;
CREATE DATABASE haf_block_log;
SQL
}

endpoint() {
    reset_db || return 1
    "$py" .aidev/compose_lane.py docker/docker-compose-ci.yml tavern "$out/endpoint" endpoint
}

# install-test's baseline is develop's tip, or its parent when the pipeline is
# develop. Here: HEAD, or HEAD's parent when the tree's db/, endpoints/ and scripts/
# are HEAD's (AIDEV_INSTALL_BASELINE overrides).
install() {
    local base d
    base="${AIDEV_INSTALL_BASELINE:-}"
    if [ -z "$base" ]; then
        base="$(git rev-parse HEAD)" || return 1
        if git diff --quiet HEAD -- db endpoints scripts && git rev-parse -q --verify HEAD~1 >/dev/null; then
            base="$(git rev-parse HEAD~1)"
        fi
    fi
    echo "install-test: baseline = $base"
    rm -rf .baseline && mkdir -p .baseline
    git archive "$base" db endpoints scripts | tar -x -C .baseline || return 1
    for d in db endpoints scripts; do
        [ -n "$(ls -A ".baseline/$d" 2>/dev/null)" ] || { echo "FAIL: .baseline/$d is missing or empty after extracting $base"; return 1; }
    done
    find .baseline/scripts -name '*.sh' -exec chmod +x {} +
    reset_db || return 1
    local rc=0
    "$py" .aidev/compose_lane.py docker/docker-compose-ci-install.yml verify-gone "$out/install" install || rc=$?
    rm -rf .baseline
    return "$rc"
}

# This run's own clone of the shared HAF, named after the suite, the time and a
# random suffix so concurrent runs never share one.
open_clone() {
    [ -n "$clone" ] && return 0
    if [ -z "${AIDEV_EXTERNAL_HAF_HOST:-}" ]; then
        echo "AIDEV_EXTERNAL_HAF_HOST is unset: this step needs sandbox.external haf (provider haf/haf)"
        return 1
    fi
    local run_id
    run_id="haf-stats-$suite-$(date -u +%Y%m%d%H%M%S)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    clone="$(psql "$consumer_url/haf_shared" -X -v ON_ERROR_STOP=on -Atc "select haf_shared.clone_run_database('$run_id')")" || { clone=""; return 1; }
    clone_id="$run_id"
    clone_url="$consumer_url/$clone"
    echo "== shared HAF clone $clone ($consumer_url)" | tee /dev/fd/3
}

drop_clone() {
    [ -n "$clone" ] || return 0
    if psql "$consumer_url/haf_shared" -X -v ON_ERROR_STOP=on -qAtc "select haf_shared.drop_run_database('$clone_id')"; then
        echo "== dropped shared HAF clone $clone" >&3
    else
        echo "== could not drop shared HAF clone $clone; the provider reaps it after its TTL" >&3
    fi
}

cleanup() {
    drop_clone
    if [ -n "$stage" ]; then rm -rf "$stage"; fi
}
trap cleanup EXIT

cq() { psql "$clone_url" -X -v ON_ERROR_STOP=on "$@"; }

# The installed sources with the db/version.sql the Dockerfile bakes (its 8-character
# GIT_HASH), in a scratch directory so the tree stays clean.
stage_sources() {
    [ -n "$stage" ] && return 0
    local hash
    stage="$(mktemp -d)"
    cp -r db endpoints scripts "$stage/" || return 1
    hash="$(git rev-parse HEAD 2>/dev/null | cut -c1-8)"
    printf "TRUNCATE haf_stats_app.app_version; INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('%s');\n" \
        "${hash:-unspecified}" > "$stage/db/version.sql"
}

# As the consumer: the roles are the shared HAF's, and db/builtin_roles.sql leaves
# them as it finds them when they already hold what it would set.
clone_install() {
    (cd "$stage" && POSTGRES_HOST="$AIDEV_EXTERNAL_HAF_HOST" POSTGRES_PORT="${AIDEV_EXTERNAL_HAF_PORT:-5432}" \
        POSTGRES_USER=haf_shared_consumer POSTGRES_DB="$clone" bash scripts/install_app.sh)
}

current_block() {
    cq -Atc "SELECT COALESCE(MAX(last_processed_block), 0) FROM haf_stats_app.app_status"
}

# The runtime's python3 is /opt/venv's; psycopg2, which haf_app_driver.py needs, is
# the system interpreter's. The sync runs with haf_stats.processor_timings on
# (db/process_block_range.sql): the INFO lines it adds reach the driver's log only at
# --server-messages=INFO, and change nothing the processors write. The lines a failed
# batch leaves are kept in the log too, but no report is made from them.
sync_blocks() {
    local block t0 seconds deferred_seconds driver_log="$out/sync-driver.log" deferred_log="$out/deferred-refresh.log"
    stage_sources && open_clone || return 1
    # The consumer owns the clone; haf_stats_owner creates its schemas in it.
    cq -c "GRANT CREATE ON DATABASE \"$clone\" TO haf_stats_owner" || return 1
    clone_install || return 1
    t0="$(date +%s.%N)"
    if ! /usr/bin/python3 "$(command -v haf_app_driver.py)" --app=haf_stats \
        --postgres-url="$clone_url?application_name=haf_stats_block_processing&options=-c%20role%3Dhaf_stats_owner%20-c%20haf_stats.processor_timings%3Don" \
        --stop-at-block="$STOP_AT_BLOCK" --startup-marker='' --server-messages=INFO > "$driver_log" 2>&1; then
        echo "the block processing failed; the end of its log ($driver_log):"
        grep -v 'haf_stats_processor_timing\|haf_stats_operation_counts' "$driver_log" | tail -40
        return 1
    fi
    seconds="$(echo "$t0 $(date +%s.%N)" | awk '{ printf "%.3f\n", $2 - $1 }')"
    echo "block processing took ${seconds}s; driver log $driver_log ($(wc -l < "$driver_log") lines)"
    block="$(current_block)" || return 1
    echo "processed up to block $block"
    [ "$block" -ge "$STOP_AT_BLOCK" ] || { echo "expected block $STOP_AT_BLOCK"; return 1; }
    cq -f tests/ci_deferred_refresh_recorded.sql || return 1
    t0="$(date +%s.%N)"
    if ! cq -c "SET ROLE haf_stats_owner; SET haf_stats.processor_timings = on; SELECT haf_stats_app.prepare_rollup_refreshes(FALSE);" \
        > "$deferred_log" 2>&1; then
        echo "the deferred rollup refreshes failed ($deferred_log):"; tail -40 "$deferred_log"
        return 1
    fi
    deferred_seconds="$(echo "$t0 $(date +%s.%N)" | awk '{ printf "%.3f\n", $2 - $1 }')"
    echo "deferred rollup refreshes took ${deferred_seconds}s"
    cq -f tests/ci_deferred_refresh_complete.sql || return 1
    synced=yes
    "$py" scripts/processor_timings_report.py --log "$driver_log" --out "$out/processor-timings.json" \
        --first-block 1 --last-block "$STOP_AT_BLOCK" --sync-seconds "$seconds" \
        --deferred-log "$deferred_log" --deferred-seconds "$deferred_seconds"
}

needs_sync() {
    if [ -z "$synced" ]; then
        echo "haf_stats is not synced: the sync step did not run or failed"
        return 1
    fi
    "$@"
}

# docker/docker-compose-ci-test.yml's postgrest service, logging in as the consumer
# (the clone's only login) instead of haf_stats_owner, and switching to the same anon
# role.
pattern_test() {
    local port=13000 base pid rc=0 i
    base="http://127.0.0.1:$port"
    PGRST_DB_URI="$clone_url?options=-c%20statement_timeout%3D30s" PGRST_DB_SCHEMA=haf_stats_endpoints \
        PGRST_DB_ANON_ROLE=haf_stats_user PGRST_DB_EXTRA_SEARCH_PATH=haf_stats_app \
        PGRST_DB_POOL=20 PGRST_DB_POOL_ACQUISITION_TIMEOUT=10 \
        PGRST_SERVER_HOST=127.0.0.1 PGRST_SERVER_PORT="$port" \
        postgrest > "$out/postgrest.log" 2>&1 &
    pid=$!
    for i in $(seq 60); do
        curl -fsS -o /dev/null "$base/rpc/get_version" && break
        kill -0 "$pid" 2>/dev/null || { echo "postgrest exited; see $out/postgrest.log"; return 1; }
        [ "$i" -lt 60 ] || { echo "postgrest did not answer in 60s"; kill "$pid"; return 1; }
        sleep 1
    done
    # .gitlab-ci.yml's global REWRITER_URL: tavern resolves it while collecting the
    # rewriter tests this run deselects.
    API_URL="$base" REWRITER_URL="http://rewriter.invalid" PYTHONPATH=tests/tavern TAVERN_DIR=tests/tavern \
        "$py" -m pytest tests/tavern -p no:cacheprovider -m "not negative and not synthetic" --tb=short -v \
        --junitxml="$out/pattern.xml" -o junit_family=xunit1 || rc=$?
    kill "$pid"; wait "$pid" 2>/dev/null
    return "$rc"
}

regression_test() {
    bash scripts/run_verification.sh --host="$AIDEV_EXTERNAL_HAF_HOST" --port="${AIDEV_EXTERNAL_HAF_PORT:-5432}" \
        --user=haf_shared_consumer --database="$clone"
}

# tests/privileges.sql minus what differs only because the clone is not CI's HAF: the
# consumer's own membership of haf_stats_owner, and haf_stats_app.refresh_rc_op_stats(),
# which only a superuser can create (PL/Python is untrusted) and so is absent here.
privileges_against_expected() {
    local actual="$out/privileges-$1.txt"
    cq -At -f tests/privileges.sql | grep -v '^membership haf_shared_consumer in ' > "$actual" || return 1
    echo "$actual: $(wc -l < "$actual") objects"
    if ! grep -q '^function haf_stats_app\.refresh_rc_op_stats()' "$actual"; then
        grep -v '^function haf_stats_app\.refresh_rc_op_stats()' tests/expected_privileges.txt
    else
        cat tests/expected_privileges.txt
    fi | diff -u - "$actual"
}

reinstall_test() {
    local before after rc=0
    cq -At -f .aidev/schema_snapshot.sql > "$out/schema-before.txt" || return 1
    echo "schema-before.txt: $(wc -l < "$out/schema-before.txt") lines"
    [ "$(wc -l < "$out/schema-before.txt")" -ge 1000 ] || { echo "the schema snapshot is too short for an install to have succeeded"; return 1; }
    privileges_against_expected first || rc=1
    before="$(current_block)" || return 1
    clone_install || return 1
    echo "Second install exited 0."
    after="$(current_block)" || return 1
    echo "synced block before $before, after $after"
    [ "$before" = "$after" ] || { echo "reinstalling over a synced schema moved its block"; rc=1; }
    cq -At -f .aidev/schema_snapshot.sql > "$out/schema-after.txt" || return 1
    if diff -u "$out/schema-before.txt" "$out/schema-after.txt" > "$out/schema.diff"; then
        echo "OK: the second install left the three schemas' definitions unchanged."
    else
        echo "FAIL: the second install changed the schema:"; head -200 "$out/schema.diff"; rc=1
    fi
    privileges_against_expected second || rc=1
    return "$rc"
}

for s in "$@"; do
    case "$s" in
        shellcheck) step shellcheck run_shellcheck ;;
        ci-shell-lint) step ci-shell-lint ci_shell_lint ;;
        unit) step unit unit "$out/unit.xml" ;;
        sql-lint) step sql-lint sql_lint ;;
        hadolint) step hadolint run_hadolint ;;
        compose-validate) step compose-validate compose_validate ;;
        openapi-drift) step openapi-drift openapi_drift ;;
        stack-pins) step stack-pins stack_pins ;;
        endpoint) step endpoint endpoint ;;
        install) step install install ;;
        sync) step sync sync_blocks ;;
        pattern) step pattern needs_sync pattern_test ;;
        regression) step regression needs_sync regression_test ;;
        reinstall) step reinstall needs_sync reinstall_test ;;
        *) echo "unknown step: $s" >&2; exit 2 ;;
    esac
done
python3 .aidev/junit_cases.py "$out/junit.xml" "$suite" "$cases"
exit "$status"
