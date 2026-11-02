"""The endpoint lane's `tavern` case in .aidev/compose_lane.py's junit.

A tavern run whose failures tavern.xml records per test is reported there, under
each test's own id, so the per-service `tavern` case is skipped: a failing umbrella
case beside them would match no quarantine entry and block a run whose only failure
is quarantined. A tavern run that failed without recording any (a usage error, a
crash) still fails as `tavern`. The lane is replayed from a one-service compose file
whose tavern runs pytest over a local tests directory.
"""

from __future__ import annotations

import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

pytest.importorskip("yaml")

SCRIPT = Path(__file__).resolve().parents[2] / ".aidev" / "compose_lane.py"
TIMEOUT = 120


def run_lane(tmp_path: Path, tests_arg: str) -> tuple[subprocess.CompletedProcess[str], Path]:
    compose = tmp_path / "compose.yml"
    compose.write_text(f'services:\n  tavern:\n    command: "pytest -q {tests_arg}"\n')
    out = tmp_path / "out"
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(compose), "tavern", str(out), "endpoint"],
        cwd=tmp_path, capture_output=True, text=True, timeout=TIMEOUT,
    )
    return result, out


def tavern_case(out: Path) -> ET.Element:
    root = ET.parse(out / "endpoint.xml").getroot()
    (case,) = [c for c in root.iter("testcase") if c.get("name") == "tavern"]
    return case


def test_tavern_failures_recorded_per_test_skip_the_service_case(tmp_path: Path) -> None:
    tests = tmp_path / "tavern_tests"
    tests.mkdir()
    (tests / "test_api.py").write_text("def test_ok():\n    pass\n\ndef test_broken():\n    assert 1 == 2\n")

    result, out = run_lane(tmp_path, "tavern_tests")

    assert result.returncode == 1, result.stderr
    case = tavern_case(out)
    assert case.find("failure") is None
    skipped = case.find("skipped")
    assert skipped is not None
    assert skipped.get("message") == "exit 1: 1 failing test(s) reported per test in tavern.xml"
    suite = ET.parse(out / "endpoint.xml").getroot()
    assert (suite.get("failures"), suite.get("skipped")) == ("0", "1")
    failing = [c.get("name") for c in ET.parse(out / "tavern.xml").getroot().iter("testcase")
               if c.find("failure") is not None]
    assert failing == ["test_broken"]


def test_tavern_failure_without_per_test_failures_fails_the_service_case(tmp_path: Path) -> None:
    result, out = run_lane(tmp_path, "no_such_tests_dir")

    assert result.returncode == 1, result.stderr
    case = tavern_case(out)
    assert case.find("skipped") is None
    failure = case.find("failure")
    assert failure is not None
    assert failure.get("message") == "exit 4"
    assert ET.parse(out / "endpoint.xml").getroot().get("failures") == "1"


def test_tavern_report_left_by_an_earlier_run_is_not_counted(tmp_path: Path) -> None:
    out = tmp_path / "out"
    out.mkdir()
    (out / "tavern.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="pytest" tests="2">'
        '<testcase classname="tavern_tests.test_api" name="test_ok"/>'
        '<testcase classname="tavern_tests.test_api" name="test_broken"><failure message="old"/></testcase>'
        '</testsuite></testsuites>\n')
    tests = tmp_path / "tavern_tests"
    tests.mkdir()
    # The run dies before it writes a report of its own.
    (tests / "conftest.py").write_text("import os\nos._exit(9)\n")
    (tests / "test_api.py").write_text("def test_ok():\n    pass\n")

    result, out = run_lane(tmp_path, "tavern_tests")

    assert result.returncode == 1, result.stderr
    case = tavern_case(out)
    assert case.find("skipped") is None
    failure = case.find("failure")
    assert failure is not None
    assert failure.get("message") == "exit 9"
    assert ET.parse(out / "endpoint.xml").getroot().get("failures") == "1"
    assert not (out / "tavern.xml").exists()
