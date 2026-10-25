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
# endpoint and install need the stack (.aidev/test-stack.compose.yml): its
# `postgres` service is the one both CI compose files start. Each lane starts on a
# freshly created haf_block_log with the app's roles dropped, as a fresh container
# gives CI. Reports go to test-results/<suite>/.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

suite="${1:?usage: $0 <suite> <step>...}"; shift
out="test-results/$suite"
rm -rf "$out"; mkdir -p "$out"
cases="$out/cases.tsv"; : > "$cases"
py=/opt/venv/bin/python3

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
        *) echo "unknown step: $s" >&2; exit 2 ;;
    esac
done
python3 .aidev/junit_cases.py "$out/junit.xml" "$suite" "$cases"
exit "$status"
