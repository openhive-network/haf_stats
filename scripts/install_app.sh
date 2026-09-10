#!/bin/bash
# One-time schema installation. Run once against a live HAF database.
# Safe to re-run: all DDL uses IF NOT EXISTS / ON CONFLICT DO NOTHING.
#
# OPTIONS:                                                      # --- help-start ---
#   --swagger-url=BASE  Base URL the OpenAPI document advertises in `servers`. Must be
#                       an absolute PATH (/haf-stats-api) or an http(s) URL that
#                       INCLUDES a path (https://host/haf-stats-api); anything else --
#                       a bare hostname or a bare origin -- is ignored in favour of the
#                       default /haf-stats-api, with a warning. (default: localhost,
#                       i.e. ignored)
#   --host=VALUE        PostgreSQL host  (default: $POSTGRES_HOST, else haf)
#   --port=NUMBER       PostgreSQL port  (default: $POSTGRES_PORT, else 5432)
#   --user=VALUE        PostgreSQL user  (default: $POSTGRES_USER, else haf_stats_owner)
#                       --postgres-host=, --postgres-port= and --postgres-user= are
#                       accepted as synonyms (balance_tracker's spelling)
#   --postgres-url=URI  NOT SUPPORTED YET -- recognised and refused with a message
#                       pointing at --host/--port/--user. --url= is the same flag.
#   --schema=NAME       Accepted for module-file compatibility; anything but
#                       haf_stats_app is warned about and ignored, not refused
#   --is_forking=FALSE  Accepted for compatibility with the upstream module template.
#                       TRUE is warned about and ignored -- see below.
#   --help,-h,-?        Show this and exit                      # --- help-end ---
#
# ENVIRONMENT:
#   HAF_STATS_SKIP_OP_TYPE_ASSERT=1
#       Last resort. Downgrades the op-type assertion's fatal arms (steps 3d/8f) to a warning so
#       an install can complete over a condition that would normally abort it. The check still
#       runs and still prints the full diagnosis - it just does not stop the install. Use it to
#       get a node back up when the cause cannot be fixed from the source tree (e.g. an orphaned
#       function body left in pg_proc by an earlier release), then fix the cause and unset it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the source relative to THIS SCRIPT rather than the linter's working directory,
# so shellcheck actually reads common.sh. Without it the connection flags below trip
# SC2034 ("POSTGRES_HOST appears unused") -- shellcheck cannot see psql_cmd consuming
# them -- at warning severity, which is the level shell-lint fails on.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SWAGGER_URL="localhost"

# Off unless explicitly set to 1. Anything else (including "true") is treated as off, so a typo
# fails safe - i.e. towards the assertion still being able to stop a bad install.
: "${HAF_STATS_SKIP_OP_TYPE_ASSERT:=0}"
if [ "${HAF_STATS_SKIP_OP_TYPE_ASSERT}" = "1" ]; then
    OP_TYPE_BYPASS="TRUE"
else
    OP_TYPE_BYPASS="FALSE"
fi

print_help() {
    # Delimited by the markers in the header rather than a hardcoded line range: a range
    # silently truncates as soon as the header grows a line, and a test asserting on one
    # early flag never notices.
    #
    # The bracket in help-sta[r]t is not decoration: written literally, the pattern
    # matches THIS LINE too, sed re-opens the range here and prints the rest of the file.
    sed -n '/--- help-sta[r]t ---/,/--- help-en[d] ---/p' "$0" | sed 's/^# //; s/^#$//; s/ *# --- help-[a-z]* ---//'
}

# The connection flags are parsed AFTER common.sh has applied its defaults, and every
# psql_cmd call expands them at call time -- so assigning here genuinely overrides the
# environment rather than being overridden by it.
for arg in "$@"; do
    case "$arg" in
        --swagger-url=*) require_flag_value "$arg"; SWAGGER_URL="${arg#*=}" ;;

        # Matching balance_tracker, haf_block_explorer and hivesense, whose docker
        # entrypoints forward these. Without them the documented upstream operator form,
        # `run --rm <svc> install_app --host=haf`, fails on an app claiming to implement
        # the same contract. balance_tracker spells it --postgres-host and takes nothing
        # else; the other two use --host. The trio does not agree, so accept both.
        --host=*|--postgres-host=*) require_flag_value "$arg"; POSTGRES_HOST="${arg#*=}" ;;
        --port=*|--postgres-port=*) require_flag_value "$arg"; POSTGRES_PORT="${arg#*=}" ;;
        --user=*|--postgres-user=*) require_flag_value "$arg"; POSTGRES_USER="${arg#*=}" ;;

        # RECOGNISED AND REFUSED, deliberately -- not warn-and-continue like --schema,
        # and not "is not a valid option" either.
        #
        # An earlier revision of this MR HONOURED it, handing the URI to psql as a
        # conninfo. That was worse than rejecting it, because only psql moved: every
        # message, the confirmation banner and the typed-the-database-name gate still
        # read ${POSTGRES_HOST}/${POSTGRES_DB}. So `uninstall_app --postgres-url=...`
        # dropped schemas on the URI's host while printing the discrete host, and
        # accepted the discrete database name as confirmation -- in the one gate whose
        # stated purpose is catching "the right command against the wrong host".
        #
        # Honouring it properly means the banner, the healthcheck's application_name
        # tag (the uninstall session guard excludes the probe by that literal), passing
        # the conninfo through to the healthcheck, a redactor that survives
        # ?password= and keyword/value forms, and the other scripts. That is tracked
        # separately.
        #
        # Refusing is safe here, unlike for --schema: --postgres-url appears in exactly
        # one upstream module file (hivemind.yaml, on hivemind-uninstall) and that file
        # carries no `restart:` key, so this cannot crash-loop a service. One clear
        # error beats a silent connection to the wrong database.
        --postgres-url=*|--url=*)
            log "ERROR: --postgres-url is not supported yet."
            log "       Use --host=, --port= and --user= instead. Accepting the URI"
            log "       would move only the psql connection: this script's messages,"
            log "       and the teardown's confirmation prompt, still read POSTGRES_HOST"
            log "       and POSTGRES_DB -- so it could act on one database while"
            log "       reporting another. Refusing is the safe answer until that is"
            log "       fixed throughout."
            exit 2
            ;;

        # haf_api_node's module files pass --schema= on EVERY verb -- balance_tracker.yaml
        # ships `process_blocks --schema=btracker_app` on a service that is
        # `restart: on-failure`. A hard failure here is therefore a permanent crash-loop
        # that blocks the whole stack, over a flag this app cannot act on either way:
        # its schema names are fixed in the SQL.
        #
        # So WARN and continue, exactly as --is_forking does. An earlier revision of this
        # MR exited 2, justified by a claim that `restart: on-failure` sat on the INSTALL
        # service -- it does not, in this repo or upstream; it sits on block-processing,
        # which is precisely where the hard failure landed.
        --schema=*)
            if [ "${arg#*=}" != "haf_stats_app" ]; then
                log "WARNING: --schema=${arg#*=} is ignored."
                log "         haf_stats owns three fixed schemas: haf_stats_app,"
                log "         haf_stats_backend and haf_stats_endpoints. Continuing."
            fi
            ;;

        # haf_api_node's module template passes --is_forking defaulted from a node-wide
        # ${IS_FORKING:-TRUE}, so a haf_stats module file copied from an upstream app
        # carries TRUE without anyone choosing it for this app. It cannot be honoured:
        # create_context_if_not_exists() calls hive.app_context_set_non_forking('haf_stats')
        # when it creates the context (db/haf_stats_app.sql), so HAF does not rewind
        # these tables on a fork.
        #
        # WARN, do not fail. Upstream module files put `restart: on-failure` on their
        # app services (balance_tracker.yaml's block-processing carries it), so a hard
        # failure on a flag that arrives from an inherited node-wide default is a
        # permanent crash-loop rather than a useful error. NOTE: this repo's own
        # docker/docker-compose.yml has no `restart:` key at all -- an earlier revision
        # of this comment claimed haf-stats-setup ran under `restart: on-failure`, which
        # was carried over from the sibling app and is false here. (Note the limit:
        # the call sits inside the `IF NOT app_context_exists` branch, so on a database
        # whose context already exists this warning is still right that the flag is not
        # honoured, but nothing here converts that context either.)
        --is_forking=*)
            case "${arg#*=}" in
                FALSE|false|False)
                    log "--is_forking=FALSE matches this app's context; nothing to do."
                    ;;
                *)
                    log "WARNING: --is_forking=${arg#*=} is ignored."
                    log "         haf_stats registers a NON-forking HAF context by design"
                    log "         (hive.app_context_set_non_forking, db/haf_stats_app.sql), so HAF"
                    log "         does NOT rewind its tables on a fork. Continuing non-forking."
                    log "         Pass --is_forking=FALSE to silence this."
                    ;;
            esac
            ;;

        --help|-h|-\?) print_help; exit 0 ;;

        # Unknown arguments are an ERROR, matching upstream's option loops. This loop
        # previously had no fallthrough at all, so a mistyped --swagger-url silently
        # installed with the "localhost" default and baked wrong example URLs into the
        # published Swagger page, with nothing in the log to say so.
        *)
            log "ERROR: '${arg}' is not a valid option"
            print_help
            exit 2
            ;;
    esac
done

wait_for_postgres

log "Installing haf_stats schema..."

# 1. Roles (must run as postgres superuser or haf_admin)
run_sql_file "${SCRIPT_DIR}/../db/builtin_roles.sql"

# 2. Schemas, control tables, lifecycle functions, main loop
run_sql_file "${SCRIPT_DIR}/../db/haf_stats_app.sql"

# 2b. App version (git hash). db/version.sql is generated by the Docker build
# (see Dockerfile GIT_HASH arg) and only exists in the built image, so guard on
# its presence. Without this, get_version()/get_health.version return NULL.
if [ -f "${SCRIPT_DIR}/../db/version.sql" ]; then
    run_sql_file "${SCRIPT_DIR}/../db/version.sql"
fi

# 3. Block processors
run_sql_file "${SCRIPT_DIR}/../db/process_block_range.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_financial.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_rc.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_account_cohorts.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_active_users.sql"
# Before process_content_stats: that file's community staging calls
# haf_stats_app.is_community_name / community_start_block, defined here.
run_sql_file "${SCRIPT_DIR}/../db/process_community_registry.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_content_stats.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_content_cohorts.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_custom_json.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_network_ops.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_network_custom_json.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_witness_blocks.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_governance_concentration.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_hp_distribution.sql"
run_sql_file "${SCRIPT_DIR}/../db/process_top_accounts_alltime.sql"

# 3b. RC rate auto-refresh sampler (#33). Self-guarded: a no-op where plpython3u is
#     unavailable (e.g. CI), so it never fails the install. Scheduling is a deploy step.
run_sql_file "${SCRIPT_DIR}/../db/refresh_rc_op_stats.sql"

# 3c. Op-type dependency registry (#56). Declares every hafd.operation_types NAME the processors
#     above resolve at runtime, and every op id they hardcode, plus the two scan helpers the
#     drift arms read. Defines functions only; the two calls that run it are below and at 8f.
run_sql_file "${SCRIPT_DIR}/../db/op_type_registry.sql"

# 3d. Op-type assertion, first pass — THE GATE. Runs here, before anything that writes data.
#
#     This position is load-bearing. Step 8 backfills witness_blocks_daily by calling
#     process_witness_blocks(1, tip), which is a UNION ALL of a produced arm reading hafd.blocks
#     unconditionally and a missed arm filtered on a NAME-resolved op id. If that name no longer
#     resolves, the missed arm matches nothing but the produced arm still writes a full table of
#     rows with missed_count = 0 - and backfill_rollup_if_empty only ever fires on an EMPTY
#     rollup, so that wrong data is permanent until someone runs scripts/rebuild_witness_blocks.sh.
#     An assertion placed after step 8 would fire too late to prevent the damage it exists to
#     prevent.
#
#     Aborting here does not leave a half-installed node. Steps 1-3c create roles, schemas,
#     control rows (app_status, app_version) and function BODIES; no processor executes at load
#     time - process_block_range's PERFORMs are inside its own function body - so nothing derived
#     from an op-type lookup has been written yet, and nothing downstream (context, endpoints,
#     grants, backfills) has run. On a re-install the node's existing context, endpoints and
#     grants are untouched and keep serving.
#
#     Deliberately NOT `|| true`. The supported escape hatch is HAF_STATS_SKIP_OP_TYPE_ASSERT=1,
#     which downgrades the fatal arms to a warning and still prints the whole diagnosis - unlike
#     `|| true`, which would discard it. Only the three arms that mean "data is wrong on this node right
#     now" are fatal - a name that no longer resolves, a hardcoded id that no longer carries its
#     name, and a lookup missing the 'hive::protocol::' prefix. Environment conditions (no hafd,
#     no USAGE on it) and registry/code drift are WARNING + continue inside the function, so only
#     genuine breakage reaches this exit code. See the severity model in db/op_type_registry.sql.
#     FALSE = do not let the fatal unprefixed arm abort on a haf_stats_endpoints body. Those are
#     still the PREVIOUS release's at this point (step 6 replaces them), so a release that FIXES a
#     shipped unprefixed lookup in an endpoint would otherwise abort here against the very body it
#     is about to replace - making the fix uninstallable. Step 8f re-runs it unscoped.
log "Verifying op-type dependencies against hafd.operation_types..."
psql_cmd -c "SET ROLE haf_stats_owner; SELECT haf_stats_app.assert_op_types(FALSE, ${OP_TYPE_BYPASS}); RESET ROLE;"

# 4. Seed lookup tables (DApp registry)
run_sql_file "${SCRIPT_DIR}/../db/seed_data.sql"

# 4b. Sync-status reader (#55) — a SECURITY DEFINER over hafd.contexts, owned by
#     haf_stats_owner. Needs the roles (step 1) and the haf_stats_app schema (step 2);
#     the context row is resolved at call time, so it may load before step 5. Deliberately
#     NOT applied under SET ROLE: it fixes its own ownership, which is the only thing that
#     can repair a node where an earlier install left the function owned by the superuser
#     running this script.
run_sql_file "${SCRIPT_DIR}/../db/sync_status.sql"

# 5. Register HAF context (idempotent; also repairs a reset or lagging pointer) — must
#    run as haf_stats_owner so that hafd.contexts.owner = haf_stats_owner, satisfying the
#    RLS UPDATE policy in hive.app_next_block() (WITH CHECK:
#    hive.can_impersonate(CURRENT_USER, owner)).
#    Ordered BEFORE the endpoints: GET /sync-status answers 503 while the context row is
#    absent. On a cold `compose up` the API is in fact gated on this container transitively
#    (haf-stats-process depends_on haf-stats-setup service_completed_successfully;
#    haf-stats-api in turn depends_on haf-stats-process) - but `compose up -d`
#    against a running stack does not restart an already-up haf-stats-api, so on any
#    ordinary redeploy a request can land between the two steps.
psql_cmd -c "SET ROLE haf_stats_owner; SELECT haf_stats_app.create_context_if_not_exists(); RESET ROLE;"

# 6. API endpoints
#
# The base URL the published document advertises. This used to be
# `SET custom.swagger_url` on THIS psql session, which nothing ever read -- and could
# not have: PostgREST connects later on its own pool and never sees another session's
# GUC. Persisted instead, and read by haf_stats_endpoints.root() at request time. (#70)
#
# Written before the endpoints load purely so a fresh install never has a window where
# root() exists and the setting does not. root() tolerates both the row and the table
# being absent, so the order is hygiene rather than a requirement.
#
# -v + :'swagger_url', NOT string interpolation. `psql -c` runs MULTIPLE statements, so
# splicing the value into the SQL text makes --swagger-url an arbitrary-SQL channel:
#
#     --swagger-url="x'; CREATE TABLE pwned(i INT); --"
#
# closes the literal and runs the rest as haf_admin. An operator installing the app
# already has that privilege, so this is not an escalation on the normal path -- but
# haf_api_node feeds this from ${PUBLIC_HOSTNAME}, i.e. from a node's .env, and a value
# containing a single apostrophe would break the install with a syntax error pointing
# nowhere near the cause. :'var' hands psql the value out-of-band and lets it do the
# quoting.
# Tell the operator when their value will be ignored. This is the half of #70 that a
# silent fallback would leave open: the issue's own failure scenario is an operator who
# "has no way to discover this short of reading the SQL, because the flag they used is
# documented as the way to set it". haf_api_node passes ${PUBLIC_HOSTNAME}, a bare
# hostname, so today that operator IS this scenario -- and a warning in the install log
# is where they would find out. Keep this pattern identical to the one in
# haf_stats_endpoints.root(); root() remains the enforcer, this only reports.
if ! printf '%s' "${SWAGGER_URL}" | grep -Eq '^(/($|[^/])|https?://[^/]+/)'; then
    log "WARNING: --swagger-url='${SWAGGER_URL}' is not an absolute path or an http(s)"
    log "         URL with a path, so the published OpenAPI document will advertise the"
    log "         default base URL '/haf-stats-api' instead. Pass a path (e.g. '/' for a"
    log "         standalone stack, '/haf-stats-api' behind a node) to set it."
fi

# Fed on STDIN, not with -c. psql's -c takes a string "completely parsable by the
# server", so psql-level features are not processed there -- `:'swagger_url'` would
# reach PostgreSQL verbatim and fail to parse. Substitution happens for -f and for
# stdin, so the heredoc is what makes the binding work. (Learned from sync going red:
# the -c form aborted haf-stats-setup with exit 1.)
#
# The heredoc delimiter is QUOTED, so the shell expands nothing inside it and the value
# never touches the SQL text -- it travels only through -v.
psql_cmd -v swagger_url="${SWAGGER_URL}" <<'SQL'
    UPDATE haf_stats_app.app_config SET swagger_base_url = :'swagger_url';
    INSERT INTO haf_stats_app.app_config (swagger_base_url)
    SELECT :'swagger_url'
    WHERE NOT EXISTS (SELECT 1 FROM haf_stats_app.app_config);
SQL
psql_cmd -f "${SCRIPT_DIR}/../endpoints/endpoint_schema.sql"

# 7. Grant read access on current and future objects to haf_stats_user
psql_cmd -c "
    ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_backend
        GRANT SELECT ON TABLES TO haf_stats_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_endpoints
        GRANT EXECUTE ON FUNCTIONS TO haf_stats_user;
"

# 8. Self-heal the precomputed endpoint rollups. They ship empty and the endpoints read
#    them directly; on an already-synced node the forward refresh hook only fills recent
#    periods, so without this the historical rollup stays empty and the endpoint returns
#    [] until a manual genesis backfill (easy to forget on a fresh environment). Each call
#    backfills only when the rollup is empty AND its source has data, so it is a no-op on a
#    fresh genesis replay (the hook fills it forward) and on a re-install of a populated
#    node. Runs as haf_stats_owner to match table ownership; the refresh statements use
#    doubled single quotes (no $-quoting) so bash leaves them intact.
log "Backfilling precomputed period rollups if empty (one-time on an already-synced node)..."
psql_cmd -c "
    SET ROLE haf_stats_owner;
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.network_vote_period_counts',
        'haf_stats_backend.network_vote_daily',
        'SELECT haf_stats_app.refresh_network_vote_periods(''2016-03-24'')');
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.network_content_period_counts',
        'haf_stats_backend.network_content_daily',
        'SELECT haf_stats_app.refresh_network_content_periods(''2016-03-24'')');
    -- network_custom_json_daily is raw-op-derived (no cheap daily source to roll up from), so its
    -- one-time backfill IS the processor over every already-processed block. Empty-only: on a
    -- fresh genesis replay app_status.last_processed_block is still 0, so process_network_custom_json(1, 0)
    -- is a no-op and the forward hook fills it; on an already-synced re-install it backfills [1, tip]
    -- once (the processor then resumes forward from tip+1, so no double-count).
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.network_custom_json_daily',
        'hafd.operations',
        'SELECT haf_stats_app.process_network_custom_json(1, (SELECT COALESCE(MAX(last_processed_block), 0) FROM haf_stats_app.app_status))');
    -- witness_blocks_daily is derived the same way (hafd.blocks + producer_missed ops), so its
    -- one-time backfill is likewise the processor over every already-processed block.
    --
    -- SIZING IS UNMEASURED AT MAINNET SCALE - treat the following as a lower bound, not an
    -- estimate. The 5M-corpus timing (2.71 s) is a fully-cached scan: hafd.blocks was resident in
    -- shared_buffers, read=0. On mainnet hafd.blocks is ~30 GB, the produced arm becomes a cold
    -- seq scan of it, and the missed arm is an indexed op-type scan PLUS one random PK probe back
    -- into that same table per producer_missed op PLUS a hash build over every account - none of
    -- which the cached figure includes. It is also NOT cheaper than the custom_json backfill above
    -- (2.71 s vs 2.11 s over the identical range, ~29% more).
    --
    -- Step 8 runs as ONE implicit transaction, which pins the xmin horizon for its whole duration
    -- (the hazard that got the community registry batched out into 8a). If a real mainnet install
    -- shows this taking more than a few minutes, move it to a batched step modelled on 8a.
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.witness_blocks_daily',
        'hafd.blocks',
        'SELECT haf_stats_app.process_witness_blocks(1, (SELECT COALESCE(MAX(last_processed_block), 0) FROM haf_stats_app.app_status))');
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.engagement_period_counts',
        'haf_stats_backend.post_engagement',
        'SELECT haf_stats_app.refresh_engagement_full()');
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.active_users_period_counts',
        'haf_stats_backend.active_users_daily',
        'SELECT haf_stats_app.refresh_active_users_periods(''2016-03-24'')');
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.account_cohort_retention',
        'haf_stats_backend.account_cohort_members',
        'SELECT haf_stats_app.refresh_account_cohort_retention((SELECT MAX(created_at) FROM hafd.blocks))');
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.author_cohort_retention',
        'haf_stats_backend.author_cohort_members',
        'SELECT haf_stats_app.refresh_author_cohort_retention((SELECT MAX(created_at) FROM hafd.blocks))');
    -- Self-heal deployments upgraded from the pre-eligibility cohort schema: the
    -- eligible_at_Nd columns were added via ALTER TABLE ... ADD COLUMN IF NOT
    -- EXISTS, which leaves them NULL on already-materialized cohorts that
    -- backfill_rollup_if_empty (empty-rollup only) never revisits. The sentinel is
    -- a column the current refresh always writes non-NULL; a full refresh once
    -- populates the new denominators. Applies to BOTH cohort rollups that gained
    -- eligible_at_Nd (author retention here, account funnel below).
    SELECT haf_stats_app.backfill_rollup_if_column_null(
        'haf_stats_backend.author_cohort_retention', 'eligible_at_30d',
        'SELECT haf_stats_app.refresh_author_cohort_retention((SELECT MAX(created_at) FROM hafd.blocks), NULL, NULL)');
    SELECT haf_stats_app.backfill_rollup_if_column_null(
        'haf_stats_backend.account_cohort_retention', 'eligible_at_7d',
        'SELECT haf_stats_app.refresh_account_cohort_retention((SELECT MAX(created_at) FROM hafd.blocks), NULL, NULL)');
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.account_financial_monthly',
        'haf_stats_backend.account_financial_daily',
        'SELECT haf_stats_app.refresh_financial_monthly(''2016-03-24'')');
    SELECT haf_stats_app.backfill_rollup_if_empty(
        'haf_stats_backend.active_users_account_monthly',
        'haf_stats_backend.active_users_daily',
        'SELECT haf_stats_app.refresh_active_users_account_monthly(''2016-03-24'')');
    RESET ROLE;
"

# 8a. Community registry backfill (#47).
#
#     Deliberately NOT a backfill_rollup_if_empty call in the block above: everything there
#     runs in ONE implicit transaction (psql executes a multi-statement -c string as a single
#     transaction), and this backfill is a row-at-a-time replay over every community
#     custom_json from block 37.5M to the tip. On an already-synced mainnet node that is tens
#     of millions of blocks inside a transaction that also holds the other ten refreshes — a
#     multi-hour install that cannot be interrupted without losing all of it, and that pins
#     the xmin horizon against vacuum for the duration.
#
#     Batched, one transaction per chunk, so it commits as it goes and a failure costs one
#     chunk. Safe to re-run: process_community_registry is idempotent (registration is
#     ON CONFLICT DO NOTHING; roles/titles are last-writer-wins over an ordered replay), and
#     it returns immediately for ranges below the community start block, so a node still
#     replaying 2016 skips it entirely.
#
#     The per-comment community mapping is NOT self-healed here: it rides on comment_registry,
#     whose create-vs-edit replay only works from genesis. Repairing it is
#     scripts/rebuild_content_volume.sh (see README).
: "${COMMUNITY_BACKFILL_BATCH:=1000000}"
community_rows="$(psql_cmd -Atc "SELECT COUNT(*) FROM haf_stats_backend.community_registry")"
community_start="$(psql_cmd -Atc "SELECT haf_stats_app.community_start_block()")"
app_head="$(psql_cmd -Atc "SELECT COALESCE(MAX(last_processed_block), 0) FROM haf_stats_app.app_status")"

if [[ "${community_rows}" =~ ^[0-9]+$ && "${community_start}" =~ ^[0-9]+$ && "${app_head}" =~ ^[0-9]+$ ]] \
   && (( community_rows == 0 )) && (( app_head >= community_start )); then
    log "Backfilling the community registry over blocks ${community_start}-${app_head} in batches of ${COMMUNITY_BACKFILL_BATCH} (one transaction each)..."
    cb_first="${community_start}"
    while (( cb_first <= app_head )); do
        cb_last=$(( cb_first + COMMUNITY_BACKFILL_BATCH - 1 ))
        if (( cb_last > app_head )); then
            cb_last="${app_head}"
        fi
        psql_cmd -c "SET ROLE haf_stats_owner; SELECT haf_stats_app.process_community_registry(${cb_first}, ${cb_last});"
        cb_first=$(( cb_last + 1 ))
    done
    log "Community registry backfill complete."
fi

# 8b. Compute the current-state snapshots once so their endpoints are populated immediately on
#     an already-synced node. No-op-safe: each writes nothing without a readable balance
#     relation. Recurring refresh is a pg_cron deploy step (see the file headers in
#     db/process_governance_concentration.sql and db/process_hp_distribution.sql).
log "Computing initial governance concentration + HP distribution snapshots (if a balance tracker is readable)..."
psql_cmd -c "SET ROLE haf_stats_owner; SELECT haf_stats_app.refresh_governance_concentration(); RESET ROLE;"
psql_cmd -c "SET ROLE haf_stats_owner; SELECT haf_stats_app.refresh_hp_distribution_snapshot(); RESET ROLE;"

# 8c. Compute the all-time top-accounts aggregates once (#38) so get_network_top_accounts' no-filter
#     leaderboard is populated immediately. Derived from the monthly rollups backfilled in step 8
#     above, so it must run after them. Recurring refresh is a pg_cron deploy step (daily; see the
#     header in db/process_top_accounts_alltime.sql). Empty-safe on a fresh genesis node (the
#     monthly rollups are empty until sync; cron fills the all-time tables once they populate).
log "Computing initial all-time top-accounts aggregates..."
psql_cmd -c "SET ROLE haf_stats_owner; SELECT haf_stats_app.refresh_top_accounts_alltime(); RESET ROLE;"

# 8d. Schedule the recurring daily refresh of every current-state snapshot via pg_cron. These used
#     to be manual, header-documented deploy steps, which is fragile: hp_distribution's cron was
#     never scheduled after its deploy, so that snapshot silently froze at its install-time values.
#     Self-guarded — a no-op where pg_cron is unavailable (e.g. CI), so it never fails the install.
#     Idempotent: cron.schedule upserts by jobname, so re-installs just refresh the schedule. Job
#     names match the cron.schedule examples in each db/process_*.sql header. The one-shot refreshes
#     above still populate the snapshots immediately at install; this only keeps them fresh after.
log "Scheduling daily snapshot refreshes via pg_cron (if available)..."
psql_cmd -c "
    DO \$do\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
            RAISE NOTICE 'pg_cron not installed; skipping snapshot-refresh scheduling';
            RETURN;
        END IF;
        -- Best-effort: cron.schedule is only callable from the database pg_cron is installed in and
        -- may need elevated rights, which varies by deployment (and is absent in CI). Never fail
        -- the install over scheduling — where it cannot run, the one-shot refreshes above still
        -- populated the snapshots and the schedule can be added manually (see the process_*.sql
        -- headers). Where it can (e.g. the app DB has pg_cron), the daily refresh is wired up.
        BEGIN
            PERFORM cron.schedule('haf_stats_governance_concentration', '0 3 * * *',
                'SELECT haf_stats_app.refresh_governance_concentration()');
            PERFORM cron.schedule('haf_stats_hp_distribution', '0 3 * * *',
                'SELECT haf_stats_app.refresh_hp_distribution_snapshot()');
            PERFORM cron.schedule('haf_stats_rc_rates', '30 3 * * *',
                'SELECT haf_stats_app.refresh_rc_op_stats()');
            PERFORM cron.schedule('haf_stats_top_accounts_alltime', '30 3 * * *',
                'SELECT haf_stats_app.refresh_top_accounts_alltime()');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'snapshot-refresh cron scheduling skipped (%): schedule manually per the db/process_*.sql headers', SQLERRM;
        END;
    END
    \$do\$;
"

# Refresh PostgREST's schema cache. haf-stats-setup re-runs this script on every stack
# start while haf-stats-api keeps running, and PostgREST caches function signatures at
# startup — so without this a changed endpoint signature is served stale until the API
# container happens to restart. Harmless when nothing is listening on the channel.
psql_cmd -c "NOTIFY pgrst, 'reload schema';"

# 8e. Post-install assertion for GET /sync-status (#55). This is the only place the whole
#     chain is exercised end to end: EXECUTE grant -> SECURITY DEFINER ownership ->
#     haf_stats_owner's hive_applications_group membership -> RLS on hafd.contexts.
#
#     Runs LAST, after every step that mutates the database. It used to sit between the
#     endpoints and the grants, which meant the very failure it exists to catch aborted the
#     install (ON_ERROR_STOP + set -e) after the context and endpoints had committed but
#     before step 7's grants and step 8's rollup self-heal - leaving a half-installed node
#     that re-aborts at the same point on every subsequent `up`, and never gets its grants.
#     Running it here means a genuine membership failure is still loud, but the node is
#     fully installed when you see it.
#
#     The readiness check is INSIDE the DO block, in one session with the assertion it
#     gates. Split across two psql invocations it was a TOCTOU window: HAF could begin an
#     index rebuild between the probe and the assertion, sync_status() would raise 53000,
#     and the install would abort for exactly the environment condition the skip exists to
#     tolerate. Nested IF/ELSIF rather than `AND`, because SQL does not guarantee
#     short-circuit evaluation and sync_status() itself raises when HAF is not ready.
#
#     Deliberately NOT `|| true` and not a relaxed ON_ERROR_STOP - either would also
#     swallow the real RLS/membership failure this assertion was added to catch.
#     haf_stats_user has EXECUTE on hive.is_instance_ready() (db/builtin_roles.sql), so the
#     whole block runs under SET ROLE with no extra grant. Follows the self-guarding idiom
#     of steps 3b and 8d: never fail the install for an environment condition.
psql_cmd -c "
    SET ROLE haf_stats_user;
    DO \$do\$
    BEGIN
        IF NOT hive.is_instance_ready() THEN
            RAISE WARNING 'HAF is in massive sync (hive.is_instance_ready() is false) - skipping the GET /sync-status assertion. Re-run scripts/install_app.sh once HAF is ready to verify the EXECUTE grant / SECURITY DEFINER / hive_applications_group / RLS chain.';
        ELSIF NOT EXISTS (SELECT 1 FROM haf_stats_app.sync_status()) THEN
            RAISE EXCEPTION 'haf_stats_app.sync_status() returned no row as haf_stats_user: GET /sync-status would answer 503. Either the HAF context is absent, or haf_stats_owner (the definer) does not INHERIT hive_applications_group, so RLS on hafd.contexts hides every row (see db/builtin_roles.sql).';
        END IF;
    END
    \$do\$;
    RESET ROLE;
"

# 8f. Op-type assertion, second pass — the full-surface scan. Step 3d already gated the data
#     writes; this one re-runs after the endpoints exist so the registry-drift arm can see
#     haf_stats_endpoints function bodies too. On a FRESH install those functions do not exist
#     yet at step 3d, so this is the only call that can catch an endpoint which resolves an
#     op-type name without registering it. ~6 ms, so running it twice is free.
#
#     After 8e for the same reason 8e runs last: a /sync-status failure is an availability
#     problem and keeps first claim on the exit code, while this one is data-correctness.
log "Re-verifying op-type dependencies across the installed endpoints..."
psql_cmd -c "SET ROLE haf_stats_owner; SELECT haf_stats_app.assert_op_types(TRUE, ${OP_TYPE_BYPASS}); RESET ROLE;"

log "Installation complete."

# PREREQUISITE (run by the balance_tracker schema owner, not this script):
# get_network_hp_distribution reads current VESTS balances from balance_tracker.
# Its schema is deployment-dependent and the function auto-detects the first
# relation haf_stats_user can read, so grant SELECT on whichever applies:
#   standalone balance_tracker:
#     GRANT SELECT ON btracker_app.current_account_balances TO haf_stats_user;
#   balance_tracker via the block explorer (hafbe):
#     GRANT USAGE  ON SCHEMA btracker_backend TO haf_stats_user;
#     GRANT SELECT ON btracker_backend.current_account_balances_view TO haf_stats_user;
# Without a readable balance relation the endpoint returns [] (documented contract).
