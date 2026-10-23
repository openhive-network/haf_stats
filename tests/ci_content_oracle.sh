#!/bin/sh
# Runs tests/parity/content_vs_hivemind.sql -- the production post/comment guard (#63) --
# for real in the stub lane, against tests/content_oracle_fixture.sql.
#
# Every case is one psql session: BEGIN, the fixture, one mutation, the guard file, ROLLBACK.
# The guard raises on failure and its own \set ON_ERROR_STOP ends the session there, so the
# open transaction is discarded either way and nothing a case does reaches the next one or
# the database. A case asserts BOTH the exit status and the message, so a guard that fails
# for some other reason (a stub gap, a typo) does not count as catching the defect.
#
# POSIX sh: the setup service is postgres:14-alpine, which has no bash.
set -u

PSQL="psql -h postgres -U postgres -d haf_block_log -X -q"
failures=0

# run_case NAME EXPECTED_EXIT EXPECTED_TEXT MUTATION_SQL
run_case() {
    out="$(
        { echo 'BEGIN;'; cat /content_oracle_fixture.sql; echo "$4"; cat /content_vs_hivemind.sql; echo 'ROLLBACK;'; } \
            | PGPASSWORD=postgres $PSQL -v ON_ERROR_STOP=1 -f - 2>&1
    )"
    rc=$?
    if [ "$rc" -ne "$2" ] || ! printf '%s\n' "$out" | grep -qF -- "$3"; then
        echo "content oracle CI: FAIL - $1: expected exit $2 and \"$3\", got exit $rc:"
        printf '%s\n' "$out" | sed 's/^/    /'
        failures=$((failures + 1))
    else
        echo "content oracle CI: ok - $1"
    fi
}

# Baseline: everything agrees, the one in-tolerance excess is reported, and both halves ran
# (5 recent days + the sampled 2023-06 day; ora-a and ora-b over 30 days + ora-a that day).
run_case 'baseline agrees' 0 \
    'content oracle: 6 days and 3 account checks agree with hivemind' ''
run_case 'baseline reports the hivemind#394 excess' 0 \
    '2025-03-03: +1 comments' ''

# #42 class: network posts off (exact rule).
run_case 'network posts +1' 3 \
    'network 2025-03-02: posts 3 vs hivemind 2' \
    "UPDATE haf_stats_backend.network_content_daily SET posts = posts + 1 WHERE day = DATE '2025-03-02';"
# Comments below hivemind are never hivemind#394.
run_case 'network comments -1' 3 \
    'network 2025-03-04: posts 2 vs hivemind 2, comments 1 vs hivemind 2' \
    "UPDATE haf_stats_backend.network_content_daily SET comments = comments - 1 WHERE day = DATE '2025-03-04';"
# One past the 2% tolerance: 64 vs 62 > floor(62 * 0.02).
run_case 'network comments past 2%' 3 \
    'network 2025-03-03: posts 2 vs hivemind 2, comments 64 vs hivemind 62' \
    "UPDATE haf_stats_backend.network_content_daily SET comments = comments + 1 WHERE day = DATE '2025-03-03';"
# #45 class on an OLD day: only the monthly-sample half of (b) can see it. Every 2023-06 day
# is changed, so the case holds whichever day the guard's rotation picks.
run_case 'old account posts +1 (monthly sample)' 3 \
    'account ora-a (2023-06-' \
    "UPDATE haf_stats_backend.account_content_daily SET posts = posts + 1 WHERE account_id = 81001 AND day BETWEEN DATE '2023-06-01' AND DATE '2023-06-30';"
# The recent 30-day window: comments below hivemind for one author (network untouched).
run_case 'recent account comments -1' 3 \
    'account ora-a (2025-02-04..2025-03-05): posts 5 vs hivemind 5, comments 9 vs hivemind 10' \
    "UPDATE haf_stats_backend.account_content_daily SET comments = comments - 1 WHERE account_id = 81001 AND day = DATE '2025-03-04';"
# Nothing to compare must not read as a pass.
run_case 'empty comparison fails' 3 \
    'a zero means a half of this check did not run' \
    "DELETE FROM hivemind_app.hive_posts; DELETE FROM haf_stats_backend.network_content_daily; DELETE FROM haf_stats_backend.account_content_daily;"

# Cannot run -> says so (exit 0, NOT RUN), never a silent pass.
run_case 'massive sync is NOT RUN' 0 \
    'NOT RUN - hivemind is in stage MASSIVE_PROCESSING' \
    "SET ci.hivemind_stage = 'MASSIVE_PROCESSING';"
run_case 'missing index is NOT RUN' 0 \
    'NOT RUN - hivemind_app.hive_posts lacks a valid' \
    'DROP INDEX hivemind_app.hive_posts_block_num_created_idx;'
# Wrong role -> an error naming the fix, not a skip.
run_case 'role without hivemind access' 3 \
    'cannot read hive_posts/hive_accounts; run it as haf_admin' \
    'SET ROLE haf_stats_user;'
run_case 'role outside hive_applications_group (RLS)' 3 \
    'row-level security' \
    'CREATE ROLE ci_oracle_reader NOLOGIN;
     GRANT USAGE ON SCHEMA hivemind_app, hafd TO ci_oracle_reader;
     GRANT SELECT ON ALL TABLES IN SCHEMA hivemind_app TO ci_oracle_reader;
     GRANT SELECT ON hafd.contexts TO ci_oracle_reader;
     SET ROLE ci_oracle_reader;'

if [ "$failures" -ne 0 ]; then
    echo "content oracle CI: ${failures} case(s) failed"
    exit 1
fi
echo "content oracle CI: all cases passed"
