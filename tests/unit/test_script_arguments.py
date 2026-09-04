"""Option handling in scripts/install_app.sh and scripts/uninstall_app.sh (#57).

Two kinds of path are covered. The ones that exit at the option loop -- `--help` and
the rejections -- run the script as-is. The ones that must NOT exit there run it with a
stub `pg_isready` and `psql` on PATH, so the script gets past wait_for_postgres, logs
what is being asserted, and then dies at its first real statement.

The timeout is 10s, not 60: these all resolve in milliseconds, so when one regresses
the test should report a diff immediately rather than stall the job and report a
timeout error.

These are new failure modes and worth pinning. Both option loops previously had no
fallthrough case at all, so any argument they did not recognise was silently discarded
and the run carried on with defaults.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, stub_bin, write_exec

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
INSTALL = SCRIPTS / "install_app.sh"
UNINSTALL = SCRIPTS / "uninstall_app.sh"
PROCESS = SCRIPTS / "process_blocks.sh"

# 10s was too tight and flaked locally on four tests at once. The scripts themselves
# resolve in milliseconds; what is slow is the harness -- run_install_full_stub spawns
# the stub psql ~30 times, and on Windows each is a Git Bash process creation. The
# timeout is a HANG detector (a regression that lets an argument fall through reaches
# wait_for_postgres, an unbounded `until pg_isready`, and the orphaned sleep holds the
# pipe open so subprocess's own timeout does not reliably fire), so it only has to be
# short enough to report a diff instead of a job timeout. 30s does that with headroom
# on a loaded runner.
# 60s. The hang this detects is an UNBOUNDED `until pg_isready` loop, so any finite
# value catches it and the number only bounds how long a real hang costs. It has to
# clear the slowest legitimate case instead: the identical-SQL tests call
# run_install_full_stub TWICE, and each call spawns the stub psql ~30 times -- 60
# Git Bash process creations on Windows, which flaked at 30s once the suite grew.
# On the Linux CI runner the whole file is under 3s.
TIMEOUT = 60


@pytest.fixture
def bash():
    return require_bash()


def run(bash, tmp_path, script: Path, *args: str) -> subprocess.CompletedProcess:
    """Always with a stub pg_isready on PATH, even for paths expected to exit at the
    option loop.

    Without it, a regression that lets an argument fall through does not FAIL these
    tests, it HANGS them: the scripts then reach wait_for_postgres, an unbounded
    `until pg_isready; do sleep 2; done`, and the orphaned `sleep` holds the captured
    pipe open so subprocess's own timeout does not reliably fire. Mutation testing
    confirmed it -- deleting install_app.sh's unknown-option fallthrough, the very
    change these tests exist to pin, ran past 120s instead of failing. In CI that is a
    job that burns to the project timeout and reports "job timeout" rather than a diff.
    """
    return subprocess.run(
        [bash, str(script), *args],
        env=clean_env(stub_bin(tmp_path)),
        capture_output=True, text=True, timeout=TIMEOUT,
    )


# --- --help -----------------------------------------------------------------------

@pytest.mark.parametrize("script", [INSTALL, UNINSTALL], ids=["install", "uninstall"])
@pytest.mark.parametrize("flag", ["--help", "-h", "-?"])
def test_help_exits_zero(bash, tmp_path, script, flag):
    r = run(bash, tmp_path, script, flag)
    assert r.returncode == 0
    assert "OPTIONS:" in r.stdout


def test_install_help_lists_every_accepted_flag(bash, tmp_path):
    """Asserting on ONE early flag is not coverage.

    An earlier revision rendered help with a hardcoded `sed -n '2,12p'`, which silently
    truncates the moment the header grows a line -- and a test that only looked for
    --swagger-url survived both narrowing the range and collapsing it to a single line.
    Every flag the option loop accepts is named here, so the two cannot drift apart
    without this failing.
    """
    out = run(bash, tmp_path, INSTALL, "--help").stdout
    for flag in ("--swagger-url", "--host", "--port", "--user", "--is_forking", "--help"):
        assert flag in out, f"{flag} missing from install_app.sh --help"


def test_uninstall_help_lists_every_accepted_flag(bash, tmp_path):
    out = run(bash, tmp_path, UNINSTALL, "--help").stdout
    for flag in ("--force", "--host", "--port", "--user", "--help"):
        assert flag in out, f"{flag} missing from uninstall_app.sh --help"


def test_help_does_not_run_off_the_end_of_the_file(bash, tmp_path):
    """The marker pattern must not match its own implementation.

    Written literally, `sed -n '/--- help-start ---/,...'` matches the line containing
    that very pattern, re-opens the range there, and prints the entire rest of the
    script -- comments, SQL and all. The character class in help-sta[r]t is what
    prevents it, and the failure is silent apart from the flood of output.
    """
    out = run(bash, tmp_path, INSTALL, "--help").stdout
    assert "psql_cmd" not in out
    assert out.count("\n") < 20


# --- rejections -------------------------------------------------------------------

@pytest.mark.parametrize("script", [INSTALL, UNINSTALL], ids=["install", "uninstall"])
def test_an_unknown_option_is_rejected(bash, tmp_path, script):
    """The behaviour change. A mistyped --swagger-url used to install silently with the
    localhost default, baking wrong example URLs into the published Swagger page with
    nothing in the log to say so."""
    r = run(bash, tmp_path, script, "--swagger-ur=example.com")
    assert r.returncode == 2
    assert "is not a valid option" in r.stdout


def test_uninstall_rejects_a_mistyped_force(bash, tmp_path):
    """The specific typo that matters here: left to fall through, it would reach the
    confirmation prompt that a compose run cannot answer, and hang."""
    r = run(bash, tmp_path, UNINSTALL, "--forse")
    assert r.returncode == 2


@pytest.mark.parametrize(
    "script",
    [SCRIPTS / "install_app.sh", SCRIPTS / "uninstall_app.sh", SCRIPTS / "process_blocks.sh"],
    ids=["install", "uninstall", "process_blocks"],
)
def test_help_does_not_run_off_the_end_of_any_script(bash, tmp_path, script):
    """The marker pattern must not match its own implementation, in EVERY script.

    Written literally, `sed -n '/--- help-start ---/,...'` matches the line holding that
    very pattern, sed re-opens the range there, and prints the rest of the file. Only
    install_app.sh was pinned for this; removing the character class from the other two
    survived, and their --help then emitted 71 and 289 lines respectively -- including
    `CALL haf_stats_app.main(...)` and four `DROP SCHEMA` statements.
    """
    out = run(bash, tmp_path, script, "--help").stdout
    assert out.count("\n") < 25, f"--help ran past the marker: {out.count(chr(10))} lines"
    for leak in ("psql_cmd", "DROP SCHEMA", "CALL haf_stats_app"):
        assert leak not in out, f"--help leaked script body: {leak!r}"


@pytest.mark.parametrize(
    "script",
    [SCRIPTS / "install_app.sh", SCRIPTS / "uninstall_app.sh", SCRIPTS / "process_blocks.sh"],
    ids=["install", "uninstall", "process_blocks"],
)
def test_the_apps_own_schema_is_accepted(bash, tmp_path, script):
    """--schema=haf_stats_app is the ONE value the flag exists to support, and nothing
    asserted it was accepted -- only that a foreign one was refused. Re-targeting the
    accepted name survived every test while breaking the documented invocation."""
    r = run(bash, tmp_path, script, "--schema=haf_stats_app", "--help")
    assert r.returncode == 0, r.stdout + r.stderr
    # SILENTLY. `--help` exits 0 whether or not the warning fired, so asserting only
    # the exit code let the ACCEPTED NAME be changed -- to haf_stats (the CONTEXT) or
    # haf_stats_backend -- while every test stayed green. The one value the flag exists
    # to carry would then warn on every verb, telling the operator this app does not own
    # the schema it does own.
    assert "WARNING: --schema" not in r.stdout


@pytest.mark.parametrize(
    "script",
    [SCRIPTS / "install_app.sh", SCRIPTS / "uninstall_app.sh", SCRIPTS / "process_blocks.sh"],
    ids=["install", "uninstall", "process_blocks"],
)
def test_a_foreign_schema_warns_but_does_not_exit(bash, tmp_path, script):
    """It must NOT hard-fail. balance_tracker.yaml passes --schema= to process_blocks on
    a service that is `restart: on-failure`, so exiting here is a permanent crash-loop
    that blocks the whole stack -- over a flag this app cannot act on either way. An
    earlier revision exited 2, justified by a claim that restart: on-failure sat on the
    INSTALL service; it sits on block-processing, exactly where the failure landed."""
    out = run_with_stub_db(bash, tmp_path, script, "--schema=btracker_app")
    assert "WARNING: --schema" in out
    # The offending value is the one part an operator needs. Without this the message
    # can decay to "WARNING: --schema flag seen" and still pass.
    assert "btracker_app" in out
    # Got past the option loop rather than bailing out of it.
    assert "Waiting for PostgreSQL" in out


def run_with_stub_db(bash, tmp_path, script, *args) -> str:
    """Run a script with a pg_isready that says yes and a psql that fails, so it gets
    past the option loop and wait_for_postgres and then dies at its first statement."""
    bindir = stub_bin(tmp_path)
    write_exec(bindir / "psql", "#!/bin/sh\necho 'stub psql: refusing' >&2\nexit 1\n")
    proc = subprocess.run(
        [bash, str(script), *args], env=clean_env(bindir),
        capture_output=True, text=True, timeout=TIMEOUT,
    )
    return proc.stdout + proc.stderr


# --- --is_forking -----------------------------------------------------------------
#
# These paths do NOT exit at the option loop -- they continue into wait_for_postgres --
# so the database is stubbed out instead: a pg_isready that says yes and a psql that
# fails. The script then gets through the option loop and the connect, logs what we
# want to assert on, and dies at its first real statement.
#
# Killing a blocked run and reading its output is NOT an option: wait_for_postgres is
# `until pg_isready; do sleep 2; done`, and the orphaned sleep keeps the captured pipe
# open long after the parent is killed, so communicate() hangs for minutes.


def run_install_with_stub_db(bash, tmp_path, *args: str) -> str:
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    write_exec(bindir / "pg_isready", "#!/bin/sh\nexit 0\n")
    write_exec(bindir / "psql", "#!/bin/sh\necho 'stub psql: refusing' >&2\nexit 1\n")
    proc = subprocess.run(
        [bash, str(INSTALL), *args], env=clean_env(bindir),
        capture_output=True, text=True, timeout=TIMEOUT,
    )
    return proc.stdout + proc.stderr


def test_is_forking_true_warns_and_continues(bash, tmp_path):
    """It must NOT exit at the option loop.

    haf-stats-setup carries `restart: on-failure` while every other service waits on
    `service_completed_successfully`, so failing here would crash-loop the installer
    and keep the whole stack from starting -- over a flag that is a no-op for this app,
    and which a module file copied from an upstream template carries by default from a
    node-wide ${IS_FORKING:-TRUE}. An earlier revision of this MR exited 2.
    """
    out = run_install_with_stub_db(bash, tmp_path, "--is_forking=TRUE")
    assert "WARNING" in out
    assert "NON-forking" in out
    # Got past the option loop rather than bailing out of it.
    assert "Waiting for PostgreSQL" in out


def test_is_forking_false_is_accepted_quietly(bash, tmp_path):
    out = run_install_with_stub_db(bash, tmp_path, "--is_forking=FALSE")
    assert "WARNING: --is_forking" not in out
    assert "Waiting for PostgreSQL" in out


def test_connection_flags_are_honoured_not_rejected(bash, tmp_path):
    """--host and --port must change where the script connects.

    Upstream's entrypoints forward --host/--user, so a module file or runbook copied
    from balance_tracker carries them. An earlier revision of this MR rejected them,
    which would have failed the most-likely-copied invocation of all. Rejecting and
    ignoring are both wrong; this asserts they are honoured.
    """
    out = run_install_with_stub_db(bash, tmp_path, "--host=elsewhere", "--port=6543")
    assert "elsewhere:6543" in out


# --- flags that must reach an EFFECT, not merely be parsed -------------------------
#
# Mutation testing found these unguarded: renaming install_app.sh's `--swagger-url=*`
# case, and parsing `--user=*` but discarding it, both left the whole suite green.
# --swagger-url is the installer's only functional option, and --user is what the
# entrypoint forwards to the destructive script.


def run_install_full_stub(bash, tmp_path, *args: str):
    """Run install_app.sh with a psql that succeeds at everything and records it all."""
    bindir = stub_bin(tmp_path)
    sql_log = tmp_path / "sql.log"
    argv_log = tmp_path / "argv.log"
    write_exec(
        bindir / "psql",
        "#!/bin/sh\n"
        f'printf "%s\n" "$*" >> "{argv_log.as_posix()}"\n'
        'prev=""\n'
        'for a in "$@"; do\n'
        # Test prev BEFORE reassigning it, or the log records the literal "-c"
        # instead of the statement that followed it.
        f'  if [ "$prev" = "-c" ]; then printf "%s\n---\n" "$a" >> "{sql_log.as_posix()}"; fi\n'
        '  prev="$a"\n'
        "done\n"
        "exit 0\n",
    )
    proc = subprocess.run(
        [bash, str(INSTALL), *args],
        env=clean_env(bindir), capture_output=True, text=True, timeout=TIMEOUT,
    )
    return proc, sql_log, argv_log


def test_swagger_url_reaches_the_endpoint_load(bash, tmp_path):
    """The installer's only functional option. Its default silently baked wrong example
    URLs into the published Swagger page -- the failure the new unknown-option error
    was added to prevent -- yet nothing asserted the flag has an effect when correct."""
    _, sql_log, _ = run_install_full_stub(bash, tmp_path, "--swagger-url=example.com")
    assert "SET custom.swagger_url = 'example.com';" in sql_log.read_text()


def test_swagger_url_defaults_to_localhost(bash, tmp_path):
    _, sql_log, _ = run_install_full_stub(bash, tmp_path)
    assert "SET custom.swagger_url = 'localhost';" in sql_log.read_text()


def test_user_flag_reaches_the_connection(bash, tmp_path):
    """Parsed-but-discarded is the exact failure mode this MR calls a bug elsewhere."""
    _, _, argv_log = run_install_full_stub(bash, tmp_path, "--user=someone_else")
    assert "-U someone_else" in argv_log.read_text()


def test_postgres_host_is_accepted_as_a_synonym(bash, tmp_path):
    """balance_tracker's install_app.sh takes --postgres-host and nothing else, so with
    the new unknown-option error a copied runbook would hard-fail. Upstream module files
    put restart: on-failure on their app services, which turns that into a crash-loop.
    (Not on haf-stats-setup: this repo's compose has no restart: key -- an earlier
    version of this docstring said otherwise, copied from the sibling app.)"""
    _, _, argv_log = run_install_full_stub(bash, tmp_path, "--postgres-host=elsewhere")
    assert "-h elsewhere" in argv_log.read_text()


def test_help_covers_every_option_the_loop_accepts(bash, tmp_path):
    """Drift guard keyed on the CODE, not on the comment header.

    The earlier version of this test grepped the header for a fixed list, so drift in
    the loop-to-help direction was invisible: adding or renaming a case went unnoticed.
    This reads the option loop itself and requires each long flag to appear in --help.
    """
    body = INSTALL.read_text()
    loop = body.split("for arg in", 1)[1].split("\ndone", 1)[0]
    # Every long flag in every case label, including the FIRST alternative of an
    # `--a=*|--b=*)` pair. An earlier regex required a trailing ')' or a leading '|',
    # so it saw 5 of the 8 accepted flags -- --host, --port, --user and --help were
    # invisible to the "drift guard keyed on the CODE".
    labels = re.findall(r"^\s*(--[^)]*?)\)", loop, re.MULTILINE)
    flags = set()
    for label in labels:
        flags |= set(re.findall(r"(--[a-z0-9_-]+)", label))
    assert flags, "no options found in the loop; the parser above needs updating"
    out = run(bash, tmp_path, INSTALL, "--help").stdout
    missing = sorted(f for f in flags if f not in out)
    assert not missing, f"accepted by the option loop but absent from --help: {missing}"


# --- --postgres-url is HONOURED, in exactly one place (#59) -------------------
#
# The earlier revision refused it, because the revision before THAT honoured it badly:
# only psql moved, while every message and the teardown's type-the-database-name gate
# still read POSTGRES_HOST/POSTGRES_DB, so the script could act on one database while
# reporting another. These tests pin the property that makes honouring it safe --
# ONE connection path, and every message describing the connection actually made.


@pytest.mark.parametrize(
    "script", [INSTALL, UNINSTALL, PROCESS], ids=["install", "uninstall", "process_blocks"]
)
@pytest.mark.parametrize("flag", ["--postgres-url", "--url"])
def test_a_connection_uri_is_accepted(bash, tmp_path, script, flag):
    r = run(bash, tmp_path, script, f"{flag}=postgresql://haf_admin@haf/db", "--help")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "is not a valid option" not in r.stdout


@pytest.mark.parametrize(
    "script", [INSTALL, UNINSTALL, PROCESS], ids=["install", "uninstall", "process_blocks"]
)
def test_an_empty_connection_uri_is_an_error_not_a_fallback(bash, tmp_path, script):
    """A module file writing --postgres-url=${DB_URL} with DB_URL unset would otherwise
    connect silently to $POSTGRES_HOST -- and for uninstall_app that is a destructive
    command quietly retargeted."""
    r = run(bash, tmp_path, script, "--postgres-url=")
    assert r.returncode == 2
    assert "empty value" in r.stdout


def test_the_uri_replaces_the_discrete_flags_rather_than_joining_them(bash, tmp_path):
    """It must reach psql, and the discrete flags must NOT be passed alongside it: a
    trailing -U overrides the URI's own user, which is the opposite of "the URL wins"."""
    _, _, argv_log = run_install_full_stub(
        bash, tmp_path, "--postgres-url=postgresql://someone@elsewhere:6543/otherdb")
    argv = argv_log.read_text()
    assert "postgresql://someone@elsewhere:6543/otherdb" in argv
    assert "-h haf" not in argv
    assert "-U haf_stats_owner" not in argv


def test_there_is_exactly_one_connection_path():
    """psql and pg_isready must both go through pg_conn_args, or they can disagree about
    where they are looking -- which is precisely how the first attempt at this flag
    produced a teardown that dropped schemas on one host while naming another."""
    common = (SCRIPTS / "common.sh").read_text()
    assert common.count("pg_conn_args()") == 1
    for caller in ("psql_cmd", "wait_for_postgres"):
        body = common.split(f"{caller}()", 1)[1].split("\n}", 1)[0]
        assert "pg_conn_args" in body, f"{caller} does not use the shared connection args"


@pytest.mark.parametrize(
    "uri,must_not_contain",
    [
        ("postgresql://u:s3cr3t@h:5432/db", "s3cr3t"),
        ("postgresql://u@h/db?password=SUPERSECRET", "SUPERSECRET"),
        ("host=haf password=SEKRIT dbname=x", "SEKRIT"),
    ],
    ids=["userinfo", "query-param", "keyword-value"],
)
def test_no_form_of_password_reaches_the_log(bash, tmp_path, uri, must_not_contain):
    """All THREE forms libpq accepts. The first redactor pattern-matched the userinfo
    shape only and leaked the other two -- reproduced inside the real Alpine image."""
    out = run_with_stub_db(bash, tmp_path, INSTALL, f"--postgres-url={uri}")
    assert must_not_contain not in out
