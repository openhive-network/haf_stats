"""scripts/backfill_rc_exact.sh, run under a stub psql (#44, part 2).

The SQL it drives (haf_stats_app.backfill_rc_exact) is tested in tests/ci_exact_rc_rollups.sql.
This covers what only the script decides: each of its refusals, that a failed query stops it
instead of reading as an answer, and the day range it asks SQL for.

NOT COVERED: the SQL the script evaluates itself - the "day before the last processed block's
day" arithmetic and the generate_series of days - since the stub answers those with fixed text.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, stub_bin, write_exec

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "backfill_rc_exact.sh"
TIMEOUT = 60

LAST_DONE_DAY = "2018-09-27"
DAYS = ["2018-09-25", "2018-09-26", "2018-09-27"]


@pytest.fixture
def bash():
    return require_bash()


def run_backfill(bash, tmp_path, available="t", recorded="t", env_extra=None, last_done=LAST_DONE_DAY,
                 fail=None):
    """Run the script with psql answering: rc_cost_available() -> `available`, the hardfork-20
    probe -> `recorded` (either may be FAIL: psql prints an error and exits 2, as on a lost
    connection), the last finished day -> `last_done` (empty: no processed block yet), the day
    list -> DAYS. `fail` names one of the later queries ("last_done", "days", "backfill") to
    fail the same way."""
    bindir = stub_bin(tmp_path)
    log = tmp_path / "sql.log"
    days = tmp_path / "days"
    days.write_text("\n".join(DAYS) + "\n", encoding="utf-8")

    def answer(value: str) -> str:
        if value == "FAIL":
            return 'echo "psql: error: server closed the connection unexpectedly" >&2; exit 2'
        return f'echo "{value}"'

    days_answer = f'cat "{days.as_posix()}"'

    write_exec(
        bindir / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        "prev=''\n"
        'for a in "$@"; do\n'
        '  case "$prev" in -c|-Atc) cmd="$cmd$a" ;; esac\n'
        '  prev="$a"\n'
        "done\n"
        f'printf "%s\\n" "$(printf \'%s\' "$cmd" | tr \'\\n\' \' \')" >> "{log.as_posix()}"\n'
        'case "$cmd" in\n'
        f"  *rc_cost_available*) {answer(available)} ;;\n"
        f"  *26256744*) {answer(recorded)} ;;\n"
        f'  *last_processed_block*) {answer("FAIL") if fail == "last_done" else answer(last_done)} ;;\n'
        f'  *generate_series*) {answer("FAIL") if fail == "days" else days_answer} ;;\n'
        f'  *backfill_rc_exact*) {answer("FAIL") if fail == "backfill" else answer("network_op_daily=1 (mismatched 0)")} ;;\n'
        "  *) : ;;\n"
        "esac\n"
        "exit 0\n",
    )
    env = clean_env(bindir)
    env.pop("FROM_DAY", None)
    env.pop("TO_DAY", None)
    env.update(env_extra or {})
    proc = subprocess.run([bash, str(SCRIPT)], capture_output=True, text=True,
                          timeout=TIMEOUT, env=env)
    statements = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    return proc, statements


def backfilled_days(statements):
    return [s.split("backfill_rc_exact('")[1][:10] for s in statements if "backfill_rc_exact('" in s]


def test_it_fills_every_finished_day_from_hardfork_20(bash, tmp_path):
    """The control: with recorded costs from hardfork 20 it backfills each day it lists."""
    proc, statements = run_backfill(bash, tmp_path)
    assert proc.returncode == 0, proc.stderr
    assert backfilled_days(statements) == DAYS
    day_list = next(s for s in statements if "generate_series" in s)
    assert f"'2018-09-25'::DATE, '{LAST_DONE_DAY}'::DATE" in day_list


@pytest.mark.parametrize("from_day", [None, "2021-01-01"], ids=["default-range", "FROM_DAY-given"])
def test_a_haf_without_rc_cost_stops_before_any_day(bash, tmp_path, from_day):
    """Whatever FROM_DAY says: every day would recompute three rollups and fill nothing."""
    extra = {"FROM_DAY": from_day} if from_day else {}
    proc, statements = run_backfill(bash, tmp_path, available="f", env_extra=extra)
    assert proc.returncode == 2, proc.stderr
    assert "no hafd.transactions.rc_cost" in proc.stderr
    assert backfilled_days(statements) == []
    # It must not even send the hardfork-20 probe, which a HAF without the column cannot parse.
    assert not any("26256744" in s for s in statements)


def test_a_haf_not_replayed_on_1_28_8_stops_by_default(bash, tmp_path):
    proc, statements = run_backfill(bash, tmp_path, recorded="f")
    assert proc.returncode == 2, proc.stderr
    assert "not replayed on 1.28.8" in proc.stderr
    assert backfilled_days(statements) == []


def test_from_day_skips_the_hardfork_20_probe(bash, tmp_path):
    """FROM_DAY is how an operator of an upgraded (not replayed) node says where costs start."""
    proc, statements = run_backfill(bash, tmp_path, recorded="f",
                                    env_extra={"FROM_DAY": "2018-09-26"})
    assert proc.returncode == 0, proc.stderr
    assert not any("26256744" in s for s in statements)
    assert backfilled_days(statements) == DAYS  # the stub's list; the range is SQL's job
    day_list = next(s for s in statements if "generate_series" in s)
    assert f"'2018-09-26'::DATE, '{LAST_DONE_DAY}'::DATE" in day_list


def test_to_day_sets_the_end_of_the_range(bash, tmp_path):
    proc, statements = run_backfill(bash, tmp_path, env_extra={"TO_DAY": "2018-09-26"})
    assert proc.returncode == 0, proc.stderr
    day_list = next(s for s in statements if "generate_series" in s)
    assert "'2018-09-25'::DATE, '2018-09-26'::DATE" in day_list


@pytest.mark.parametrize("knob", ["FROM_DAY", "TO_DAY"])
@pytest.mark.parametrize("bad", ["2018-9-25", "2018-09-25'; SELECT 1; --", "x'; SELECT 1; --2018-09-25",
                                 "2018-0'-25"],
                         ids=["short", "payload-after", "payload-before", "right-length"])
def test_a_day_not_in_iso_form_is_refused_before_it_reaches_sql(bash, tmp_path, knob, bad):
    """The days are interpolated into SQL text; the YYYY-MM-DD check is all that stands there."""
    proc, statements = run_backfill(bash, tmp_path, env_extra={knob: bad})
    assert proc.returncode == 2, proc.stderr
    assert "Not a YYYY-MM-DD day" in proc.stderr
    assert not any(bad in s for s in statements)


def test_a_single_day_is_filled(bash, tmp_path):
    """FROM_DAY == TO_DAY is how a run resumes from the last day it logged."""
    proc, statements = run_backfill(bash, tmp_path,
                                    env_extra={"FROM_DAY": "2018-09-26", "TO_DAY": "2018-09-26"})
    assert proc.returncode == 0, proc.stderr
    assert "Nothing to do" not in proc.stderr
    day_list = next(s for s in statements if "generate_series" in s)
    assert "'2018-09-26'::DATE, '2018-09-26'::DATE" in day_list


@pytest.mark.parametrize("query", ["last_done", "days", "backfill"])
def test_a_failed_query_after_the_probes_stops_it_too(bash, tmp_path, query):
    """A day that fails must not be logged as "no blocks" and the run reported complete."""
    proc, statements = run_backfill(bash, tmp_path, fail=query)
    assert proc.returncode != 0
    assert "server closed the connection" in proc.stderr
    assert "backfill complete" not in proc.stdout + proc.stderr
    assert "no blocks" not in proc.stdout + proc.stderr


def test_from_day_after_to_day_does_nothing(bash, tmp_path):
    proc, statements = run_backfill(bash, tmp_path,
                                    env_extra={"FROM_DAY": "2018-09-27", "TO_DAY": "2018-09-26"})
    assert proc.returncode == 0, proc.stderr
    assert "Nothing to do" in proc.stderr
    assert not any("generate_series" in s for s in statements)
    assert backfilled_days(statements) == []


def test_a_processor_with_no_finished_day_is_refused(bash, tmp_path):
    proc, statements = run_backfill(bash, tmp_path, last_done="")
    assert proc.returncode == 2, proc.stderr
    assert "has not finished any day" in proc.stderr
    assert backfilled_days(statements) == []


@pytest.mark.parametrize("which", ["available", "recorded"])
def test_a_failed_probe_stops_it_and_is_not_read_as_an_answer(bash, tmp_path, which):
    """A lost connection used to read as "not replayed on 1.28.8" (`2>/dev/null || echo f`)."""
    proc, statements = run_backfill(bash, tmp_path, **{which: "FAIL"})
    assert proc.returncode != 0
    assert "server closed the connection" in proc.stderr
    assert "not replayed" not in proc.stderr
    assert "nothing to fill" not in proc.stderr
    assert backfilled_days(statements) == []


def test_it_refuses_a_to_day_the_processor_has_not_finished(bash, tmp_path):
    proc, statements = run_backfill(bash, tmp_path, env_extra={"TO_DAY": "2018-09-28"})
    assert proc.returncode == 2, proc.stderr
    assert "not finished by the processor" in proc.stderr
    assert backfilled_days(statements) == []
