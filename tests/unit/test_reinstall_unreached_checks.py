"""reinstall's junit reports in .aidev/run-checks.sh, as the quarantine reads them.

A failing step that recorded per-test failures is reported skipped, its failures
under their own ids (.aidev/junit_cases.py). reinstall's checks depend on each
other, so a failure can stop the run before the later checks: those must be
reported failing too, or quarantining the checks that did run would pass a step
whose remaining checks never ran. The step's own functions run from the script,
with the database calls stubbed.
"""

from __future__ import annotations

import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, sh_quote

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".aidev" / "run-checks.sh"
FUNCTIONS = ("record", "current_block", "reinstall_test", "check", "reinstall_unreached", "reinstall_checks_run")
TIMEOUT = 60
QUARANTINED = {"reinstall::privileges-first"}
LATER_CHECKS = ["second-install", "block-unchanged", "schema-unchanged", "privileges-second"]


@pytest.fixture
def bash() -> str:
    return require_bash()


def _script_definitions() -> str:
    text = SCRIPT.read_text(encoding="utf-8")
    checks = re.search(r"^reinstall_checks=\(.*\)$", text, re.M)
    assert checks, f"reinstall_checks not found in {SCRIPT}"
    parts = [checks.group(0)]
    for name in FUNCTIONS:
        match = re.search(rf"^{name}\(\) {{.*?^}}$", text, re.M | re.S)
        assert match, f"{name} not found in {SCRIPT}"
        parts.append(match.group(0))
    return "\n".join(parts)


def run_reinstall_step(bash: str, tmp_path: Path, *, snapshot_lines: int, privileges_first_rc: int, block_query_rc: int) -> Path:
    """Run reinstall as `step` records it; return the directory holding junit.xml and reinstall.xml."""
    out = tmp_path / "out"
    out.mkdir()
    stubs = f"""
cq() {{
    case "$*" in
        *schema_snapshot.sql*) seq {snapshot_lines} ;;
        *last_processed_block*) [ {block_query_rc} -eq 0 ] && echo 5000000 || return {block_query_rc} ;;
    esac
}}
clone_install() {{ :; }}
privileges_against_expected() {{ [ "$1" != first ] || return {privileges_first_rc}; }}
"""
    program = f"""
set -uo pipefail
out={sh_quote(str(out))}
{_script_definitions()}
{stubs}
rc=0
reinstall_test > "$out/reinstall.log" 2>&1 || rc=$?
record "$out/cases.tsv" reinstall "$rc" 0 "$out/reinstall.log" "$out/reinstall.xml"
python3 .aidev/junit_cases.py "$out/junit.xml" full "$out/cases.tsv"
"""
    result = subprocess.run([bash, "-c", program], cwd=ROOT, env=clean_env(), capture_output=True,
                            text=True, timeout=TIMEOUT, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    return out


def _cases(junit: Path) -> dict[str, str]:
    if not junit.is_file():
        return {}
    status = {}
    for case in ET.parse(junit).getroot().iter("testcase"):
        if case.find("failure") is not None:
            status[f"{case.get('classname')}::{case.get('name')}"] = "fail"
        elif case.find("skipped") is not None:
            status[f"{case.get('classname')}::{case.get('name')}"] = "skip"
        else:
            status[f"{case.get('classname')}::{case.get('name')}"] = "pass"
    return status


def blocking_failures(out: Path) -> set[str]:
    cases = {**_cases(out / "junit.xml"), **_cases(out / "reinstall.xml")}
    return {name for name, status in cases.items() if status == "fail"} - QUARANTINED


def test_a_run_stopped_after_a_quarantined_check_still_blocks(bash: str, tmp_path: Path) -> None:
    out = run_reinstall_step(bash, tmp_path, snapshot_lines=1000, privileges_first_rc=1, block_query_rc=2)

    reinstall = _cases(out / "reinstall.xml")
    assert reinstall == {"reinstall::privileges-first": "fail",
                         **{f"reinstall::{c}": "fail" for c in LATER_CHECKS}}
    assert blocking_failures(out) == {f"reinstall::{c}" for c in LATER_CHECKS}
    messages: dict[str | None, str] = {}
    for case in ET.parse(out / "reinstall.xml").getroot().iter("testcase"):
        failure = case.find("failure")
        assert failure is not None
        messages[case.get("name")] = failure.get("message", "")
    assert all(messages[c].startswith("not reached") for c in LATER_CHECKS)
    assert messages["privileges-first"] == "exit 1"


def test_only_quarantined_failures_among_checks_that_all_ran_is_pardoned(bash: str, tmp_path: Path) -> None:
    out = run_reinstall_step(bash, tmp_path, snapshot_lines=1000, privileges_first_rc=1, block_query_rc=0)

    assert _cases(out / "junit.xml") == {"full::reinstall": "skip"}
    assert _cases(out / "reinstall.xml") == {"reinstall::privileges-first": "fail",
                                             **{f"reinstall::{c}": "pass" for c in LATER_CHECKS}}
    assert blocking_failures(out) == set()


def test_a_run_stopped_before_the_first_check_fails_as_itself(bash: str, tmp_path: Path) -> None:
    out = run_reinstall_step(bash, tmp_path, snapshot_lines=10, privileges_first_rc=0, block_query_rc=0)

    assert _cases(out / "junit.xml") == {"full::reinstall": "fail"}
    assert _cases(out / "reinstall.xml") == {}
    assert blocking_failures(out) == {"full::reinstall"}
