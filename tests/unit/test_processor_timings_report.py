"""scripts/processor_timings_report.py: the per-processor timings report of a replay.

The driver logs here are built line by line in haf_app_driver.py's shape (a timestamp,
then the server message), from batches whose seconds and op counts the tests choose, so
every expected number is known independently of the script. The last tests hold the
script's step lists to the SQL that emits the lines, so a processor or refresh added to
db/ without a timing, or timed under another name, fails here rather than in the lane.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "processor_timings_report.py"


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("processor_timings_report", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["processor_timings_report"] = module
    spec.loader.exec_module(module)
    return module


report_script = _load()
PROCESSORS: tuple[str, ...] = report_script.PROCESSORS
REFRESHES: dict[str, str] = report_script.REFRESHES

READS = {
    "process_financial": ["transfer_operation"],
    "prepare_batch_authored_ops": ["non_virtual"],
    "process_custom_json": ["custom_json_operation"],
}
COUNTS = [
    {"op_type": "custom_json_operation", "virtual": False, "rows": 7},
    {"op_type": "producer_reward_operation", "virtual": True, "rows": 100},
    {"op_type": "transfer_operation", "virtual": False, "rows": 3},
    {"op_type": "vote_operation", "virtual": False, "rows": 20},
]


def _line(kind: str, record: dict[str, Any]) -> str:
    return f"2026-10-25T10:00:00.000Z INFO:  {kind} {json.dumps(record)}\n"


def _batch(first: int, last: int, seconds: float, refreshes: tuple[str, ...] = ()) -> list[str]:
    """One batch as the driver logs it: every processor at ``seconds``, each refresh named
    at ``seconds / 10``, the op counts (instrumentation 0.5 s) and the driver's own line."""
    lines = []
    for p in PROCESSORS:
        lines += [_line("haf_stats_processor_timing", {
            "first_block": first, "last_block": last, "step": r, "within": p, "seconds": seconds / 10, "reads": [],
        }) for r in refreshes if REFRESHES[r] == p]
        lines.append(_line("haf_stats_processor_timing", {
            "first_block": first, "last_block": last, "step": p, "within": None, "seconds": seconds,
            "reads": READS.get(p, []),
        }))
    lines.append(_line("haf_stats_operation_counts", {
        "first_block": first, "last_block": last, "seconds": 0.5, "counts": COUNTS,
    }))
    lines.append(f"2026-10-25T10:00:00.000Z blocks {first}..{last} ({last - first + 1}) processed in 1.00s\n")
    return lines


def _run(tmp_path: Path, lines: list[str], first: int = 1, last: int = 2_000_000) -> tuple[int, Path]:
    log = tmp_path / "driver.log"
    log.write_text("2026-10-25T09:59:59.000Z application 'haf_stats': current block 0\n" + "".join(lines),
                   encoding="utf-8")
    out = tmp_path / "processor-timings.json"
    rc: int = report_script.main(["--log", str(log), "--out", str(out), "--first-block", str(first),
                                  "--last-block", str(last), "--sync-seconds", "100"])
    return rc, out


def _three_batches() -> list[str]:
    return (_batch(1, 1_000_000, 1.0)
            + _batch(1_000_001, 1_500_000, 2.0, ("refresh_financial_monthly", "refresh_engagement_touched"))
            + _batch(1_500_001, 2_000_000, 4.0, ("refresh_financial_monthly",)))


def test_a_timed_run_makes_the_report(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    rc, out = _run(tmp_path, _three_batches())

    assert rc == 0
    report = json.loads(out.read_text(encoding="utf-8"))
    assert report["batches"] == 3
    assert report["sync_wall_seconds"] == 100.0
    assert report["blocks_per_second"] == 20000.0
    assert report["processors"]["process_witness_blocks"] == {"seconds": 7.0, "calls": 3, "share": 0.0833}
    assert report["processing_seconds"] == 7.0 * len(PROCESSORS)
    assert report["instrumentation_seconds"] == 1.5
    assert report["refreshes"]["refresh_financial_monthly"] == {
        "seconds": 0.6, "calls": 2, "share": 0.0071, "within": "process_financial"}
    assert report["refreshes"]["refresh_engagement_touched"]["calls"] == 1
    assert report["refreshes"]["refresh_author_cohort_retention"]["calls"] == 0
    # A batch counts towards the million its first block is in.
    assert [(b["first_block"], b["batches"]) for b in report["per_million"]] == [(1, 1), (1_000_001, 2)]
    assert report["per_million"][1]["seconds"]["process_financial"] == 6.0
    assert report["per_million"][1]["seconds"]["refresh_financial_monthly"] == 0.6
    assert report["per_million"][1]["processing_seconds"] == 6.0 * len(PROCESSORS)
    assert report["rows_read"]["process_financial"] == {"transfer_operation": 9}
    # non_virtual: custom_json + transfer + vote, not the virtual producer_reward.
    assert report["rows_read"]["prepare_batch_authored_ops"] == {"non_virtual": 90}
    assert report["rows_read"]["process_active_users"] == {}
    assert report["operations"]["producer_reward_operation"] == 300

    table = capsys.readouterr().out
    assert re.search(r"^process_financial +7\.00 +8\.3% +3 +1\.00 +6\.00$", table, re.M)
    assert re.search(r"^  refresh_financial_monthly +0\.60 +0\.7% +2 +0\.00 +0\.60$", table, re.M)
    assert "sync wall 100.0s over 3 batches (blocks 1..2000000)" in table
    assert "process_financial: transfer_operation 9" in table


@pytest.mark.parametrize(("lines", "problem"), [
    pytest.param([], "no processor timings", id="no timings at all"),
    pytest.param(["2026-10-25T10:00:00.000Z blocks 1..10 (10) processed in 1.00s\n"],
                 "no processor timings", id="an untimed run's log"),
    pytest.param(_batch(1, 999_999, 1.0) + _batch(1_000_001, 2_000_000, 1.0), "a gap", id="a gap"),
    pytest.param(_batch(1, 1_000_000, 1.0) + _batch(1_000_000, 2_000_000, 1.0), "an overlap", id="an overlap"),
    pytest.param(_batch(1, 1_500_000, 1.0), "end at block 1500000", id="ends short"),
    pytest.param([line for line in _batch(1, 2_000_000, 1.0) if '"process_network_ops"' not in line],
                 "no timing for process_network_ops", id="a processor missing"),
    pytest.param([line for line in _batch(1, 2_000_000, 1.0) if "haf_stats_operation_counts" not in line],
                 "no operation counts", id="counts missing"),
    pytest.param(_batch(1, 2_000_000, 1.0) + _batch(1, 2_000_000, 1.0)[:1], "timed twice", id="timed twice"),
    pytest.param(_batch(1, 2_000_000, -1.0), "negative", id="negative seconds"),
    pytest.param(_batch(1, 2_000_000, 1.0) + ["x INFO:  haf_stats_processor_timing {\"first_block\": 1,\n"],
                 "not JSON", id="a truncated line"),
    pytest.param(_batch(1, 2_000_000, 1.0) + [_line("haf_stats_processor_timing", {
        "first_block": 1, "last_block": 2_000_000, "step": "process_votes", "within": None, "seconds": 1,
        "reads": []})], "unknown step 'process_votes'", id="an unknown step"),
    pytest.param(_batch(1, 2_000_000, 1.0) + [_line("haf_stats_processor_timing", {
        "first_block": 1, "last_block": 2_000_000, "step": "refresh_financial_monthly",
        "within": "process_active_users", "seconds": 1, "reads": []})],
        "not process_financial", id="a refresh credited to another processor"),
    pytest.param([line.replace('"rows": 7', '"rows": "7"') for line in _batch(1, 2_000_000, 1.0)],
                 "'rows' is '7'", id="a count that is not a number"),
])
def test_bad_input_fails_and_writes_nothing(tmp_path: Path, capsys: pytest.CaptureFixture[str],
                                            lines: list[str], problem: str) -> None:
    rc, out = _run(tmp_path, lines)

    assert rc == 1
    assert not out.exists()
    assert problem in capsys.readouterr().err


def test_a_missing_log_fails(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out = tmp_path / "processor-timings.json"
    rc = report_script.main(["--log", str(tmp_path / "absent.log"), "--out", str(out), "--first-block", "1",
                             "--last-block", "10", "--sync-seconds", "1"])

    assert rc == 1
    assert not out.exists()
    assert "no report:" in capsys.readouterr().err


# --- the step lists against the SQL that emits the lines ------------------------------

_TIMING_CALL = re.compile(r"report_processor_timing\('(\w+)', _first_block, _last_block, _t, '\{([^}]*)\}', "
                          r"(NULL|'(\w+)')\)")


def _sql(name: str) -> str:
    return (ROOT / "db" / name).read_text(encoding="utf-8")


def _dispatcher() -> str:
    text = _sql("process_block_range.sql")
    return text[text.index("CREATE OR REPLACE FUNCTION haf_stats_app.process_block_range("):]


def test_every_step_the_dispatcher_calls_is_timed_in_order() -> None:
    body = _dispatcher()
    called = re.findall(r"PERFORM haf_stats_app\.((?:process|prepare)_\w+)\(_first_block, _last_block\);", body)
    timed = [m.group(1) for m in _TIMING_CALL.finditer(body) if m.group(3) == "NULL"]

    assert called == list(PROCESSORS)
    assert timed == list(PROCESSORS)


def test_every_refresh_is_timed_inside_its_processor() -> None:
    timed: dict[str, str] = {}
    for path in sorted((ROOT / "db").glob("*.sql")):
        for m in _TIMING_CALL.finditer(path.read_text(encoding="utf-8")):
            if m.group(4) is not None:
                timed[m.group(1)] = m.group(4)
                assert f"PERFORM haf_stats_app.{m.group(1)}(" in path.read_text(encoding="utf-8")

    assert timed == REFRESHES


def test_the_reads_name_op_types_the_counts_can_report() -> None:
    reads = {r for m in _TIMING_CALL.finditer(_dispatcher()) for r in m.group(2).split(",") if r}

    assert reads, "the dispatcher names no op type it reads"
    for r in reads:
        assert r == report_script.NON_VIRTUAL or r.endswith("_operation"), r
