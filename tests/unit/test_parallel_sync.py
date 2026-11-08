"""scripts/haf_stats_parallel.py, the parallel massive-sync range processor (#140), against a
fake database; and the wiring in scripts/process_blocks.sh that hands it to the driver.

What the fake stands in for is only the SQL interface the coordinator drives
(begin_parallel_range, processor_groups, shared_batch_stage_levels, stage_shared_batch,
process_processor_group, finish_parallel_range, process_blocks). Whether those functions keep
the batch all-or-nothing in PostgreSQL is the synced lane's check
(tests/ci_parallel_sync_equality.sh); this file checks that the coordinator calls them so that
it can: the batch staged a level at a time and committed on worker connections before any
group starts, every group on a worker connection of its own and committed there, the batch
finished on the driver's connection only after every group committed, never after a failure,
and live ranges left to the single-session procedure.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import threading
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from tests.unit.shell_harness import clean_env, require_bash, stub_bin, write_exec

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "haf_stats_parallel.py"
PROCESS_BLOCKS = ROOT / "scripts" / "process_blocks.sh"

GROUPS = ["financial", "users", "content", "custom_json", "network"]
STAGE_LEVELS = [["ops"], ["authored_ops", "exact_rc"]]


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("haf_stats_parallel", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["haf_stats_parallel"] = module
    spec.loader.exec_module(module)
    return module


parallel = _load()


class FakeDbError(Exception):
    pass


class FakeDb:
    """The server side: what each connection ran, and the groups' committed progress."""

    def __init__(
        self,
        massive: bool = True,
        fail_group: str | None = None,
        barrier: threading.Barrier | None = None,
        fail_stage: str | None = None,
    ) -> None:
        self.massive = massive
        self.fail_group = fail_group
        self.fail_stage = fail_stage
        self.barrier = barrier
        self.lock = threading.Lock()
        self.log: list[tuple[str, str]] = []  # (connection name, event)
        self.committed: list[str] = []
        self.staged: list[str] = []
        self.opened = 0

    def record(self, name: str, event: str) -> None:
        with self.lock:
            self.log.append((name, event))


class FakeCursor:
    def __init__(self, conn: FakeConn) -> None:
        self.conn = conn
        self.row: tuple[Any, ...] | None = None

    def execute(self, sql: str, params: tuple[Any, ...] = ()) -> None:
        db = self.conn.db
        if "begin_parallel_range" in sql:
            self.conn.db.record(self.conn.name, "begin")
            self.row = (db.massive,)
        elif "processor_groups(), haf_stats_app.shared_batch_stage_levels()" in sql:
            self.row = (list(GROUPS), [list(level) for level in STAGE_LEVELS])
        elif "stage_shared_batch" in sql:
            step = params[0]
            self.conn.pending = f"stage {step}"
            db.record(self.conn.name, f"stage {step} {params[1]}..{params[2]}")
            if step == db.fail_stage:
                raise FakeDbError(f"injected failure in staging step {step}")
        elif "process_processor_group" in sql:
            group = params[0]
            self.conn.pending = group
            db.record(self.conn.name, f"group {group} {params[1]}..{params[2]}")
            if db.barrier is not None:
                db.barrier.wait()
            if group == db.fail_group:
                raise FakeDbError(f"injected failure in {group}")
            self.conn.notices.append(f"INFO:  haf_stats_processor_timing {{\"step\":\"{group}\"}}\n")
        elif "finish_parallel_range" in sql:
            db.record(self.conn.name, f"finish {params[0]}..{params[1]}")
        elif "CALL haf_stats_app.process_blocks" in sql:
            db.record(self.conn.name, f"process_blocks {params[0]}")
        else:
            raise AssertionError(f"unexpected SQL: {sql}")

    def fetchone(self) -> tuple[Any, ...] | None:
        return self.row


DRIVER_PARAMS = {"user": "haf_stats_owner", "dbname": "haf_block_log", "application_name": "haf_stats_block_processing"}


class FakeInfo:
    def __init__(self, password: str) -> None:
        self.password = password


class FakeConn:
    """A psycopg2 connection as it presents its parameters: get_dsn_parameters() leaves the
    password out, info.password is the one it authenticated with ("" for none), and dsn
    masks it as "password=xxx"."""

    def __init__(self, db: FakeDb, name: str, params: dict[str, str] | None = None) -> None:
        self.db = db
        self.name = name
        params = dict(DRIVER_PARAMS if params is None else params)
        self.info = FakeInfo(params.pop("password", ""))
        self.params = params
        self.dsn = " ".join(f"{k}={v}" for k, v in params.items()) + (" password=xxx" if self.info.password else "")
        self.pending: str | None = None
        self.closed = False
        self.notices: list[str] = []

    def get_dsn_parameters(self) -> dict[str, str]:
        return dict(self.params)

    def cursor(self) -> FakeCursor:
        return FakeCursor(self)

    def commit(self) -> None:
        assert self.pending is not None, "commit without a group or staging statement"
        with self.db.lock:
            if self.pending.startswith("stage "):
                self.db.staged.append(self.pending.removeprefix("stage "))
            else:
                self.db.committed.append(self.pending)
        self.db.record(self.name, f"commit {self.pending}")
        self.pending = None

    def rollback(self) -> None:
        self.db.record(self.name, f"rollback {self.pending}")
        self.pending = None

    def close(self) -> None:
        self.closed = True


def coordinator(db: FakeDb, parallelism: int = 4, opened_with: list[dict[str, str]] | None = None) -> Any:
    def connect(**params: str) -> FakeConn:
        with db.lock:
            db.opened += 1
            n = db.opened
            if opened_with is not None:
                opened_with.append(params)
        assert params.get("application_name") == "haf_stats_block_processing", params
        return FakeConn(db, f"worker{n}", params)

    return parallel.ParallelCoordinator(parallelism, connect, FakeDbError)


def driver_conn(db: FakeDb) -> FakeConn:
    return FakeConn(db, "driver")


def test_a_massive_range_runs_every_group_on_workers_and_finishes_after_all_committed() -> None:
    db = FakeDb()
    driver = driver_conn(db)
    coordinator(db).process(driver, 101, 10100)

    group_events = [(n, e) for n, e in db.log if e.startswith("group ")]
    assert sorted(e for _, e in group_events) == sorted(f"group {g} 101..10100" for g in GROUPS)
    assert all(n != "driver" for n, _ in group_events), "a group ran on the driver's connection"
    assert sorted(db.committed) == sorted(GROUPS)

    finish = db.log.index(("driver", "finish 101..10100"))
    last_commit = max(i for i, (_, e) in enumerate(db.log) if e.startswith("commit "))
    assert finish > last_commit, "the batch was finished before every group had committed"
    assert ("driver", "begin") in db.log[:1]
    assert not any(e.startswith("process_blocks") for _, e in db.log)


def test_the_batch_is_staged_once_a_level_at_a_time_before_any_group() -> None:
    db = FakeDb()
    coordinator(db).process(driver_conn(db), 101, 10100)

    assert sorted(db.staged) == sorted(step for level in STAGE_LEVELS for step in level)
    starts = {e.split()[1]: i for i, (_, e) in enumerate(db.log) if e.startswith("stage ")}
    commits = {e.split()[2]: i for i, (_, e) in enumerate(db.log) if e.startswith("commit stage ")}
    assert all(e.endswith(" 101..10100") for _, e in db.log if e.startswith("stage "))
    assert all(n != "driver" for n, e in db.log if e.startswith("stage ")), "staging ran on the driver's connection"
    for earlier, later in zip(STAGE_LEVELS, STAGE_LEVELS[1:]):
        assert max(commits[s] for s in earlier) < min(starts[s] for s in later), "a level started before the last committed"
    first_group = min(i for i, (_, e) in enumerate(db.log) if e.startswith("group "))
    assert max(commits.values()) < first_group, "a group started before the staging committed"


def test_a_failed_staging_step_runs_no_group_and_does_not_finish_the_batch() -> None:
    db = FakeDb(fail_stage="ops")
    with pytest.raises(FakeDbError, match="injected failure in staging step ops"):
        coordinator(db).process(driver_conn(db), 101, 10100)

    assert not any(e.startswith(("group ", "finish", "stage authored_ops", "stage exact_rc")) for _, e in db.log)
    assert ("worker1", "rollback stage ops") in db.log
    assert db.committed == [] and db.staged == []


def test_the_groups_run_at_once() -> None:
    # Every group waits until all five are inside process_processor_group together; run one at
    # a time they would never all arrive and the barrier breaks.
    db = FakeDb(barrier=threading.Barrier(len(GROUPS), timeout=10))
    coordinator(db, parallelism=len(GROUPS)).process(driver_conn(db), 1, 10000)
    assert sorted(db.committed) == sorted(GROUPS)
    assert db.opened == len(GROUPS)


def test_no_more_connections_than_the_parallelism() -> None:
    db = FakeDb()
    c = coordinator(db, parallelism=2)
    c.process(driver_conn(db), 1, 10000)
    c.process(driver_conn(db), 10001, 20000)
    assert db.opened <= 2
    assert sorted(db.committed) == sorted(GROUPS * 2)


def test_a_failed_group_stops_the_batch_before_it_is_finished() -> None:
    db = FakeDb(fail_group="content")
    with pytest.raises(FakeDbError, match="injected failure in content"):
        coordinator(db).process(driver_conn(db), 101, 10100)

    assert not any(e.startswith("finish") for _, e in db.log), "a batch with a failed group was finished"
    assert sorted(db.committed) == sorted(g for g in GROUPS if g != "content")
    assert any(e == "rollback content" for _, e in db.log)


def test_the_retry_after_a_failure_runs_the_batch_again() -> None:
    db = FakeDb(fail_group="network")
    c = coordinator(db)
    with pytest.raises(FakeDbError):
        c.process(driver_conn(db), 101, 10100)
    db.fail_group = None
    c.process(driver_conn(db), 101, 10100)
    assert ("driver", "finish 101..10100") in db.log


def test_a_live_range_goes_to_the_single_session_procedure() -> None:
    db = FakeDb(massive=False)
    coordinator(db).process(driver_conn(db), 5000001, 5000001)
    assert db.log == [("driver", "begin"), ("driver", "process_blocks (5000001,5000001)")]
    assert db.opened == 0


def test_parallelism_one_is_the_single_session_path_even_in_massive_sync() -> None:
    db = FakeDb(massive=True)
    coordinator(db, parallelism=1).process(driver_conn(db), 101, 10100)
    assert db.log == [("driver", "process_blocks (101,10100)")]
    assert db.opened == 0


def test_workers_connect_with_the_password_the_driver_authenticated_with() -> None:
    db = FakeDb()
    driver = FakeConn(db, "driver", {**DRIVER_PARAMS, "host": "haf", "password": "s3cret"})
    assert "password=xxx" in driver.dsn
    opened_with: list[dict[str, str]] = []
    coordinator(db, opened_with=opened_with).process(driver, 101, 10100)

    assert opened_with, "no worker connection was opened"
    assert all(p == {**DRIVER_PARAMS, "host": "haf", "password": "s3cret"} for p in opened_with), opened_with
    assert ("driver", "finish 101..10100") in db.log


def test_workers_pass_no_password_when_the_driver_had_none() -> None:
    # No password key, so libpq takes one from PGPASSWORD or ~/.pgpass as it did for the driver.
    db = FakeDb()
    opened_with: list[dict[str, str]] = []
    coordinator(db, opened_with=opened_with).process(driver_conn(db), 101, 10100)

    assert opened_with
    assert all(p == DRIVER_PARAMS for p in opened_with), opened_with


def test_worker_server_messages_reach_the_log(capsys: pytest.CaptureFixture[str]) -> None:
    db = FakeDb()
    coordinator(db).process(driver_conn(db), 101, 10100)
    out = capsys.readouterr().out
    for group in GROUPS:
        assert f'INFO:  haf_stats_processor_timing {{"step":"{group}"}}' in out


@pytest.mark.parametrize("value,expected", [("", 1), ("1", 1), ("4", 4), (" 8 ", 8)])
def test_parallelism_from_env(value: str, expected: int) -> None:
    assert parallel.parallelism_from_env({parallel.PARALLELISM_ENV: value}) == expected
    assert parallel.parallelism_from_env({}) == 1


@pytest.mark.parametrize("value", ["0", "-2", "four", "1.5"])
def test_a_bad_parallelism_is_refused(value: str) -> None:
    with pytest.raises(ValueError, match=parallel.PARALLELISM_ENV):
        parallel.parallelism_from_env({parallel.PARALLELISM_ENV: value})


# --- scripts/process_blocks.sh -----------------------------------------------------


def _run_process_blocks(tmp_path: Path, parallelism: str | None = None) -> tuple[list[str], str, str]:
    bash = require_bash()
    stub_bin(tmp_path)
    write_exec(
        tmp_path / "bin" / "psql",
        "#!/bin/sh\n"
        "cmd=''\nprev=''\n"
        'for a in "$@"; do case "$prev" in -c) cmd="$cmd$a" ;; esac; prev="$a"; done\n'
        'case "$cmd" in\n'
        '  *"now()"*) printf "2026-09-01 12:34:56" ;;\n'
        '  *to_regclass*|*"FROM hafd.applications"*) printf "t" ;;\n'
        "esac\nexit 0\n",
    )
    argv = tmp_path / "driver.log"
    write_exec(
        tmp_path / "bin" / "haf_app_driver.py",
        f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{argv.as_posix()}"\n'
        f'printf "%s|%s\\n" "${{PYTHONPATH-}}" "${{HAF_STATS_SYNC_PARALLELISM-}}" >> "{argv.as_posix()}"\nexit 0\n',
    )
    env = clean_env(stub_bin(tmp_path))
    env["HAF_STATS_STARTUP_TIME_FILE"] = str(tmp_path / "startup.txt")
    if parallelism is not None:
        env["HAF_STATS_SYNC_PARALLELISM"] = parallelism
    result = subprocess.run([bash, str(PROCESS_BLOCKS)], env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
    args, environment = argv.read_text(encoding="utf-8").splitlines()
    return args.split(), environment, result.stdout + result.stderr


def test_the_driver_gets_the_parallel_range_processor_above_one(tmp_path: Path) -> None:
    args, environment, _ = _run_process_blocks(tmp_path, "4")
    assert "--process-python=haf_stats_parallel:process_blocks" in args
    pythonpath, value = environment.split("|")
    assert str(ROOT / "scripts") in pythonpath.split(":")
    assert value == "4"
    assert "--startup-marker=" in args


@pytest.mark.parametrize("value", [None, "1"])
def test_the_driver_keeps_its_registered_procedure_at_one(tmp_path: Path, value: str | None) -> None:
    args, _, _ = _run_process_blocks(tmp_path, value)
    assert not any(a.startswith("--process-python") for a in args)


@pytest.mark.parametrize("value", ["0", "four", "-3"])
def test_a_bad_value_falls_back_to_one_session(tmp_path: Path, value: str) -> None:
    args, _, output = _run_process_blocks(tmp_path, value)
    assert not any(a.startswith("--process-python") for a in args)
    assert "is not a positive integer; using 1" in output
