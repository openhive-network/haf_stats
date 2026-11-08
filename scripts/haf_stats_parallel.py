"""Parallel massive sync: haf_app_driver.py's range processor when HAF_STATS_SYNC_PARALLELISM > 1.

    haf_app_driver.py --app=haf_stats ... --process-python=haf_stats_parallel:process_blocks

The driver opens a transaction, calls hive.app_next_iteration, calls process_blocks(conn,
first, last) on the same connection, and commits; that commit is what moves the HAF context.
Here, for one range:

  * outside MASSIVE_PROCESSING (haf_stats_app.begin_parallel_range returns FALSE) the range goes
    to CALL haf_stats_app.process_blocks, exactly as the driver would call it without this
    module, so live sync keeps the single-session path;
  * during massive sync each processor group (haf_stats_app.processor_groups(),
    db/process_block_range.sql) runs on a connection of its own, at most
    HAF_STATS_SYNC_PARALLELISM at once, in a transaction of its own that commits the group's
    writes with its progress row (haf_stats_app.process_processor_group). Once every group has
    committed, haf_stats_app.finish_parallel_range runs in the driver's transaction and the
    driver commits. If a group fails, the first failure is raised once every group has
    finished, the driver rolls its transaction back, and the context stays before the range: the
    range is delivered again and the groups that committed skip it.

The worker connections use the driver's connection parameters (conn.get_dsn_parameters(), so
the same application_name the rebuild scripts look for) and the password the driver's
connection authenticated with (conn.info.password), whether it came from the URL, PGPASSWORD
or ~/.pgpass. conn.dsn is not used: psycopg2 masks a password in it as "password=xxx", which
would override PGPASSWORD and ~/.pgpass. Their server messages are written to stdout as the
driver writes its own.
"""

from __future__ import annotations

import datetime
import os
import queue
import sys
import threading
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Protocol

PARALLELISM_ENV = "HAF_STATS_SYNC_PARALLELISM"


class _Cursor(Protocol):
    def execute(self, sql: str, params: Sequence[object] = ...) -> Any: ...

    def fetchone(self) -> Any: ...


class _ConnectionInfo(Protocol):
    password: str | None


class _Connection(Protocol):
    info: _ConnectionInfo
    notices: list[str]

    def get_dsn_parameters(self) -> dict[str, str]: ...

    def cursor(self) -> _Cursor: ...

    def commit(self) -> None: ...

    def rollback(self) -> None: ...

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
    """Runs a range's processor groups on up to `parallelism` connections of its own.

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
        self._groups: list[str] | None = None
        self._out_lock = threading.Lock()

    def process(self, conn: _Connection, first_block: int, last_block: int) -> None:
        cur = conn.cursor()
        if self._parallelism == 1 or not self._begin(cur, first_block, last_block):
            cur.execute("CALL haf_stats_app.process_blocks(%s::hive.blocks_range)", (f"({first_block},{last_block})",))
            return
        if self._groups is None or self._executor is None:
            cur.execute("SELECT haf_stats_app.processor_groups()")
            self._groups = list(cur.fetchone()[0])
            self._executor = ThreadPoolExecutor(
                max_workers=min(self._parallelism, len(self._groups)), thread_name_prefix="haf_stats_group"
            )
        executor = self._executor
        params = _worker_connection_params(conn)
        futures = [
            executor.submit(self._run_group, params, group, first_block, last_block) for group in self._groups
        ]
        # Every group is waited for, failed or not, so no worker of this range is still running
        # when the driver rolls back and asks for the range again.
        errors = [f.exception() for f in futures]
        failed = next((e for e in errors if e is not None), None)
        if failed is not None:
            raise failed
        cur.execute("SELECT haf_stats_app.finish_parallel_range(%s, %s)", (first_block, last_block))

    @staticmethod
    def _begin(cur: _Cursor, first_block: int, last_block: int) -> bool:
        cur.execute("SELECT haf_stats_app.begin_parallel_range(%s, %s)", (first_block, last_block))
        return bool(cur.fetchone()[0])

    def _run_group(self, params: Mapping[str, str], group: str, first_block: int, last_block: int) -> None:
        try:
            worker = self._idle.get_nowait()
        except queue.Empty:
            worker = self._connect(**params)
            worker.notices = []
        healthy = False
        try:
            cur = worker.cursor()
            cur.execute("SELECT haf_stats_app.process_processor_group(%s, %s, %s)", (group, first_block, last_block))
            worker.commit()
            healthy = True
        except self._db_error as e:
            self._log(f"processor group {group}, blocks {first_block}..{last_block}, failed: {str(e).strip()}")
            healthy = self._rolled_back(worker)
            raise
        finally:
            self._forward_notices(worker)
            if healthy:
                self._idle.put(worker)
            else:
                self._close(worker)

    def _rolled_back(self, worker: _Connection) -> bool:
        """Whether the worker connection is still usable after its transaction failed: one that
        cannot roll back (a lost connection) is closed and replaced on the next range."""
        try:
            worker.rollback()
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
