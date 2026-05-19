#!/usr/bin/env bash
# Run the integration test stack and return Tavern's exit code.
#
# Uses detached mode so that the one-shot setup container exiting does
# not abort the rest of the stack (a Docker Compose limitation with
# --abort-on-container-exit).
#
# The PostgreSQL data volume (haf_pgdata) is PRESERVED between runs so
# the block_log replay only happens once.  Use --reset to wipe it.
#
# Usage:
#   ./scripts/run_tests.sh            # run tests, keep replayed data
#   ./scripts/run_tests.sh --reset    # wipe haf_pgdata and re-replay
#   ./scripts/run_tests.sh --keep     # skip final teardown (leave stack up)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="docker compose --env-file ${SCRIPT_DIR}/../docker/.env -f ${SCRIPT_DIR}/../docker/docker-compose-test.yml"

KEEP=0
RESET=0
for arg in "$@"; do
  [[ "$arg" == "--keep"  ]] && KEEP=1
  [[ "$arg" == "--reset" ]] && RESET=1
done

if [[ $RESET -eq 1 ]]; then
  echo "==> Resetting: removing all volumes including replayed block data..."
  ${COMPOSE} down -v --remove-orphans 2>/dev/null || true
else
  echo "==> Tearing down previous containers (preserving haf_pgdata)..."
  # Remove containers and ephemeral pg_socket volume, but keep haf_pgdata.
  ${COMPOSE} down --remove-orphans 2>/dev/null || true
fi

echo "==> Starting test stack (detached)..."
${COMPOSE} up -d

echo "==> Waiting for Tavern tests to complete..."
${COMPOSE} wait tavern
EXIT_CODE=$?

if [[ $KEEP -eq 0 ]]; then
  echo "==> Stopping containers (data volume preserved)..."
  ${COMPOSE} down
fi

echo "==> Tavern exited with code ${EXIT_CODE}"
exit "${EXIT_CODE}"
