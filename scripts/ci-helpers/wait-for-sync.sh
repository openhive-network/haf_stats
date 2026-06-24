#!/bin/bash
# =============================================================================
# wait-for-sync.sh — block until the haf_stats app has processed the whole chain.
# =============================================================================
# Mirrors balance_tracker/scripts/ci-helpers/wait-for-bt-startup.sh. The block
# processor (process_blocks.sh -> haf_stats_app.main) is an INFINITE loop that
# never "completes", so the sync job cannot gate on the container exiting. Instead
# we poll hive.is_app_in_sync('haf_stats'), which flips true once the context's
# processed block catches up to HAF's head (the --stop-at-block replay tip). Once
# true, the sync job cleanly shuts PostgreSQL down and saves the datadir to cache.
#
# Timeout is generous because the app sync (install + process-to-head) runs per
# commit even when the underlying 5M HAF replay is served from the warm cache.
set -e

print_help() {
cat <<-EOF
Usage: $0 [OPTION[=VALUE]]...

Waits until the haf_stats app has finished processing all available blocks.
OPTIONS:
    --postgres-access=URL    PostgreSQL connection URL
                             (default: postgresql://haf_admin@localhost:5432/haf_block_log)
    --timeout=SECONDS        Overall timeout (default: 5400 = 90 minutes)
    --help|-h|-?             Display this help screen and exit
EOF
}

POSTGRES_ACCESS="postgresql://haf_admin@localhost:5432/haf_block_log"
TIMEOUT=5400

while [ $# -gt 0 ]; do
  case "$1" in
    --postgres-access=*) POSTGRES_ACCESS="${1#*=}" ;;
    --timeout=*)         TIMEOUT="${1#*=}" ;;
    --help|-h|-\?)       print_help; exit 0 ;;
    *) echo "ERROR: '$1' is not a valid option"; print_help; exit 2 ;;
  esac
  shift
done

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is required but was not found in PATH."
  exit 1
fi

export POSTGRES_ACCESS
wait_for_sync() {
  until psql "$POSTGRES_ACCESS" --quiet --tuples-only \
      --command="SELECT hive.is_app_in_sync('haf_stats')::INT;" | grep -q 1
  do
    echo "Waiting for haf_stats to finish processing blocks..."
    sleep 20
  done
}
export -f wait_for_sync

timeout -k 1m "${TIMEOUT}s" bash -c wait_for_sync

echo "Block processing is finished (haf_stats is in sync)."
