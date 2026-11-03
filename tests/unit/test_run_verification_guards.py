"""Guard selection in scripts/run_verification.sh.

`--guard=NAME` is how .aidev/run-checks.sh reports each correctness guard as its own
test and re-runs one alone, so a name must select exactly its guard: one that ran a
neighbour as well, or nothing, would pass a re-run for a guard that never ran. psql
is a stub that records the SQL files it is given, in TCP mode, so nothing connects.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, sh_quote, write_exec

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "run_verification.sh"
TIMEOUT = 60


@pytest.fixture
def bash() -> str:
    return require_bash()


def run(bash: str, tmp_path: Path, *args: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    bindir = tmp_path / "bin"
    bindir.mkdir(parents=True)
    calls = tmp_path / "psql-files"
    write_exec(
        bindir / "psql",
        "#!/bin/sh\n"
        'while [ $# -gt 0 ]; do\n'
        f'  if [ "$1" = -f ]; then printf "%s\\n" "$2" >> {sh_quote(str(calls))}; fi\n'
        "  shift\n"
        "done\n",
    )
    result = subprocess.run(
        [bash, str(SCRIPT), "--host=db.invalid", *args],
        env=clean_env(bindir), capture_output=True, text=True, timeout=TIMEOUT,
    )
    return result, calls.read_text().splitlines() if calls.exists() else []


def test_the_named_guards_run_and_no_other(bash: str, tmp_path: Path) -> None:
    result, files = run(bash, tmp_path, "--guard=interactions-cap", "--guard=parity")
    assert result.returncode == 0, result.stdout + result.stderr
    assert files == ["tests/parity/mainnet_metrics_parity.sql", "tests/parity/interactions_cap.sql"]
    assert "Guard 1/9" in result.stdout and "Guard 5/9" in result.stdout
    assert "Guard 3/9" not in result.stdout
    assert "Selected correctness guards PASSED (interactions-cap parity)" in result.stdout


def test_every_listed_guard_selects_exactly_one_guard(bash: str, tmp_path: Path) -> None:
    listed = subprocess.run(
        [bash, str(SCRIPT), "--list-guards"], env=clean_env(), capture_output=True, text=True, timeout=TIMEOUT,
    )
    assert listed.returncode == 0
    names = listed.stdout.split()
    assert len(names) == 9 and len(set(names)) == 9
    for index, name in enumerate(names, start=1):
        result, _ = run(bash, tmp_path / name, f"--guard={name}")
        headers = [line for line in result.stdout.splitlines() if line.startswith("===== Guard ")]
        assert headers and all(header.startswith(f"===== Guard {index}/9:") for header in headers), (name, result.stdout)


def test_an_unknown_guard_is_rejected_before_anything_runs(bash: str, tmp_path: Path) -> None:
    result, files = run(bash, tmp_path, "--guard=parity", "--guard=no-such-guard")
    assert result.returncode == 1
    assert "unknown guard: no-such-guard" in result.stdout
    assert files == []


def test_an_empty_guard_name_is_rejected(bash: str, tmp_path: Path) -> None:
    result, files = run(bash, tmp_path, "--guard=")
    assert result.returncode != 0
    assert files == []
