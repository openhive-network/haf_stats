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

def make_install_stubs(tmp_path, *, wrapper=True):
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
        f'for a in "$@"; do printf "%s\\n" "$a" >> "{argv.as_posix()}"; done\nexit 0\n',
    )
    wrapper_path = tmp_path / "install_with_app_lock.py"
    if wrapper:
        wrapper_path.write_text("# stand-in; python3 is stubbed\n")
    return events, argv, wrapper_path


def run_install(bash, tmp_path, wrapper_path, *args, held=False, env_extra=None):
    env = clean_env(tmp_path / "bin")
    env["HAF_STATS_INSTALL_LOCK_WRAPPER"] = str(wrapper_path)
    if held:
        env["HAF_INSTALL_LOCK_HELD"] = "1"
    env.update(env_extra or {})
    return subprocess.run(
        [bash, str(INSTALL), *args], env=env, capture_output=True, text=True, timeout=TIMEOUT
    )


def test_the_install_hands_itself_to_the_lock_wrapper(bash, tmp_path):
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
    assert (tmp_path / "held.env").read_text() == "1"


def test_the_hand_off_waits_for_postgres(bash, tmp_path):
    """Before wait_for_postgres, the wrapper's own connect fails against a server that is
    still starting, the install exits non-zero, and the processor never starts."""
    events, _, wrapper = make_install_stubs(tmp_path)
    run_install(bash, tmp_path, wrapper)
    seen = events.read_text().split()
    assert seen.index("pg_isready") < seen.index("python3")


def test_a_bad_flag_fails_before_the_hand_off(bash, tmp_path):
    """After it, a bad flag's exit 2 would be hidden by a skip's exit 0 whenever a
    processor holds the lock."""
    events, argv, wrapper = make_install_stubs(tmp_path)
    r = run_install(bash, tmp_path, wrapper, "--content-source=nonsense")
    assert r.returncode == 2, r.stdout + r.stderr
    assert not argv.exists()


def test_the_rerun_under_the_lock_installs(bash, tmp_path):
    """The wrapper's child: HAF_INSTALL_LOCK_HELD set, so it goes straight on."""
    events, argv, wrapper = make_install_stubs(tmp_path)
    r = run_install(bash, tmp_path, wrapper, held=True)
    assert not argv.exists(), "the re-run handed itself to the wrapper again"
    assert "Installing haf_stats schema" in r.stdout
    assert "psql" in events.read_text().split()


def test_without_the_wrapper_it_installs_unlocked_and_says_so(bash, tmp_path):
    events, argv, wrapper = make_install_stubs(tmp_path, wrapper=False)
    r = run_install(bash, tmp_path, wrapper)
    assert not argv.exists()
    assert "WITHOUT HAF's install lock" in r.stdout
    assert "Installing haf_stats schema" in r.stdout


def test_connection_values_are_quoted_for_libpq(bash, tmp_path):
    """A space or quote in a value must not split or end it."""
    _, argv, wrapper = make_install_stubs(tmp_path)
    run_install(bash, tmp_path, wrapper, env_extra={"POSTGRES_USER": "o'b x"})
    dsn = argv.read_text().splitlines()[2]
    assert "user='o\\'b x'" in dsn, dsn


# --- the processor ------------------------------------------------------------------

def run_process(bash, tmp_path, env_extra=None):
    env = clean_env(stub_bin(tmp_path))
    env["HAF_STATS_STARTUP_TIME_FILE"] = str(tmp_path / "startup.txt")
    env.update(env_extra or {})
    return subprocess.run(
        [bash, str(PROCESS)], env=env, capture_output=True, text=True, timeout=TIMEOUT
    )


def test_the_driver_holds_the_shared_lock(bash, tmp_path):
    make_psql_with_registry(tmp_path)
    driver = make_driver(tmp_path)
    r = run_process(bash, tmp_path)
    assert r.returncode == 0, r.stderr
    assert "--lock=haf_stats" in driver.read_text().split()


def make_psql_recording_each_command(tmp_path):
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


def test_the_legacy_loop_takes_the_lock_in_its_own_session_first(bash, tmp_path):
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


def test_the_legacy_lock_file_names_the_lock_and_the_session_check():
    sql = (REPO / "db" / "legacy_loop_lock.sql").read_text(encoding="utf-8")
    assert LOCK_CALL in sql
    assert "client_connection_check_interval" in sql
