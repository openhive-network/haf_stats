"""HAF's application lock (#157): the install takes it exclusively, the processor shared.

The install re-execs itself through the psql base image's install_with_app_lock.py, which
holds the exclusive lock on a connection of its own and skips while a processor holds the
shared one. Stubbed here: `python3` records what it was asked to run, so these tests pin the
hand-off (lock name, connection, the re-run command, and WHEN it happens), not the wrapper.
The wrapper's own skip is exercised against a real server by the install-test lane
(app-lock-holder / install-skips-under-app-lock in docker/docker-compose-ci-install.yml).

The processor half: the driver gets --lock=haf_stats, and the legacy CALL main() loop takes
the same lock in its own session first.
"""

from __future__ import annotations

import posixpath
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, stub_bin, write_exec
from tests.unit.test_process_blocks import make_driver, make_psql_with_registry

REPO = Path(__file__).resolve().parents[2]
INSTALL = REPO / "scripts" / "install_app.sh"
PROCESS = REPO / "scripts" / "process_blocks.sh"

TIMEOUT = 60

LOCK_CALL = "hive.acquire_app_block_processor_locks(ARRAY['haf_stats'])"


@pytest.fixture
def bash():
    return require_bash()


# --- the install --------------------------------------------------------------------

def make_install_stubs(tmp_path: Path, *, wrapper=True):
    """pg_isready, psql and python3 that log, in order, to one file.

    psql exits 1 on its first call: an install that gets past the lock hand-off stops at
    step 1, which is all these tests need to see.
    """
    bindir = stub_bin(tmp_path)
    events = tmp_path / "events.log"
    write_exec(bindir / "pg_isready", f'#!/bin/sh\necho pg_isready >> "{events.as_posix()}"\nexit 0\n')
    write_exec(bindir / "psql", f'#!/bin/sh\necho psql >> "{events.as_posix()}"\nexit 1\n')
    argv = tmp_path / "python3.argv"
    write_exec(
        bindir / "python3",
        f'#!/bin/sh\necho python3 >> "{events.as_posix()}"\n'
        f'printf "%s" "${{HAF_INSTALL_LOCK_HELD-unset}}" > "{(tmp_path / "held.env").as_posix()}"\n'
        f'printf "%s\\n%s" "${{HAF_APP_INSTALL_VERSION-unset}}" "${{HAF_APP_INSTALLED_VERSION_QUERY-unset}}"'
        f' > "{(tmp_path / "version.env").as_posix()}"\n'
        f'for a in "$@"; do printf "%s\\n" "$a" >> "{argv.as_posix()}"; done\nexit 0\n',
    )
    wrapper_path = tmp_path / "install_with_app_lock.py"
    if wrapper:
        wrapper_path.write_text("# stand-in; python3 is stubbed\n")
    return events, argv, wrapper_path


def run_install(bash, tmp_path: Path, wrapper_path, *args, held=False, env_extra=None, script=INSTALL):
    env = clean_env(tmp_path / "bin")
    env["HAF_STATS_INSTALL_LOCK_WRAPPER"] = str(wrapper_path)
    if held:
        env["HAF_INSTALL_LOCK_HELD"] = "haf_stats"
    env.update(env_extra or {})
    return subprocess.run(
        [bash, str(script), *args], env=env, capture_output=True, text=True, timeout=TIMEOUT
    )


def test_the_install_hands_itself_to_the_lock_wrapper(bash, tmp_path: Path) -> None:
    events, argv, wrapper = make_install_stubs(tmp_path)
    r = run_install(bash, tmp_path, wrapper, "--host=h1", "--port=6543", "--user=u1",
                    "--swagger-url=/x")
    assert r.returncode == 0, r.stdout + r.stderr
    args = argv.read_text().splitlines()
    assert args[0] == str(wrapper)
    assert args[1] == "haf_stats", "the lock name must be the registered name, haf_stats"
    dsn = args[2]
    for part in ("host='h1'", "port='6543'", "user='u1'", "dbname='haf_block_log'",
                 "application_name=haf_stats-install"):
        assert part in dsn, dsn
    # Re-run through bash (the script is not executable in a checkout), with every flag.
    assert args[3] == "bash"
    assert Path(args[4]).name == "install_app.sh"
    assert args[5:] == ["--host=h1", "--port=6543", "--user=u1", "--swagger-url=/x"]
    # exec'd: nothing of the install ran in this process.
    assert "Installing haf_stats schema" not in r.stdout
    assert "psql" not in events.read_text().split()
    # Exported, so the wrapper's child goes straight on: unexported, the child wraps itself
    # again and skips against its own parent's exclusive lock (the wrapper does not set it).
    assert (tmp_path / "held.env").read_text() == "haf_stats"


INSTALLED_VERSION_QUERY = "SELECT git_hash FROM haf_stats_app.app_version LIMIT 1"


def test_a_checkout_leaves_upgrade_detection_off(bash, tmp_path: Path) -> None:
    """No db/version.sql in a checkout, so there is no version to compare: neither is set."""
    assert not (REPO / "db" / "version.sql").exists(), "a stray db/version.sql would skew this"
    _, _, wrapper = make_install_stubs(tmp_path)
    r = run_install(bash, tmp_path, wrapper)
    assert r.returncode == 0, r.stdout + r.stderr
    assert (tmp_path / "version.env").read_text() == "unset\nunset"


@pytest.mark.parametrize("git_hash", ["ab6d7c4b", "1.28.8-rc1_x", None])
def test_the_image_hands_the_wrapper_its_version_and_how_to_read_the_installed_one(
        bash, tmp_path: Path, git_hash) -> None:
    """common-ci-configuration#85: with both, a held lock fails an upgrade instead of skipping it.

    Run from an image-shaped tree whose db/version.sql the Dockerfile's real RUN line wrote,
    so the version handed over is exactly what the install would write to app_version.
    None = a build with no --build-arg (the placeholder).
    """
    from tests.unit.test_version_provenance import PLACEHOLDER, _bake

    app = tmp_path / "app"
    shutil.copytree(REPO / "scripts", app / "scripts")
    (app / "db").mkdir()
    (app / "db" / "version.sql").write_text(_bake(bash, tmp_path, git_hash), encoding="utf-8")
    _, argv, wrapper = make_install_stubs(tmp_path)
    r = run_install(bash, tmp_path, wrapper, script=app / "scripts" / "install_app.sh")
    # The stub wrapper installs nothing, so a versioned image's upgrade was skipped, which
    # install_app.sh fails (test_an_upgrade_the_wrapper_skips_fails); the placeholder cannot
    # tell an upgrade apart and keeps the plain skip.
    assert r.returncode == (0 if git_hash is None else 1), r.stdout + r.stderr
    assert argv.read_text().splitlines()[1] == "haf_stats", "it must still hand off"
    version, query = (tmp_path / "version.env").read_text().split("\n")
    assert version == (PLACEHOLDER if git_hash is None else git_hash)
    assert query == INSTALLED_VERSION_QUERY


def test_the_installed_version_query_reads_the_column_the_install_writes() -> None:
    sql = (REPO / "db" / "haf_stats_app.sql").read_text(encoding="utf-8")
    assert re.search(r"CREATE TABLE IF NOT EXISTS haf_stats_app\.app_version \(\s*git_hash TEXT",
                     sql), "app_version.git_hash moved; update the query in install_app.sh"
    assert INSTALLED_VERSION_QUERY in INSTALL.read_text(encoding="utf-8")


def test_the_hand_off_waits_for_postgres(bash, tmp_path: Path) -> None:
    """Before wait_for_postgres, the wrapper's own connect fails against a server that is
    still starting, the install exits non-zero, and the processor never starts."""
    events, _, wrapper = make_install_stubs(tmp_path)
    run_install(bash, tmp_path, wrapper)
    seen = events.read_text().split()
    assert seen.index("pg_isready") < seen.index("python3")


def test_a_bad_flag_fails_before_the_hand_off(bash, tmp_path: Path) -> None:
    """After it, a bad flag's exit 2 would be hidden by a skip's exit 0 whenever a
    processor holds the lock."""
    events, argv, wrapper = make_install_stubs(tmp_path)
    r = run_install(bash, tmp_path, wrapper, "--content-source=nonsense")
    assert r.returncode == 2, r.stdout + r.stderr
    assert not argv.exists()


def test_the_rerun_under_the_lock_installs(bash, tmp_path: Path) -> None:
    """The wrapper's child: HAF_INSTALL_LOCK_HELD set, so it goes straight on."""
    events, argv, wrapper = make_install_stubs(tmp_path)
    r = run_install(bash, tmp_path, wrapper, held=True)
    assert not argv.exists(), "the re-run handed itself to the wrapper again"
    assert "Installing haf_stats schema" in r.stdout
    assert "psql" in events.read_text().split()


@pytest.mark.parametrize("value", ["1", "balance_tracker", "haf_stats_x"])
def test_another_apps_held_marker_does_not_skip_the_lock(bash, tmp_path: Path, value) -> None:
    """Six other apps' installers set HAF_INSTALL_LOCK_HELD=1 for their own re-runs: a value
    left in the environment by one of them must not let this install run without the lock."""
    events, argv, wrapper = make_install_stubs(tmp_path)
    r = run_install(bash, tmp_path, wrapper, env_extra={"HAF_INSTALL_LOCK_HELD": value})
    assert r.returncode == 0, r.stdout + r.stderr
    assert argv.read_text().splitlines()[0] == str(wrapper), "the install skipped the lock wrapper"
    assert "Installing haf_stats schema" not in r.stdout
    assert (tmp_path / "held.env").read_text() == "haf_stats"


def test_without_the_wrapper_it_installs_unlocked_and_says_so(bash, tmp_path: Path) -> None:
    events, argv, wrapper = make_install_stubs(tmp_path, wrapper=False)
    r = run_install(bash, tmp_path, wrapper)
    assert not argv.exists()
    assert "WITHOUT HAF's install lock" in r.stdout
    assert "Installing haf_stats schema" in r.stdout


def test_connection_values_are_quoted_for_libpq(bash, tmp_path: Path) -> None:
    """A space or quote in a value must not split or end it."""
    _, argv, wrapper = make_install_stubs(tmp_path)
    run_install(bash, tmp_path, wrapper, env_extra={"POSTGRES_USER": "o'b x"})
    dsn = argv.read_text().splitlines()[2]
    assert "user='o\\'b x'" in dsn, dsn


# --- the processor ------------------------------------------------------------------

def run_process(bash, tmp_path: Path, env_extra=None):
    env = clean_env(stub_bin(tmp_path))
    env["HAF_STATS_STARTUP_TIME_FILE"] = str(tmp_path / "startup.txt")
    env.update(env_extra or {})
    return subprocess.run(
        [bash, str(PROCESS)], env=env, capture_output=True, text=True, timeout=TIMEOUT
    )


def test_the_driver_holds_the_shared_lock(bash, tmp_path: Path) -> None:
    make_psql_with_registry(tmp_path)
    driver = make_driver(tmp_path)
    r = run_process(bash, tmp_path)
    assert r.returncode == 0, r.stderr
    assert "--lock=haf_stats" in driver.read_text().split()


@pytest.mark.parametrize("ambient", [None, "-c statement_timeout=0"])
def test_the_drivers_connection_notices_a_dead_client_on_14(bash, tmp_path: Path, ambient) -> None:
    """A SIGKILLed driver's backend busy in a range must not keep the lock until the range
    ends: the same client_connection_check_interval as db/legacy_loop_lock.sql, through libpq,
    added to whatever PGOPTIONS the container already carries."""
    make_psql_with_registry(tmp_path, server_14=True)
    make_driver(tmp_path)
    r = run_process(bash, tmp_path, env_extra={"PGOPTIONS": ambient} if ambient else None)
    assert r.returncode == 0, r.stderr
    expected = "-c client_connection_check_interval=10s"
    assert (tmp_path / "driver.env").read_text() == (f"{ambient} {expected}" if ambient else expected)


def test_the_drivers_connection_check_is_left_off_before_14(bash, tmp_path: Path) -> None:
    """PostgreSQL 13 refuses a connection that sets a parameter it does not have."""
    make_psql_with_registry(tmp_path, server_14=False)
    make_driver(tmp_path)
    r = run_process(bash, tmp_path)
    assert r.returncode == 0, r.stderr
    assert (tmp_path / "driver.env").read_text() == "unset"


def make_psql_recording_each_command(tmp_path: Path):
    """psql that writes each -c, and each -f as `-f <path>`, of an invocation on its own
    line, in order, invocations separated."""
    bindir = stub_bin(tmp_path)
    log = tmp_path / "commands.log"
    write_exec(
        bindir / "psql",
        "#!/bin/sh\nprev=''\n"
        'for a in "$@"; do\n'
        f'  case "$prev" in -c) printf "%s\\n" "$a" >> "{log.as_posix()}" ;;\n'
        f'                  -f) printf -- "-f %s\\n" "$a" >> "{log.as_posix()}" ;; esac\n'
        '  prev="$a"\n'
        "done\n"
        f'echo "=== end of invocation" >> "{log.as_posix()}"\n'
        'case "$*" in *"now()"*) printf "2026-09-01 12:34:56" ;; esac\n'
        "exit 0\n",
    )
    return log


def test_the_legacy_loop_takes_the_lock_in_its_own_session_first(bash, tmp_path: Path) -> None:
    log = make_psql_recording_each_command(tmp_path)
    r = run_process(bash, tmp_path, env_extra={"HAF_STATS_USE_LEGACY_LOOP": "true"})
    assert r.returncode == 0, r.stderr
    invocations = [inv.strip().splitlines() for inv in log.read_text().split("=== end of invocation")]
    loop = [cmds for cmds in invocations if any("CALL haf_stats_app.main" in c for c in cmds)]
    assert len(loop) == 1, invocations
    cmds = loop[0]
    # Same psql invocation (one session, so the lock lasts as long as the loop): the lock file
    # first, then the CALL on its own -c (one -c with both would be one transaction, and main()
    # commits inside). What the file does is run against a real server by the install-test
    # lane (tests/ci_install_skips_under_app_lock.sh); here, that this is the file it runs.
    assert len(cmds) == 2, cmds
    assert cmds[0].startswith("-f "), cmds
    # Compared as text: under Git Bash the script sees /tmp/... where Python sees C:/...
    assert posixpath.normpath(cmds[0][3:]).endswith("/db/legacy_loop_lock.sql"), cmds
    assert cmds[1] == "CALL haf_stats_app.main('haf_stats');"


def test_the_legacy_lock_file_names_the_lock_and_the_session_check() -> None:
    sql = (REPO / "db" / "legacy_loop_lock.sql").read_text(encoding="utf-8")
    assert LOCK_CALL in sql
    assert "client_connection_check_interval" in sql
    # A top-level SELECT prints its result table into the processor's log.
    assert not re.search(r"^\s*SELECT\b", sql, re.MULTILINE | re.IGNORECASE), sql


# --- an upgrade is never skipped silently ---------------------------------------------
#
# On an image upgrade compose starts the install seconds after it stops the old processor,
# whose backend can still hold the shared lock. The wrapper tries once and skips with exit 0,
# so the install waits (bounded) for the holders when this image's version is not the
# installed one, and fails if the wrapper skips anyway.

IMAGE = "abcd1234"
OLD = "0000beef"


def make_upgrade_stubs(tmp_path: Path, *, installed, holders, wrapper_installs, wrapper_exit=0):
    """psql answering the installed version and the lock holders from files; python3 (the
    wrapper) that, when wrapper_installs, records the image's version as an install would;
    sleep that returns at once. version.sql holds the image's version."""
    bindir = stub_bin(tmp_path)
    installed_file = tmp_path / "installed.txt"
    installed_file.write_text(installed)
    holders_file = tmp_path / "holders.txt"
    holders_file.write_text(str(holders))
    sleeps = tmp_path / "sleeps.log"
    write_exec(
        bindir / "psql",
        "#!/bin/sh\ncmd=''\nprev=''\n"
        'for a in "$@"; do case "$prev" in -c) cmd="$cmd$a" ;; esac; prev="$a"; done\n'
        'case "$cmd" in\n'
        f'  *app_version*) cat "{installed_file.as_posix()}" ;;\n'
        f'  *pg_locks*) cat "{holders_file.as_posix()}" ;;\n'
        "esac\nexit 0\n",
    )
    write_exec(bindir / "sleep", f'#!/bin/sh\necho "$1" >> "{sleeps.as_posix()}"\nexit 0\n')
    body = "#!/bin/sh\n"
    if wrapper_installs:
        body += f'printf "%s" "{IMAGE}" > "{installed_file.as_posix()}"\n'
    body += f"exit {wrapper_exit}\n"
    write_exec(bindir / "python3", body)
    version_sql = tmp_path / "version.sql"
    version_sql.write_text(
        "TRUNCATE haf_stats_app.app_version; "
        f"INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('{IMAGE}');\n"
    )
    wrapper_path = tmp_path / "install_with_app_lock.py"
    wrapper_path.write_text("# stand-in; python3 is stubbed\n")
    return wrapper_path, version_sql, sleeps


def run_upgrade(bash, tmp_path: Path, wrapper, version_sql, **env):
    return run_install(bash, tmp_path, wrapper, env_extra={
        "HAF_STATS_VERSION_SQL": str(version_sql), "HAF_STATS_INSTALL_LOCK_WAIT": "6", **env})


def test_an_upgrade_the_wrapper_skips_fails(bash, tmp_path: Path) -> None:
    """THE review finding: the processor still holds the lock, the wrapper skips (exit 0),
    and the old schema stays. That must not look like success."""
    wrapper, version_sql, sleeps = make_upgrade_stubs(
        tmp_path, installed=OLD, holders=1, wrapper_installs=False)
    r = run_upgrade(bash, tmp_path, wrapper, version_sql)
    assert r.returncode == 1, r.stdout + r.stderr
    assert f"version {IMAGE} was NOT installed (installed: {OLD})" in r.stdout
    # It waited the bound first, in 2 s steps, and no longer.
    assert sleeps.read_text().split() == ["2", "2", "2"]
    assert "waiting up to 6s" in r.stdout


def test_an_upgrade_installs_once_the_holder_is_gone(bash, tmp_path: Path) -> None:
    wrapper, version_sql, sleeps = make_upgrade_stubs(
        tmp_path, installed=OLD, holders=0, wrapper_installs=True)
    r = run_upgrade(bash, tmp_path, wrapper, version_sql)
    assert r.returncode == 0, r.stdout + r.stderr
    assert not sleeps.exists(), "no holder, no wait"


def test_a_fresh_database_counts_as_an_upgrade(bash, tmp_path: Path) -> None:
    wrapper, version_sql, _ = make_upgrade_stubs(
        tmp_path, installed="", holders=1, wrapper_installs=False)
    r = run_upgrade(bash, tmp_path, wrapper, version_sql)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "(installed: none)" in r.stdout


def test_the_same_version_still_skips_with_exit_0(bash, tmp_path: Path) -> None:
    """A plain `up -d` with nothing changed re-runs the setup beside a live processor: a
    skip applies nothing that was missing, so it stays a success, and nothing waits."""
    wrapper, version_sql, sleeps = make_upgrade_stubs(
        tmp_path, installed=IMAGE, holders=1, wrapper_installs=False)
    r = run_upgrade(bash, tmp_path, wrapper, version_sql)
    assert r.returncode == 0, r.stdout + r.stderr
    assert not sleeps.exists()
    assert "NOT installed" not in r.stdout


def test_an_unversioned_image_keeps_the_old_behaviour(bash, tmp_path: Path) -> None:
    """GIT_HASH "unspecified": versions cannot tell an upgrade from a re-run."""
    wrapper, version_sql, sleeps = make_upgrade_stubs(
        tmp_path, installed="unspecified", holders=1, wrapper_installs=False)
    version_sql.write_text(version_sql.read_text().replace(IMAGE, "unspecified"))
    r = run_upgrade(bash, tmp_path, wrapper, version_sql)
    assert r.returncode == 0, r.stdout + r.stderr
    assert not sleeps.exists()


def test_the_wrappers_failure_is_the_installs(bash, tmp_path: Path) -> None:
    wrapper, version_sql, _ = make_upgrade_stubs(
        tmp_path, installed=OLD, holders=0, wrapper_installs=False, wrapper_exit=3)
    r = run_upgrade(bash, tmp_path, wrapper, version_sql)
    assert r.returncode == 3, r.stdout + r.stderr


def test_a_bad_wait_falls_back_to_60(bash, tmp_path: Path) -> None:
    wrapper, version_sql, _ = make_upgrade_stubs(
        tmp_path, installed=OLD, holders=0, wrapper_installs=True)
    r = run_upgrade(bash, tmp_path, wrapper, version_sql, HAF_STATS_INSTALL_LOCK_WAIT="soon")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "HAF_STATS_INSTALL_LOCK_WAIT='soon'" in r.stdout


# --- the processor refuses another version's schema -----------------------------------

def make_versioned_processor(tmp_path: Path, installed):
    _, _ = make_psql_with_registry(tmp_path, has_table=False)
    psql = tmp_path / "bin" / "psql"
    body = psql.read_text()
    # Answer the installed-version query ahead of the registry stub's arms.
    psql.write_text(body.replace("case \"$cmd\" in\n",
                                 f"case \"$cmd\" in\n  *app_version*) printf '%s' '{installed}'; exit 0 ;;\n", 1))
    version_sql = tmp_path / "version.sql"
    version_sql.write_text(f"INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('{IMAGE}');\n")
    return version_sql


def test_the_processor_refuses_another_versions_schema(bash, tmp_path: Path) -> None:
    version_sql = make_versioned_processor(tmp_path, OLD)
    r = run_process(bash, tmp_path, env_extra={"HAF_STATS_VERSION_SQL": str(version_sql)})
    assert r.returncode == 1, r.stdout + r.stderr
    assert f"this image is version {IMAGE}, but the database has {OLD}" in r.stdout
    assert not (tmp_path / "startup.txt").exists(), "it must stop before processing starts"


@pytest.mark.parametrize("installed", [IMAGE, ""])
def test_the_processor_runs_on_its_own_version_or_none_recorded(bash, tmp_path: Path, installed) -> None:
    version_sql = make_versioned_processor(tmp_path, installed)
    r = run_process(bash, tmp_path, env_extra={"HAF_STATS_VERSION_SQL": str(version_sql)})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "but the database has" not in r.stdout
