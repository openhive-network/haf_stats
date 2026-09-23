"""GET /version has to identify the commit, or say plainly that it cannot (#76).

A hand-built image used to bake the literal `unknown` into `app_version`, which
`get_version()` and `get_health.version` then reported with exactly the authority of a
real commit. It was found on a live node by comparing against the pre-deploy value;
nothing in the repository documented a build command at all, and no test covered any of
it.

THESE TESTS RUN THE REAL LINES rather than searching the files for strings. The first
revision of this module did the latter and mutation testing took it apart: 16 of 31
mutations survived, including the two that matter most -- the `RUN` line baking the
literal `unknown` again, and the installer's warning block deleted outright -- because in
both cases the strings being asserted on still existed in a COMMENT. A test that passes
with the original bug reinstated is worse than no test, because CI keeps reporting green
over the regression.

So: the `RUN` line is extracted from the Dockerfile and executed; the installer's guard is
extracted and executed; and the README is checked on the `docker build` LINE, not on the
prose around it, which repeats both flags and made the command itself unfalsifiable.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import require_bash

REPO = Path(__file__).resolve().parents[2]
PLACEHOLDER = "unspecified"
TIMEOUT = 15


@pytest.fixture
def bash():
    return require_bash()


def _read(*parts: str) -> str:
    """Read at call time, not import time.

    This module used to read four files at module scope -- the only one in tests/unit/
    that did -- so renaming any of them turned a single failure into
    `Interrupted: 1 error during collection` and stopped the whole unit suite.
    """
    return (REPO.joinpath(*parts)).read_text(encoding="utf-8")


# --- the Dockerfile's RUN line, actually run ---------------------------------------

def _bake(bash: str, tmp_path: Path, git_hash: str | None) -> str:
    """Execute the Dockerfile's real version.sql RUN line and return what it wrote.

    `docker build` sets ARG values as environment variables for the RUN shell, so running
    the same command under bash with GIT_HASH set (or not) reproduces the build exactly,
    without docker, a daemon or a network.
    """
    dockerfile = _read("Dockerfile")
    match = re.search(r"^RUN (.*?> /app/db/version\.sql)\s*$", dockerfile, re.M | re.S)
    assert match, "Dockerfile no longer has a RUN that writes /app/db/version.sql"

    out = tmp_path / "version.sql"
    # Un-fold the line continuations, then redirect to somewhere writable.
    script = match.group(1).replace("\\\n", " ")
    script = script.replace("> /app/db/version.sql", f"> {out.as_posix()}")

    env = {"PATH": "/usr/bin:/bin"}
    if git_hash is not None:
        env["GIT_HASH"] = git_hash
    result = subprocess.run([bash, "-c", script], env=env, capture_output=True,
                            text=True, timeout=TIMEOUT)
    assert result.returncode == 0, result.stderr
    return out.read_text(encoding="utf-8")


def test_a_build_with_no_argument_bakes_the_placeholder(bash, tmp_path):
    """The bug: an absent --build-arg produced a value that read like a real commit."""
    sql = _bake(bash, tmp_path, None)
    assert f"VALUES ('{PLACEHOLDER}')" in sql, sql
    assert "unknown" not in sql, "the placeholder is back to reading like a chosen value"


def test_an_empty_argument_also_bakes_the_placeholder(bash, tmp_path):
    """`--build-arg GIT_HASH=` is set-but-empty, which `${VAR-default}` would let through."""
    sql = _bake(bash, tmp_path, "")
    assert f"VALUES ('{PLACEHOLDER}')" in sql, sql


def test_a_real_hash_is_baked_verbatim(bash, tmp_path):
    sql = _bake(bash, tmp_path, "0dbc914b")
    assert "VALUES ('0dbc914b')" in sql, sql
    assert PLACEHOLDER not in sql


def test_a_whitespace_only_argument_is_treated_as_unset(bash, tmp_path):
    """scripts/common.sh refuses whitespace-only POSTGRES_* values for the same reason:
    "the same operator error, opposite verdicts, depending only on which channel it
    arrived through"."""
    sql = _bake(bash, tmp_path, "   ")
    assert f"VALUES ('{PLACEHOLDER}')" in sql, sql


@pytest.mark.parametrize("hostile", [
    "v1'; DROP SCHEMA haf_stats_app CASCADE; --",   # closes the literal
    "x') ; SELECT 1; --",
    "has space",
    'has"quote',
])
def test_a_value_that_is_not_hash_shaped_is_rejected_outright(bash, tmp_path, hostile):
    """This is interpolated into SQL that install_app runs as haf_admin, and git refs
    permit quotes -- so `$(git describe --tags)` of an oddly-named tag reaches it.

    Rejected, not scrubbed: a half-cleaned value would be served by GET /version as though
    someone had chosen it, which is the bug this whole change removes.
    """
    sql = _bake(bash, tmp_path, hostile)
    assert f"VALUES ('{PLACEHOLDER}')" in sql, sql
    # One statement, one literal: nothing from the argument escaped into the SQL.
    assert sql.count(";") == 2, sql
    assert "DROP SCHEMA" not in sql, sql


def test_the_build_argument_does_not_default_to_a_plausible_value():
    """Every declaration, not just the first: ARG must be re-declared per build stage, so
    a multi-stage Dockerfile can carry more than one."""
    declarations = re.findall(r"^ARG GIT_HASH(?:=(.*))?$", _read("Dockerfile"), re.M)
    assert declarations, "Dockerfile no longer declares ARG GIT_HASH"
    for raw in declarations:
        default = (raw or "").strip().strip('"').strip("'")
        assert default == "", f"GIT_HASH defaults to {default!r}, which will be served as a version"


# --- the installer's guard, actually run --------------------------------------------

def _run_guard(bash: str, recorded: str) -> str:
    """Execute the installer's real placeholder guard with a given recorded version."""
    install = _read("scripts", "install_app.sh")
    match = re.search(r"^(if \[ \"\$\{_installed_version\}\".*?^fi)$", install, re.M | re.S)
    assert match, "install_app.sh no longer guards on _installed_version"

    script = (
        "log() { echo \"[haf_stats] $*\"; }\n"
        f"_installed_version={recorded!r}\n" + match.group(1) + "\n"
    ).replace("'", "'", 1)
    result = subprocess.run([bash, "-c", script], capture_output=True, text=True,
                            timeout=TIMEOUT)
    assert result.returncode == 0, result.stderr
    return result.stdout


def test_the_installer_warns_on_the_placeholder(bash):
    out = _run_guard(bash, PLACEHOLDER)
    assert "WARNING" in out, out
    # And says how to fix it -- asserted on the build command itself, because the sentence
    # naming the problem also contains the flag name.
    assert "docker build --build-arg GIT_HASH=" in out, out


def test_the_installer_is_silent_on_a_real_hash(bash):
    assert _run_guard(bash, "0dbc914b").strip() == ""


def test_the_installer_is_silent_when_nothing_was_recorded(bash):
    """No version.sql at all (a dev checkout) is not the same fault and must not warn."""
    assert _run_guard(bash, "").strip() == ""


def test_the_installer_warns_on_a_hash_that_is_not_ci_width(bash):
    """The state every already-hand-built node is in, including one of ours: a 7-character
    hash matches no registry tag, and the placeholder guard alone would never mention it."""
    out = _run_guard(bash, "0dbc914")
    assert "WARNING" in out, out
    assert "--short=8" in out, out


def test_the_installer_reports_the_value_it_recorded():
    install = _read("scripts", "install_app.sh")
    assert 'Recorded version: ${_installed_version' in install, \
        "the log line no longer interpolates the recorded value"
    # LIMIT 1 specifically. app_version has no singleton unique index (its two sibling
    # control tables do), so more than one row makes the substitution a newline-joined
    # string: the log line splits, and the placeholder comparison below goes false even
    # when the placeholder IS what is recorded -- silencing the warning in the one case it
    # exists for. get_version() and get_health compensate the same way.
    assert "SELECT git_hash FROM haf_stats_app.app_version LIMIT 1" in install, \
        "the recorded-version query lost its LIMIT 1"


# --- the README's command, checked as a command -------------------------------------

def _build_command_lines() -> list[str]:
    """Only lines that ARE the command. The prose around it repeats both flags, which is
    how a command stripped of both once passed this file."""
    return [line.strip() for line in _read("README.md").splitlines()
            if line.strip().startswith("docker build")]


def test_the_readme_documents_a_build_command():
    assert _build_command_lines(), "README documents no docker build command"


def test_the_documented_command_passes_the_build_argument():
    assert all("--build-arg GIT_HASH" in line for line in _build_command_lines()), \
        _build_command_lines()


def test_the_documented_command_uses_the_ci_width():
    """CI passes CI_COMMIT_SHORT_SHA, a fixed EIGHT characters. git's --short is `auto`
    (7 today for this repo, and it grows), so the width has to be explicit or a hand-build
    cannot be matched to a registry tag."""
    for line in _build_command_lines():
        if "rev-parse" in line:
            assert "--short=8" in line, line


def test_the_placeholder_is_the_same_string_everywhere_it_is_named():
    """The drift that would silence the warning without failing anything."""
    for where in (("Dockerfile",), ("scripts", "install_app.sh"), ("README.md",)):
        assert PLACEHOLDER in _read(*where), f"{'/'.join(where)} does not name the placeholder"


def test_ci_still_passes_the_real_commit():
    """If this is ever 'simplified' away, every published image reports the placeholder."""
    ci = _read(".gitlab-ci.yml")
    # Both quotings: `--build-arg GIT_HASH="$VAR"` and `--build-arg "GIT_HASH=$VAR"` mean
    # the same thing to docker, and a test that fails on the second is a trap for whoever
    # reformats the line correctly.
    assert re.search(r'--build-arg\s+"?GIT_HASH="?\$CI_COMMIT_SHORT_SHA"?', ci), \
        "CI no longer passes the commit into the build"
