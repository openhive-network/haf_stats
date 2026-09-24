"""Shared helpers for the shell-script test suites (#57).

A module rather than a conftest.py so the helpers are imported explicitly by the
suites that use them, and nothing is injected implicitly into unrelated tests.
"""

from __future__ import annotations

import os
import shutil

import pytest

# On Linux -- CI, and the containers these scripts actually run in -- this resolves to
# /bin/bash and the override is never used. It exists for Windows developer machines,
# where `bash` on PATH resolves to WSL's bash.exe, which cannot execute a script from a
# Windows path or see a stub's executable bit. Point HAF_STATS_TEST_BASH at Git Bash there.
BASH = os.environ.get("HAF_STATS_TEST_BASH") or shutil.which("bash")


def require_bash() -> str:
    """Resolve bash, or decide whether its absence is a skip or a failure.

    Skipping on a developer machine is a convenience. Skipping in CI would be a hole:
    if bash ever left the test image, every shell test would quietly stop running and
    the pipeline would stay green with these scripts uncovered -- exactly the silent
    rot they exist to prevent. So CI fails instead of skipping.
    """
    if BASH is not None:
        return BASH
    if os.environ.get("CI"):
        pytest.fail("bash is unavailable, so the shell-script tests cannot run in CI")
    pytest.skip("bash is required to run the shell-script tests")
    raise AssertionError("unreachable")  # pragma: no cover


def write_exec(path, body: str) -> None:
    """Write an executable /bin/sh stub with LF line endings.

    newline="\\n" is load-bearing on Windows: default text mode writes CRLF, the
    shebang becomes `#!/bin/sh\\r`, and the stub either fails to exec or emits output
    carrying stray carriage returns that the script under test then parses. A test that
    passes because of a \\r is worse than one that fails.
    """
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(body)
    os.chmod(path, 0o755)


def sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def clean_env(bindir=None) -> dict:
    """os.environ minus anything that would steer the scripts under test.

    Inheriting the ambient environment wholesale means a developer with, say,
    HAF_STATS_HEALTHCHECK_MAX_AGE_SECONDS exported gets failures unrelated to their
    change. Stripping the app's own variables makes each test state its own inputs.
    """
    # PG* too, as of haf_stats#75: scripts/uninstall_app.sh now READS PGHOSTADDR,
    # PGSERVICE and PGSERVICEFILE, and libpq itself reads PGHOST/PGUSER/PGDATABASE/
    # PGOPTIONS. A developer with any of those exported would otherwise steer the scripts
    # under test: the redirect NOTE would print on every run, so the negative control that
    # asserts it is ABSENT would fail on their machine and pass in CI -- a test that
    # depends on the developer's shell, which is the thing this helper exists to prevent.
    # (An earlier revision of this comment had it backwards, saying such a control would
    # "silently pass".) Tests that want one inject it explicitly through env_extra.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("HAF_STATS_")
           and not k.startswith("POSTGRES_")
           and not k.startswith("PG")}
    if "HAF_STATS_TEST_BASH" in os.environ:
        env["HAF_STATS_TEST_BASH"] = os.environ["HAF_STATS_TEST_BASH"]
    if bindir is not None:
        env["PATH"] = f"{bindir}{os.pathsep}{env.get('PATH', '')}"
    return env


def stub_bin(tmp_path):
    """A bin/ directory on PATH holding a pg_isready that always succeeds.

    EVERY invocation of install_app.sh / uninstall_app.sh / process_blocks.sh needs
    this, including ones expected to exit at the option loop. Those scripts call
    wait_for_postgres -- an unbounded `until pg_isready; do sleep 2; done` -- so a
    regression that lets an argument fall through does not fail the test, it HANGS it.
    subprocess timeouts do not reliably rescue that: the orphaned `sleep` keeps the
    captured pipe open, so `subprocess.run(..., timeout=N)` can block well past N. A CI
    job that burns to the project timeout and reports "job timeout" rather than a diff
    is barely better than no test at all.
    """
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    write_exec(bindir / "pg_isready", "#!/bin/sh\nexit 0\n")
    return bindir
