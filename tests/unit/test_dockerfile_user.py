"""The app image must not run as root (#64).

The behavioural check is scripts/ci-helpers/check_runtime_user.sh, which the docker-build
smoke test runs INSIDE the built image (and against mutant images it must reject). This
file pins the Dockerfile's declarations, so a regression names the line rather than
surfacing as "running as 0:0" after a build.

The parser follows Docker's rules closely enough to be trusted, and REFUSES what it does
not model rather than guessing:
  * comments and blank lines are dropped, including inside a continuation (Docker does
    the same), so prose about `USER root` can neither satisfy nor fail a check;
  * a continuation is `\\` followed by optional trailing whitespace, as in Docker;
  * keywords are case-insensitive: a trailing lowercase `user 0` is a real USER;
  * heredocs (`RUN <<EOF`) and an `# escape=` parser directive are refused outright --
    a heredoc body parsed as instructions could hide anything;
  * only the FINAL build stage (after the last FROM) counts for USER, the user-creation
    RUN and the tail rule: a later bare `FROM alpine` stage is what actually ships.

Every check is a function from Dockerfile text to a list of problems, so the mutation
tests at the bottom run the same checks against edited copies of the real file.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
UID = "10001"
REAL = (ROOT / "Dockerfile").read_text(encoding="utf-8")


class DockerfileParseError(ValueError):
    """Syntax this parser deliberately does not model."""


_CONTINUATION = re.compile(r"\\[ \t]*$")
_HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*[\"']?[A-Za-z_]")


def _instructions(text: str) -> list[tuple[str, str]]:
    """(KEYWORD, arguments) per instruction, in order."""
    lines = text.splitlines()
    if lines and re.match(r"#\s*escape\s*=", lines[0], re.I):
        raise DockerfileParseError("an `# escape=` parser directive is not supported")
    out: list[tuple[str, str]] = []
    cur: str | None = None
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue  # comment or blank line, also inside a continuation
        cur = raw if cur is None else f"{cur} {raw}"
        if _CONTINUATION.search(cur):
            cur = _CONTINUATION.sub("", cur)
            continue
        out.append(_split(cur))
        cur = None
    if cur is not None:
        out.append(_split(cur))
    return out


def _split(instruction: str) -> tuple[str, str]:
    m = re.match(r"\s*([A-Za-z]+)(?:\s+(.*))?$", instruction)
    if not m:
        raise DockerfileParseError(f"cannot parse instruction: {instruction!r}")
    keyword, args = m.group(1).upper(), (m.group(2) or "").strip()
    if _HEREDOC.search(args):
        raise DockerfileParseError(f"heredocs are not supported: {instruction!r}")
    return keyword, args


def _final_stage(text: str) -> list[tuple[str, str]]:
    instructions = _instructions(text)
    froms = [i for i, (k, _) in enumerate(instructions) if k == "FROM"]
    if not froms:
        raise DockerfileParseError("no FROM instruction")
    return instructions[froms[-1] + 1:]


def final_user_problems(text: str) -> list[str]:
    users = [a for k, a in _final_stage(text) if k == "USER"]
    if not users:
        return ["no USER in the final stage; the base image's would apply"]
    # Numeric so runAsNonRoot can verify it without resolving a name.
    if users[-1] != f"{UID}:{UID}":
        return [f"final USER is {users[-1]!r}, want {UID}:{UID}"]
    return []


def user_creation_problems(text: str) -> list[str]:
    stage = _final_stage(text)
    create = [a for k, a in stage if k == "RUN" and "adduser" in a]
    if len(create) != 1:
        return [f"expected one RUN creating the runtime user in the final stage, got {create}"]
    run, problems = create[0], []
    if not re.search(rf"\baddgroup\b[^&]*-g {UID}\b[^&]*\bhaf_stats\b", run):
        problems.append(f"addgroup does not create haf_stats with gid {UID}: {run}")
    if not re.search(rf"\badduser\b[^&]*-u {UID}\b[^&]*-G haf_stats\b", run):
        problems.append(f"adduser does not create uid {UID} in haf_stats: {run}")
    # No home directory: a runtime-owned home is a Python user-site code path.
    if not re.search(r"\badduser\b[^&]*\s-H\s[^&]*-h /nonexistent\s", run):
        problems.append(f"adduser must use -H and -h /nonexistent (no home): {run}")
    # COPY keeps the build context's modes: CI checks out world-writable (umask 0000),
    # and openapi-drift leaves endpoints/rewrite_rules.conf 0600 in a reused build dir.
    if not re.search(r"\bchmod -R u=rwX,go=rX /app$", run):
        problems.append(f"no `chmod -R u=rwX,go=rX /app` after the copies: {run}")
    # The base image ships /usr/local/bin/haf_app_driver.py (exec'd from PATH by
    # process_blocks.sh) and two siblings as 0777.
    if not re.search(r"for d in [^;]*/usr/local/bin\b[^;]*; do .*"
                     r"-perm -0002 -o -perm -0020 .*-exec chmod go-w \{\} \+", run):
        problems.append(f"no group/other-write strip over the PATH directories: {run}")
    if not any(k == "ENV" and re.fullmatch(r"PYTHONNOUSERSITE[= ]1", a) for k, a in stage):
        problems.append("final stage does not set ENV PYTHONNOUSERSITE=1")
    return problems


# chmod granting group/other WRITE. Symbolic: a clause (start of the mode or after a
# comma) whose who-list includes g, o or a -- or is empty, which means a -- with `+` or
# `=` and a w among the perms: o+w, a+rw, go=rwX, u=rwX,go=rwX, +w, =rw. Octal: a group
# or other digit carrying the write bit (2, 3, 6, 7).
_CHMOD_GROUP_OTHER_WRITE = re.compile(
    r"\bchmod\b[^&;|]*?"
    r"(?:[\s,](?:[ugoa]*[ago][ugoa]*|)[+=][rwxXst]*w"
    r"|\s[0-7]?[0-7](?:[2367][0-7]|[0-7][2367])\b)")


def privilege_problems(text: str) -> list[str]:
    """No instruction may hand the runtime user sudo or ownership of anything.

    EVERY RUN is scanned, not just the adduser one: a separate
    `RUN echo "haf_stats ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers` is the same hole."""
    problems = []
    for k, a in _instructions(text):
        if k == "RUN" and re.search(r"sudo|wheel|\bchown\b", a, re.I):
            problems.append(f"RUN touches sudo/wheel/chown: {a}")
        if k == "RUN" and _CHMOD_GROUP_OTHER_WRITE.search(a):
            problems.append(f"RUN chmod grants group/other write: {a}")
        if k in ("COPY", "ADD") and re.search(r"--chown\b", a, re.I):
            problems.append(f"{k} --chown hands files to a non-root owner: {a}")
    return problems


def tail_problems(text: str) -> list[str]:
    """The user-creation/chmod RUN must be the LAST build step.

    Anything after it escapes the chmod: a COPY lands files with the build context's
    modes (world-writable on CI), whether it sits before or after the final USER, and a
    RUN after the USER runs as 10001."""
    instructions = _final_stage(text)
    create = [i for i, (k, a) in enumerate(instructions) if k == "RUN" and "adduser" in a]
    if not create:
        return []  # user_creation_problems reports this
    return [f"{k} after the user-creation/chmod RUN: {a}"
            for k, a in instructions[create[-1] + 1:] if k in ("RUN", "COPY", "ADD")]


CHECKS = [final_user_problems, user_creation_problems, privilege_problems, tail_problems]


def all_problems(text: str) -> list[str]:
    try:
        return [p for check in CHECKS for p in check(text)]
    except DockerfileParseError as e:
        return [f"refused: {e}"]


@pytest.mark.parametrize("check", CHECKS, ids=lambda c: c.__name__)
def test_real_dockerfile(check):
    assert check(REAL) == []


# --- mutations: the same checks must reject each of these edits of the real file -------

def _append(line: str) -> str:
    return REAL.rstrip("\n") + "\n" + line + "\n"


MUTATIONS = {
    # The review's mutations, verbatim where they are Dockerfile-level.
    "separate_sudoers_run": _append('RUN echo "haf_stats ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers'),
    "trailing_lowercase_user_0": _append("user 0"),
    "copy_chown_db": REAL.replace("COPY db/ ", "COPY --chown=10001:10001 db/ ", 1),
    # And the obvious neighbours.
    "final_user_root": REAL.replace(f"USER {UID}:{UID}", "USER root"),
    "final_user_by_name": REAL.replace(f"USER {UID}:{UID}", "USER haf_stats"),
    "uid_1000": REAL.replace(f"-u {UID}", "-u 1000"),
    "no_chmod": REAL.replace(" \\\n && chmod -R u=rwX,go=rX /app", ""),
    # The pre-182878 form: readable, but leaves the context's world-write bits in place.
    "chmod_without_go_minus_w": REAL.replace("chmod -R u=rwX,go=rX /app", "chmod -R a+rX /app"),
    "lowercase_run_after_user": _append("run true"),
    "runtime_chown": _append("RUN chown -R 10001:10001 /app/db"),
    "chmod_o_w_db": REAL.replace("&& chmod -R u=rwX,go=rX /app",
                                 "&& chmod -R u=rwX,go=rX /app && chmod -R o+w /app/db"),
    "chmod_octal_777": REAL.replace("&& chmod -R u=rwX,go=rX /app", "&& chmod -R 777 /app"),
    # Round 2: `=` is as much a grant as `+`, including after a comma.
    "chmod_go_eq_rwx": REAL.replace("chmod -R u=rwX,go=rX /app", "chmod -R go=rwX /app"),
    "chmod_u_go_eq_rwx": REAL.replace("chmod -R u=rwX,go=rX /app", "chmod -R u=rwX,go=rwX /app"),
    # Round 2 M1: a COPY between the chmod RUN and USER escapes the chmod.
    "copy_after_chmod_before_user": REAL.replace(
        'ENTRYPOINT ["/app/docker_entrypoint.sh"]',
        'COPY docker/docker_entrypoint.sh /app/late.sh\nENTRYPOINT ["/app/docker_entrypoint.sh"]', 1),
    # Round 2: the base image's 0777 files in /usr/local/bin left alone.
    "no_path_strip": REAL.replace("-exec chmod go-w {} +", "-print"),
    # Round 3: a home directory, the user site back on, a later bare stage, a heredoc.
    "home_created": REAL.replace("adduser -S -D -H ", "adduser -S -D ", 1),
    "home_under_home": REAL.replace("-h /nonexistent", "-h /home/haf_stats", 1),
    "no_pythonnousersite": REAL.replace("ENV PYTHONNOUSERSITE=1", "ENV PYTHONNOUSERSITE="),
    "later_bare_stage": _append("FROM alpine:3.20"),
    "heredoc_run": _append("RUN <<EOF\nchmod -R 777 /app\nEOF"),
}


@pytest.mark.parametrize("name", sorted(MUTATIONS))
def test_mutation_is_rejected(name):
    mutated = MUTATIONS[name]
    assert mutated != REAL, f"mutation {name} did not apply -- its anchor text moved"
    assert all_problems(mutated), f"mutation {name} passed every check"


@pytest.mark.parametrize("cmd, grants", [
    ("chmod -R o+w /app/db", True),
    ("chmod g+w x", True),
    ("chmod a+rw x", True),
    ("chmod +w x", True),
    ("chmod =rw x", True),
    ("chmod -R go=rwX /app", True),
    ("chmod -R u=rwX,go=rwX /app", True),
    ("chmod 777 /app", True),
    ("chmod 0664 x", True),
    ("chmod 4757 x", True),
    ("chmod -R u=rwX,go=rX /app", False),
    ("chmod -R a+rX /app", False),
    ("chmod go-w x", False),
    ("chmod u+w x", False),
    ("chmod u=rw x", False),
    ("chmod 0755 x", False),
    ("chmod 4755 x", False),
])
def test_group_other_write_regex(cmd, grants):
    assert bool(_CHMOD_GROUP_OTHER_WRITE.search(cmd)) is grants, cmd


def _equivalent_forms() -> dict[str, str]:
    adduser = " && adduser -S -D -H -u 10001"
    assert REAL.count(adduser) == 1
    return {
        # `\` followed by trailing whitespace is still a continuation in Docker.
        "trailing_whitespace_after_backslash": REAL.replace(" \\\n", " \\  \t\n"),
        # Comment and blank lines inside a continuation are dropped by Docker.
        "comment_inside_continuation": REAL.replace(adduser, "# a comment\n" + adduser, 1),
        "blank_inside_continuation": REAL.replace(adduser, "\n" + adduser, 1),
        "lowercase_keywords": re.sub(r"(?m)^(RUN|COPY|USER|ENV) ", lambda m: m.group(1).lower() + " ", REAL),
    }


@pytest.mark.parametrize("name", sorted(_equivalent_forms()))
def test_equivalent_spelling_parses_the_same(name):
    variant = _equivalent_forms()[name]
    assert variant != REAL, f"{name} did not apply"
    assert _instructions(variant) == [(k, a) for k, a in _instructions(REAL)], name
    assert all_problems(variant) == []


def test_heredoc_is_refused_not_parsed():
    problems = all_problems(MUTATIONS["heredoc_run"])
    assert problems and problems[0].startswith("refused: heredocs"), problems
