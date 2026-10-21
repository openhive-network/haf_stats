"""The app image must not run as root (#64).

The behavioural check is the docker-build smoke test in .gitlab-ci.yml, which runs `id`,
reads every file under /app and writes the healthcheck's startup file INSIDE the built
image. This file pins the Dockerfile's declarations, which that smoke test runs too late
to explain: a wrong final USER fails it as "running as 0:0", and this says which line.

Comments are stripped before matching, because the Dockerfile discusses `USER root` in
prose and a comment must not be able to satisfy, or fail, an assertion here.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UID = "10001"


def _instructions() -> list[str]:
    """The Dockerfile as instruction lines: comments dropped, continuations joined."""
    text = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    lines = [l for l in text.splitlines() if not l.lstrip().startswith("#")]
    return [l.strip() for l in "\n".join(lines).replace("\\\n", " ").splitlines() if l.strip()]


def _users() -> list[str]:
    return [l.split(None, 1)[1].strip() for l in _instructions() if re.match(r"USER\s", l)]


def test_final_user_is_the_numeric_unprivileged_uid():
    users = _users()
    assert users, "Dockerfile has no USER instruction; the base image's would apply"
    # Numeric so runAsNonRoot can verify it without resolving a name.
    assert users[-1] == f"{UID}:{UID}", f"final USER is {users[-1]!r}, want {UID}:{UID}"


def test_the_uid_is_created_with_that_number_and_without_sudo():
    runs = [l for l in _instructions() if l.startswith("RUN ")]
    create = [r for r in runs if "adduser" in r]
    assert len(create) == 1, f"expected one RUN creating the runtime user, got {create}"
    assert re.search(rf"\baddgroup\b[^&]*-g {UID}\b[^&]*\bhaf_stats\b", create[0]), create[0]
    assert re.search(rf"\badduser\b[^&]*-u {UID}\b[^&]*-G haf_stats\b", create[0]), create[0]
    # The base image grants haf_admin NOPASSWD sudo; the runtime user must not be added
    # to sudoers or to a group that has it.
    assert "sudo" not in create[0], create[0]


def test_nothing_after_the_final_user_switches_back():
    instructions = _instructions()
    last_user = max(i for i, l in enumerate(instructions) if re.match(r"USER\s", l))
    tail = [l for l in instructions[last_user + 1:] if re.match(r"(RUN|COPY|ADD)\s", l)]
    # A COPY/RUN after the switch would run as 10001 (RUN) or land root-owned files the
    # reader of this file assumes were placed before it; either way it belongs above.
    assert not tail, f"build steps after the final USER: {tail}"
