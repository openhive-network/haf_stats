"""Behavioural tests for scripts/uninstall_app.sh (#57).

This is the destructive script — it drops all three schemas CASCADE and both roles — and
until this file existed its only coverage was argument parsing. Mutation testing found
that deleting its entire body, neutering the session guard, removing the no-TTY
refusal, or swapping the context name for the schema name (the exact trap the script's
own header says it exists to avoid) all left the suite green.

Everything below runs against a stub `psql` on PATH that answers each read the script
performs — the session count, the to_regclass probe, the surviving-context query and
the verification file — so the guards, the ordering and the reporting are exercised
without a database. The two queries whose MEANING matters are compared whole rather
than grepped, because a substring search cannot tell a guard that counts the right
sessions from one whose comparison has been inverted.

NOT COVERED, stated plainly rather than implied: the interactive branch below
`[ ! -t 0 ]`. Nothing here opens a PTY, so the type-the-database-name comparison and
the post-prompt session re-check are unexercised — inverting the comparison, or
deleting the re-check, passes. An earlier version of this docstring claimed otherwise.
Closing it needs a pty case, which only runs on POSIX.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, stub_bin, write_exec

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "uninstall_app.sh"

# 30s, matching test_script_arguments.py. These resolve in milliseconds; the timeout
# is a HANG detector (a regression that lets an argument fall through reaches
# wait_for_postgres, an unbounded `until pg_isready`, and the orphaned sleep holds
# the pipe open so subprocess's own timeout does not reliably fire). 15s flaked
# under CPU contention on Windows, where every stub psql is a Git Bash process.
TIMEOUT = 30


@pytest.fixture
def bash():
    return require_bash()


# The section-0 target block asks the server what it is, and now REFUSES when it
# cannot find out. Every stub in this file therefore has to answer it -- including the
# bespoke ones below, which would otherwise exit 2 on the refusal rather than on the
# defect each of them is named for.
STUB_SERVER_IDENTITY = "10.1.1.7:5432/somedb as someone [cluster 1234]"


def make_psql(tmp_path, *, sessions: str = "0", listing: str = "",
              remaining: str = "",
              context_left: str = "", cron_left: str = "", can_remove: str = "t",
              app_left: str = "",
              log: str = "sql.log", fail_on: str | None = None,
              server: str = STUB_SERVER_IDENTITY) -> Path:
    """A stub psql that records what it was asked and answers each of the script's reads.

    Rows are answered with `printf "%s\\n"`, because `psql -Atq` terminates EVERY row --
    including the last. An earlier revision used `printf "%s"`, and `report_active_sessions
    | while read -r line` drops an unterminated final line, so the session listing was
    silently empty in every test here: the refusal an operator hits most often ended in a
    colon promising a list, and deleting the listing was green. A fixture that models
    something the real tool does not do produces exactly this class of hole.

    Dispatch is on the statement text AND on any -f file, because the verification is a
    file now (scripts/uninstall_verify.sql) rather than an inline string. The reads are:
    the pre-flight probes, the session count, the to_regclass probe, the context-survivor
    query, the two pg_cron probes, and the verification file. Everything else is a
    destructive statement and just gets logged.
    """
    stub_bin(tmp_path)  # creates bin/ and the pg_isready stub; idempotent
    logfile = tmp_path / log
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        "files=''\n"
        'prev=""\n'
        'for a in "$@"; do\n'
        '  case "$prev" in -c) cmd="$cmd$a" ;; -f) files="$files$a" ;; esac\n'
        '  prev="$a"\n'
        "done\n"
        f'printf "%s\\n---\\n" "$cmd" >> "{logfile.as_posix()}"\n'
        # ONE LINE PER INVOCATION. "$*" carries the statement's own newlines, so a raw
        # printf wrote one log line per SQL LINE -- which makes a per-invocation
        # assertion ("is -Atq on the call that counts sessions?") impossible to express.
        f'printf "%s\\n" "$(printf \'%s\' "$*" | tr \'\\n\' \' \')" >> "{(tmp_path / "argv.log").as_posix()}"\n'
        'case "$cmd$files" in\n'
        # FIRST. A fail_on naming a query that ALSO has an answer arm below would never
        # fire otherwise, because `case` takes the first match -- so a test asking for a
        # failure silently got a successful answer instead.
        # The pattern is QUOTED. An unquoted `case` pattern is a word, so a fail_on
        # containing a space -- "DROP SCHEMA", "hafd.contexts AS c" -- was a shell syntax
        # error, and the stub died instead of simulating the failure it was asked for.
        + (f'  *"{fail_on}"*) echo "stub psql: simulated failure" >&2; exit 3 ;;\n' if fail_on else "")
        # pg_cron: `has the extension` and `which jobs are left`. Both must answer,
        # or the survivor branch is skipped and a leftover job goes unreported.
        # The section-0 identity query, and the confirmation's current_database().
        # Without these the whole suite runs the degraded path, which now exits 2 -- so
        # every test would fail before reaching its own subject.
        + f'  *inet_server_addr*)     printf "%s\\n" {server!r} ;;\n'
        + '  *"SELECT current_database()"*) printf "somedb" ;;\n'
        + f'  *pg_extension*)         printf "%s\\n" {("t" if cron_left else "f")!r} ;;\n'
        f'  *cron.job*)             printf "%s\\n" {cron_left!r} ;;\n'
        # The pre-flight probes. All three mention is_superuser, so one arm answers
        # them all; _guarded_psql below separates them where a test needs to.
        # The script REFUSES rather than warns when this is not 't'. Be accurate about
        # why, since an earlier comment here was not: step 6 DOES see a surviving
        # context -- SELECT on hafd.contexts is a separate policy, USING (TRUE), and
        # only DELETE is filtered by can_impersonate. The refusal exists because the
        # alternative is a loud failure that arrives AFTER three DROP SCHEMA CASCADEs.
        f'  *is_superuser*)         printf "%s\\n" {can_remove!r} ;;\n'
        # BEFORE the count arm: both queries read pg_stat_activity, so a single arm
        # answered both and the listing could only ever echo the count back.
        # %b, not %s: the listing is multi-row and arrives as a Python repr, so its
        # newlines are literal backslash-n. printf interprets escapes in the FORMAT,
        # not in an argument, so %s would emit one line containing a literal "\n" --
        # the same trap that made an earlier negative control pass for the wrong reason.
        + f'  *string_agg*)           printf "%b" {listing!r} ;;\n'
        + f'  *pg_stat_activity*)     printf "%s\\n" {sessions!r} ;;\n'
        f'  *uninstall_verify.sql*) printf "%s\\n" {remaining!r} ;;\n'
        # Step 6's HAF probe is a pg_class/pg_namespace join (to_regclass raises
        # without USAGE on hafd). Both spellings answer, so a regression to the
        # old form fails the whole-expression test rather than silently passing.
        '  *pg_class*)             printf "t" ;;\n'
        '  *to_regclass*)          printf "t" ;;\n'
        f'  *"hafd.contexts AS c"*) printf "%s\\n" {context_left!r} ;;\n'
        # Step 6's registry-survivor query (#97). Its own arm, and a parameter no default
        # sets, for the reason test_a_surviving_context_is_reported gives.
        f'  *"hafd.applications AS a"*) printf "%s\\n" {app_left!r} ;;\n'
        + "esac\n"
        "exit 0\n",
    )
    return logfile


def run(bash, tmp_path, *args: str, stdin: str | None = None,
        env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = clean_env(stub_bin(tmp_path))
    # After clean_env, which strips the app's own variables on purpose. PGHOSTADDR is
    # libpq's, not ours, and is the point of the #75 tests.
    env.update(env_extra or {})
    return subprocess.run(
        [bash, str(SCRIPT), *args],
        env=env,
        input=stdin,
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
    )


def sql_of(logfile: Path) -> str:
    return logfile.read_text() if logfile.exists() else ""


# --- the pre-flight, rewritten in round two ---------------------------------------

# The whole expression, compared after comments are stripped -- the standard this module
# already holds every other probe to (see _probe_sql). Mutation testing showed why it is
# needed here: replacing inet_server_addr()/inet_server_port() with the REQUESTED
# '${POSTGRES_HOST}'/'${POSTGRES_PORT}' -- which reinstates exactly the bug #75 exists to
# fix -- left all 59 tests green, because the fixture dispatches on the token
# `inet_server_addr` appearing anywhere in the statement, and a comment mentioning it
# satisfies that.
EXPECTED_SERVER_IDENTITY = (
    "SELECT coalesce(host(inet_server_addr()), 'LOCAL SOCKET') "
    "|| ':' || coalesce(inet_server_port()::text, '-') "
    "|| '/' || current_database() "
    "|| ' as ' || current_user "
    "|| CASE WHEN current_user <> session_user "
    "THEN ' (current_user differs from session_user ' || session_user || ')' "
    "ELSE '' END "
    "|| ' [cluster ' || (SELECT system_identifier FROM pg_control_system()) || ']'"
)


def _server_identity_sql() -> str:
    """The SQL _server_identity() actually sends, comments stripped and whitespace flat."""
    body = SCRIPT.read_text(encoding="utf-8")
    start = body.index("_server_identity() {")
    frag = body[start:body.index("\n}", start)]
    sql = frag.split('-c "', 1)[1].rsplit('"', 1)[0]
    lines = [l.split("--")[0] for l in sql.splitlines()]
    return " ".join(" ".join(lines).split())


def test_the_identity_query_asks_the_server_not_the_variables():
    """A regression that keeps the psql call and changes WHAT it asks is otherwise
    invisible: the stub answers on a token, and a comment carries the token."""
    assert _server_identity_sql() == EXPECTED_SERVER_IDENTITY


def _guarded_psql(tmp_path, *, can_impersonate="t", createrole="t", has_contexts="t",
                  group_member="t", admin_option="t", fail_on=None,
                  server="10.1.1.7:5432/somedb as someone [cluster 7391424]"):
    """A psql that answers the three pre-flight probes independently."""
    stub_bin(tmp_path)
    logfile = tmp_path / "sql.log"
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        'prev=""\n'
        'for a in "$@"; do\n'
        '  case "$prev" in -c) cmd="$cmd$a" ;; esac\n'
        '  prev="$a"\n'
        "done\n"
        f'printf "%s\\n---\\n" "$cmd" >> "{logfile.as_posix()}"\n'
        # argv too, like make_psql: the REFUSAL paths all use this stub, and they are
        # the only ones that reach _report_connected_identity. Without it, a refusal
        # re-querying the identity with a bare `psql` -- losing -h/-p/-U/-d, so it
        # names the LOCAL server while the teardown targets the remote one -- was
        # invisible to the whole module.
        f'printf "%s\n" "$*" >> "{(tmp_path / "argv.log").as_posix()}"\n'
        + (f'case "$cmd" in *{fail_on}*) echo "stub: failing" >&2; exit 2 ;; esac\n'
           if fail_on else "")
        + 'case "$cmd" in\n'
        # FIRST, and keyed on tokens that exist ONLY in the round-four predicates.
        # The arms below key on `rolcreaterole` and `can_impersonate`, which appear in
        # the broken round-three forms too -- so with only those, restoring a broken
        # guard left every test named after its fix green.
        #
        # Each guard is ONE query carrying both its tokens, so these answer for the
        # WHOLE predicate: true only when every component the caller set is true. If
        # the script loses the round-four token, the arm stops matching, the old arm
        # below answers "t", the teardown proceeds, and the test fails. That
        # fall-through IS the discrimination.
        f'  *"MEMBER WITH ADMIN OPTION"*) printf "%s\\n" {("t" if createrole == "t" and admin_option == "t" else "f")!r} ;;\n'
        f'  *hive_applications_group*)   printf "%s" {("t" if group_member == "t" and can_impersonate == "t" else "f")!r} ;;\n'
        # Guard 1 is a pg_class/pg_namespace join now, NOT to_regclass -- to_regclass
        # raises `permission denied for schema hafd` without USAGE on it, verified on
        # postgres:14 and :17. Both spellings answer here so a regression to the old
        # form is caught by the whole-expression test rather than silently passing.
        f'  *pg_class*)        printf "%s" {has_contexts!r} ;;\n'
        f'  *to_regclass*)     printf "%s" {has_contexts!r} ;;\n'
        f'  *can_impersonate*) printf "%s" {can_impersonate!r} ;;\n'
        f'  *rolcreaterole*)   printf "%s" {createrole!r} ;;\n'
        '  *pg_stat_activity*) printf "0" ;;\n'
        # AFTER pg_stat_activity, and matched on the identity query's own
        # distinctive text: the session-count query ALSO says current_database(),
        # and `case` takes the first match, so a *current_database* arm above it
        # fed this string to the session guard as a count.
        # The #75 identity query. Keyed on inet_server_addr, which appears in no other
        # query here -- it is the whole point of that one: it describes the connection
        # that was MADE, where every other value the script could print describes what
        # was REQUESTED.
        # Derived from PGHOSTADDR when it is set, so a test that sets it is actually
        # testing retargeting rather than two constants the author made match. The real
        # libpq does exactly this: hostaddr wins, and -h applies only to auth and TLS.
        '  *inet_server_addr*) if [ -n "${PGHOSTADDR:-}" ]; then\n'
        '                          printf "%s:5432/somedb as someone [cluster 1234]" "$PGHOSTADDR"\n'
        f'                      else printf "%s\\n" {server!r}; fi ;;\n'
        "esac\n"
        "exit 0\n",
    )
    return logfile


def test_refuses_when_the_role_cannot_impersonate_the_context_owner(bash, tmp_path):
    """The guard must ask the question the POLICY asks.

    hafd.contexts' DELETE policy is USING (hive.can_impersonate(current_user, owner)),
    where `owner` is the ROW's column. An earlier revision tested membership of the
    literal 'haf_stats_owner' instead, which is a different question and answers TRUE in
    cases where the delete still matches nothing -- install_app.sh documents a context
    registered by an older build as owned by haf_admin.

    Refusing matters because the alternative is not a silent success (step 6 DOES see
    the row -- SELECT is a separate policy, USING (TRUE)) but a loud failure that
    arrives AFTER three DROP SCHEMA CASCADEs.
    """
    log = _guarded_psql(tmp_path, can_impersonate="f")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "Nothing has been changed" in r.stdout
    assert "DROP SCHEMA" not in sql_of(log)
    assert "app_remove_context" not in sql_of(log)
    # And it names the SERVER (#75), not just the role. Only guard 3's refusal was
    # covered, so deleting _report_connected_identity from THIS one -- a call site this
    # MR moved -- passed the whole module. "Re-run as haf_admin" sends the operator to a
    # machine; under a redirected connection it is the wrong one.
    assert "connected to 10.1.1.7:5432/somedb as someone" in r.stdout, r.stdout
    assert "[cluster 7391424]" in r.stdout, r.stdout


def test_refuses_a_role_that_cannot_drop_roles(bash, tmp_path):
    """--user=haf_stats_owner passes the impersonation check -- a role can always
    impersonate itself -- but step 5's DROP ROLE needs CREATEROLE or superuser, and a
    role cannot drop itself. Without this the teardown dropped all three schemas and
    only failed at step 5, with the rollups already gone."""
    log = _guarded_psql(tmp_path, createrole="f")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "Nothing has been changed" in r.stdout
    assert "DROP SCHEMA" not in sql_of(log)


def test_a_permitted_role_gets_past_the_pre_flight(bash, tmp_path):
    """The positive half. Asserting only the refusals leaves an inverted comparison
    green, which would refuse every teardown including haf_admin's."""
    log = _guarded_psql(tmp_path)
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "app_remove_context" in sql_of(log)


def test_a_failing_pre_flight_probe_refuses_rather_than_guessing(bash, tmp_path):
    """It must not collapse a connection failure into "you lack permission".

    An earlier revision wrapped the probe in `2>/dev/null || echo ""`, so a reset, an
    auth error and a genuine "no" all produced the same misleading message with the real
    psql error discarded."""
    log = _guarded_psql(tmp_path, fail_on="can_impersonate")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "Nothing has been changed" in r.stdout
    assert "DROP SCHEMA" not in sql_of(log)


def test_a_non_haf_database_skips_the_context_pre_flight(bash, tmp_path):
    """No hafd.contexts means no context to fail to delete. The guard must not refuse a
    teardown of the schemas and roles on a database that never had HAF."""
    log = _guarded_psql(tmp_path, has_contexts="f", can_impersonate="f")
    r = run(bash, tmp_path, "--force")
    assert "DROP SCHEMA" in sql_of(log), r.stdout + r.stderr


# --- pg_cron (round two) -----------------------------------------------------------
#
# install_app.sh step 8d schedules four jobs in cron.job, which is OUTSIDE the three
# schemas step 4 drops, so a "successful" teardown used to leave them firing nightly
# against functions that no longer exist. The unschedule block and its survivor probe
# were added in round one with no tests at all: deleting both wholesale left the whole
# suite green.


def test_every_scheduled_cron_job_is_also_unscheduled(bash, tmp_path):
    """The two lists must not drift.

    A job added to install_app.sh and forgotten here survives every teardown, and
    nothing else in this suite would notice. Read from the SOURCE of both scripts rather
    than from a hardcoded list here, so adding a fifth job fails this test rather than
    silently agreeing with a stale copy.
    """
    import re
    install = (SCRIPT.parent / "install_app.sh").read_text()
    scheduled = set(re.findall(r"cron\.schedule\(\s*'([a-z0-9_]+)'", install))
    unscheduled = set(re.findall(r"'(haf_stats_[a-z0-9_]+)'", SCRIPT.read_text().split(
        "Unscheduling pg_cron jobs", 1)[1].split("END\\$\\$;", 1)[0]))
    assert scheduled, "no cron.schedule calls found in install_app.sh; update the parser"
    missing = scheduled - unscheduled
    assert not missing, f"scheduled by install_app.sh but never unscheduled: {sorted(missing)}"


def test_the_jobs_are_unscheduled_before_the_schemas_are_dropped(bash, tmp_path):
    """Order matters: a job that fires between DROP SCHEMA and the unschedule runs
    against a half-removed app."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    sql = sql_of(log)
    assert "cron.unschedule" in sql
    assert sql.index("cron.unschedule") < sql.index("DROP SCHEMA"), (
        "the cron jobs must be unscheduled before the schemas are dropped"
    )


def test_a_surviving_cron_job_is_reported(bash, tmp_path):
    """uninstall_verify.sql deliberately does not look at cron.job, so this branch is
    the only thing that reports one. Without it a teardown that failed to unschedule
    prints 'haf_stats removed' and exits 0."""
    log = make_psql(tmp_path, cron_left="cron job haf_stats_rc_rates")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "INCOMPLETE" in r.stdout
    assert "haf_stats_rc_rates" in r.stdout
    # And the teardown really did try to unschedule it, rather than the survivor being
    # reported by a branch that never ran.
    assert "cron.unschedule" in sql_of(log)


def test_the_cron_probe_does_not_need_usage_on_the_cron_schema(bash, tmp_path):
    """to_regclass('cron.job') RESOLVES THE SCHEMA and raises `permission denied for
    schema cron` -- aclcheck_error fires even under missing_ok -- for any caller without
    USAGE on it, which pg_cron does not grant by default. That would set _probe_failed
    and print 'could not verify ... Do NOT assume it succeeded' forever, after a
    teardown that in fact completed. pg_extension is readable by every role."""
    body = SCRIPT.read_text()
    probe = body.split("_has_cron=", 1)[1].split("\n", 2)[0:2]
    probe = "".join(probe)
    assert "pg_extension" in probe
    assert "to_regclass('cron.job')" not in probe


# --- the session guard ------------------------------------------------------------

def test_refuses_while_a_haf_stats_session_is_connected(bash, tmp_path):
    """The block processor and PostgREST all hold sessions on these schemas, and
    DROP SCHEMA CASCADE needs an AccessExclusiveLock -- so with one live the teardown
    would BLOCK rather than fail, after the context was already gone."""
    log = make_psql(tmp_path, sessions="3",
                    listing="haf_stats_user x2 (haf-stats-api)\nhaf_stats_owner x1\n")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "still connected" in r.stdout
    assert "DROP SCHEMA" not in sql_of(log)
    # #75, and ORDERING, not just presence: this is the refusal an operator hits
    # routinely, and it named no server at all. Moving `Target:` back below the guard
    # restores exactly that while every other test still passes, because they all use a
    # stub with sessions="0" and reach the banner anyway.
    assert "reached  :" in r.stdout, r.stdout
    assert r.stdout.index("reached  :") < r.stdout.index("still connected"), r.stdout
    # The LISTING, not just the count. This refusal ends in a colon promising one, and it
    # was silently empty in every test: the stub answered without psql's row terminator,
    # and `... | while read -r line` drops an unterminated final line -- so deleting the
    # listing outright was green. Telling an operator "3 sessions" without saying WHICH
    # leaves them the work this line exists to do.
    assert "haf_stats_user x2 (haf-stats-api)" in r.stdout, r.stdout
    assert "haf_stats_owner x1" in r.stdout, r.stdout
    # And the inventory must NOT have printed: nothing was destroyed.
    assert "PERMANENTLY" not in r.stdout, r.stdout


def test_an_empty_session_count_refuses_rather_than_proceeding(bash, tmp_path):
    """Fail CLOSED. `[ "$x" -ne 0 ]` with x empty is a syntax error returning 2, and as
    an `if` condition `set -e` does not fire -- so an earlier revision read an empty
    psql reply as "no sessions" and dropped everything."""
    log = make_psql(tmp_path, sessions="")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "DROP SCHEMA" not in sql_of(log)


def test_a_non_numeric_session_count_refuses(bash, tmp_path):
    log = make_psql(tmp_path, sessions="ERROR")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "DROP SCHEMA" not in sql_of(log)


def test_the_guard_keys_on_usename_not_query_text(bash, tmp_path):
    """pg_stat_activity hides `query` for other roles' backends from non-superusers, so
    a query-text guard returns zero rows for such an operator and waves the uninstall
    through while the processor is running."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    guard = sql_of(log)
    assert "usename IN ('haf_stats_owner', 'haf_stats_user')" in guard
    assert "haf_stats_app.main" not in guard


def test_the_guard_ignores_this_apps_own_healthcheck(bash, tmp_path):
    """It connects as haf_stats_owner every 60s, holds no lock, and lives milliseconds.
    Catching one in flight must not refuse a staged teardown."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    assert "haf_stats_health_check" in sql_of(log)


# --- confirmation -----------------------------------------------------------------

def test_refuses_without_a_tty_and_without_force(bash, tmp_path):
    """A compose run has no TTY, so hanging on a prompt nobody can answer is the
    failure this prevents."""
    log = make_psql(tmp_path)
    r = run(bash, tmp_path, stdin="")
    assert r.returncode == 2
    assert "without --force" in r.stdout
    # No inventory ahead of a refusal -- the TTY check comes first for that reason.
    assert "PERMANENTLY" not in r.stdout, r.stdout
    assert "DROP SCHEMA" not in sql_of(log)


def test_force_skips_the_prompt_and_proceeds(bash, tmp_path):
    log = make_psql(tmp_path)
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "DROP SCHEMA IF EXISTS haf_stats_app CASCADE;" in sql_of(log)


# --- what it actually removes -----------------------------------------------------

def test_removes_the_context_by_its_context_name_not_the_schema_name(bash, tmp_path):
    """The trap the script exists to get right. The context is haf_stats; the schema is
    haf_stats_app. app_remove_context('haf_stats_app') is guarded by app_context_exists(),
    so the wrong name does nothing at all and orphans the context silently."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    sql = sql_of(log)
    assert "hive.app_remove_context('haf_stats')" in sql
    assert "hive.app_remove_context('haf_stats_app')" not in sql


def test_drops_all_three_schemas(bash, tmp_path):
    """haf_stats owns three, not two: _app, _backend (the rollups) and _endpoints.
    Missing one leaves data behind and the verification then reports INCOMPLETE."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    sql = sql_of(log)
    for schema in ("haf_stats_app", "haf_stats_backend", "haf_stats_endpoints"):
        assert f"DROP SCHEMA IF EXISTS {schema} CASCADE;" in sql


def test_drops_both_roles_guarded_by_remaining_context_ownership(bash, tmp_path):
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    sql = sql_of(log)
    assert "DROP ROLE haf_stats_user;" in sql
    assert "DROP ROLE haf_stats_owner;" in sql
    assert "owner = 'haf_stats_owner'" in sql


def test_removes_the_context_before_dropping_the_schemas(bash, tmp_path):
    """hive.context_remove drops the context's own table out of the app schema, so the
    schema has to still be there."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    sql = sql_of(log)
    assert sql.index("app_remove_context") < sql.index("DROP SCHEMA IF EXISTS haf_stats_app")


def test_a_surviving_context_is_reported(bash, tmp_path):
    """The ONLY thing that reports a context the teardown failed to remove --
    uninstall_verify.sql deliberately excludes hafd.contexts. The stub had a
    context_left parameter that no test ever set, so deleting the whole branch was
    green, and the RLS zero-rows scenario the script warns about by name would have
    printed "haf_stats removed" and exited 0."""
    make_psql(tmp_path, context_left="context haf_stats")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "INCOMPLETE" in r.stdout
    assert "context haf_stats" in r.stdout


# --- the application registry row (#97) ---------------------------------------------

def _registry_block(sql: str) -> str:
    """The step-3a DO block, as sent."""
    start = sql.index("hive.app_unregister(text)")
    return sql[sql.rindex("DO $$", 0, start):sql.index("END$$;", start)]


def test_unregisters_the_app_before_dropping_the_schemas(bash, tmp_path):
    """Step 3's context removal normally unregisters the app as a side effect, but step 3
    may fail and be pushed past, and then the row outlives the schema its
    process_procedure names. scripts/process_blocks.sh reads that row to decide whether to
    exec the driver."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    sql = sql_of(log)
    assert "PERFORM hive.app_unregister('haf_stats');" in sql
    assert sql.index("hive.app_unregister('haf_stats')") < sql.index("DROP SCHEMA IF EXISTS haf_stats_app")


def test_the_unregister_is_guarded_in_sequence(bash, tmp_path):
    """No-op on a registry-less HAF. to_regnamespace before to_regprocedure, because the
    latter RAISES on a missing schema on PostgreSQL <= 15; the EXISTS before the call,
    because hive.app_unregister RAISES when there is no row -- the normal state once step
    3 has succeeded, so an unguarded call would count an error on every clean uninstall."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    block = _registry_block(sql_of(log))
    steps = [
        "to_regnamespace('hive') IS NULL",
        "to_regprocedure('hive.app_unregister(text)') IS NULL",
        "EXISTS (SELECT 1 FROM hafd.applications WHERE name = 'haf_stats')",
        "PERFORM hive.app_unregister('haf_stats');",
    ]
    positions = [block.index(s) for s in steps]
    assert positions == sorted(positions), block
    # Separate statements, each returning early -- not one AND chain, whose evaluation
    # order PostgreSQL does not promise.
    assert block.count("RETURN;") == 2
    assert " AND " not in block


def test_a_surviving_registry_row_is_reported(bash, tmp_path):
    make_psql(tmp_path, app_left="application registry entry haf_stats")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "INCOMPLETE" in r.stdout
    assert "application registry entry haf_stats" in r.stdout


def test_a_failing_registry_probe_does_not_report_a_clean_teardown(bash, tmp_path):
    make_psql(tmp_path, fail_on="hafd.applications AS a")
    r = run(bash, tmp_path, "--force")
    assert r.returncode != 0
    assert "haf_stats removed" not in r.stdout
    assert "could not verify" in r.stdout


def test_a_failing_registry_table_probe_does_not_report_a_clean_teardown(bash, tmp_path):
    """The EARLIER of the two registry probes. Its failure yields "" -- not "t" -- so
    without its own `|| _probe_failed=1` the survivor query is skipped silently and a
    surviving row goes unreported. Negative control: deleting that capture left every
    other registry test green."""
    make_psql(tmp_path, fail_on="c.relname = 'applications'")
    r = run(bash, tmp_path, "--force")
    assert r.returncode != 0
    assert "haf_stats removed" not in r.stdout
    assert "could not verify" in r.stdout


# The step-3a block and both step-6 registry probes, compared WHOLE (whitespace
# normalised), as this module does for every other probe. The substring tests above cannot
# tell `IF EXISTS (...)` from `IF TRUE THEN -- EXISTS (...)`, a deleted RETURN, a
# survivor query that matches any application, or a pg_class probe pointed at the wrong
# schema -- reviewer mutation testing found this class of change passing them.
EXPECTED_REGISTRY_BLOCK = " ".join("""
DO $$
BEGIN
    IF to_regnamespace('hive') IS NULL THEN
        RAISE NOTICE 'no hive schema - no application registry to clean up';
        RETURN;
    END IF;
    IF to_regprocedure('hive.app_unregister(text)') IS NULL THEN
        RAISE NOTICE 'HAF has no application registry (pre-haf#341) - nothing to unregister';
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM hafd.applications WHERE name = 'haf_stats') THEN
        PERFORM hive.app_unregister('haf_stats');
        RAISE NOTICE 'unregistered application haf_stats';
    ELSE
        RAISE NOTICE 'haf_stats is not in the application registry - nothing to unregister';
    END IF;
END$$;
""".split())

EXPECTED_HAS_REGISTRY = (
    "SELECT EXISTS (SELECT 1 FROM pg_class c "
    "JOIN pg_namespace n ON n.oid = c.relnamespace "
    "WHERE n.nspname = 'hafd' AND c.relname = 'applications')"
)

EXPECTED_APP_LEFT = (
    "SELECT 'application registry entry ' || a.name "
    "FROM hafd.applications AS a WHERE a.name = 'haf_stats'"
)


def _statements(logfile: Path) -> list[str]:
    """Every -c statement the stub received, whitespace-normalised, in order."""
    return [" ".join(c.split()) for c in sql_of(logfile).split("---\n") if c.strip()]


def test_the_registry_statements_are_exactly_what_is_expected(bash, tmp_path):
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    stmts = _statements(log)

    blocks = [s for s in stmts if "app_unregister" in s]
    assert blocks == ["SET lock_timeout = '30s'; " + EXPECTED_REGISTRY_BLOCK]
    assert [s for s in stmts if "relname = 'applications'" in s] == [EXPECTED_HAS_REGISTRY]
    assert [s for s in stmts if "hafd.applications AS a" in s] == [EXPECTED_APP_LEFT]


def test_the_registry_survivor_probe_needs_no_usage_on_hafd(bash, tmp_path):
    """Asked through pg_class, like the context probe: to_regclass('hafd.applications')
    raises for a caller without USAGE on hafd, and that would read as a failed probe."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    sql = sql_of(log)
    assert "c.relname = 'applications'" in sql
    assert "to_regclass('hafd.applications')" not in sql


def test_the_lock_timeout_has_a_real_value(bash, tmp_path):
    """Greping for the key alone let '30s' become '0', which DISABLES the timeout and
    restores the indefinite block it exists to prevent."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    assert "SET lock_timeout = '30s';" in sql_of(log)


def test_sets_a_lock_timeout_on_the_destructive_statements(bash, tmp_path):
    """Without it, a DROP that cannot get its lock waits forever behind a session that
    appeared after the guard ran."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    assert "SET lock_timeout" in sql_of(log)


# --- reporting --------------------------------------------------------------------

def test_reports_incomplete_and_exits_nonzero_when_something_survives(bash, tmp_path):
    """The whole reason the destructive statements are allowed to push past an error:
    a partial teardown must be visible, not silent."""
    make_psql(tmp_path, remaining="schema haf_stats_endpoints, role haf_stats_owner")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "INCOMPLETE" in r.stdout
    assert "haf_stats_endpoints" in r.stdout


def test_a_clean_teardown_exits_zero(bash, tmp_path):
    make_psql(tmp_path, remaining="")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 0
    assert "INCOMPLETE" not in r.stdout


# --- connection flags -------------------------------------------------------------

def test_defaults_to_haf_admin_not_the_owner_role(bash, tmp_path):
    """common.sh defaults POSTGRES_USER to haf_stats_owner, which cannot drop roles and
    cannot drop itself. The override has to be applied BEFORE the source -- applied
    after, `: "${POSTGRES_USER:=...}"` has already run and the default never takes
    effect. Asserted on the connection psql was actually given, not on a log line."""
    make_psql(tmp_path)
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "-U haf_admin" in (tmp_path / "argv.log").read_text()


def test_user_flag_overrides_the_default(bash, tmp_path):
    """--user is what docker_entrypoint.sh forwards to this script, so it has to reach
    the connection rather than just being parsed."""
    make_psql(tmp_path)
    run(bash, tmp_path, "--force", "--user=someone_else")
    assert "-U someone_else" in (tmp_path / "argv.log").read_text()


def test_postgres_host_is_accepted_as_a_synonym_for_host(bash, tmp_path):
    """balance_tracker's runbooks say --postgres-host; the other two say --host. With
    the new unknown-option error, rejecting either would turn a copied runbook into a
    hard failure."""
    make_psql(tmp_path)
    r = run(bash, tmp_path, "--force", "--postgres-host=elsewhere")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "-h elsewhere" in (tmp_path / "argv.log").read_text()


# --- the guard's SQL, not just the number it returns ---------------------------------
#
# The stub answers `sessions=` whatever the query computes, so until now the guard's
# SQL was unverified: inverting the healthcheck exclusion to `=`, turning
# `pid <> pg_backend_pid()` into `=`, dropping the datname filter or injecting `AND 1=0`
# all left the suite green while the guard counted the wrong thing or nothing at all.
# Compared whole, the way the healthcheck predicate is.

EXPECTED_SESSION_QUERY = (
    "SELECT count(*) FROM pg_stat_activity "
    "WHERE datname = current_database() "
    "AND pid <> pg_backend_pid() "
    "AND usename IN ('haf_stats_owner', 'haf_stats_user') "
    "AND coalesce(application_name, '') <> 'haf_stats_health_check'"
)


def normalised(sql: str) -> str:
    return " ".join(sql.split())


def test_the_session_guard_query_is_exactly_what_is_expected(bash, tmp_path):
    """Deliberately brittle. Every clause here is load-bearing: the datname filter keeps
    other databases out, `pid <>` keeps the guard from counting itself, `usename IN`
    covers both roles, and the application_name exclusion keeps this
    app's own healthcheck probe from blocking a staged teardown."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    guard = [b for b in sql_of(log).split("---") if "pg_stat_activity" in b and "count(*)" in b][0]
    assert normalised(guard) == EXPECTED_SESSION_QUERY


def test_the_verification_sql_is_a_reviewed_file_not_an_inline_string(bash, tmp_path):
    """Inline, a test could only grep the assembled string, which cannot tell a query
    that reports survivors from one whose branches return nothing."""
    verify = (SCRIPT.parent / "uninstall_verify.sql").read_text()
    body = normalised(" ".join(
        line for line in verify.splitlines() if not line.lstrip().startswith("--")
    ))
    assert body == (
        "SELECT string_agg( item, ', ' ORDER BY item ) FROM ( "
        "SELECT 'schema ' || n.nspname AS item FROM pg_namespace AS n "
        "WHERE n.nspname IN ('haf_stats_app', 'haf_stats_backend', 'haf_stats_endpoints') "
        "UNION ALL "
        "SELECT 'role ' || r.rolname AS item FROM pg_roles AS r "
        "WHERE r.rolname IN ('haf_stats_owner', 'haf_stats_user') "
        ") AS s;"
    )


def test_the_verification_sql_never_references_hafd(bash, tmp_path):
    """A WHERE clause cannot protect a FROM clause -- PostgreSQL resolves relation names
    during parse analysis. An earlier revision put `WHERE to_regclass('hafd.contexts')
    IS NOT NULL` on a branch selecting FROM hafd.contexts and claimed that guarded the
    non-HAF case; it did not, and the script still died there after dropping
    everything. The context is now checked separately, only when it exists."""
    code = [line for line in (SCRIPT.parent / "uninstall_verify.sql").read_text().splitlines()
            if not line.lstrip().startswith("--")]
    assert not any("hafd" in line for line in code)


def test_a_non_haf_database_completes_instead_of_aborting(bash, tmp_path):
    """Behavioural, not textual. The stub errors on any query touching hafd.contexts,
    exactly as a database without the HAF extension would, and the script must still
    finish and report cleanly.

    The version this replaces asserted only that the string
    "to_regclass('hafd.contexts') IS NOT NULL" appeared in the query -- which was true
    of the broken guard it was written to pin, and would be equally true of
    `WHERE 1=0 AND to_regclass(...)`. It tested the presence of a fix, not the fix.
    """
    stub_bin(tmp_path)
    logfile = tmp_path / "sql.log"
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        'prev=""\n'
        'for a in "$@"; do\n'
        '  if [ "$prev" = "-c" ]; then cmd="$a"; fi\n'
        '  prev="$a"\n'
        "done\n"
        f'printf "%s\\n---\\n" "$cmd" >> "{logfile.as_posix()}"\n'
        'case "$cmd" in\n'
        # pg_stat_activity FIRST: the guard query mentions neither of the others.
        f'  *inet_server_addr*) printf "%s" {STUB_SERVER_IDENTITY!r} ;;\n'
        '  *is_superuser*)     printf "t" ;;\n'
        '  *pg_stat_activity*) printf "0" ;;\n'
        # The bare to_regclass probe is the ONLY statement that is just a probe; every
        # other hafd-touching statement in the script also contains to_regclass(), so
        # matching *to_regclass* before *hafd.contexts* made the error arm dead code and
        # this test inert. Match the probe exactly, then let anything else that touches
        # hafd.contexts error the way a non-HAF database would.
        '  "SELECT to_regclass(\'hafd.contexts\') IS NOT NULL") printf "f" ;;\n'
        '  *hafd.contexts*)    echo "ERROR:  relation hafd.contexts does not exist" >&2; exit 3 ;;\n'
        "esac\n"
        "exit 0\n",
    )
    r = subprocess.run(
        [bash, str(SCRIPT), "--force"],
        env=clean_env(tmp_path / "bin"),
        capture_output=True, text=True, timeout=TIMEOUT,
    )
    assert r.returncode == 0, r.stdout + r.stderr
    assert "haf_stats removed" in r.stdout


def test_the_closing_message_does_not_claim_the_grants_survived(bash, tmp_path):
    """db/builtin_roles.sql grants TO these roles, so they are the grantee and
    `DROP OWNED BY ... CASCADE` revokes those privileges -- which is precisely why step
    5 needs it, as step 5's own comment says. An earlier closing message told the
    operator the opposite, and the closing message is the line they actually read."""
    make_psql(tmp_path)
    out = run(bash, tmp_path, "--force").stdout
    assert "went with" in out
    assert "grants held by OTHER roles" not in out


# --- the role-drop guard, compared whole ---------------------------------------------
#
# Mutation testing: flattening the nested IF back into
# `to_regclass(...) IS NOT NULL AND EXISTS (SELECT ... FROM hafd.contexts ...)` -- the
# exact parse-time bug the comment says the nesting exists to prevent -- survived, and
# so did deleting the RETURN that stops both roles being dropped while haf_stats_owner
# still owns another context. Both were greped for a substring both mutants contain.

def _role_block(log):
    """The role-drop statement with its SQL comments stripped.

    Stripped BEFORE collapsing whitespace: the block's comments quote the broken flat
    form verbatim to explain why the nesting exists, so a naive search finds it in the
    prose and the assertion can never fail.
    """
    raw = [b for b in sql_of(log).split("---") if "DROP ROLE" in b][0]
    code = [line.split("--")[0] for line in raw.splitlines()]
    return normalised(" ".join(code))


def test_the_role_guard_nests_rather_than_conjoins(bash, tmp_path):
    """PL/pgSQL plans an IF condition as one expression, so `A AND EXISTS(SELECT ...
    FROM missing)` still fails at parse time. Verified against a live PostgreSQL: the
    flat form errors, the nested form does not."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    block = _role_block(log)
    assert "IF to_regclass('hafd.contexts') IS NOT NULL THEN IF EXISTS" in block
    assert "IS NOT NULL AND EXISTS" not in block


def test_the_role_guard_returns_when_a_context_still_owns_the_role(bash, tmp_path):
    """Without the RETURN, both roles are dropped precisely when another HAF context
    still belongs to haf_stats_owner -- the case the guard exists for."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    block = _role_block(log)
    head = block.split("IF EXISTS (SELECT 1 FROM pg_roles")[0]
    assert "RETURN;" in head


def test_both_roles_get_drop_owned_by_before_drop_role(bash, tmp_path):
    """DROP ROLE fails while the role holds privileges granted by
    db/builtin_roles.sql, which is what the closing message says step 5 is for."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    block = _role_block(log)
    for role in ("haf_stats_user", "haf_stats_owner"):
        assert f"DROP OWNED BY {role} CASCADE;" in block
        assert block.index(f"DROP OWNED BY {role}") < block.index(f"DROP ROLE {role};")
        # GUARDED by an existence test, and guarded BEFORE the drop. Without it a re-run
        # raises 42704 on the first missing role, which aborts the whole DO block -- so
        # the SECOND role is never dropped and every subsequent run reports INCOMPLETE.
        # The idempotent re-run is what the file header advertises and what step 6 tells
        # the operator to rely on.
        guard = f"IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN"
        assert guard in block, (
            f"the {role} drop is no longer guarded by an existence test, so a re-run "
            f"aborts the DO block on 42704: {block}")
        assert block.index(guard) < block.index(f"DROP OWNED BY {role}")


# --- the teardown must not die at the first failing statement -------------------------

def test_a_failing_destructive_statement_does_not_abort_the_run(bash, tmp_path):
    """The design's whole premise, and it was broken.

    `-v ON_ERROR_STOP=off` does NOT keep psql's exit status at 0 when the failing
    statement is the last -c -- verified against a live PostgreSQL 14:

        -c failing LAST,  ON_ERROR_STOP=off -> exit 1
        -f  failing,      ON_ERROR_STOP=off -> exit 0

    As a bare command under `set -e` that killed the script at the first destructive
    error, before step 6 could report anything, leaving the unrecoverable half-torn-down
    state the design exists to prevent.
    """
    stub_bin(tmp_path)
    logfile = tmp_path / "sql.log"
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        "files=''\n"
        'prev=""\n'
        'for a in "$@"; do\n'
        '  case "$prev" in -c) cmd="$cmd$a" ;; -f) files="$files$a" ;; esac\n'
        '  prev="$a"\n'
        "done\n"
        f'printf "%s\\n---\\n" "$cmd" >> "{logfile.as_posix()}"\n'
        'case "$cmd$files" in\n'
        f'  *inet_server_addr*)     printf "%s" {STUB_SERVER_IDENTITY!r} ;;\n'
        '  *is_superuser*)         printf "t" ;;\n'
        '  *pg_stat_activity*)     printf "0" ;;\n'
        '  *uninstall_verify.sql*) printf "" ;;\n'
        # Step 6's HAF probe is a pg_class/pg_namespace join (to_regclass raises
        # without USAGE on hafd). Both spellings answer, so a regression to the
        # old form fails the whole-expression test rather than silently passing.
        '  *pg_class*)             printf "t" ;;\n'
        '  *to_regclass*)          printf "t" ;;\n'
        # The first schema drop fails, exactly as a lock timeout would.
        '  *"DROP SCHEMA IF EXISTS haf_stats_app"*) echo "ERROR: canceling statement due to lock timeout" >&2; exit 1 ;;\n'
        '  *"hafd.contexts AS c"*) printf "" ;;\n'
        "esac\n"
        "exit 0\n",
    )
    r = subprocess.run(
        [bash, str(SCRIPT), "--force"], env=clean_env(tmp_path / "bin"),
        capture_output=True, text=True, timeout=TIMEOUT,
    )
    sql = sql_of(logfile)
    # It kept going: the SECOND schema and the roles were still attempted.
    assert "DROP SCHEMA IF EXISTS haf_stats_endpoints CASCADE;" in sql
    assert "DROP ROLE haf_stats_owner;" in sql
    # And it said so rather than exiting silently. BOTH, not either: the first always
    # holds, so `or` meant the summary NOTE was never tested -- a teardown that errored on
    # several statements could exit reporting nothing at all.
    assert "statement failed" in r.stdout, r.stdout
    assert "errored during teardown" in r.stdout, r.stdout


def test_a_failing_verification_probe_does_not_report_success(bash, tmp_path):
    """A command substitution inside an `if` CONDITION is exempt from set -e, so a psql
    that failed yielded "" -- not "t" -- and the context branch was skipped SILENTLY,
    printing "haf_stats removed" with the context still registered."""
    stub_bin(tmp_path)
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        "files=''\n"
        'prev=""\n'
        # ONE loop. An earlier revision read -f in a second loop that never reassigned
        # prev, so `files` was always empty, the -f arm never matched, the stub exited 0
        # for everything and the test passed while asserting nothing.
        'for a in "$@"; do\n'
        '  case "$prev" in -c) cmd="$cmd$a" ;; -f) files="$files$a" ;; esac\n'
        '  prev="$a"\n'
        "done\n"
        'case "$cmd$files" in\n'
        f'  *inet_server_addr*)      printf "%s" {STUB_SERVER_IDENTITY!r}; exit 0 ;;\n'
        '  *is_superuser*)          printf "t"; exit 0 ;;\n'
        '  *can_impersonate*)       printf "t"; exit 0 ;;\n'
        '  *rolcreaterole*)         printf "t"; exit 0 ;;\n'
        '  *pg_stat_activity*)      printf "0"; exit 0 ;;\n'
        # Fail on the VERIFICATION file, not on to_regclass. Both the pre-flight
        # HAF-detection probe and step 6's guard use the identical
        # `SELECT to_regclass('hafd.contexts') IS NOT NULL`, so failing that text now
        # trips the pre-flight and never reaches step 6 -- which is a different (also
        # correct) refusal, covered by its own test below. Failing the -f file exercises
        # the path this test is named for.
        '  *uninstall_verify.sql*)  echo "ERROR: connection lost" >&2; exit 2 ;;\n'
        "esac\n"
        "exit 0\n",
    )
    r = subprocess.run(
        [bash, str(SCRIPT), "--force"], env=clean_env(tmp_path / "bin"),
        capture_output=True, text=True, timeout=TIMEOUT,
    )
    assert r.returncode != 0
    assert "haf_stats removed" not in r.stdout
    assert "could not verify" in r.stdout


# --- the pre-flight predicates, pinned WHOLE (round three) --------------------------
#
# Mutation testing: `... OR true` appended to either probe makes the guard a permanent
# pass -- the #30/#57 refusal is dead and the destructive teardown runs for any role --
# and the entire suite stays green. It survives because the psql stub dispatches on a
# SUBSTRING of the statement (*can_impersonate*, *rolcreaterole*) and returns a canned
# answer, so it can only confirm that SOME statement mentioning that token was issued.
# The predicate around it is invisible to every behavioural test in this file.
#
# So compare the whole normalised expression, the way this file's docstring says the
# queries whose MEANING matters are compared. This catches an added disjunct, an
# inverted comparison, a swapped operand and a renamed column -- none of which the
# earlier token greps could see.


def _probe_sql(marker: str, occurrence: int = 0) -> str:
    """The -c argument of the assignment beginning `marker`, whitespace-normalised.

    COMMENTS ARE STRIPPED FIRST, and the marker must be unique. Both matter: this
    extractor takes the first TEXTUAL match, so a comment line containing the marker
    shadows the real assignment -- and an audit demonstrated exactly that, restoring the
    broken round-three guard while the whole suite stayed green. A commented-out copy of
    an old predicate is not a hypothetical either; it is the natural thing to leave
    behind when rewriting one.

    `occurrence` selects among genuine repeats -- _has_contexts is probed twice, in the
    pre-flight and in step 6, and both must avoid to_regclass.
    """
    body = "\n".join(
        line for line in SCRIPT.read_text().splitlines()
        if not line.lstrip().startswith("#")
    )
    assert body.count(marker) > occurrence, (
        f"{marker!r} not found {occurrence + 1}x in the executable lines of {SCRIPT.name}"
    )
    after = body.split(marker)[occurrence + 1]
    sql = after.split('-c "', 1)[1].split('")', 1)[0]
    return " ".join(sql.split())


EXPECTED_HAS_CONTEXTS = (
    "SELECT EXISTS (SELECT 1 FROM pg_class c "
    "JOIN pg_namespace n ON n.oid = c.relnamespace "
    "WHERE n.nspname = 'hafd' AND c.relname = 'contexts')"
)

# Guard 2 must require MEMBERSHIP OF hive_applications_group before believing what it
# reads. Without that arm, `NOT EXISTS (row)` cannot distinguish "the context is gone"
# from "the context is invisible to me under RLS" -- it reads the row through the very
# policy in question -- and a role holding SELECT on hafd but outside the group passed
# vacuously, then dropped every schema while step 6 printed success.
EXPECTED_CAN_REMOVE = (
    "SELECT current_setting('is_superuser') = 'on' "
    "OR (to_regrole('hive_applications_group') IS NOT NULL "
    "AND pg_has_role(current_user, 'hive_applications_group', 'USAGE') "
    "AND (NOT EXISTS (SELECT 1 FROM hafd.contexts WHERE name = '${HAF_STATS_CONTEXT}') "
    "OR EXISTS (SELECT 1 FROM hafd.contexts "
    "WHERE name = '${HAF_STATS_CONTEXT}' "
    "AND hive.can_impersonate(current_user, owner))))"
)

# CREATEROLE is NOT what step 5 needs. Verified on postgres:14 and :17 as a
# non-superuser CREATEROLE role that is not a member of the target:
#   DROP OWNED BY  -> "Only roles with privileges of role X may drop objects owned by it"
#   DROP ROLE      -> "Only roles with the CREATEROLE attribute and the ADMIN option"
# The second is the PG16+ rule, and HAF's Dockerfile pins POSTGRES_VERSION=17, so it is
# live. USAGE is has_privs_of_role (what DROP OWNED BY checks); MEMBER WITH ADMIN OPTION
# is what DROP ROLE checks.
EXPECTED_CAN_DROP_ROLES = (
    "SELECT current_setting('is_superuser') = 'on' "
    "OR (COALESCE((SELECT rolcreaterole FROM pg_roles WHERE rolname = current_user), false) "
    "AND NOT EXISTS ( "
    "SELECT 1 FROM pg_roles r "
    "WHERE r.rolname IN ('haf_stats_user', 'haf_stats_owner') "
    "AND NOT (pg_has_role(current_user, r.oid, 'USAGE') "
    "AND pg_has_role(current_user, r.oid, 'MEMBER WITH ADMIN OPTION'))))"
)


EXPECTED_CRON_SURVIVORS = (
    "SELECT string_agg('cron job ' || jobname, ', ' ORDER BY jobname) "
    r"FROM cron.job WHERE jobname LIKE 'haf_stats\\_%'"
)


def test_the_impersonation_probe_is_exactly_the_policys_question():
    """hafd.contexts' DELETE policy is USING (hive.can_impersonate(current_user, owner)).
    Anything else -- an extra OR, a different column, a role literal -- is a different
    question, and the stub cannot tell the difference."""
    assert _probe_sql('_can_remove="$(psql_cmd') == EXPECTED_CAN_REMOVE


def test_the_drop_roles_probe_is_exactly_what_step_5_needs():
    """DROP ROLE needs CREATEROLE or superuser. COALESCE(..., false) matters: a
    current_user with no pg_roles row must be a refusal, not NULL."""
    assert _probe_sql('_can_drop_roles="$(psql_cmd') == EXPECTED_CAN_DROP_ROLES


# --- --schema must have NO EFFECT on the teardown (round three) ---------------------

@pytest.mark.parametrize(
    "value", ["btracker_app", "haf_stats_backend", "haf_stats", "public"],
    ids=["foreign", "our-other-schema", "the-context-name", "public"])
def test_the_teardown_emits_identical_sql_with_and_without_schema(bash, tmp_path, value):
    """The worst case this flag could cause, and the one the tests did not exclude.

    A mutant that assigns HAF_STATS_SCHEMAS or HAF_STATS_CONTEXT from --schema prints
    the exact "is ignored" warning the acceptance tests assert on, then emits
    `DROP SCHEMA IF EXISTS public CASCADE` or removes ANOTHER HAF APP'S CONTEXT, with
    the whole suite green. Comparing the emitted SQL is the only assertion that
    excludes it.
    """
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir()
    b.mkdir()
    base = make_psql(a)
    run(bash, a, "--force")
    flag = make_psql(b)
    run(bash, b, "--force", f"--schema={value}")
    # The baseline must actually contain the teardown, or this is "" == "" and
    # passes on a script that does nothing. Demonstrated: inserting `exit 0`
    # before wait_for_postgres left all four parametrisations green, in both
    # repos, on the one test whose docstring calls itself "the only assertion
    # that excludes" the retargeting mutant.
    assert "DROP SCHEMA" in sql_of(base), "the baseline run emitted no teardown SQL"
    assert "app_remove_context" in sql_of(base)
    assert sql_of(flag) == sql_of(base), f"--schema={value} changed the teardown's SQL"


def test_the_refusal_is_logged_as_an_ERROR(bash, tmp_path):
    """Operators and log scrapers key on the severity token; nothing pinned it, so it
    was free to drift to `note:` while the exit code stayed 1."""
    _guarded_psql(tmp_path, can_impersonate="f")
    r = run(bash, tmp_path, "--force")
    assert "ERROR:" in r.stdout


# --- survivors from the round-two mutation pass (round three) -----------------------

def test_the_lock_timeout_shares_a_session_with_the_ddl(bash, tmp_path):
    """SET lock_timeout is SESSION-LOCAL.

    Issued in a separate psql invocation it has no effect on the DROP that follows --
    the indefinite block it exists to prevent, restored, with the literal
    `SET lock_timeout = '30s';` still in the log for the other two tests to find.
    Presence is not the property; co-location in the same -c batch is.
    """
    log = make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    blocks = [b for b in sql_of(log).split("---") if "DROP SCHEMA" in b or "DROP ROLE" in b]
    assert blocks, "no destructive statement was issued"
    for block in blocks:
        assert "SET lock_timeout = '30s';" in block, (
            "a destructive statement ran in a session without the lock timeout"
        )


def test_a_failing_context_probe_does_not_report_a_clean_teardown(bash, tmp_path):
    """Precisely the failure the surrounding comment describes.

    The sibling test fails psql on *to_regclass*, which now trips the EARLIER
    _has_contexts probe and short-circuits before this line is reached -- so the
    surviving-context probe's own `|| _probe_failed=1` was left unpinned. This one
    answers to_regclass normally and errors only on the survivor query.
    """
    make_psql(tmp_path, fail_on="hafd.contexts AS c")
    r = run(bash, tmp_path, "--force")
    assert r.returncode != 0
    assert "haf_stats removed" not in r.stdout
    assert "could not verify" in r.stdout


def test_the_session_probe_asks_for_a_bare_value(bash, tmp_path):
    """Without -Atq real psql returns a header, a rule and `(1 row)`. The fail-closed
    branch then refuses EVERY teardown permanently with "unexpected session count" --
    not a fail-open, but an unrunnable script."""
    make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    argv = (tmp_path / "argv.log").read_text()
    sessions = [ln for ln in argv.split("\n") if "pg_stat_activity" in ln]
    assert sessions, "the session guard never ran"
    for line in sessions:
        assert "-Atq" in line, f"the session count must be a bare value: {line}"


def test_the_confirmation_variable_names_every_role_the_script_drops():
    """HAF_STATS_ROLES feeds the confirmation banner and the "Dropping roles ..." line,
    while step 5's DO block names both roles as literals. Drop one from the variable and
    the operator consents to less than the script actually does -- with every test
    green, because the behaviour does not change, only what the operator is told.

    Asserted on the SOURCE rather than by running the script: the banner is inside the
    `[ ! -t 0 ]` interactive branch, which this module's docstring records as uncovered
    (nothing here opens a pty, and a pty case is POSIX-only).
    """
    body = SCRIPT.read_text()
    declared = set(body.split('HAF_STATS_ROLES="', 1)[1].split('"', 1)[0].split())
    dropped = set(re.findall(r"DROP ROLE (\w+);", body))
    assert dropped, "no DROP ROLE statements found; the parser needs updating"
    assert dropped <= declared, (
        f"dropped but not named in HAF_STATS_ROLES: {sorted(dropped - declared)}"
    )


# --- the guards, corrected in round four ------------------------------------------

def test_the_haf_detection_probe_needs_no_usage_on_hafd():
    """to_regclass RESOLVES THE SCHEMA and raises `permission denied for schema hafd`
    for any caller without USAGE on it -- aclcheck_error fires even under missing_ok.
    Reproduced on postgres:14 and postgres:17. The script then announced "this is not a
    HAF instance" about a database that plainly is one. This is the same trap step 6
    already documents for `cron`; it was left in the pre-flight until round four."""
    assert _probe_sql('_has_contexts="$(psql_cmd') == EXPECTED_HAS_CONTEXTS
    # Scoped to the two _has_contexts PROBES, not the whole file. Step 3's DO block
    # legitimately uses to_regclass to skip context removal on a non-HAF database:
    # by then guard 2 has established membership of hive_applications_group, which
    # holds SELECT on hafd tables and therefore USAGE on the schema. The probes run
    # BEFORE that is known, which is exactly why they may not use it.
    for occurrence in range(2):
        probe = _probe_sql('_has_contexts="$(psql_cmd', occurrence=occurrence)
        assert "to_regclass" not in probe, (
            "_has_contexts probe %d resolves hafd.contexts by name; it raises "
            "rather than returning NULL without USAGE on the schema" % occurrence
        )


def test_refuses_a_role_outside_hive_applications_group(bash, tmp_path):
    """The RLS-invisible hole. A role with SELECT on hafd but outside
    hive_applications_group sees zero context rows, so an `OR NOT EXISTS(row)` arm
    passed it vacuously; hive.app_context_exists() then read through the same filter and
    reported nothing to remove, all three schemas were dropped, and step 6 -- same filter
    again -- printed success while the context survived. db/builtin_roles.sql creates
    exactly such a role."""
    # Not a member of hive_applications_group, but otherwise able to impersonate:
    # the RLS-invisible case. With can_impersonate="f" alone this passed against
    # the vacuous round-three guard too.
    log = _guarded_psql(tmp_path, group_member="f", can_impersonate="t")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "DROP SCHEMA" not in sql_of(log)
    assert "app_remove_context" not in sql_of(log)


def test_refuses_createrole_without_the_admin_option(bash, tmp_path):
    """The guard added in round two to prevent a partial teardown CAUSED one.

    It tested rolcreaterole alone, which answers TRUE for a CREATEROLE role that is not
    a member of haf_stats_user/haf_stats_owner -- and that role then removed the context, dropped
    every schema CASCADE, and failed on step 5's FIRST statement. Verified on
    postgres:14 and :17: DROP OWNED BY needs the privileges of the target role, and
    PG16+ DROP ROLE needs CREATEROLE *and* the ADMIN option.
    """
    # createrole TRUE, admin option FALSE -- the case round three waved through.
    # With createrole="f" alone this passed against the BROKEN guard too, since
    # both predicates mention rolcreaterole.
    log = _guarded_psql(tmp_path, createrole="t", admin_option="f")
    r = run(bash, tmp_path, "--force")
    assert r.returncode == 1
    assert "DROP SCHEMA" not in sql_of(log)
    assert "DROP OWNED BY" not in sql_of(log)


def test_a_refusal_never_falls_back_to_the_requested_target():
    """`(connected to ${_reached:-${POSTGRES_HOST}...})` is unreachable today -- the
    fail-closed refusal means _reached is non-empty by the time any guard refuses -- so no
    behavioural test can see it. Pinned at source instead, because a refusal naming the
    host that was TYPED rather than the one that ANSWERED is the whole of #75, and
    defence-in-depth that quietly turns back into the bug is worse than none."""
    whole = SCRIPT.read_text(encoding="utf-8")
    start = whole.index("_report_connected_identity() {")
    fn = whole[start:whole.index("\n}", start)]
    live = "\n".join(l.split("#", 1)[0] for l in fn.splitlines())
    for requested in ("POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_DB", "POSTGRES_USER"):
        assert requested not in live, (
            "a refusal would name the REQUESTED target, not the one that answered: " + fn)


def test_the_confirmation_asks_the_server_which_database_this_is():
    """The interactive branch cannot be driven without a pty, and the module says so --
    but every other unrunnable probe here still gets a SOURCE pin, and this one had
    neither. Restoring `!= "${POSTGRES_DB}"` reinstates precisely the defect this MR's
    own comment says it fixed, and nothing objected."""
    body = SCRIPT.read_text(encoding="utf-8")
    line = body[body.index('_target_db="$(psql_cmd'):].splitlines()[0]
    # First closing quote, not _probe_sql: this call is followed by `| tr ... || true`,
    # a shape _probe_sql does not parse -- it ran to the last quote in the file.
    assert line.split('-c "', 1)[1].split('"', 1)[0] == "SELECT current_database()", line


def test_the_confirmation_probe_tests_its_own_status():
    """Same treatment as the identity query, for the same reason. `|| true` there
    discarded psql's exit code, so a failed query reached the operator as "Aborted --
    nothing was changed" -- their typed name not matching noise -- rather than as "could
    not ask the server", which is a different fault pointing somewhere else. Behavioural
    coverage would need a pty, so this is pinned at source, comments stripped."""
    live = "\n".join(l.split("#", 1)[0]
                     for l in SCRIPT.read_text(encoding="utf-8").splitlines())
    start = live.index("_target_db=")
    stanza = live[live.rindex("\n", 0, start):start + 400]
    assert 'if ! _target_db="$(psql_cmd' in stanza, (
        "the confirmation probe no longer tests whether psql succeeded:\n" + stanza)
    # NO CONNECTION FLAGS of its own. psql takes the last -h/-p/-d, so
    # `psql_cmd -Atq -h 127.0.0.1 -c "SELECT current_database()"` asks a DIFFERENT server
    # which database this is, and the typed-name gate -- this MR's headline improvement --
    # then compares the operator's answer against a database on another host. The
    # interactive branch has no behavioural test, so nothing else can see it.
    flags = stanza.split("psql_cmd", 1)[1].split("-c", 1)[0]
    for flag in ("-h", "-p", "-U", "-d", "-X"):
        assert flag not in flags.split(), (
            "the confirmation probe overrides its own connection or repeats psql_cmd's "
            "flags; it must inherit them: " + stanza)


def test_the_confirmation_compares_against_the_servers_answer():
    """Comments stripped, so a commented-out copy of the old comparison cannot satisfy
    this -- the failure mode _probe_sql's own docstring describes."""
    live = [l.split("#", 1)[0] for l in SCRIPT.read_text(encoding="utf-8").splitlines()]
    body = "\n".join(live)
    assert '[ "${_reply}" != "${_target_db}" ]' in body, (
        "the typed-name gate no longer compares against what the server answered")
    assert '[ "${_reply}" != "${POSTGRES_DB}" ]' not in body


def test_a_refusal_names_the_role_the_database_actually_sees(bash, tmp_path):
    """Every refusal used to interpolate ${POSTGRES_USER} -- what was REQUESTED --
    while the probes correctly ask about current_user. The two differ whenever a
    PGUSER/PGSERVICE/.pgpass in the environment redirects the connection, and a refusal
    naming the wrong role sends the operator to change the wrong thing."""
    _guarded_psql(tmp_path, createrole="f")
    r = run(bash, tmp_path, "--force")
    # Now also names the SERVER (#75). ${POSTGRES_HOST} is what was requested; this line
    # is what answered.
    assert "connected to 10.1.1.7:5432/somedb as someone" in r.stdout
    # ...and the cluster id, which is the part that survives a socket connection.
    assert "[cluster 7391424]" in r.stdout, r.stdout
    # RESOLVED ONCE. The script says so, and only a SUCCESSFUL run pinned it -- but
    # _report_connected_identity runs only on a REFUSAL, so a second, flagless query here
    # passed the whole module. That second call reaches the local server while the
    # teardown targets the remote one: #75, inside the refusal meant to explain it.
    identity = [l for l in (tmp_path / "argv.log").read_text(encoding="utf-8").splitlines()
                if "inet_server_addr" in l]
    assert len(identity) == 1, (
        "the identity query ran %d times on a refusal path; it is resolved once into "
        "_reached and reused:\n%s" % (len(identity), "\n".join(identity)))
    # The inventory belongs BELOW the guards: this run destroyed nothing, so the phrase
    # an operator greps for must not appear. Moving the block back above the guards --
    # undoing half of what this MR does -- otherwise passes the whole module.
    assert "PERMANENTLY" not in r.stdout, r.stdout


def test_the_cron_survivor_probe_looks_for_this_apps_jobs():
    """Pinned WHOLE, because the stub cannot see the predicate.

    make_psql's *cron.job* arm answers with the canned cron_left whatever the query
    asks, so repointing the LIKE prefix at another app -- the realistic port error for a
    file whose header calls itself a port of hive/haf_fyp's equivalent -- left the full
    suite green while four surviving haf_stats_* jobs went unreported and the script
    exited 0 saying "haf_stats removed".
    """
    assert _probe_sql('_cron_left="$(psql_cmd') == EXPECTED_CRON_SURVIVORS
    # And the prefix really is this app's, not merely SOME prefix.
    assert "haf_stats" in EXPECTED_CRON_SURVIVORS
    assert "haf_fyp" not in _probe_sql('_cron_left="$(psql_cmd')


# --- naming the server that answered, not the one we asked for (#75) ---------------
#
# The premise was REPRODUCED before these were written, against two live PostgreSQL
# servers: `PGHOSTADDR=<B> psql -h <A>` connected to B -- B's inet_server_addr(), B's
# tables, A's tables absent -- while every message this script prints said A. libpq uses
# `hostaddr` for the connection and `host` only for authentication and TLS, and -h sets
# `host`. No flag was wrong in that run, which is why flag validation cannot close it.


def test_the_banner_names_the_server_that_answered(bash, tmp_path):
    _guarded_psql(tmp_path)
    r = run(bash, tmp_path, "--force")
    assert "requested: haf:5432/haf_block_log" in r.stdout, r.stdout
    assert "reached  : 10.1.1.7:5432/somedb as someone" in r.stdout, r.stdout


def test_force_still_leaves_a_record_of_what_it_destroyed_and_where(bash, tmp_path):
    """--force skips the PROMPT, not the account. docker-compose.yml ships --force, so
    the unattended path was the one running with no record at all."""
    _guarded_psql(tmp_path)
    r = run(bash, tmp_path, "--force")
    # The `server   :` line specifically, and that it carries what the SERVER said.
    # `requested:`/`reached  :` come from section 0, which prints on every path including
    # pure refusals -- so listing only those satisfied the "and where" half of this
    # test's own name with output the banner does not produce, and the banner's line
    # could be re-pointed at ${POSTGRES_HOST} or deleted outright with nothing red.
    reached = [l.split("reached  : ", 1)[1] for l in r.stdout.splitlines()
               if "reached  : " in l]
    server = [l.split("server   : ", 1)[1] for l in r.stdout.splitlines()
              if "server   : " in l]
    assert len(reached) == 1 and len(server) == 1, (reached, server)
    assert server[0] == reached[0], (
        "the line printed immediately before DROP SCHEMA names something other than the "
        "server that answered: %r vs %r" % (server[0], reached[0]))

    for expected in ("About to PERMANENTLY remove haf_stats:",
                     "requested:", "reached  :", "server   :",
                     "context  : haf_stats",
                     "schemas  : haf_stats_app haf_stats_backend haf_stats_endpoints",
                     "roles    : haf_stats_user haf_stats_owner"):
        assert expected in r.stdout, (expected, r.stdout)


def test_pghostaddr_is_called_out_by_name(bash, tmp_path):
    """The one vector that needs explaining: nothing in the repo mentions PGHOSTADDR, and
    an operator reading `requested: haf:5432` has no reason to suspect it."""
    # The stub is NOT told the answer: it derives it from PGHOSTADDR the way libpq does,
    # so this asserts retargeting rather than two constants the author made match. An
    # earlier version passed even with the variable removed from the environment.
    _guarded_psql(tmp_path, server="10.1.1.7:5432/somedb as someone [cluster 1234]")
    r = run(bash, tmp_path, "--force", env_extra={"PGHOSTADDR": "10.9.9.9"})
    assert "reached  : 10.9.9.9:5432/somedb as someone" in r.stdout, r.stdout
    assert "10.1.1.7" not in r.stdout, "the -h value was reported instead of the hostaddr"
    # One variable per line now. Asserted with the label, so a value printed loose
    # somewhere else in the output cannot satisfy it.
    assert "NOTE     : PGHOSTADDR=10.9.9.9" in r.stdout, r.stdout
    assert "Any of PGHOSTADDR, PGSERVICE or PGSERVICEFILE" in r.stdout, r.stdout


def test_every_psql_invocation_runs_on_the_connection_being_torn_down(bash, tmp_path):
    """Not just the identity query -- EVERY call, including the ones that destroy.

    The test below explains why a bare `psql` inside _server_identity matters: it drops
    -h/-p/-U/-d, so the banner describes the LOCAL server while the teardown destroys the
    remote one. Mutation testing found that exact escape unguarded one function over, on
    `_psql_destructive` itself, and on the session guard and the verification file --
    #75's own failure mode, on the statements that actually drop schemas, reachable on
    the `--force` path production uses.

    Counting rather than membership, because psql takes the LAST -h/-p/-d: a second one
    retargets the call while every flag a membership test looks for is still present.
    """
    make_psql(tmp_path)
    run(bash, tmp_path, "--force", "--host=elsewhere", "--port=6543", "--user=someadmin")
    lines = [l for l in (tmp_path / "argv.log").read_text(encoding="utf-8").splitlines()
             if l.strip()]
    assert len(lines) > 5, lines
    for line in lines:
        argv = line.split(" -c ", 1)[0].split(" -f ", 1)[0].split()
        for flag, value in (("-h", "elsewhere"), ("-p", "6543"), ("-U", "someadmin"),
                            ("-d", "haf_block_log")):
            assert argv.count(flag) == 1, (
                "%s appears %d times, so a later one wins and this call runs somewhere "
                "other than the target being destroyed: %s" % (flag, argv.count(flag), line))
            assert argv[argv.index(flag) + 1] == value, (flag, value, line)
        # psql_cmd carries -X for every caller: these scripts parse psql's stdout, and an
        # interactive ~/.psqlrc writes to it.
        assert "-X" in argv, ("this call can be polluted by ~/.psqlrc: " + line)


def test_the_identity_query_runs_on_the_connection_being_torn_down(bash, tmp_path):
    """Swapping psql_cmd for a bare psql inside _server_identity drops -h/-p/-U/-d, so the
    banner would describe the LOCAL server while the teardown destroys the remote one --
    #75's own failure mode, arriving through the fix for #75. Mutation testing showed the
    suite could not see it: the stub is on PATH and ignores every flag."""
    make_psql(tmp_path)
    run(bash, tmp_path, "--force", "--host=elsewhere", "--port=6543", "--user=someadmin")
    identity = [l for l in (tmp_path / "argv.log").read_text(encoding="utf-8").splitlines()
                if "inet_server_addr" in l]
    assert identity, "the identity query was never issued"

    # EXACTLY ONE. The script says the identity is "resolved ONCE and reused by every
    # later line", and nothing pinned that: a refusal path re-querying with a bare `psql`
    # -- the same escape as below, one function over -- was invisible, because this test
    # took identity[0] and that first call is still the properly-flagged one.
    assert len(identity) == 1, (
        "the identity query ran %d times; it is supposed to be resolved once into "
        "_reached and reused:\n%s" % (len(identity), "\n".join(identity)))
    line = identity[0]

    # PRESENCE IS NOT ENOUGH. psql takes the LAST -h/-p/-d, so appending `-h 127.0.0.1`
    # or `-d postgres` inside _server_identity leaves all of these present while the
    # identity describes a different server than the one being torn down -- #75 arriving
    # through the fix for #75. Count them.
    # Tokenised, because the line BEGINS with -h and a " -h " substring search misses it.
    # Only the flags, not the SQL: the statement itself contains words like -- comments.
    argv = line.split(" -c ", 1)[0].split()
    for flag, value in (("-h", "elsewhere"), ("-p", "6543"), ("-U", "someadmin"),
                        ("-d", "haf_block_log")):
        assert argv.count(flag) == 1, (
            "%s appears %d times; psql takes the LAST one, so a later one retargets the "
            "query while every flag is still 'present': %s" % (flag, argv.count(flag), line))
        assert argv[argv.index(flag) + 1] == value, (flag, value, line)
    assert "-Atq" in argv, line


@pytest.mark.parametrize("env_extra, expected", [
    ({"PGHOSTADDR": "10.9.9.9"}, ["PGHOSTADDR=10.9.9.9"]),
    ({"PGSERVICE": "decoy"}, ["PGSERVICE=decoy"]),
    ({"PGSERVICE": "decoy", "PGSERVICEFILE": "/tmp/decoy.conf"},
     ["PGSERVICE=decoy", "PGSERVICEFILE=/tmp/decoy.conf"]),
])
def test_every_redirect_channel_is_called_out_by_name(bash, tmp_path, env_extra, expected):
    """Commit two is titled "cover every hostaddr channel" and only PGHOSTADDR had a
    test: deleting the PGSERVICE and PGSERVICEFILE arms left all 62 green. The service
    file is the vector the script singles out as the dangerous one, because it leaves no
    environment variable behind."""
    _guarded_psql(tmp_path)
    r = run(bash, tmp_path, "--force", env_extra=env_extra)
    for token in expected:
        assert "NOTE     : %s" % token in r.stdout, (token, r.stdout)


def test_a_service_file_without_a_service_name_is_not_called_out(bash, tmp_path):
    """libpq reads a service file only when a service NAME is given -- PGSERVICE, or
    `service=` in a conninfo. PGSERVICEFILE alone redirects nothing, so warning about it
    during a destructive run points the operator at a variable that is inert."""
    _guarded_psql(tmp_path)
    r = run(bash, tmp_path, "--force", env_extra={"PGSERVICEFILE": "/tmp/decoy.conf"})
    assert "PGSERVICEFILE" not in r.stdout, r.stdout
    assert "NOTE" not in r.stdout, r.stdout


def test_a_redirect_is_still_named_when_the_identity_query_fails(bash, tmp_path):
    """The two paths never crossed: the fail-closed test sets no redirect variable, and
    the redirect tests always have a working query. Ordering the refusal above the NOTE
    suppresses the single most useful diagnostic exactly when it is needed -- an operator
    whose PGHOSTADDR broke the connection would get a bare refusal."""
    _guarded_psql(tmp_path, fail_on="inet_server_addr")
    r = run(bash, tmp_path, "--force", env_extra={"PGHOSTADDR": "10.9.9.9"})
    assert "NOTE     : PGHOSTADDR=10.9.9.9" in r.stdout, r.stdout
    assert "refusing to continue" in r.stdout, r.stdout
    assert r.returncode == 1, r.returncode


def test_the_note_is_absent_when_nothing_redirects_the_connection(bash, tmp_path):
    """Negative control. Without it, `if [ -n "${PGHOSTADDR:-}" ]` becoming `if true`
    would print a redirect NOTE on every run on every node, unfalsifiably."""
    _guarded_psql(tmp_path)
    r = run(bash, tmp_path, "--force")
    assert "NOTE" not in r.stdout, r.stdout
    assert "PGHOSTADDR" not in r.stdout, r.stdout


def test_a_local_socket_is_reported_as_such(bash, tmp_path):
    """inet_server_addr() is NULL over a Unix socket, which is exactly the case
    --host=/var/run/postgresql lands on -- a legal host value that the flag guard added
    by !81 cannot distinguish from a network host."""
    _guarded_psql(tmp_path, server="LOCAL SOCKET:-/somedb as someone [cluster 7391424]")
    r = run(bash, tmp_path, "--force")
    assert "reached  : LOCAL SOCKET" in r.stdout, r.stdout
    # THE POINT of the socket case: the address is NULL, so the cluster id is the only
    # thing distinguishing two clusters on one box -- which is where #67's empty-host
    # failure lands. Nothing asserted the word "cluster" anywhere before this.
    assert "[cluster 7391424]" in r.stdout, r.stdout
    # And the line saying what LOCAL SOCKET does and does not mean.
    assert "is the SERVER's end of the connection" in r.stdout, r.stdout


def test_a_server_that_cannot_be_asked_refuses_rather_than_guessing(bash, tmp_path):
    """Silence here would read as agreement with the `requested` line, and --force would
    then destroy on nothing but the host that was typed.

    fail_on, not server="": every operand of the identity expression is non-NULL by
    construction, so a successful psql cannot return an empty row. The branch's real
    trigger is psql FAILING -- an earlier version of this test modelled a state the query
    cannot produce.

    exit 1: in this file 2 means "invoked wrong" and 1 means "refused, or a probe could
    not answer". This is the latter.
    """
    _guarded_psql(tmp_path, fail_on="inet_server_addr")
    r = run(bash, tmp_path, "--force")
    assert "COULD NOT ASK THE SERVER" in r.stdout, r.stdout
    assert "refusing to continue" in r.stdout, r.stdout
    assert r.returncode == 1, r.returncode
    # And nothing was dropped.
    assert "DROP SCHEMA" not in sql_of(tmp_path / "sql.log")


def test_a_failed_query_that_still_printed_something_is_not_an_identity(bash, tmp_path):
    r"""THE negative control for the fail-closed branch, and the one that was missing.

    The test above uses a stub that writes to stderr and exits 3, so stdout is EMPTY --
    it proves `empty => refuse`, never `failed => refuse`. Those came apart in the real
    script: `psql_cmd ... | tr ... || true` discarded the status, so emptiness was the
    only signal, and a failing psql prints to stdout whenever anything already has. A
    ~/.psqlrc `\echo`, or `\timing`, does exactly that at connection time, and nothing in
    this repo passes --no-psqlrc. The refusal then did not fire and the `reached:` line --
    the only record --force leaves -- printed that noise as the server's identity.
    """
    make_psql(tmp_path)
    # A psql that greets on stdout and THEN fails the identity query.
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        'prev=""\n'
        'for a in "$@"; do\n'
        '  if [ "$prev" = "-c" ]; then cmd="$a"; fi\n'
        '  prev="$a"\n'
        "done\n"
        'printf "Welcome to psql\\n"\n'          # ~/.psqlrc, on EVERY invocation
        'case "$cmd" in\n'
        '  *inet_server_addr*) echo "psql: FATAL: permission denied" >&2; exit 3 ;;\n'
        '  *is_superuser*)     printf "t" ;;\n'
        '  *pg_stat_activity*) printf "0" ;;\n'
        "esac\n"
        "exit 0\n",
    )
    r = run(bash, tmp_path, "--force")
    assert "Welcome to psql" not in r.stdout.split("reached")[-1].split("\n")[0], (
        "the greeting was reported as the server's identity:\n" + r.stdout)
    assert "COULD NOT ASK THE SERVER" in r.stdout, r.stdout
    assert r.returncode == 1, r.returncode
    assert "DROP SCHEMA" not in sql_of(tmp_path / "sql.log")


# pg_namespace / pg_extension, NOT to_regclass / cron.job: the DECISION probes use the
# catalog joins (to_regclass RAISES rather than returning NULL without USAGE on the
# schema, which is why they were rewritten). to_regclass and cron.job survive only inside
# the destructive DO blocks, where an error is tolerated by design -- so failing on those
# token names would test the error tolerance, not the guards.
@pytest.mark.parametrize("probe", [
    "is_superuser",      # pre-flight: can this role impersonate at all
    "pg_stat_activity",  # guard 1: is anything still connected
    "can_impersonate",   # guard 2: may it remove the context
    "rolcreaterole",     # guard 3: may it drop the roles
    "pg_namespace",      # is this a HAF database
])
def test_a_gate_that_cannot_answer_drops_nothing(bash, tmp_path, probe):
    """Five probes decide whether the teardown may START, and only two of their failure
    paths were exercised -- so the others could be turned fail-OPEN with the module green.
    A catalog error becoming "not a HAF database" skips the context-owner guard entirely.
    Whatever the refusal says, nothing may be dropped."""
    _guarded_psql(tmp_path, fail_on=probe)
    r = run(bash, tmp_path, "--force")
    assert r.returncode != 0, r.stdout
    assert "DROP SCHEMA" not in sql_of(tmp_path / "sql.log"), r.stdout
    assert "DROP ROLE" not in sql_of(tmp_path / "sql.log"), r.stdout


def test_a_verification_probe_that_cannot_answer_does_not_claim_success(bash, tmp_path):
    """The cron-survivor probe runs at step 6, AFTER the teardown -- it decides whether
    the run may claim success, not whether it may start, so "drops nothing" is the wrong
    property for it. The right one: a run whose verification could not answer must not
    report `haf_stats removed`, because an operator reading that stops looking."""
    _guarded_psql(tmp_path, fail_on="pg_extension")
    r = run(bash, tmp_path, "--force")
    assert r.returncode != 0, r.stdout
    assert "haf_stats removed" not in r.stdout, r.stdout


def test_a_well_formed_answer_from_a_FAILED_query_is_not_an_identity(bash, tmp_path):
    """The one input that separates the status check from the shape check.

    Every other failing stub in this file emits nothing, or something badly shaped, so the
    SHAPE test rejects all of them on its own -- and removing the status test survived the
    entire module while leaving the script destroying on a query that failed. psql exiting
    non-zero after printing a perfectly good row is not exotic: the connection can drop
    after the row is sent, and `-v ON_ERROR_STOP=on` turns a later notice into a failure.
    A well-formed string from a failed query is not an answer.
    """
    make_psql(tmp_path)
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        'prev=""\n'
        'for a in "$@"; do\n'
        '  if [ "$prev" = "-c" ]; then cmd="$a"; fi\n'
        '  prev="$a"\n'
        "done\n"
        'case "$cmd" in\n'
        # A textbook identity -- and a non-zero exit.
        '  *inet_server_addr*) printf "10.1.1.7:5432/somedb as someone [cluster 1234]"\n'
        '                      exit 3 ;;\n'
        '  *is_superuser*)     printf "t" ;;\n'
        '  *pg_stat_activity*) printf "0" ;;\n'
        "esac\n"
        "exit 0\n",
    )
    r = run(bash, tmp_path, "--force")
    assert "COULD NOT ASK THE SERVER" in r.stdout, r.stdout
    assert "10.1.1.7" not in r.stdout, (
        "a string from a FAILED query was reported as the server's identity:\n" + r.stdout)
    assert r.returncode == 1, r.returncode
    assert "DROP SCHEMA" not in sql_of(tmp_path / "sql.log")


def test_noise_BEFORE_the_answer_is_not_an_identity(bash, tmp_path):
    """The shape check requires the answer to END in the cluster id, so it rejects
    appended junk and ACCEPTS prepended junk -- and ~/.psqlrc produces prepended junk,
    because `\\echo` writes at connection time. Measured on the real check:

        "Timing is on. LOCAL SOCKET:-/haf_block_log as haf_admin [cluster 764]"

    passed, reached the `reached:` and `server:` lines, and silently suppressed the LOCAL
    SOCKET note, whose `case` is anchored at the START of the string. The script now
    passes -X so psqlrc cannot speak at all, and rejects any answer of more than one line.
    """
    make_psql(tmp_path)
    # A bespoke stub, because make_psql answers with `printf "%s" '<server>'` and printf
    # interprets escapes in the FORMAT, not in an argument -- a "\n" in the server string
    # stays two literal characters, so the answer would still be one line.
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        'prev=""\n'
        'for a in "$@"; do\n'
        '  if [ "$prev" = "-c" ]; then cmd="$a"; fi\n'
        '  prev="$a"\n'
        "done\n"
        'case "$cmd" in\n'
        '  *inet_server_addr*)\n'
        '      printf "Timing is on.\\n10.1.1.7:5432/somedb as x [cluster 1234]\\n" ;;\n'
        '  *is_superuser*)     printf "t" ;;\n'
        '  *pg_stat_activity*) printf "0" ;;\n'
        "esac\n"
        "exit 0\n",
    )
    r = run(bash, tmp_path, "--force")
    assert "COULD NOT ASK THE SERVER" in r.stdout, r.stdout
    assert "Timing is on." not in r.stdout, r.stdout
    assert r.returncode == 1, r.returncode
    assert "DROP SCHEMA" not in sql_of(tmp_path / "sql.log")


def test_the_identity_query_does_not_read_the_operators_psqlrc(bash, tmp_path):
    """-X is what removes the whole noise class at source. Without it an operator's own
    dotfile decides part of the text naming what is about to be destroyed."""
    make_psql(tmp_path)
    run(bash, tmp_path, "--force")
    identity = [l for l in (tmp_path / "argv.log").read_text(encoding="utf-8").splitlines()
                if "inet_server_addr" in l]
    assert identity, "the identity query was never issued"
    assert "-X" in identity[0].split(" -c ", 1)[0].split(), identity[0]


def test_a_service_file_path_with_spaces_is_named_once(bash, tmp_path):
    """PGSERVICEFILE is a PATH. An unquoted `for` split it on spaces, so a file under
    /etc/my conf/ printed as two NOTE lines naming two files that do not exist -- in the
    line whose entire job is telling the operator which file to go and read."""
    _guarded_psql(tmp_path)
    r = run(bash, tmp_path, "--force",
            env_extra={"PGSERVICE": "decoy", "PGSERVICEFILE": "/etc/my conf/pg_service.conf"})
    assert "NOTE     : PGSERVICEFILE=/etc/my conf/pg_service.conf" in r.stdout, r.stdout


def test_an_answer_without_a_cluster_id_is_not_an_identity(bash, tmp_path):
    """Belt and braces for the same failure on a SUCCESSFUL query: stdout noise ahead of
    a working identity corrupts the line just as badly, and the status says nothing. The
    query always appends `[cluster <n>]`, so anything not ending that way is not one."""
    _guarded_psql(tmp_path, server="Timing is on.")
    r = run(bash, tmp_path, "--force")
    assert "COULD NOT ASK THE SERVER" in r.stdout, r.stdout
    assert r.returncode == 1, r.returncode
    assert "DROP SCHEMA" not in sql_of(tmp_path / "sql.log")
