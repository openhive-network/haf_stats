"""Parallel massive sync: haf_app_driver.py's range processor when HAF_STATS_SYNC_PARALLELISM > 1.

    haf_app_driver.py --app=haf_stats ... --process-python=haf_stats_parallel:process_blocks

The driver opens a transaction, calls hive.app_next_iteration, calls process_blocks(conn,
first, last) on the same connection, and commits; that commit is what moves the HAF context.
Here, for one range:

  * outside MASSIVE_PROCESSING (haf_stats_app.begin_parallel_range returns FALSE) the range goes
    to CALL haf_stats_app.process_blocks, exactly as the driver would call it without this
    module, so live sync keeps the single-session path;
  * during massive sync the range is staged once for every group: the steps of
    haf_stats_app.shared_batch_stage_levels(), in level order, each in a transaction of its own
    that commits the staged rows (haf_stats_app.stage_shared_batch, db/process_block_range.sql,
    "Shared batch staging"). Then the processor groups (haf_stats_app.processor_groups()) are
    dealt out in call order to at most HAF_STATS_SYNC_PARALLELISM worker connections, which run
    at once; a connection runs its groups one after another, each in a transaction of its own
    that reads the shared staging and commits the group's writes with its progress row
    (haf_stats_app.process_processor_group). Once every group has committed,
    haf_stats_app.finish_parallel_range runs in the driver's transaction and the driver commits.
    If a staging step or a group fails, the steps and groups after it on its connection do not
    run, the first failure is raised once every connection has finished, the driver rolls its
    transaction back, and the context stays before the range: the range is delivered again, the
    staging steps that committed are reused and the groups that committed skip it. Staging
    cannot run in the driver's transaction: the groups could not read it before that transaction
    commits, and its commit is what moves the HAF context.

The staging is pipelined: while a batch's groups run, one more worker connection stages the
range the next batch is likely to be -- as long as the longest range delivered so far, right
after this one -- and the next call waits for that staging before anything else. When the
staging ahead completed the range the driver delivers, the batch's groups start at once;
otherwise (the first batch, a shorter range, or a staging ahead that failed, which is logged)
the batch is staged before its groups, as above. The staging ahead is never waited for by its
own batch, so a batch takes the longer of its groups and the next batch's staging, not their
sum. The SQL side keeps it safe whatever the guess: two batches' stages live in separate slots,
a range past HAF's irreversible block is not staged, and a group reads only stages marked
complete for exactly its range.

A worker connection gets everything it runs for a batch in one round trip: the staging, or its
share of the groups, as one query string of BEGIN; SELECT ...; COMMIT blocks, on a connection in
autocommit mode. So a batch staged ahead waits on three round trips in a row -- begin, groups and
finish -- and one that was not on four, staging before the groups, which is what it costs where
a round trip to the server is slow.

With haf_stats.processor_timings on, each batch also writes one line with the wall time of each
of those four phases, as the driver measures the range processor's ("processed in"):

    haf_stats_batch_phases {"first_block":..,"last_block":..,"seconds":{"begin":..,
                            "staging":..,"groups":..,"finish":..}}

"begin" runs from the call to the staging's dispatch: begin_parallel_range, and on the first
batch the query for the groups and staging steps. "staging" is the wait for the staging ahead
and, when that did not stage the range, the batch's own staging. The staging ahead logs its
steps' timings under the range it staged, which may be a range the driver never delivers.
scripts/processor_timings_report.py reads them.

The worker connections use the driver's connection parameters (conn.get_dsn_parameters(), so
the same application_name the rebuild scripts look for) and the password the driver's
connection authenticated with (conn.info.password), whether it came from the URL, PGPASSWORD
or ~/.pgpass. conn.dsn is not used: psycopg2 masks a password in it as "password=xxx", which
would override PGPASSWORD and ~/.pgpass. Their server messages are written to stdout as the
driver writes its own.
"""

from __future__ import annotations

import datetime
import json
import os
import queue
import sys
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import Future, ThreadPoolExecutor
from typing import Any, Protocol

PARALLELISM_ENV = "HAF_STATS_SYNC_PARALLELISM"

_STAGE_SQL = "SELECT haf_stats_app.stage_shared_batch(%s, %s, %s)"
_STAGED_SQL = "SELECT haf_stats_app.shared_batch_complete(%s, %s)"
_GROUP_SQL = "SELECT haf_stats_app.process_processor_group(%s, %s, %s)"


class _Cursor(Protocol):
    def execute(self, sql: str, params: Sequence[object] = ...) -> Any: ...

    def fetchone(self) -> Any: ...


class _ConnectionInfo(Protocol):
    password: str | None


class _Connection(Protocol):
    info: _ConnectionInfo
    notices: list[str]
    autocommit: bool

    def get_dsn_parameters(self) -> dict[str, str]: ...

    def cursor(self) -> _Cursor: ...

    def close(self) -> None: ...


def parallelism_from_env(environ: Mapping[str, str] = os.environ) -> int:
    """HAF_STATS_SYNC_PARALLELISM as a positive integer; 1 when unset or empty.

    :raises ValueError: the value is not a positive integer.
    """
    raw = environ.get(PARALLELISM_ENV, "").strip()
    if not raw:
        return 1
    if not raw.isdigit() or int(raw) < 1:
        raise ValueError(f"{PARALLELISM_ENV} must be a positive integer, not {raw!r}")
    return int(raw)


class ParallelCoordinator:
    """Runs a range's processor groups on up to `parallelism` connections of its own, and stages
    the next range ahead on one more.

    `connect` opens a worker connection from libpq connection parameters given as keyword
    arguments (psycopg2.connect); `db_error` is the base class of what its connections raise
    (psycopg2.Error).
    """

    def __init__(self, parallelism: int, connect: Callable[..., _Connection], db_error: type[Exception]) -> None:
        if parallelism < 1:
            raise ValueError(f"parallelism must be at least 1, not {parallelism}")
        self._parallelism = parallelism
        self._connect = connect
        self._db_error = db_error
        self._idle: queue.SimpleQueue[_Connection] = queue.SimpleQueue()
        self._executor: ThreadPoolExecutor | None = None
        self._group_shares: list[list[str]] | None = None
        self._stage_steps: list[str] | None = None
        self._timed = False
        self._out_lock = threading.Lock()
        self._batch_blocks = 0
        self._ahead: Future[tuple[int, int] | None] | None = None

    def process(self, conn: _Connection, first_block: int, last_block: int) -> None:
        started = time.monotonic()
        cur = conn.cursor()
        massive = self._parallelism > 1 and self._begin(cur, first_block, last_block)
        if massive and self._executor is None:
            self._prepare(cur)
        staging_started = time.monotonic()
        staged_ahead = self._staged_ahead()
        if not massive:
            cur.execute("CALL haf_stats_app.process_blocks(%s::hive.blocks_range)", (f"({first_block},{last_block})",))
            return
        if self._group_shares is None or self._stage_steps is None or self._executor is None:
            raise RuntimeError("the coordinator has no groups or staging steps")
        params = _worker_connection_params(conn)
        if staged_ahead != (first_block, last_block):
            self._run_at_once(params, "batch staging steps", _STAGE_SQL, [self._stage_steps], first_block, last_block)
        groups_started = time.monotonic()
        self._batch_blocks = max(self._batch_blocks, last_block - first_block + 1)
        self._ahead = self._executor.submit(
            self._stage_ahead, params, self._stage_steps, last_block + 1, last_block + self._batch_blocks
        )
        self._run_at_once(params, "processor groups", _GROUP_SQL, self._group_shares, first_block, last_block)
        finish_started = time.monotonic()
        cur.execute("SELECT haf_stats_app.finish_parallel_range(%s, %s)", (first_block, last_block))
        if self._timed:
            phases = {
                "begin": staging_started - started,
                "staging": groups_started - staging_started,
                "groups": finish_started - groups_started,
                "finish": time.monotonic() - finish_started,
            }
            self._log("haf_stats_batch_phases " + json.dumps({
                "first_block": first_block,
                "last_block": last_block,
                "seconds": {phase: round(seconds, 6) for phase, seconds in phases.items()},
            }))

    def _run_at_once(
        self,
        params: Mapping[str, str],
        kind: str,
        sql: str,
        shares: Sequence[Sequence[str]],
        first_block: int,
        last_block: int,
    ) -> None:
        """`sql` for each name of each share and the range: each share on a worker connection of
        its own, in one round trip, each name's statement committed there on its own."""
        if self._executor is None:
            raise RuntimeError("the coordinator has no executor")
        futures = [
            self._executor.submit(self._run_on_worker, params, kind, sql, names, first_block, last_block)
            for names in shares
        ]
        # Every share is waited for, failed or not, so no worker of this range is still running
        # when the next phase starts, or when the driver rolls back and asks for the range again.
        errors = [f.exception() for f in futures]
        failed = next((e for e in errors if e is not None), None)
        if failed is not None:
            raise failed

    def _prepare(self, cur: _Cursor) -> None:
        cur.execute(
            "SELECT haf_stats_app.processor_groups(), haf_stats_app.shared_batch_stage_levels(),"
            " current_setting('haf_stats.processor_timings', TRUE) = 'on'"
        )
        groups, levels, timed = cur.fetchone()
        workers = min(self._parallelism, len(groups))
        # Dealt out in call order: connection i runs groups i, i + workers, ...
        self._group_shares = [list(groups[i::workers]) for i in range(workers)]
        self._stage_steps = [step for level in levels for step in level]
        self._timed = bool(timed)
        # One more than the groups' connections: the staging ahead runs beside them.
        self._executor = ThreadPoolExecutor(max_workers=workers + 1, thread_name_prefix="haf_stats_group")

    def _staged_ahead(self) -> tuple[int, int] | None:
        """The range the previous batch staged ahead, once that staging has finished; None when it
        did not complete one (or there was none)."""
        ahead, self._ahead = self._ahead, None
        if ahead is None:
            return None
        try:
            return ahead.result()
        except self._db_error:
            # _run_on_worker logged it; the batch stages its range itself.
            return None

    def _stage_ahead(
        self, params: Mapping[str, str], steps: Sequence[str], first_block: int, last_block: int
    ) -> tuple[int, int] | None:
        complete = self._run_on_worker(
            params, "batch staging ahead", _STAGE_SQL, steps, first_block, last_block, check=_STAGED_SQL
        )
        return (first_block, last_block) if complete else None

    @staticmethod
    def _begin(cur: _Cursor, first_block: int, last_block: int) -> bool:
        cur.execute("SELECT haf_stats_app.begin_parallel_range(%s, %s)", (first_block, last_block))
        return bool(cur.fetchone()[0])

    def _run_on_worker(
        self,
        params: Mapping[str, str],
        kind: str,
        sql: str,
        names: Sequence[str],
        first_block: int,
        last_block: int,
        check: str | None = None,
    ) -> Any:
        """`sql` for each name and the range, each committed on its own; then `check`, given the
        range, whose value is returned (None without one)."""
        try:
            worker = self._idle.get_nowait()
        except queue.Empty:
            worker = self._connect(**params)
            worker.autocommit = True
            worker.notices = []
        healthy = False
        try:
            # One query string, so one round trip. A statement that fails leaves its BEGIN block
            # aborted and the server skips the rest of the string; the blocks before it stay
            # committed.
            statements = [f"BEGIN; {sql}; COMMIT" for _ in names]
            values: list[object] = [value for name in names for value in (name, first_block, last_block)]
            if check is not None:
                statements.append(check)
                values += [first_block, last_block]
            cur = worker.cursor()
            cur.execute("; ".join(statements), values)
            result = cur.fetchone()[0] if check is not None else None
            healthy = True
        except self._db_error as e:
            self._log(f"{kind} {', '.join(names)}, blocks {first_block}..{last_block}, failed: {str(e).strip()}")
            healthy = self._rolled_back(worker)
            raise
        finally:
            self._forward_notices(worker)
            if healthy:
                self._idle.put(worker)
            else:
                self._close(worker)
        return result

    def _rolled_back(self, worker: _Connection) -> bool:
        """Whether the worker connection is still usable after a statement failed: one that
        cannot roll back (a lost connection) is closed and replaced on the next range. ROLLBACK
        as a statement: psycopg2's rollback() sends nothing on a connection in autocommit mode,
        which a failed BEGIN block leaves aborted."""
        try:
            worker.cursor().execute("ROLLBACK")
            return True
        except self._db_error as e:
            self._log(f"discarding a worker connection that could not roll back: {str(e).strip()}")
            return False

    def _close(self, worker: _Connection) -> None:
        try:
            worker.close()
        except self._db_error as e:
            self._log(f"closing a discarded worker connection failed: {str(e).strip()}")

    def _forward_notices(self, worker: _Connection) -> None:
        for notice in worker.notices:
            lines = [line.rstrip() for line in notice.rstrip("\n").split("\n") if line.strip()]
            if lines:
                self._emit(lines)
        del worker.notices[:]

    def _log(self, message: str) -> None:
        self._emit([f"haf_stats_parallel: {message}"])

    def _emit(self, lines: list[str]) -> None:
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        with self._out_lock:
            sys.stdout.write(f"{ts} {lines[0]}\n" + "".join(f"    {extra}\n" for extra in lines[1:]))
            sys.stdout.flush()


def _worker_connection_params(conn: _Connection) -> dict[str, str]:
    params = dict(conn.get_dsn_parameters())
    password = conn.info.password
    # libpq reports "" for a connection that authenticated without a password.
    if password:
        params["password"] = password
    return params


_coordinator: ParallelCoordinator | None = None


def process_blocks(conn: _Connection, first_block: int, last_block: int) -> None:
    """haf_app_driver.py's --process-python entry point: one delivered range, in the driver's
    transaction on `conn`, which this does not commit."""
    global _coordinator
    if _coordinator is None:
        import psycopg2

        _coordinator = ParallelCoordinator(parallelism_from_env(), psycopg2.connect, psycopg2.Error)
    _coordinator.process(conn, first_block, last_block)
