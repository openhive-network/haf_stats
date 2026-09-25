"""GET /version has to identify the commit, or say plainly that it cannot (#76).

A hand-built image used to bake the literal `unknown` into `app_version`, which
`get_version()` and `get_health.version` then reported with exactly the authority of a
real commit. It was found on a live node by comparing against the pre-deploy value;
nothing in the repository documented a build command at all, and no test covered any of
it.

WHEREVER A TEST CAN RUN THE REAL LINES, IT DOES rather than searching the files for
strings. The first revision of this module did the latter and mutation testing took it
apart: 16 of 31 mutations survived, including the two that matter most -- the `RUN` line
baking the literal `unknown` again, and the installer's warning block deleted outright --
because in both cases the strings being asserted on still existed in a COMMENT. A test
that passes with the original bug reinstated is worse than no test, because CI keeps
reporting green over the regression.

The claim is deliberately not absolute, because some of this file cannot be executed: the
Dockerfile's `ARG` declaration, the README, and `.gitlab-ci.yml` are declarations, not
code. Those are pinned as WHOLE EXPRESSIONS or whole command lines, with comments stripped
first, so a comment cannot satisfy them -- which is the property that matters, not
execution as such. A second review round found three that still reached around the thing
they checked; see the comments on `_bake`, `_run_guard` and the CI check.

So: the `RUN` line is extracted from the Dockerfile and executed; the installer's guard is
extracted and executed; and the README is checked on the `docker build` LINE, not on the
prose around it, which repeats both flags and made the command itself unfalsifiable.
"""

from __future__ import annotations

import re
import subprocess

from tests.unit.shell_harness import sh_quote
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

    # THE DECLARED DEFAULT, not an unset variable. `docker build` with no --build-arg
    # does not leave GIT_HASH unset in the RUN's environment: it supplies whatever the
    # `ARG GIT_HASH=<default>` line declares. Modelling the no-argument case as "unset"
    # left the link between the declaration and the RUN untested, and an added
    # `ENV GIT_HASH=${GIT_HASH:-unknown}` -- bug #76, verbatim -- kept all 19 tests green.
    env = {"PATH": "/usr/bin:/bin"}
    env["GIT_HASH"] = _declared_default() if git_hash is None else git_hash
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


# ONE forbidden character per fixture, plus the realistic compound ones. Every fixture
# here used to carry two (a quote AND a space), so widening the pattern to admit a single
# quote -- `*[!A-Za-z0-9._\'-]*` -- left all of them still rejected and the suite green,
# while `--build-arg GIT_HASH="a'"` then baked VALUES ('a'') and failed every install.
# The same blind spot covered the classic bracket-range slip, `[!A-Za-z0-9.-_]`, where
# `.-_` becomes a RANGE (0x2E-0x5F) and quietly admits ; \ [ ] = < > ? @ ^.
@pytest.mark.parametrize("hostile", [
    "v1'; DROP SCHEMA haf_stats_app CASCADE; --",   # closes the literal
    "x') ; SELECT 1; --",
    "has space",
    'has"quote',
    "'",                                            # one class per fixture, from here
    '"',
    ";",
    "|",
    " ",
    "]",
    "[",
    "=",
    "<",
    "$",
    "`",
    "\\",
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


def _declared_default() -> str:
    """The value `docker build` puts in the RUN's environment when no --build-arg is
    passed: the last `ARG GIT_HASH=` declaration before the RUN, unquoted."""
    declarations = re.findall(r"^ARG GIT_HASH(?:=(.*))?$", _read("Dockerfile"), re.M)
    assert declarations, "Dockerfile no longer declares ARG GIT_HASH"
    return (declarations[-1] or "").strip().strip('"').strip("'")


def test_nothing_else_establishes_git_hash_for_the_build():
    """`ARG` is not the only way to put GIT_HASH in the RUN's environment -- `ENV` does it
    too, and wins. Without this, `ENV GIT_HASH=${GIT_HASH:-unknown}` after the ARG
    reinstates the exact defect #76 exists to close: --build-arg still works, so every
    behavioural test passes, while a hand-build with no argument bakes `unknown` again."""
    dockerfile = _read("Dockerfile")
    run_at = dockerfile.index("RUN case")
    before = dockerfile[:run_at]
    offenders = [line for line in before.splitlines()
                 if re.match(r"^\s*ENV\s+.*\bGIT_HASH\b", line)]
    assert not offenders, (
        "an ENV sets GIT_HASH before the RUN, which overrides the ARG default the "
        "no-argument test relies on: %r" % offenders)


def test_the_build_argument_does_not_default_to_a_plausible_value():
    """Every declaration, not just the first: ARG must be re-declared per build stage, so
    a multi-stage Dockerfile can carry more than one."""
    declarations = re.findall(r"^ARG GIT_HASH(?:=(.*))?$", _read("Dockerfile"), re.M)
    assert declarations, "Dockerfile no longer declares ARG GIT_HASH"
    for raw in declarations:
        default = (raw or "").strip().strip('"').strip("'")
        assert default == "", f"GIT_HASH defaults to {default!r}, which will be served as a version"


# --- the installer's guard, actually run --------------------------------------------

def _run_guard(bash: str, recorded: str = "", rc: int = 0) -> str:
    """Execute the installer's version reporting **in its real control flow**.

    The whole contiguous span is extracted -- the `if _installed_version="$(psql_cmd ...)"`
    reader AND the warning block that follows -- rather than the warning block alone, and
    `psql_cmd` is stubbed instead of `_installed_version` being injected. Both details are
    load-bearing, and mutation testing is what showed it:

      - Lifting the warning block out meant a mutation appending `_installed_version=""`
        after the reader survived: the warning could then never fire on any node.
      - It also meant wrapping the entire guard in `if [ "${SOMETHING}" = "0" ]` survived,
        because the regex still found the inner block while the guard was dead in
        production. The span is anchored at column zero, so that wrapping now indents it
        and the assertion below fires.
      - Stubbing psql_cmd rather than the variable is what lets the "query failed" and
        "no row" arms be exercised at all; they were previously covered only by a string
        search for their message text, which a comment satisfies.
    """
    install = _read("scripts", "install_app.sh")
    # Sliced, not matched with a non-greedy regex: `.*?^fi` stops at the READER's `fi` and
    # silently drops the warning block, which is most of the point.
    reader = '\nif _installed_version="$(psql_cmd'
    warning = '\nif [ "${_installed_version}" = "unspecified" ]'
    assert reader in install, (
        "install_app.sh no longer reads the recorded version at column zero -- either the "
        "block moved, or it is nested inside another construct, which would make it "
        "conditional in production while this extraction still found it")
    start = install.index(reader) + 1
    assert warning in install[start:], (
        "the placeholder warning no longer follows the reader at column zero")
    after_warning = install.index(warning, start) + 1
    end = install.index("\nfi\n", after_warning) + len("\nfi\n")
    span = install[start:end]
    # Everything between the two `if`s comes along, so a mutation appending
    # `_installed_version=""` after the reader is executed rather than skipped.
    assert span.count("\nfi\n") == 2, span

    script = (
        'log() { echo "[haf_stats] $*"; }\n'
        "psql_cmd() { printf '%s' " + sh_quote(recorded) + "; return " + str(rc) + "; }\n"
        + span + "\n"
    )
    result = subprocess.run([bash, "-c", script], capture_output=True, text=True,
                            timeout=TIMEOUT)
    assert result.returncode == 0, result.stderr
    return result.stdout


EXPECTED_VERSION_QUERY = "SELECT git_hash FROM haf_stats_app.app_version LIMIT 1"


def _version_query() -> str:
    """The SQL the reader actually sends, comments stripped and whitespace flattened."""
    install = _read("scripts", "install_app.sh")
    line = install[install.index('if _installed_version="$(psql_cmd'):].split("\n", 1)[0]
    # First closing quote, not the last: the line ends `..."); then`, so rsplit kept the
    # trailing `")`. The query itself contains no double quote.
    return line.split('-c "', 1)[1].split('"', 1)[0].strip()


def test_the_reader_asks_for_one_row():
    """`_run_guard` stubs psql_cmd, so the QUERY is the one thing it cannot check -- and a
    mutation dropping `LIMIT 1` while leaving the text in a comment above it survived the
    whole suite. app_version is the only control table in db/haf_stats_app.sql without a
    singleton unique index, so a duplicated row makes the reader return two lines and the
    guard take the width arm, warning about a mangled string rather than the real fault."""
    assert _version_query() == EXPECTED_VERSION_QUERY


def test_the_baked_file_is_loaded_into_the_database():
    """The one line connecting the build to the endpoint: db/version.sql is generated by
    the Docker build, and this is what puts it in app_version. Commenting it out left the
    whole module green while GET /version reported whatever the previous install wrote.
    Comments stripped first, so a commented-out call cannot satisfy this."""
    live = [l.split("#", 1)[0].strip()
            for l in _read("scripts", "install_app.sh").splitlines()]
    assert 'run_sql_file "${SCRIPT_DIR}/../db/version.sql"' in live, (
        "install_app.sh no longer loads the baked version.sql")


def test_a_failed_version_query_is_not_reported_as_a_version(bash):
    """A non-zero psql must read as a failure, not as a version -- and must not go on to
    warn about the width of something it never read. Covered only by a string search for
    the message text before, which a comment satisfies."""
    out = _run_guard(bash, recorded="", rc=2)
    assert "could not be read" in out, out
    assert "WARNING" not in out, out





def test_the_installer_warns_on_the_placeholder(bash):
    out = _run_guard(bash, PLACEHOLDER)
    assert "WARNING" in out, out
    # And says how to fix it -- asserted on the build command itself, because the sentence
    # naming the problem also contains the flag name.
    assert "docker build --build-arg GIT_HASH=" in out, out


def test_the_installer_is_silent_on_a_real_hash(bash):
    """Silent means DOES NOT WARN. The reader is inside the extracted span now, so the
    install log always carries a `Recorded version:` line -- asserting on total silence
    would only have held while the reader was excluded, which is the defect that let a
    mutation appending `_installed_version=""` survive."""
    out = _run_guard(bash, "0dbc914b")
    assert "Recorded version: 0dbc914b" in out, out
    assert "WARNING" not in out, out


def test_the_installer_is_silent_when_nothing_was_recorded(bash):
    """No version.sql at all (a dev checkout) is not the same fault and must not warn."""
    out = _run_guard(bash, "")
    assert "no row in app_version" in out, out
    assert "WARNING" not in out, out


@pytest.mark.parametrize("recorded", [
    "0dbc914",                                   # `git rev-parse --short` today: seven
    "0dbc914b3a2f1e0d9c8b7a6f5e4d3c2b1a099887",  # plain `git rev-parse HEAD`: forty
    "0dbc914b9",                                 # `--short=8` where the prefix collides
    "unknown",                                   # the legacy placeholder, pre-#76 images
    "1.29.0-rc2",                                # someone passing a tag
])
def test_the_installer_warns_on_anything_that_is_not_a_ci_width_hash(bash, recorded):
    """The anchors on `^[0-9a-f]{8}$` are load-bearing and were unpinned: the suite only
    ever fed seven characters, so dropping `^`/`$` -- which makes a 40-character SHA and a
    9-character abbreviation pass -- survived. `unknown` is here because it is the state of
    every image built before #76, and nothing fed it."""
    out = _run_guard(bash, recorded)
    assert "WARNING" in out, out
    assert recorded in out, out


def test_the_installer_warns_on_a_hash_that_is_not_ci_width(bash):
    """The state every already-hand-built node is in, including one of ours: a 7-character
    hash matches no registry tag, and the placeholder guard alone would never mention it."""
    out = _run_guard(bash, "0dbc914")
    assert "WARNING" in out, out
    assert "--short=8" in out, out


def _build_command_lines() -> list[str]:
    """Only lines that ARE the command. The prose around it repeats both flags, which is
    how a command stripped of both once passed this file."""
    return [line.strip() for line in _read("README.md").splitlines()
            if line.strip().startswith("docker build")]


def test_the_readme_documents_a_build_command():
    assert _build_command_lines(), "README documents no docker build command"


def test_the_documented_command_passes_the_build_argument():
    """Scoped to the APP image. `all()` over every `docker build` line in the README was a
    trap for a correct change: the rewriter is a second image built from
    Dockerfile.rewriter, and it takes no GIT_HASH, so documenting it turned this red."""
    app_build = [l for l in _build_command_lines() if "Dockerfile.rewriter" not in l]
    assert app_build, _build_command_lines()
    assert all("--build-arg GIT_HASH" in line for line in app_build), app_build


def test_the_documented_command_uses_the_ci_width():
    """CI passes CI_COMMIT_SHORT_SHA: unconditionally the FIRST EIGHT characters of the
    SHA. The whole expression is pinned, not a token in it, because both halves matter and
    either can be removed without the other noticing:

      - `--short=8` is NOT a width. `--short=N` is a minimum; git extends the abbreviation
        until it is unambiguous in the reader's clone (`--short=3` returns four characters
        in this repository today). In a clone where the eight-character prefix collides it
        bakes nine or more, which matches no registry tag AND trips install_app's own width
        warning -- while the operator followed the README exactly.
      - A `rev-parse`-guarded assertion is vacuous by construction: deleting `rev-parse`
        from the line satisfies it. That is how `--build-arg GIT_HASH="$MY_HASH"` passed.
    """
    lines = _build_command_lines()
    app_build = [l for l in lines if "Dockerfile.rewriter" not in l]
    assert app_build, lines
    for line in app_build:
        assert '--build-arg GIT_HASH="$(git rev-parse HEAD | cut -c1-8)"' in line, line


def test_the_placeholder_is_the_same_string_everywhere_it_is_named():
    """The drift that would silence the warning without failing anything."""
    for where in (("Dockerfile",), ("scripts", "install_app.sh"), ("README.md",)):
        assert PLACEHOLDER in _read(*where), f"{'/'.join(where)} does not name the placeholder"


def test_ci_still_passes_the_real_commit():
    """If this is ever 'simplified' away, every published image reports the placeholder."""
    # Comments stripped FIRST. `# - docker build --build-arg GIT_HASH="$CI_COMMIT_SHORT_SHA"`
    # satisfied the regex while the real build line no longer passed anything, so the one
    # check standing between develop and a fleet of `unspecified` images was green.
    ci = "\n".join(line for line in _read(".gitlab-ci.yml").splitlines()
                   if not line.lstrip().startswith("#"))
    # Both quotings: `--build-arg GIT_HASH="$VAR"` and `--build-arg "GIT_HASH=$VAR"` mean
    # the same thing to docker, and a test that fails on the second is a trap for whoever
    # reformats the line correctly.
    assert re.search(r'--build-arg\s+"?GIT_HASH="?\$CI_COMMIT_SHORT_SHA"?', ci), \
        "CI no longer passes the commit into the build"
