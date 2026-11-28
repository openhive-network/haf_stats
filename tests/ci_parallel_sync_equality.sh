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
#   parallel  at HAF_STATS_SYNC_PARALLELISM=4 (scripts/haf_stats_parallel.py), with triggers
#             that fail the network group once, on the first network_op_daily row of
#             FAIL_BLOCK's day, and the custom_json_1 shard of the custom_json group once, on its
#             first account_custom_json_daily row in the batch holding that day's first block.
#             The driver must stop on them with the context before that batch, the batch's four
#             shared stages committed (they are staged before any group starts, while the batch
#             before it runs or right before its own groups) and the other groups' progress
#             rows committed for it, other custom_json shards' among them. Then the triggers are
#             dropped, the network group and the custom_json_1 shard apply the first half of the
#             batch on their own, as a delivery of the batch cut short would have left them,
#             and the server crash's reset of every
#             UNLOGGED haf_stats_app table is emulated: the shared staging of the batch, and of
#             the next range, staged ahead before any of its groups started, is gone, and the
#             progress rows stay. The sync is resumed to STOP_BLOCK at parallelism 4: the other
#             groups skip the batch, the network group and the shard stage and apply the rest of
#             it (haf_stats_app.processor_group_from past the first block), and the next batch is
#             staged again. This leg stages with HAF_STATS_SPLIT_STAGING_SECONDS=0, each step of a
#             staging level on a connection of its own, and before the resume a trigger fails the
#             authored_ops step of the batch after the failed one twice, staged ahead and staged
#             by itself: the resume must stop on it before that batch with the other three
#             stages committed by the steps beside it, and a second resume, delivering the batch
#             again, stages the rest;
#   serial    the same failures and partial batch, with the staging kept, then resumed at
#             parallelism 1: the single-session process_block_range skips what the groups
#             and shards have applied.
#
# The three run at once, each on its own clone, its output kept in OUT_DIR/<name>.out and
# printed once all three are done. Then every haf_stats table's checksum
# (tests/ci_table_checksums.sql) must be the same in each resumed clone as in single, and
# neither may hold a progress row, or a shared stage marked complete for a range at or before
# STOP_BLOCK (the range after it may be staged ahead). The clones are dropped on exit.
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

# CLONE_NAME VAR: a fresh clone with haf_stats installed, its database name put in VAR. Not
# called in a command substitution: that subshell's clones+= would never reach cleanup.
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
    printf -v "$2" '%s' "$db"
}

# DB LOG PARALLELISM [SPLIT_SECONDS]: the driver to stop_block, with SPLIT_SECONDS as
# HAF_STATS_SPLIT_STAGING_SECONDS when given; returns its exit status.
sync_to_stop() {
    local db="$1" log="$2" parallelism="$3" split="${4:-}" args=(-u HAF_STATS_SPLIT_STAGING_SECONDS -u HAF_STATS_SYNC_PARALLELISM) process_python=()
    if [ "$parallelism" -gt 1 ]; then
        args=(-u HAF_STATS_SPLIT_STAGING_SECONDS "HAF_STATS_SYNC_PARALLELISM=$parallelism")
        [ -z "$split" ] || args+=("HAF_STATS_SPLIT_STAGING_SECONDS=$split")
        process_python=(--process-python=haf_stats_parallel:process_blocks)
    fi
    env "${args[@]}" PYTHONPATH="$sources/scripts" /usr/bin/python3 "$(command -v haf_app_driver.py)" --app=haf_stats \
        --postgres-url="$haf_url/$db?application_name=haf_stats_block_processing&options=-c%20role%3Dhaf_stats_owner" \
        --stop-at-block="$stop_block" --startup-marker='' "${process_python[@]}" >> "$log" 2>&1
}

q() { psql "$haf_url/$1" -X -v ON_ERROR_STOP=on -Atc "$2"; }

single="" parallel="" serial=""
new_clone single single || exit 1
new_clone parallel parallel || exit 1
new_clone serial serial || exit 1
echo "clones: single=$single parallel=$parallel serial=$serial"

sync_single() {
    local t0=$SECONDS
    sync_to_stop "$single" "$out/single.log" 1 || { echo "the single-session sync failed:"; tail -40 "$out/single.log"; return 1; }
    echo "single-session sync to $stop_block: $((SECONDS - t0))s"
    psql "$haf_url/$single" -X -At -v ON_ERROR_STOP=1 -f "$here/ci_table_checksums.sql" > "$out/single.checksums"
}

# NAME DB RESUME_PARALLELISM CRASH: the failure, the partial batch, with CRASH=crash the emulated
# crash, split staging and a failed staging step, and the resume, then the checksums.
fail_and_resume() {
    local name="$1" db="$2" resume_parallelism="$3" crash="$4" log="$out/$1.log" t0=$SECONDS split=""
    [ "$crash" != crash ] || split=0
    local fail_day day_start state at rows continuing network shard shards context batch_end half left staged
    fail_day="$(q "$db" "SELECT created_at::DATE FROM hafd.blocks WHERE num = $fail_block")" || return 1
    [ -n "$fail_day" ] || { echo "block $fail_block is not in HAF"; return 1; }
    day_start="$(q "$db" "SELECT MIN(num) FROM hafd.blocks WHERE created_at::DATE = DATE '$fail_day'")" || return 1
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
        -- The batch a row is for is the range key its custom_json stage was attached or staged
        -- under: the rows carry only a day, and the shard's accounts may sign nothing on that one.
        CREATE SEQUENCE haf_stats_app.ci_fail_shard_once;
        CREATE FUNCTION haf_stats_app.ci_fail_shard_once() RETURNS TRIGGER LANGUAGE plpgsql AS \$\$
        DECLARE
            _range TEXT := NULLIF(current_setting('haf_stats.batch_custom_json_ops_range', TRUE), '');
        BEGIN
            IF split_part(_range, ':', 1)::INT <= $day_start AND split_part(_range, ':', 2)::INT >= $day_start THEN
                IF nextval('haf_stats_app.ci_fail_shard_once') = 1 THEN
                    RAISE EXCEPTION 'ci: injected custom_json_1 shard failure at blocks %', _range;
                END IF;
            END IF;
            RETURN NEW;
        END;
        \$\$;
        CREATE TRIGGER ci_fail_shard_once BEFORE INSERT ON haf_stats_backend.account_custom_json_daily
        FOR EACH ROW WHEN (NEW.account_id % cardinality(haf_stats_app.custom_json_shards()) = 1)
        EXECUTE FUNCTION haf_stats_app.ci_fail_shard_once();
    " >/dev/null || return 1

    if sync_to_stop "$db" "$log" 4 "$split"; then
        echo "FAIL: $name: the parallel sync passed the injected failure"; return 1
    fi
    grep -q "ci: injected network group failure" "$log" \
        || { echo "FAIL: $name: the parallel sync stopped, but not on the injected failure:"; tail -40 "$log"; return 1; }
    grep -q "ci: injected custom_json_1 shard failure at blocks" "$log" \
        || { echo "FAIL: $name: the custom_json_1 shard was not failed in the network group's batch:"; tail -40 "$log"; return 1; }
    state="$(q "$db" "
        SELECT s.last_processed_block
               || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress)
               || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress AS p
                          WHERE p.first_block = s.last_processed_block + 1)
               || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress WHERE group_name = 'network')
               || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress WHERE group_name = 'custom_json_1')
               || ' ' || (SELECT COUNT(*) FROM haf_stats_app.processor_group_progress
                          WHERE group_name = ANY(haf_stats_app.custom_json_shards()))
               || ' ' || hive.app_get_current_block_num('haf_stats')
               || ' ' || (SELECT COALESCE(MAX(last_block), 0) FROM haf_stats_app.processor_group_progress)
        FROM haf_stats_app.app_status AS s")" || return 1
    read -r at rows continuing network shard shards context batch_end <<< "$state"
    echo "$name, after the failure: app_status $at, context $context, $rows progress rows ($continuing for the batch $((at + 1))..$batch_end, $network for network, $shards for custom_json shards, $shard for custom_json_1)"
    [ "$at" -lt "$fail_block" ] && [ "$at" -gt 0 ] || { echo "FAIL: $name: stopped at block $at, not before $fail_block"; return 1; }
    [ "$context" = "$at" ] || { echo "FAIL: $name: the HAF context ($context) moved apart from app_status ($at)"; return 1; }
    [ "$rows" -ge 1 ] && [ "$rows" = "$continuing" ] && [ "$network" = 0 ] && [ "$shard" = 0 ] && [ "$shards" -ge 1 ] \
        || { echo "FAIL: $name: expected the other groups' progress rows for the failed batch, other custom_json shards' among them, and none for network or custom_json_1"; return 1; }
    staged="$(q "$db" "SELECT COUNT(*) FROM haf_stats_app.shared_batch_marker
                       WHERE first_block = $((at + 1)) AND last_block = $batch_end
                         AND stage IN ('ops', 'authored_ops', 'exact_rc', 'custom_json_ops')")" || return 1
    [ "$staged" = 4 ] || { echo "FAIL: $name: $staged of the failed batch's 4 shared stages committed"; return 1; }

    q "$db" "SET ROLE haf_stats_owner; DROP TRIGGER ci_fail_network_once ON haf_stats_backend.network_op_daily;
             DROP FUNCTION haf_stats_app.ci_fail_network_once(); DROP SEQUENCE haf_stats_app.ci_fail_once;
             DROP TRIGGER ci_fail_shard_once ON haf_stats_backend.account_custom_json_daily;
             DROP FUNCTION haf_stats_app.ci_fail_shard_once(); DROP SEQUENCE haf_stats_app.ci_fail_shard_once;" >/dev/null || return 1
    half=$(((at + 1 + batch_end) / 2))
    [ "$half" -lt "$batch_end" ] || { echo "FAIL: $name: the failed batch $((at + 1))..$batch_end is too short to apply in part"; return 1; }
    q "$db" "SET ROLE haf_stats_owner; SELECT haf_stats_app.process_processor_group('network', $((at + 1)), $half)" >/dev/null || return 1
    q "$db" "SET ROLE haf_stats_owner; SELECT haf_stats_app.process_processor_group('custom_json_1', $((at + 1)), $half)" >/dev/null || return 1
    echo "$name: the network group and the custom_json_1 shard applied $((at + 1))..$half of the batch"
    if [ "$crash" = crash ]; then
        # What crash recovery does to UNLOGGED tables: each is reset to empty.
        q "$db" "SET ROLE haf_stats_owner; DO \$\$ BEGIN
                 EXECUTE (SELECT 'TRUNCATE ' || string_agg(c.oid::REGCLASS::TEXT, ', ')
                          FROM pg_class AS c
                          WHERE c.relnamespace = 'haf_stats_app'::REGNAMESPACE AND c.relkind = 'r'
                            AND c.relpersistence = 'u');
                 END \$\$" >/dev/null || return 1
        staged="$(q "$db" "SELECT COUNT(*) FROM haf_stats_app.shared_batch_marker")" || return 1
        [ "$staged" = 0 ] || { echo "FAIL: $name: $staged shared stages left after the emulated crash"; return 1; }
        echo "$name: the crash's reset of the UNLOGGED tables emulated"
        fail_staging_twice "$db" "$log" "$((batch_end + 1))" "$split" || { echo "FAIL: $name: see above"; return 1; }
    fi

    sync_to_stop "$db" "$log" "$resume_parallelism" "$split" \
        || { echo "$name: the sync resumed at parallelism $resume_parallelism failed:"; tail -40 "$log"; return 1; }
    echo "$name: sync to $stop_block, with the failure and the resume at parallelism $resume_parallelism: $((SECONDS - t0))s"

    left="$(q "$db" "SELECT COUNT(*) FROM haf_stats_app.processor_group_progress")" || return 1
    [ "$left" = 0 ] || { echo "FAIL: $name: $left progress rows left after the resumed sync"; return 1; }
    left="$(q "$db" "SELECT COUNT(*) FROM haf_stats_app.shared_batch_marker WHERE first_block <= $stop_block")" || return 1
    [ "$left" = 0 ] || { echo "FAIL: $name: $left shared stages marked complete for a synced range after the resumed sync"; return 1; }
    psql "$haf_url/$db" -X -At -v ON_ERROR_STOP=1 -f "$here/ci_table_checksums.sql" > "$out/$name.checksums"
}

# DB LOG FIRST SPLIT: the authored_ops step of the batch from block FIRST fails twice, on its
# marker row: staged ahead (the batch before it needs no staging: each of its groups has applied
# part of it), then staged before its own groups. The resume must stop on the second with the
# batch's other stages committed by the steps beside it on other connections (one step after
# another on one connection, exact_rc would never have run), and its context before the batch,
# so that the batch is delivered again.
fail_staging_twice() {
    local db="$1" log="$2" first="$3" split="$4" staged expected at
    q "$db" "
        SET ROLE haf_stats_owner;
        CREATE SEQUENCE haf_stats_app.ci_fail_stage_twice;
        CREATE FUNCTION haf_stats_app.ci_fail_stage_twice() RETURNS TRIGGER LANGUAGE plpgsql AS \$\$
        BEGIN
            IF nextval('haf_stats_app.ci_fail_stage_twice') <= 2 THEN
                RAISE EXCEPTION 'ci: injected authored_ops staging failure at blocks %..%', NEW.first_block, NEW.last_block;
            END IF;
            RETURN NEW;
        END \$\$;
        CREATE TRIGGER ci_fail_stage_twice BEFORE INSERT ON haf_stats_app.shared_batch_marker
        FOR EACH ROW WHEN (NEW.stage = 'authored_ops' AND NEW.first_block = $first)
        EXECUTE FUNCTION haf_stats_app.ci_fail_stage_twice();
    " >/dev/null || return 1
    if sync_to_stop "$db" "$log" 4 "$split"; then
        echo "the resume passed the injected staging failures"; return 1
    fi
    grep -q "batch staging ahead authored_ops, blocks $first\.\..*failed: .*ci: injected authored_ops staging failure" "$log" \
        || { echo "the staging ahead of the batch from $first did not fail split on the injected failure:"; tail -40 "$log"; return 1; }
    grep -q "batch staging steps authored_ops, blocks $first\.\..*failed: .*ci: injected authored_ops staging failure" "$log" \
        || { echo "the resume did not stop on the injected failure of the batch from $first staging itself, split:"; tail -40 "$log"; return 1; }
    staged="$(q "$db" "SELECT string_agg(DISTINCT stage COLLATE \"C\", ',' ORDER BY stage COLLATE \"C\") FROM haf_stats_app.shared_batch_marker
                       WHERE first_block = $first")" || return 1
    expected="custom_json_ops,exact_rc,ops,$(q "$db" "SELECT string_agg('ops_' || k, ',' ORDER BY k)
                                                      FROM generate_series(0, haf_stats_app.shared_batch_ops_parts() - 1) AS k"),slot" || return 1
    [ "$staged" = "$expected" ] \
        || { echo "after the failed authored_ops steps, stages '$staged' of the batch from $first committed, not $expected"; return 1; }
    at="$(q "$db" "SELECT last_processed_block FROM haf_stats_app.app_status")" || return 1
    [ "$at" = "$((first - 1))" ] || { echo "the resume stopped at block $at, not before the batch from $first"; return 1; }
    q "$db" "SET ROLE haf_stats_owner; DROP TRIGGER ci_fail_stage_twice ON haf_stats_app.shared_batch_marker;
             DROP FUNCTION haf_stats_app.ci_fail_stage_twice(); DROP SEQUENCE haf_stats_app.ci_fail_stage_twice;" >/dev/null || return 1
    echo "the resume stopped on the injected authored_ops staging failures of the batch from $first, with $staged committed beside them"
}

# NAME: its checksums against single's.
compare() {
    echo "$1: $(wc -l < "$out/$1.checksums") tables compared"
    if ! diff -u "$out/single.checksums" "$out/$1.checksums"; then
        echo "FAIL: $1: the resumed sync wrote different table contents"; return 1
    fi
    echo "$1: every table is identical"
}

sync_single > "$out/single.out" 2>&1 & pids=($!)
fail_and_resume parallel "$parallel" 4 crash > "$out/parallel.out" 2>&1 & pids+=($!)
fail_and_resume serial "$serial" 1 keep > "$out/serial.out" 2>&1 & pids+=($!)
rc=0
for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
cat "$out/single.out" "$out/parallel.out" "$out/serial.out"
[ "$rc" = 0 ] || exit 1
compare parallel || exit 1
compare serial || exit 1
