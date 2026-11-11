"""Behavioural tests for scripts/ci-helpers/wait_service_exit.sh (#154).

The helper is the gate of the install-test and endpoint-tests jobs: its exit code is
the job's verdict on the whole compose chain. It replaced `docker compose wait`, which
failed a green lane because it finds only running containers, so the case that broke
it -- the service has already exited 0 -- is pinned here alongside the ones that must
stay red: a non-zero exit, no container at all, and a container left in Created state
(which `docker wait` would report as 0).

The daemon is a stub `docker` on PATH that answers `compose ps`, `inspect` and `wait`
from files the test writes, and logs every invocation.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, sh_quote, write_exec

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "ci-helpers" / "wait_service_exit.sh"
COMPOSE_FILE = "docker/docker-compose-ci-install.yml"
SERVICE = "verify-gone"
TIMEOUT = 10


@pytest.fixture
def bash() -> str:
    return require_bash()


def _stub_docker(tmp_path: Path, *, ids: str, status: str = "exited", code: str = "0",
                 ps_rc: int = 0) -> Path:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    log = tmp_path / "docker.log"
    write_exec(
        bindir / "docker",
        "#!/bin/sh\n"
        f"echo \"$*\" >> {sh_quote(str(log))}\n"
        "case \"$1\" in\n"
        f"  compose) printf '%s' {sh_quote(ids)}; exit {ps_rc} ;;\n"
        f"  inspect) echo {sh_quote(status)} ;;\n"
        f"  wait) echo {sh_quote(code)} ;;\n"
        "  *) echo \"unexpected docker $*\" >&2; exit 99 ;;\n"
        "esac\n",
    )
    return bindir


def _run(bash: str, bindir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [bash, str(SCRIPT), COMPOSE_FILE, SERVICE],
        env=clean_env(bindir), capture_output=True, text=True, timeout=TIMEOUT, check=False,
    )


def _calls(tmp_path: Path) -> list[str]:
    return (tmp_path / "docker.log").read_text().splitlines()


@pytest.mark.parametrize("status", ["exited", "running"])
def test_passes_on_exit_zero_whether_already_exited_or_still_running(tmp_path: Path, bash: str, status: str) -> None:
    bindir = _stub_docker(tmp_path, ids="abc123\n", status=status, code="0")
    result = _run(bash, bindir)
    assert result.returncode == 0, result.stderr
    assert f"{SERVICE} exited 0" in result.stdout
    assert _calls(tmp_path) == [
        f"compose -f {COMPOSE_FILE} ps --all --quiet {SERVICE}",
        "inspect --format {{.State.Status}} abc123",
        "wait abc123",
    ]


def test_fails_on_non_zero_exit(tmp_path: Path, bash: str) -> None:
    bindir = _stub_docker(tmp_path, ids="abc123\n", code="3")
    result = _run(bash, bindir)
    assert result.returncode == 1
    assert f"FAIL: {SERVICE} exited 3" in result.stderr


def test_fails_naming_the_service_when_it_has_no_container(tmp_path: Path, bash: str) -> None:
    bindir = _stub_docker(tmp_path, ids="")
    result = _run(bash, bindir)
    assert result.returncode == 1
    assert f"FAIL: {SERVICE} has no container" in result.stderr
    assert not any(c.startswith(("inspect", "wait")) for c in _calls(tmp_path))


def test_fails_naming_the_service_when_it_was_never_started(tmp_path: Path, bash: str) -> None:
    bindir = _stub_docker(tmp_path, ids="abc123\n", status="created", code="0")
    result = _run(bash, bindir)
    assert result.returncode == 1
    assert f"FAIL: {SERVICE} was created but never started" in result.stderr
    assert not any(c.startswith("wait") for c in _calls(tmp_path))


def test_fails_when_the_containers_cannot_be_listed(tmp_path: Path, bash: str) -> None:
    bindir = _stub_docker(tmp_path, ids="", ps_rc=1)
    result = _run(bash, bindir)
    assert result.returncode == 1
    assert f"cannot list the containers of {SERVICE}" in result.stderr


def test_fails_when_more_than_one_container_matches(tmp_path: Path, bash: str) -> None:
    bindir = _stub_docker(tmp_path, ids="abc123\ndef456\n")
    result = _run(bash, bindir)
    assert result.returncode == 1
    assert f"{SERVICE} has 2 containers" in result.stderr
