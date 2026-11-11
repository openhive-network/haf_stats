#!/bin/sh
# wait_service_exit.sh COMPOSE_FILE SERVICE -- gate a CI job on a one-shot compose
# service's exit code (#154).
#
# Exits 0 only when SERVICE's container ran and exited 0. Waits for it first if it is
# still running. `docker compose wait` is not usable as this gate: it only finds RUNNING
# containers, so when `up --detach` blocks on a long service_completed_successfully
# chain and the last link has already exited by the time the gate runs, it reports
# "no containers for project" and fails a green lane.
#
# Fails, naming SERVICE, when:
#   * it has no container (an upstream link failed before compose created it);
#   * its container is still in Created state (created, but its dependency failed so
#     it was never started -- `docker wait` would return 0 for it);
#   * it exited non-zero.
# Bound the wait from the caller (`timeout 600 sh .../wait_service_exit.sh ...`).
set -u
set -f

file="${1:?usage: wait_service_exit.sh COMPOSE_FILE SERVICE}"
svc="${2:?usage: wait_service_exit.sh COMPOSE_FILE SERVICE}"

ids="$(docker compose -f "${file}" ps --all --quiet "${svc}")" \
    || { echo "FAIL: cannot list the containers of ${svc}" >&2; exit 1; }
# shellcheck disable=SC2086 # split the newline-separated ids into positional args
set -- ${ids}
if [ "$#" -eq 0 ]; then
    echo "FAIL: ${svc} has no container -- an earlier link of the chain failed, so it never ran" >&2
    exit 1
fi
if [ "$#" -ne 1 ]; then
    echo "FAIL: ${svc} has $# containers, expected exactly one" >&2
    exit 1
fi
cid="$1"

status="$(docker inspect --format '{{.State.Status}}' "${cid}")" \
    || { echo "FAIL: cannot inspect the ${svc} container ${cid}" >&2; exit 1; }
if [ "${status}" = created ]; then
    echo "FAIL: ${svc} was created but never started -- an earlier link of the chain failed" >&2
    exit 1
fi

echo "${svc}: container ${cid} is ${status}; waiting for its exit code"
code="$(docker wait "${cid}")" \
    || { echo "FAIL: cannot wait for the ${svc} container ${cid}" >&2; exit 1; }
if [ "${code}" != 0 ]; then
    echo "FAIL: ${svc} exited ${code}" >&2
    exit 1
fi
echo "${svc} exited 0"
