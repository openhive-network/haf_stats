"""The app image must not run as root (#64).

The behavioural check is scripts/ci-helpers/check_runtime_user.sh, which the docker-build
smoke test runs INSIDE the built image (and against mutant images it must reject). This
file pins the Dockerfile's declarations, so a regression names the line rather than
surfacing as "running as 0:0" after a build.

Comments are stripped before matching, because the Dockerfile discusses `USER root` and
sudo in prose and a comment must not be able to satisfy, or fail, an assertion here.
Instruction keywords are matched CASE-INSENSITIVELY, as Docker parses them: a trailing
lowercase `user 0` is a real USER instruction.

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


def _instructions(text: str) -> list[tuple[str, str]]:
    """(KEYWORD, arguments) per instruction: comments dropped, continuations joined."""
    lines = [l for l in text.splitlines() if not l.lstrip().startswith("#")]
    joined = "\n".join(lines).replace("\\\n", " ")
    out = []
    for line in joined.splitlines():
        m = re.match(r"\s*([A-Za-z]+)\s+(.*)", line)
        if m:
            out.append((m.group(1).upper(), m.group(2).strip()))
    return out


def final_user_problems(text: str) -> list[str]:
    users = [(i, a) for i, (k, a) in enumerate(_instructions(text)) if k == "USER"]
    if not users:
        return ["no USER instruction; the base image's would apply"]
    # Numeric so runAsNonRoot can verify it without resolving a name.
    if users[-1][1] != f"{UID}:{UID}":
        return [f"final USER is {users[-1][1]!r}, want {UID}:{UID}"]
    return []


def user_creation_problems(text: str) -> list[str]:
    create = [a for k, a in _instructions(text) if k == "RUN" and "adduser" in a]
    if len(create) != 1:
        return [f"expected one RUN creating the runtime user, got {create}"]
    run, problems = create[0], []
    if not re.search(rf"\baddgroup\b[^&]*-g {UID}\b[^&]*\bhaf_stats\b", run):
        problems.append(f"addgroup does not create haf_stats with gid {UID}: {run}")
    if not re.search(rf"\badduser\b[^&]*-u {UID}\b[^&]*-G haf_stats\b", run):
        problems.append(f"adduser does not create uid {UID} in haf_stats: {run}")
    # COPY keeps the build context's modes; CI's openapi-drift leaves
    # endpoints/rewrite_rules.conf 0600 in a reused runner build directory.
    if not re.search(r"\bchmod -R a\+rX /app$", run):
        problems.append(f"no `chmod -R a+rX /app` after the copies: {run}")
    return problems


def privilege_problems(text: str) -> list[str]:
    """No instruction may hand the runtime user sudo or ownership of anything.

    EVERY RUN is scanned, not just the adduser one: a separate
    `RUN echo "haf_stats ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers` is the same hole."""
    problems = []
    for k, a in _instructions(text):
        if k == "RUN" and re.search(r"sudo|wheel|\bchown\b", a, re.I):
            problems.append(f"RUN touches sudo/wheel/chown: {a}")
        # chmod granting group/other WRITE: symbolic (o+w, a+rw, +w) or an octal mode
        # whose group or other digit carries the write bit (2, 3, 6, 7).
        if k == "RUN" and re.search(
                r"\bchmod\b[^&;|]*(?:\s[ugoa]*[ago][ugoa]*\+[rxX]*w|\s\+[rxX]*w"
                r"|\s[0-7]?[0-7](?:[2367][0-7]|[0-7][2367])\b)", a):
            problems.append(f"RUN chmod grants group/other write: {a}")
        if k in ("COPY", "ADD") and re.search(r"--chown\b", a, re.I):
            problems.append(f"{k} --chown hands files to a non-root owner: {a}")
    return problems


def tail_problems(text: str) -> list[str]:
    instructions = _instructions(text)
    last = max((i for i, (k, _) in enumerate(instructions) if k == "USER"), default=None)
    if last is None:
        return []
    # A RUN after the switch runs as 10001; a COPY lands files below a reader's
    # assumption that the build is over. Either way it belongs above the final USER.
    return [f"{k} after the final USER: {a}" for k, a in instructions[last + 1:]
            if k in ("RUN", "COPY", "ADD")]


CHECKS = [final_user_problems, user_creation_problems, privilege_problems, tail_problems]


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
    "no_chmod": REAL.replace(" \\\n && chmod -R a+rX /app", ""),
    "lowercase_run_after_user": _append("run true"),
    "runtime_chown": _append("RUN chown -R 10001:10001 /app/db"),
    "chmod_o_w_db": REAL.replace("&& chmod -R a+rX /app", "&& chmod -R a+rX /app && chmod -R o+w /app/db"),
    "chmod_octal_777": REAL.replace("&& chmod -R a+rX /app", "&& chmod -R 777 /app"),
}


@pytest.mark.parametrize("name", sorted(MUTATIONS))
def test_mutation_is_rejected(name):
    mutated = MUTATIONS[name]
    assert mutated != REAL, f"mutation {name} did not apply -- its anchor text moved"
    problems = [p for check in CHECKS for p in check(mutated)]
    assert problems, f"mutation {name} passed every check"
