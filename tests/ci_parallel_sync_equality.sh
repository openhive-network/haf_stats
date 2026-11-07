#!/usr/bin/env bash
# The parallel massive sync writes what the single-session one writes, and a processor group
# failing mid-batch leaves nothing a resumed sync counts twice (#140).
#
#   tests/ci_parallel_sync_equality.sh CONSUMER_URL SOURCES_DIR OUT_DIR STOP_BLOCK FAIL_BLOCK
#
# CONSUMER_URL is the shared HAF as haf_shared_consumer (.aidev/run-checks.sh), SOURCES_DIR an
# install tree (db/, endpoints/, scripts/ with db/version.sql). Two fresh clones of the shared
# HAF get the app installed and are synced from scratch to STOP_BLOCK by haf_app_driver.py,
# as scripts/process_blocks.sh runs it:
#
#   single    HAF_STATS_SYNC_PARALLELISM unset: the registered process_blocks procedure;
#   parallel  HAF_STATS_SYNC_PARALLELISM=4 (scripts/haf_stats_parallel.py), with a trigger
#             that fails the network group once, on the first network_op_daily row of
#             FAIL_BLOCK's day. The driver must stop on it with the context before that batch
#             and the other groups' progress rows committed for it; then the trigger is
#             dropped and the sync resumed to STOP_BLOCK.
#
# Then every haf_stats table's checksum (tests/ci_table_checksums.sql) must be the same in
# both, and the parallel clone must hold no progress row. Both clones are dropped on exit.
set -uo pipefail

consumer_url="${1:?consumer url}"
sources="${2:?sources dir}"
out="${3:?out dir}"
stop_block="${4:?stop block}"
fail_block="${5:?fail block}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$out"

clones=()
cleanup() {
    local id
    for id in "${clones[@]}"; do
        psql "$consumer_url/haf_shared" -X -qAtc "select haf_shared.drop_run_database('$id')" >/dev/null \
            || echo "could not drop clone $id; the provider reaps it after its TTL" >&2
    done
}
trap cleanup EXIT

# CLONE_NAME: a fresh clone with haf_stats installed; prints the database name.
new_clone() {
    local id db
    id="hsp-$1-$(date -u +%Y%m%d%H%M%S)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    db="$(psql "$consumer_url/haf_shared" -X -v ON_ERROR_STOP=on -Atc "select haf_shared.clone_run_database('$id')")" || return 1
    clones+=("$id")
    psql "$consumer_url/$db" -X -v ON_ERROR_STOP=on -qc "GRANT CREATE ON DATABASE \"$db\" TO haf_stats_owner" || return 1
    local host_port="${consumer_url#*@}"
    (cd "$sources" && POSTGRES_HOST="${host_port%:*}" POSTGRES_PORT="${host_port##*:}" \
        POSTGRES_USER=haf_shared_consumer POSTGRES_DB="$db" bash scripts/install_app.sh) > "$out/install-$1.log" 2>&1 \
        || { echo "install into $db failed:"; tail -30 "$out/install-$1.log"; return 1; }
    echo "$db"
}

# DB LOG [ENV...]: the driver to stop_block; returns its exit status.
sync_to_stop() {
    local db="$1" log="$2"
    shift 2
    env "$@" PYTHONPATH="$sources/scripts" /usr/bin/python3 "$(command -v haf_app_driver.py)" --app=haf_stats \
        --postgres-url="$consumer_url/$db?application_name=haf_stats_block_processing&options=-c%20role%3Dhaf_stats_owner" \
        --stop-at-block="$stop_block" --startup-marker='' "${process_python[@]}" >> "$log" 2>&1
}

q() { psql "$consumer_url/$1" -X -v ON_ERROR_STOP=on -Atc "$2"; }

single="$(new_clone single)" || exit 1
parallel="$(new_clone parallel)" || exit 1
echo "clones: single=$single parallel=$parallel"

t0=$SECONDS
process_python=()
sync_to_stop "$single" "$out/single.log" || { echo "the single-session sync failed:"; tail -40 "$out/single.log"; exit 1; }
echo "single-session sync to $stop_block: $((SECONDS - t0))s"

fail_day="$(q "$parallel" "SELECT created_at::DATE FROM hafd.blocks WHERE num = $fail_block")" || exit 1
[ -n "$fail_day" ] || { echo "block $fail_block is not in the shared HAF"; exit 1; }
q "$parallel" "
    SET ROLE haf_stats_owner;
    CREATE SEQUENCE haf_stats_app.ci_fail_once;
    CREATE FUNCTION haf_stats_app.ci_fail_network_once() RETURNS TRIGGER LANGUAGE plpgsql AS \$\$
    BEGIN
        IF nextval('haf_stats_app.ci_fail_once') = 1 THEN
            RAISE EXCEPTION 'ci: injected network group failure at %', NEW.day;
        END IF;
        RETURN NEW;
    END;
    \$\$;
    CREATE TRIGGER ci_fail_network_once BEFORE INSERT ON haf_stats_backend.network_op_daily
    FOR EACH ROW WHEN (NEW.day >= DATE '$fail_day')
    EXECUTE FUNCTION haf_stats_app.ci_fail_network_once();
" >/dev/null || exit 1

t0=$SECONDS
process_python=(--process-python=haf_stats_parallel:process_blocks)
if sync_to_stop "$parallel" "$out/parallel.log" HAF_STATS_SYNC_PARALLELISM=4; then
    echo "FAIL: the parallel sync passed the injected failure"; exit 1
fi
grep -q "ci: injected network group failure" "$out/parallel.log" \
    || { echo "FAIL: the parallel sync stopped, but not on the injected failure:"; tail -40 "$out/parallel.log"; exit 1; }
state="$(q "$parallel" "
    SELECT s.last_processed_block
           || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress)
           || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress AS p
                      WHERE p.first_block = s.last_processed_block + 1)
           || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress WHERE group_name = 'network')
           || ' ' || hive.app_get_current_block_num('haf_stats')
    FROM haf_stats_app.app_status AS s")" || exit 1
read -r at rows continuing network context <<< "$state"
echo "after the failure: app_status $at, context $context, $rows progress rows ($continuing for the next batch, $network for network)"
[ "$at" -lt "$fail_block" ] && [ "$at" -gt 0 ] || { echo "FAIL: stopped at block $at, not before $fail_block"; exit 1; }
[ "$context" = "$at" ] || { echo "FAIL: the HAF context ($context) moved apart from app_status ($at)"; exit 1; }
[ "$rows" -ge 1 ] && [ "$rows" = "$continuing" ] && [ "$network" = 0 ] \
    || { echo "FAIL: expected the other groups' progress rows for the failed batch, and none for network"; exit 1; }

q "$parallel" "SET ROLE haf_stats_owner; DROP TRIGGER ci_fail_network_once ON haf_stats_backend.network_op_daily;
               DROP FUNCTION haf_stats_app.ci_fail_network_once(); DROP SEQUENCE haf_stats_app.ci_fail_once;" >/dev/null || exit 1
sync_to_stop "$parallel" "$out/parallel.log" HAF_STATS_SYNC_PARALLELISM=4 \
    || { echo "the resumed parallel sync failed:"; tail -40 "$out/parallel.log"; exit 1; }
echo "parallel sync to $stop_block, with the failure and the resume: $((SECONDS - t0))s"

left="$(q "$parallel" "SELECT COUNT(*) FROM haf_stats_app.processor_group_progress")" || exit 1
[ "$left" = 0 ] || { echo "FAIL: $left progress rows left after the parallel sync"; exit 1; }

psql "$consumer_url/$single" -X -At -v ON_ERROR_STOP=1 -f "$here/ci_table_checksums.sql" > "$out/single.checksums" || exit 1
psql "$consumer_url/$parallel" -X -At -v ON_ERROR_STOP=1 -f "$here/ci_table_checksums.sql" > "$out/parallel.checksums" || exit 1
echo "$(wc -l < "$out/single.checksums") tables compared"
if ! diff -u "$out/single.checksums" "$out/parallel.checksums"; then
    echo "FAIL: the parallel sync wrote different table contents"; exit 1
fi
echo "every table is identical"
