#!/usr/bin/env bash
# The parallel massive sync writes what the single-session one writes, and a processor group
# failing mid-batch leaves nothing a resumed sync counts twice, at either parallelism (#140).
#
#   tests/ci_parallel_sync_equality.sh HAF_URL SOURCES_DIR OUT_DIR STOP_BLOCK FAIL_BLOCK [TEMPLATE_DB]
#
# HAF_URL is postgresql://USER@HOST:PORT, SOURCES_DIR an install tree (db/, endpoints/, scripts/
# with db/version.sql). The clones it syncs are fresh copies of a HAF database without haf_stats:
#
#   without TEMPLATE_DB  the shared HAF's (haf_shared.clone_run_database), as haf_shared_consumer
#                        (.aidev/run-checks.sh);
#   with TEMPLATE_DB     CREATE DATABASE ... TEMPLATE TEMPLATE_DB, which no session may be
#                        connected to, as a user that may create databases (.gitlab-ci.yml's
#                        sync job).
#
# Each clone gets the app installed and is synced from scratch to STOP_BLOCK by
# haf_app_driver.py, as scripts/process_blocks.sh runs it:
#
#   single    at parallelism 1: the registered process_blocks procedure;
#   parallel  at HAF_STATS_SYNC_PARALLELISM=4 (scripts/haf_stats_parallel.py), with a trigger
#             that fails the network group once, on the first network_op_daily row of
#             FAIL_BLOCK's day. The driver must stop on it with the context before that batch
#             and the other groups' progress rows committed for it. Then the trigger is
#             dropped, the network group applies the first half of the batch on its own, as a
#             delivery of the batch cut short would have left it, and the sync is resumed to
#             STOP_BLOCK at parallelism 4: the other groups skip the batch, the network group
#             applies the rest of it (haf_stats_app.processor_group_from past the first block);
#   serial    the same failure and partial batch, then resumed at parallelism 1: the
#             single-session process_block_range skips what the groups have applied.
#
# Then every haf_stats table's checksum (tests/ci_table_checksums.sql) must be the same in
# each resumed clone as in single, and neither may hold a progress row. The clones are dropped
# on exit.
set -uo pipefail

haf_url="${1:?haf url}"
sources="${2:?sources dir}"
out="${3:?out dir}"
stop_block="${4:?stop block}"
fail_block="${5:?fail block}"
template="${6:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
haf_user="${haf_url#*://}"
haf_user="${haf_user%%@*}"
mkdir -p "$out"

clones=()
drop_db() {
    if [ -n "$template" ]; then
        psql "$haf_url/postgres" -X -qAtc "DROP DATABASE IF EXISTS \"$1\""
    else
        psql "$haf_url/haf_shared" -X -qAtc "select haf_shared.drop_run_database('$1')"
    fi
}
cleanup() {
    local id
    for id in "${clones[@]}"; do
        drop_db "$id" >/dev/null || echo "could not drop clone $id" >&2
    done
}
trap cleanup EXIT

# CLONE_NAME: a fresh clone with haf_stats installed; prints the database name.
new_clone() {
    local id db
    id="hsp-$1-$(date -u +%Y%m%d%H%M%S)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    if [ -n "$template" ]; then
        psql "$haf_url/postgres" -X -v ON_ERROR_STOP=on -qc "CREATE DATABASE \"$id\" TEMPLATE \"$template\"" || return 1
        db="$id"
    else
        db="$(psql "$haf_url/haf_shared" -X -v ON_ERROR_STOP=on -Atc "select haf_shared.clone_run_database('$id')")" || return 1
    fi
    clones+=("$id")
    psql "$haf_url/$db" -X -v ON_ERROR_STOP=on -qc "GRANT CREATE ON DATABASE \"$db\" TO haf_stats_owner" || return 1
    local host_port="${haf_url#*@}"
    (cd "$sources" && POSTGRES_HOST="${host_port%:*}" POSTGRES_PORT="${host_port##*:}" \
        POSTGRES_USER="$haf_user" POSTGRES_DB="$db" bash scripts/install_app.sh) > "$out/install-$1.log" 2>&1 \
        || { echo "install into $db failed:"; tail -30 "$out/install-$1.log"; return 1; }
    echo "$db"
}

# DB LOG PARALLELISM: the driver to stop_block; returns its exit status.
sync_to_stop() {
    local db="$1" log="$2" parallelism="$3" args=(-u HAF_STATS_SYNC_PARALLELISM) process_python=()
    if [ "$parallelism" -gt 1 ]; then
        args=("HAF_STATS_SYNC_PARALLELISM=$parallelism")
        process_python=(--process-python=haf_stats_parallel:process_blocks)
    fi
    env "${args[@]}" PYTHONPATH="$sources/scripts" /usr/bin/python3 "$(command -v haf_app_driver.py)" --app=haf_stats \
        --postgres-url="$haf_url/$db?application_name=haf_stats_block_processing&options=-c%20role%3Dhaf_stats_owner" \
        --stop-at-block="$stop_block" --startup-marker='' "${process_python[@]}" >> "$log" 2>&1
}

q() { psql "$haf_url/$1" -X -v ON_ERROR_STOP=on -Atc "$2"; }

single="$(new_clone single)" || exit 1
parallel="$(new_clone parallel)" || exit 1
serial="$(new_clone serial)" || exit 1
echo "clones: single=$single parallel=$parallel serial=$serial"

t0=$SECONDS
sync_to_stop "$single" "$out/single.log" 1 || { echo "the single-session sync failed:"; tail -40 "$out/single.log"; exit 1; }
echo "single-session sync to $stop_block: $((SECONDS - t0))s"
psql "$haf_url/$single" -X -At -v ON_ERROR_STOP=1 -f "$here/ci_table_checksums.sql" > "$out/single.checksums" || exit 1

# NAME DB RESUME_PARALLELISM: the failure, the partial batch and the resume, then the checksums
# against single's.
fail_and_resume() {
    local name="$1" db="$2" resume_parallelism="$3" log="$out/$1.log" t0=$SECONDS
    local fail_day state at rows continuing network context batch_end half left
    fail_day="$(q "$db" "SELECT created_at::DATE FROM hafd.blocks WHERE num = $fail_block")" || return 1
    [ -n "$fail_day" ] || { echo "block $fail_block is not in HAF"; return 1; }
    q "$db" "
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
    " >/dev/null || return 1

    if sync_to_stop "$db" "$log" 4; then
        echo "FAIL: $name: the parallel sync passed the injected failure"; return 1
    fi
    grep -q "ci: injected network group failure" "$log" \
        || { echo "FAIL: $name: the parallel sync stopped, but not on the injected failure:"; tail -40 "$log"; return 1; }
    state="$(q "$db" "
        SELECT s.last_processed_block
               || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress)
               || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress AS p
                          WHERE p.first_block = s.last_processed_block + 1)
               || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress WHERE group_name = 'network')
               || ' ' || hive.app_get_current_block_num('haf_stats')
               || ' ' || (SELECT COALESCE(MAX(last_block), 0) FROM haf_stats_app.processor_group_progress)
        FROM haf_stats_app.app_status AS s")" || return 1
    read -r at rows continuing network context batch_end <<< "$state"
    echo "$name, after the failure: app_status $at, context $context, $rows progress rows ($continuing for the batch $((at + 1))..$batch_end, $network for network)"
    [ "$at" -lt "$fail_block" ] && [ "$at" -gt 0 ] || { echo "FAIL: $name: stopped at block $at, not before $fail_block"; return 1; }
    [ "$context" = "$at" ] || { echo "FAIL: $name: the HAF context ($context) moved apart from app_status ($at)"; return 1; }
    [ "$rows" -ge 1 ] && [ "$rows" = "$continuing" ] && [ "$network" = 0 ] \
        || { echo "FAIL: $name: expected the other groups' progress rows for the failed batch, and none for network"; return 1; }

    q "$db" "SET ROLE haf_stats_owner; DROP TRIGGER ci_fail_network_once ON haf_stats_backend.network_op_daily;
             DROP FUNCTION haf_stats_app.ci_fail_network_once(); DROP SEQUENCE haf_stats_app.ci_fail_once;" >/dev/null || return 1
    half=$(((at + 1 + batch_end) / 2))
    [ "$half" -lt "$batch_end" ] || { echo "FAIL: $name: the failed batch $((at + 1))..$batch_end is too short to apply in part"; return 1; }
    q "$db" "SET ROLE haf_stats_owner; SELECT haf_stats_app.process_processor_group('network', $((at + 1)), $half)" >/dev/null || return 1
    echo "$name: the network group applied $((at + 1))..$half of the batch"

    sync_to_stop "$db" "$log" "$resume_parallelism" \
        || { echo "$name: the sync resumed at parallelism $resume_parallelism failed:"; tail -40 "$log"; return 1; }
    echo "$name: sync to $stop_block, with the failure and the resume at parallelism $resume_parallelism: $((SECONDS - t0))s"

    left="$(q "$db" "SELECT COUNT(*) FROM haf_stats_app.processor_group_progress")" || return 1
    [ "$left" = 0 ] || { echo "FAIL: $name: $left progress rows left after the resumed sync"; return 1; }
    psql "$haf_url/$db" -X -At -v ON_ERROR_STOP=1 -f "$here/ci_table_checksums.sql" > "$out/$name.checksums" || return 1
    echo "$name: $(wc -l < "$out/$name.checksums") tables compared"
    if ! diff -u "$out/single.checksums" "$out/$name.checksums"; then
        echo "FAIL: $name: the resumed sync wrote different table contents"; return 1
    fi
    echo "$name: every table is identical"
}

fail_and_resume parallel "$parallel" 4 || exit 1
fail_and_resume serial "$serial" 1 || exit 1
