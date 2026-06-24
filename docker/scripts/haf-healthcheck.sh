#!/usr/bin/env bash
# HAF instance healthcheck (mirrors balance_tracker/docker/scripts/haf-healthcheck.sh).
#
# The CI sync/test stacks run the HAF *instance* image with --skip-hived against a
# pre-replayed datadir, so the container is "healthy" only once HAF has finished its
# internal startup and hive.is_instance_ready() returns true — not merely when the
# socket accepts connections. Downstream services (install, processing, PostgREST)
# gate on this via depends_on: { condition: service_healthy }.
set -e

# Kill any pending healthcheck SQL query when the script is interrupted.
trap 'trap - SIGINT SIGTERM && kill -- -$$' SIGINT SIGTERM

INSTANCE_READY=$(psql -U haf_admin --dbname "haf_block_log" --quiet --tuples-only \
    --command="SELECT hive.is_instance_ready()::VARCHAR;")

if [[ "$INSTANCE_READY" == " true" ]]; then
    echo "HAF instance ready!"
    exit 0
else
    echo "HAF instance still starting up."
    exit 1
fi
