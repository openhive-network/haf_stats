#!/usr/bin/env bash
# Run the integration test stack and return Tavern's exit code.
#
# Uses detached mode so that the one-shot setup container exiting does
# not abort the rest of the stack (a Docker Compose limitation with
# --abort-on-container-exit).
#
# Usage:
#   ./scripts/run_tests.sh [--keep]   # --keep skips final 'down -v' cleanup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="docker compose --env-file ${SCRIPT_DIR}/../docker/.env -f ${SCRIPT_DIR}/../docker/docker-compose-test.yml"

KEEP=0
for arg in "$@"; do
  [[ "$arg" == "--keep" ]] && KEEP=1
done

echo "==> Tearing down any previous stack..."
${COMPOSE} down -v --remove-orphans 2>/dev/null || true

echo "==> Starting test stack (detached)..."
${COMPOSE} up -d

echo "==> Waiting for Tavern tests to complete..."
${COMPOSE} wait tavern
EXIT_CODE=$?

if [[ $KEEP -eq 0 ]]; then
  echo "==> Cleaning up..."
  ${COMPOSE} down -v
fi

echo "==> Tavern exited with code ${EXIT_CODE}"
exit "${EXIT_CODE}"
