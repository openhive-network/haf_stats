"""Behavioural tests for scripts/process_blocks.sh (#57).

This script is half of the healthcheck contract — it writes the startup timestamp the
check compares against — and nothing executed it before this file existed:
test_docker_entrypoint.py stubs it out, and no CI lane runs the image. Mutation testing
confirmed the gap: deleting the timestamp write, pointing it at a different path from
the one the reader defaults to, emitting a non-ISO or local-time value, and calling
main() with the wrong context name ALL survived the full suite.

The most expensive of those was not hypothetical. An earlier revision wrote the
timestamp with `date --utc --iso-8601=seconds`, a GNU long option the image's BusyBox
does not have. Under `set -euo pipefail` that is a non-zero exit on the first line of
the block processor, before it ever connects — so `restart: unless-stopped` would have
crash-looped haf-stats-process on every deployment. It passed every job, because the tests
run on Debian and nothing in CI starts the image.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, stub_bin, write_exec

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "process_blocks.sh"
HEALTHCHECK = REPO / "docker" / "block-processing-healthcheck.sh"

TIMEOUT = 15

# What the database clock returns for the stub, in the shape psql -Atq would print.
STUB_NOW = "2026-09-01 12:34:56.789"


@pytest.fixture
def bash():
    return require_bash()


def make_psql(tmp_path) -> Path:
    """A stub psql: answers `SELECT now()`, records every -c, and never blocks."""
    stub_bin(tmp_path)
    logfile = tmp_path / "sql.log"
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        'for a in "$@"; do\n'
        '  case "$prev" in -c) cmd="$cmd$a" ;; esac\n'
        '  prev="$a"\n'
        "done\n"
        f'printf "%s\\n---\\n" "$cmd" >> "{logfile.as_posix()}"\n'
        f'printf "%s\\n" "$*" >> "{(tmp_path / "argv.log").as_posix()}"\n'
        'case "$cmd" in\n'
        f'  *"now()"*) printf "%s" {STUB_NOW!r} ;;\n'
        "esac\n"
        "exit 0\n",
    )
    return logfile


def run(bash, tmp_path, *args: str, startup_file: Path | None = None, env_extra=None):
    env = clean_env(stub_bin(tmp_path))
    if startup_file is not None:
        env["HAF_STATS_STARTUP_TIME_FILE"] = str(startup_file)
    # Set AFTER clean_env, which strips every HAF_STATS_* name on purpose.
    for key, value in (env_extra or {}).items():
        env[key] = value
    return subprocess.run(
        [bash, str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=TIMEOUT
    )


# --- the startup timestamp --------------------------------------------------------

def test_writes_the_startup_timestamp(bash, tmp_path):
    """Without it the healthcheck reports "block processing hasn't started yet" for the
    life of the container."""
    make_psql(tmp_path)
    startup = tmp_path / "startup.txt"
    r = run(bash, tmp_path, startup_file=startup)
    assert r.returncode == 0, r.stdout + r.stderr
    assert startup.read_text().strip() == STUB_NOW


def test_the_timestamp_comes_from_the_database_not_the_container(bash, tmp_path):
    """Two reasons, and the first is a correctness one.

    last_active_at is `timestamp without time zone`, written by HAF in the SERVER's
    session time zone. A timestamp taken in the container is only comparable to it if
    both agree on the zone, and when they disagree the error is in the FAIL-OPEN
    direction — a server ahead of the container makes the freshness difference
    negative, so a dead loop reports healthy forever.

    The second is that `date --utc --iso-8601=seconds` does not exist on the image's
    BusyBox, which is how an earlier revision would have crash-looped the container.
    """
    log = make_psql(tmp_path)
    startup = tmp_path / "startup.txt"
    run(bash, tmp_path, startup_file=startup)
    assert startup.read_text().strip() == STUB_NOW
    # The value came from a query, not from the container's clock.
    assert "SELECT now()::timestamp" in log.read_text()


def test_no_gnu_only_date_invocation_survives_in_the_script(bash, tmp_path):
    """Pinned by name. The image is Alpine, so `date` is BusyBox: it has `-I[SPEC]` but
    no `--iso-8601`, and no `--utc`. Reintroducing either kills the container on line
    one, and no other test in this repo would notice."""
    # Comments explain WHY these are absent, so only executable lines are inspected.
    code = [line for line in SCRIPT.read_text().splitlines()
            if not line.lstrip().startswith("#")]
    assert not any("--iso-8601" in line for line in code)
    assert not any("--utc" in line for line in code)


def test_the_writer_and_the_reader_agree_on_the_default_path(bash, tmp_path):
    """They are two files that must name the same location. If they drift, the check
    reports "hasn't started yet" forever and nothing else fails."""
    default = "/tmp/block_processing_startup_time.txt"
    writer = re.search(r"HAF_STATS_STARTUP_TIME_FILE:-([^}\"]+)", SCRIPT.read_text())
    reader = re.search(r"HAF_STATS_STARTUP_TIME_FILE:-([^}\"]+)", HEALTHCHECK.read_text())
    assert writer is not None and reader is not None
    assert writer.group(1) == reader.group(1) == default


def test_the_timestamp_is_written_after_the_database_is_reachable(bash, tmp_path):
    """It is read from the database now, so it cannot precede wait_for_postgres. That
    also sharpens what the file's absence means: not "the container started" but
    "block processing has not begun"."""
    make_psql(tmp_path)
    out = run(bash, tmp_path, startup_file=tmp_path / "startup.txt").stdout
    assert out.index("Waiting for PostgreSQL") < out.index("start time recorded")


# --- the loop ---------------------------------------------------------------------

def test_calls_main_with_the_context_name_not_the_schema_name(bash, tmp_path):
    """haf_stats is the context; haf_stats_app is the schema. main() takes the context."""
    log = make_psql(tmp_path)
    run(bash, tmp_path, startup_file=tmp_path / "startup.txt")
    assert "CALL haf_stats_app.main('haf_stats');" in log.read_text()


# --- option handling --------------------------------------------------------------

def test_host_flag_reaches_the_connection(bash, tmp_path):
    """Asserted on psql's argv, not on wait_for_postgres's log line.

    The log line is built from the option loop's own variables, so it stays correct
    even if psql_cmd hardcoded the host — flag parsed, message right, connection wrong.
    argv is what decides where it actually connects.
    """
    make_psql(tmp_path)
    run(bash, tmp_path, "--host=elsewhere", "--port=6543",
        startup_file=tmp_path / "startup.txt")
    argv = (tmp_path / "argv.log").read_text()
    assert "-h elsewhere" in argv
    assert "-p 6543" in argv


def test_user_flag_reaches_the_connection(bash, tmp_path):
    """--user could be parsed and then discarded with no test noticing, while --help
    still advertised it — the silent-discard failure this MR calls a bug elsewhere."""
    make_psql(tmp_path)
    run(bash, tmp_path, "--user=someone_else", startup_file=tmp_path / "startup.txt")
    assert "-U someone_else" in (tmp_path / "argv.log").read_text()


def test_an_unknown_option_is_rejected(bash, tmp_path):
    make_psql(tmp_path)
    r = run(bash, tmp_path, "--nope", startup_file=tmp_path / "startup.txt")
    assert r.returncode == 2
    assert "is not a valid option" in r.stdout


def test_help_exits_zero_and_lists_the_flags(bash, tmp_path):
    r = run(bash, tmp_path, "--help")
    assert r.returncode == 0
    for flag in ("--host", "--port", "--user", "--help"):
        assert flag in r.stdout


def test_the_startup_query_asks_for_a_bare_value(bash, tmp_path):
    """-At on the startup query. Without it real psql writes a header and "(1 row)" into
    the file, `:'startup_time'::timestamp` becomes a cast error, and the container is
    permanently unhealthy -- while a stub that ignores flags reports everything fine."""
    make_psql(tmp_path)
    run(bash, tmp_path, startup_file=tmp_path / "startup.txt")
    argv = (tmp_path / "argv.log").read_text()
    assert "-Atq" in argv or "-At" in argv


def test_the_startup_file_is_written_before_the_loop_starts(bash, tmp_path):
    """main() never returns in production, so a write placed after the CALL would never
    happen and the healthcheck would report "hasn't started yet" for the life of the
    container. Ordering asserted against the SQL log, not against two log lines that
    stay in order regardless."""
    log = make_psql(tmp_path)
    startup = tmp_path / "startup.txt"
    run(bash, tmp_path, startup_file=startup)
    sql = log.read_text()
    assert sql.index("SELECT now()::timestamp") < sql.index("CALL haf_stats_app.main")


def test_the_startup_write_is_atomic(bash, tmp_path):
    """A plain `psql > file` truncates before psql runs, so a psql that fails after
    pg_isready succeeded leaves a zero-byte file that passes an existence check. The
    write goes to a temp file and is moved into place."""
    body = [line for line in SCRIPT.read_text().splitlines()
            if not line.lstrip().startswith("#")]
    assert any("mv " in line for line in body)
    assert not any(
        'SELECT now()::timestamp" > "${STARTUP_TIME_FILE}"' in line for line in body
    )


# --- per-invocation flags, and the atomic startup write (round three) ---------------

def _argv_lines(tmp_path) -> list:
    """One psql invocation per entry, so a flag cannot be asserted on the wrong call."""
    log = tmp_path / "argv.log"
    return [ln for ln in log.read_text().split("\n") if ln.strip()] if log.exists() else []


def test_the_startup_query_alone_carries_the_bare_value_flag(bash, tmp_path):
    """-Atq was asserted by grepping the WHOLE argv log, so MOVING it from the startup
    query to the CALL kept the suite green. The startup file then gets a header and
    `(1 row)`, `:'startup_time'::timestamp` raises on the reader side, and the container
    is unhealthy forever -- the exact failure the reader-side test documents."""
    make_psql(tmp_path)
    run(bash, tmp_path, startup_file=tmp_path / "startup.txt")
    startup = [ln for ln in _argv_lines(tmp_path) if "now()" in ln]
    assert startup, f"no startup query issued: {_argv_lines(tmp_path)}"
    for line in startup:
        assert "-Atq" in line, f"the startup query must ask for a bare value: {line}"


def test_a_failed_startup_query_leaves_no_truncated_file(bash, tmp_path):
    """Behavioural, because the source-grep version passes against a no-op `mv`.

    Redirecting straight at the destination truncates it before psql runs, so a psql
    that fails after pg_isready succeeded leaves a ZERO-BYTE file -- which the reader
    treats as unhealthy forever. Writing to a temp file and renaming means a failed run
    leaves no file at all, or the previous complete value.
    """
    stub_bin(tmp_path)
    write_exec(tmp_path / "bin" / "psql",
               "#!/bin/sh\nprintf 'partial'\necho 'stub psql: failing' >&2\nexit 1\n")
    startup = tmp_path / "startup.txt"
    run(bash, tmp_path, startup_file=startup)
    if startup.exists():
        assert startup.read_text().strip(), (
            "a failed run left a truncated startup file; the write is not atomic"
        )


# --- choosing between the driver and the legacy loop (#85) -------------------------
#
# These cover the combination that has no other coverage anywhere: driver ON PATH,
# registry ABSENT. The sync lane only ever runs against a HAF that HAS the registry, the
# install lane never runs this script, and the docker-build smoke test runs it with
# `--help` and no database. That gap is not academic -- hive/haf_fyp!51 shipped a guard
# that tested only `command -v`, which is permanently true once the base image ships the
# driver, and on a registry-less HAF the driver exits before its first range as PID 1.


def make_psql_with_registry(tmp_path, *, has_table=True, registered=True, probe_fails=False):
    """A stub psql that also answers the two registry-probe queries.

    Records $PGAPPNAME per invocation so a test can prove the legacy loop tags its own
    session the way scripts/rebuild_*.sh now look for.
    """
    stub_bin(tmp_path)
    logfile = tmp_path / "sql.log"
    appnames = tmp_path / "appname.log"
    probe_exit = "exit 1" if probe_fails else ":"
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        "prev=''\n"
        'for a in "$@"; do\n'
        '  case "$prev" in -c) cmd="$cmd$a" ;; esac\n'
        '  prev="$a"\n'
        "done\n"
        f'printf "%s\\n---\\n" "$cmd" >> "{logfile.as_posix()}"\n'
        f'printf "%s\\n" "${{PGAPPNAME-}}" >> "{appnames.as_posix()}"\n'
        'case "$cmd" in\n'
        f'  *"now()"*) printf "%s" {STUB_NOW!r} ;;\n'
        f'  *to_regclass*) {probe_exit}; printf "%s" {("t" if has_table else "f")!r} ;;\n'
        f'  *"FROM hafd.applications"*) {probe_exit}; printf "%s" {("t" if registered else "f")!r} ;;\n'
        "esac\n"
        "exit 0\n",
    )
    return logfile, appnames


def make_driver(tmp_path):
    """A stub haf_app_driver.py that records its argv instead of running."""
    stub_bin(tmp_path)
    argv = tmp_path / "driver.log"
    write_exec(
        tmp_path / "bin" / "haf_app_driver.py",
        f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{argv.as_posix()}"\nexit 0\n',
    )
    return argv


def test_a_registry_less_haf_does_not_get_the_driver(bash, tmp_path):
    """THE crash-loop case. The driver is on PATH -- it always is, from psql:14-3 on --
    but this HAF predates haf#341, so hafd.applications does not exist. Exec'ing the
    driver here means it exits before its first range as PID 1."""
    sql, _ = make_psql_with_registry(tmp_path, has_table=False)
    driver = make_driver(tmp_path)
    result = run(bash, tmp_path, startup_file=tmp_path / "startup.txt")

    assert result.returncode == 0, result.stderr
    assert not driver.exists(), "the driver was exec'd against a HAF with no registry"
    assert "CALL haf_stats_app.main" in sql.read_text(encoding="utf-8")


def test_a_registered_app_gets_the_driver_and_not_the_legacy_loop(bash, tmp_path):
    sql, _ = make_psql_with_registry(tmp_path)
    driver = make_driver(tmp_path)
    result = run(bash, tmp_path, startup_file=tmp_path / "startup.txt")

    assert result.returncode == 0, result.stderr
    argv = driver.read_text(encoding="utf-8")
    assert "--app=haf_stats" in argv

    # The OTHER half of the rebuild-guard contract. scripts/rebuild_*.sh find a live
    # processor by this application_name; if the driver stops sending it, those scripts go
    # back to TRUNCATEing under a live writer. Mutation testing found this untested:
    # deleting it from the URI left all 42 tests passing.
    assert "application_name=haf_stats_block_processing" in argv

    # Empty on purpose, and asserted as an exact token: the startup timestamp is ours, from
    # the DATABASE clock, and the driver's own marker would be the container clock -- the
    # fail-open timezone bug the timestamp block near the top of the script exists to
    # avoid. A substring test also passes for `--startup-marker=/tmp/...`, which is that
    # bug reinstated.
    assert "--startup-marker=" in argv.split()
    assert "CALL haf_stats_app.main" not in sql.read_text(encoding="utf-8")


def test_a_row_without_an_entry_procedure_is_not_enough(bash, tmp_path):
    """haf_app_driver.py has two fatal pre-first-range exits, not one: unregistered, and
    registered-but-self-driven. The probe asks for process_procedure IS NOT NULL so the
    second is not mistaken for a usable registration."""
    sql, _ = make_psql_with_registry(tmp_path, has_table=True, registered=False)
    driver = make_driver(tmp_path)
    run(bash, tmp_path, startup_file=tmp_path / "startup.txt")

    assert not driver.exists()
    assert "process_procedure IS NOT NULL" in sql.read_text(encoding="utf-8")
    assert "CALL haf_stats_app.main" in sql.read_text(encoding="utf-8")


def test_a_probe_that_errors_falls_back(bash, tmp_path):
    """Every psql failure in the probe is swallowed, so an ERRORING probe must not be read
    as a usable registry.

    Not an unreachable database, despite what an earlier name here said: the startup
    timestamp query runs first under `set -euo pipefail`, so an unreachable database kills
    the script long before the probe. This is the permission-denied / statement-timeout
    shape.
    """
    sql, _ = make_psql_with_registry(tmp_path, probe_fails=True)
    driver = make_driver(tmp_path)
    run(bash, tmp_path, startup_file=tmp_path / "startup.txt")

    assert not driver.exists()
    assert "CALL haf_stats_app.main" in sql.read_text(encoding="utf-8")


@pytest.mark.parametrize("spelling", ["true", "TRUE", "True", "1", "yes", "on"])
def test_the_legacy_override_wins_over_a_live_registry(bash, tmp_path, spelling):
    """A typo must fail toward the loop the operator asked for, not silently back to the
    driver -- the convention install_app.sh states for its own flags."""
    sql, _ = make_psql_with_registry(tmp_path)
    driver = make_driver(tmp_path)
    run(bash, tmp_path, startup_file=tmp_path / "startup.txt",
        env_extra={"HAF_STATS_USE_LEGACY_LOOP": spelling})

    assert not driver.exists(), f"{spelling!r} did not force the legacy loop"
    assert "CALL haf_stats_app.main" in sql.read_text(encoding="utf-8")


def test_the_legacy_loop_tags_its_session_for_the_rebuild_guard(bash, tmp_path):
    """scripts/rebuild_*.sh refuse to TRUNCATE while a processor is connected, and find it
    by application_name. The driver sets that through its connection URI; the legacy loop
    has to set it here or it is matched by query text alone."""
    sql, appnames = make_psql_with_registry(tmp_path, has_table=False)
    make_driver(tmp_path)
    run(bash, tmp_path, startup_file=tmp_path / "startup.txt")

    calls = sql.read_text(encoding="utf-8").split("---\n")
    tags = appnames.read_text(encoding="utf-8").splitlines()
    assert len(tags) == len([c for c in calls if c.strip()])
    main_index = next(i for i, c in enumerate(calls) if "CALL haf_stats_app.main" in c)
    assert tags[main_index] == "haf_stats_block_processing"
    # And NOT before: the probe and the startup-timestamp queries must not look like a
    # running block processor to the rebuild guard.
    assert all(t != "haf_stats_block_processing" for t in tags[:main_index])
