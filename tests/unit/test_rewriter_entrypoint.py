"""Behavioural tests for docker/rewriter_entrypoint.sh (#165).

nginx's resolver does not read /etc/hosts, so the entrypoint swaps a POSTGREST_HOST
listed there for its address and leaves every other name for nginx to re-resolve per
request (#164). The script runs against the real template, with a stand-in openresty
prefix whose binary is a stub, and the rendered upstream line is what is asserted.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, write_exec

REPO = Path(__file__).resolve().parents[2]
ENTRYPOINT = REPO / "docker" / "rewriter_entrypoint.sh"
TEMPLATE = REPO / "docker" / "haf_stats_nginx.conf.template"

TIMEOUT = 10

HOSTS = """\
127.0.0.1\tlocalhost
::1\tlocalhost ip6-localhost ip6-loopback
# 10.9.9.9\tcommented-out
172.17.0.1\thost.docker.internal   # extra_hosts: host-gateway
fd00::7\tv6-only
172.17.0.26\tf8e3b8fc77a8
"""


@pytest.fixture
def bash() -> str:
    return require_bash()


@pytest.fixture
def prefix(tmp_path: Path) -> Path:
    conf = tmp_path / "nginx" / "conf"
    conf.mkdir(parents=True)
    shutil.copy(TEMPLATE, conf / "nginx.conf.template")
    (tmp_path / "bin").mkdir()
    write_exec(tmp_path / "bin" / "openresty", '#!/bin/sh\necho "openresty $*"\n')
    return tmp_path


def run_entrypoint(
    bash: str, prefix: Path, hosts: str = HOSTS, **env_extra: str
) -> tuple[subprocess.CompletedProcess[str], str]:
    hosts_file = prefix / "hosts"
    hosts_file.write_text(hosts, encoding="utf-8")
    env = clean_env()
    for name in ("POSTGREST_HOST", "POSTGREST_PORT", "RESOLVER", "REWRITE_LOG"):
        env.pop(name, None)
    env["REWRITER_HOSTS_FILE"] = str(hosts_file)
    env["REWRITER_OPENRESTY_PREFIX"] = str(prefix)
    env.update(env_extra)
    result = subprocess.run(
        [bash, str(ENTRYPOINT)], env=env, capture_output=True, text=True, timeout=TIMEOUT
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "openresty -g daemon off;"
    return result, (prefix / "nginx" / "conf" / "nginx.conf").read_text(encoding="utf-8")


def upstream(conf: str) -> str:
    [line] = [ln.strip() for ln in conf.splitlines() if ln.strip().startswith("set $postgrest_upstream")]
    return line


@pytest.mark.parametrize(
    ("host", "expected"),
    [
        ("localhost", "http://127.0.0.1:3000"),
        ("LocalHost", "http://127.0.0.1:3000"),
        ("host.docker.internal", "http://172.17.0.1:3000"),
        ("v6-only", "http://[fd00::7]:3000"),
    ],
)
def test_hosts_file_name_is_replaced_by_its_address(
    bash: str, prefix: Path, host: str, expected: str
) -> None:
    result, conf = run_entrypoint(bash, prefix, POSTGREST_HOST=host)
    assert upstream(conf) == f"set $postgrest_upstream {expected};"
    assert f"POSTGREST_HOST {host} is in" in result.stderr
    assert "resolver 127.0.0.11 valid=10s;" in conf


@pytest.mark.parametrize("host", ["haf-stats-api", "postgrest", "commented-out", "10.0.0.5"])
def test_other_names_stay_for_the_resolver(bash: str, prefix: Path, host: str) -> None:
    result, conf = run_entrypoint(bash, prefix, POSTGREST_HOST=host, POSTGREST_PORT="3005")
    assert upstream(conf) == f"set $postgrest_upstream http://{host}:3005;"
    assert result.stderr == ""


def test_default_host_is_the_service_name(bash: str, prefix: Path) -> None:
    _, conf = run_entrypoint(bash, prefix, RESOLVER="10.1.2.3")
    assert upstream(conf) == "set $postgrest_upstream http://haf-stats-api:3000;"
    assert "resolver 10.1.2.3 valid=10s;" in conf


def test_missing_hosts_file_leaves_the_name(bash: str, prefix: Path, tmp_path: Path) -> None:
    _, conf = run_entrypoint(
        bash, prefix, POSTGREST_HOST="localhost", REWRITER_HOSTS_FILE=str(tmp_path / "absent")
    )
    assert upstream(conf) == "set $postgrest_upstream http://localhost:3000;"
