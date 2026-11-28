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

Once staging a batch took HAF_STATS_SPLIT_STAGING_SECONDS (default 2) or longer, as it does in the
dense blocks from about 57M on, the next staging runs each level's steps at once instead, each on
a worker connection of its own: a round trip per level, and a connection for each step of the
widest level (the ops stage's parts) while it runs. Each step still commits on its own, so a
failed step leaves the steps that committed, on its connection or another, to be reused when the
range is staged again. The value is a number of seconds; 0 splits every staging.

Each batch writes one line with the wall time of each of those four phases, as the driver
measures the range processor's ("processed in"), and what bounds them:

    haf_stats_batch_phases {"first_block":..,"last_block":..,"seconds":{"begin":..,
                            "staging":..,"groups":..,"finish":..},"stage_seconds":..,
                            "stage_level_seconds":[..],"group_seconds":{"financial":..,..},
                            "critical":"custom_json_0"}

"begin" runs from the call to the staging's dispatch: begin_parallel_range, and on the first
batch the query for the groups and staging steps. "staging" is the wait for the staging ahead
and, when that did not stage the range, the batch's own staging. "stage_seconds" is how long
staging the batch's range took, ahead or not, and "stage_level_seconds" each of its round trips':
one per level of a split staging, a single one for all of them otherwise; "group_seconds" each
group's time on its worker connection (its haf_stats_app.processor_group_progress row, as
finish_parallel_range returns them; a group that applied the batch in an earlier delivery
reports that delivery's). A batch staged ahead takes the longer of its groups and the next
batch's staging, so "critical" names the longest of the groups and "staging". With
haf_stats.processor_timings on, the staging ahead also logs its steps' timings under the range it
staged, which may be a range the driver never delivers. scripts/processor_timings_report.py reads
both.

The worker connections use the driver's connection parameters (conn.get_dsn_parameters(), so
the same application_name the rebuild scripts look for) and the password the driver's
connection authenticated with (conn.info.password), whether it came from the URL, PGPASSWORD
or ~/.pgpass. conn.dsn is not used: psycopg2 masks a password in it as "password=xxx", which
would override PGPASSWORD and ~/.pgpass. Their server messages are written to stdout as the
driver writes its own.

Each worker connection, when it opens, takes HAF's shared lock on haf_stats the way the legacy
loop's session does, by running db/legacy_loop_lock.sql (#157). The driver's --lock covers only
the driver's own connection: when that drops, a worker's backend can still be committing a
group or a staging step, and without its own lock an install could start under it. With it, an
install waits for every worker backend too, and client_connection_check_interval ends a worker
backend whose process is gone. A worker connection that cannot take the lock is closed, not used.
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
from pathlib import Path
from typing import Any, NamedTuple, Protocol

PARALLELISM_ENV = "HAF_STATS_SYNC_PARALLELISM"
SPLIT_STAGING_ENV = "HAF_STATS_SPLIT_STAGING_SECONDS"
# Well above the gate's staging (a few tenths of a second a batch, where a round trip takes about
# 0.14 s), well below the dense era's (8-13 s on steem-20 at 57-70M).
_SPLIT_STAGING_SECONDS = 2.0

# The processor session's half of HAF's application lock, shared with the legacy loop.
SESSION_LOCK_SQL = (Path(__file__).resolve().parent.parent / "db" / "legacy_loop_lock.sql").read_text(encoding="utf-8")

_STAGE_SQL = "SELECT haf_stats_app.stage_shared_batch(%s, %s, %s)"
_STAGED_SQL = "SELECT haf_stats_app.shared_batch_complete(%s, %s)"
_GROUP_SQL = "SELECT haf_stats_app.process_processor_group(%s, %s, %s)"


class _Cursor(Protocol):
    def execute(self, sql: str, params: Sequence[object] = ...) -> Any: ...

    def fetchone(self) -> Any: ...


class _Staged(NamedTuple):
    first_block: int
    last_block: int
    seconds: float
    # Each round trip's seconds, in order.
    level_seconds: tuple[float, ...]


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


def split_staging_seconds_from_env(environ: Mapping[str, str] = os.environ) -> float:
    """HAF_STATS_SPLIT_STAGING_SECONDS as a number of seconds, 0 or more; 2 when unset or empty.

    :raises ValueError: the value is not a finite number of seconds, 0 or more.
    """
    raw = environ.get(SPLIT_STAGING_ENV, "").strip()
    if not raw:
        return _SPLIT_STAGING_SECONDS
    refused = f"{SPLIT_STAGING_ENV} must be a number of seconds, 0 or more, not {raw!r}"
    try:
        seconds = float(raw)
    except ValueError:
        raise ValueError(refused) from None
    if not 0 <= seconds < float("inf"):
        raise ValueError(refused)
    return seconds


class ParallelCoordinator:
    """Runs a range's processor groups on up to `parallelism` connections of its own, and stages
    the next range ahead on one more, or on one per step of a staging level once staging a batch
    took `split_staging_seconds` or longer.

    `connect` opens a worker connection from libpq connection parameters given as keyword
    arguments (psycopg2.connect); `db_error` is the base class of what its connections raise
    (psycopg2.Error).
    """

    def __init__(
        self,
        parallelism: int,
        connect: Callable[..., _Connection],
        db_error: type[Exception],
        split_staging_seconds: float = _SPLIT_STAGING_SECONDS,
    ) -> None:
        if parallelism < 1:
            raise ValueError(f"parallelism must be at least 1, not {parallelism}")
        if split_staging_seconds < 0:
            raise ValueError(f"split_staging_seconds must be 0 or more, not {split_staging_seconds}")
        self._parallelism = parallelism
        self._split_staging_seconds = split_staging_seconds
        self._connect = connect
        self._db_error = db_error
        self._idle: queue.SimpleQueue[_Connection] = queue.SimpleQueue()
        self._executor: ThreadPoolExecutor | None = None
        self._group_shares: list[list[str]] | None = None
        self._stage_levels: list[list[str]] | None = None
        # How long staging the last batch took.
        self._stage_seconds = 0.0
        self._out_lock = threading.Lock()
        self._batch_blocks = 0
        self._ahead: Future[_Staged | None] | None = None

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
        if self._group_shares is None or self._executor is None:
            raise RuntimeError("the coordinator has no groups or staging steps")
        params = _worker_connection_params(conn)
        if staged_ahead is not None and (staged_ahead.first_block, staged_ahead.last_block) == (first_block, last_block):
            stage_seconds, level_seconds = staged_ahead.seconds, staged_ahead.level_seconds
        else:
            own_staging_started = time.monotonic()
            _, level_seconds = self._stage(
                params, "batch staging steps", self._stage_round_trips(), first_block, last_block
            )
            stage_seconds = time.monotonic() - own_staging_started
        self._stage_seconds = stage_seconds
        groups_started = time.monotonic()
        self._batch_blocks = max(self._batch_blocks, last_block - first_block + 1)
        self._ahead = self._executor.submit(
            self._stage_ahead, params, self._stage_round_trips(), last_block + 1, last_block + self._batch_blocks
        )
        self._run_at_once(params, "processor groups", _GROUP_SQL, self._group_shares, first_block, last_block)
        finish_started = time.monotonic()
        cur.execute("SELECT haf_stats_app.finish_parallel_range(%s, %s)", (first_block, last_block))
        group_seconds: dict[str, float | None] = cur.fetchone()[0]
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
            "stage_seconds": round(stage_seconds, 6),
            "stage_level_seconds": [round(seconds, 6) for seconds in level_seconds],
            "group_seconds": {g: None if t is None else round(t, 6) for g, t in group_seconds.items()},
            "critical": _critical(stage_seconds, group_seconds),
        }))

    def _run_at_once(
        self,
        params: Mapping[str, str],
        kind: str,
        sql: str,
        shares: Sequence[Sequence[str]],
        first_block: int,
        last_block: int,
        check: str | None = None,
    ) -> list[Any]:
        """`sql` for each name of each share and the range: each share on a worker connection of
        its own, in one round trip, each name's statement committed there on its own, then
        `check`. Returns each share's value of `check` (None without one)."""
        if self._executor is None:
            raise RuntimeError("the coordinator has no executor")
        futures = [
            self._executor.submit(self._run_on_worker, params, kind, sql, names, first_block, last_block, check)
            for names in shares
        ]
        # Every share is waited for, failed or not, so no worker of this range is still running
        # when the next phase starts, or when the driver rolls back and asks for the range again.
        errors = [f.exception() for f in futures]
        failed = next((e for e in errors if e is not None), None)
        if failed is not None:
            raise failed
        return [f.result() for f in futures]

    def _stage_round_trips(self) -> list[list[list[str]]]:
        """The staging's round trips, one after another: each the shares of steps sent at once,
        a worker connection each. All the steps in one share while the last batch's staging was
        quick; otherwise a round trip per level and a share per step."""
        if self._stage_levels is None:
            raise RuntimeError("the coordinator has no staging steps")
        if self._stage_seconds < self._split_staging_seconds:
            return [[[step for level in self._stage_levels for step in level]]]
        return [[[step] for step in level] for level in self._stage_levels]

    def _stage(
        self,
        params: Mapping[str, str],
        kind: str,
        round_trips: Sequence[Sequence[Sequence[str]]],
        first_block: int,
        last_block: int,
        check: str | None = None,
    ) -> tuple[bool, tuple[float, ...]]:
        """The staging steps for the range, round trip by round trip; then whether `check` found
        the range staged, and each round trip's seconds. Every share of the last round trip runs
        `check` after its own steps: the share whose check runs last sees what every share
        committed."""
        complete: list[Any] = []
        seconds: list[float] = []
        for i, shares in enumerate(round_trips):
            final = i == len(round_trips) - 1
            started = time.monotonic()
            complete = self._run_at_once(
                params, kind, _STAGE_SQL, shares, first_block, last_block, check if final else None
            )
            seconds.append(time.monotonic() - started)
        return any(complete), tuple(seconds)

    def _prepare(self, cur: _Cursor) -> None:
        cur.execute("SELECT haf_stats_app.processor_groups(), haf_stats_app.shared_batch_stage_levels()")
        groups, levels = cur.fetchone()
        workers = min(self._parallelism, len(groups))
        # Dealt out in call order: connection i runs groups i, i + workers, ...
        self._group_shares = [list(groups[i::workers]) for i in range(workers)]
        self._stage_levels = [list(level) for level in levels]
        # Beside the groups' threads, the staging ahead's, waiting on the threads of the shares it
        # sends at once: one per step of a level at most.
        widest = max(len(level) for level in self._stage_levels)
        self._executor = ThreadPoolExecutor(max_workers=workers + 1 + widest, thread_name_prefix="haf_stats_group")

    def _staged_ahead(self) -> _Staged | None:
        """The range the previous batch staged ahead and how long that took, once that staging has
        finished; None when it did not complete one (or there was none)."""
        ahead, self._ahead = self._ahead, None
        if ahead is None:
            return None
        try:
            return ahead.result()
        except self._db_error:
            # _run_on_worker logged it; the batch stages its range itself.
            return None

    def _stage_ahead(
        self,
        params: Mapping[str, str],
        round_trips: Sequence[Sequence[Sequence[str]]],
        first_block: int,
        last_block: int,
    ) -> _Staged | None:
        started = time.monotonic()
        complete, level_seconds = self._stage(
            params, "batch staging ahead", round_trips, first_block, last_block, check=_STAGED_SQL
        )
        return _Staged(first_block, last_block, time.monotonic() - started, level_seconds) if complete else None

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
            worker = self._open_worker(params, kind)
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

    def _open_worker(self, params: Mapping[str, str], kind: str) -> _Connection:
        """A new worker connection in autocommit mode, holding HAF's shared lock on haf_stats."""
        worker = self._connect(**params)
        worker.autocommit = True
        worker.notices = []
        try:
            worker.cursor().execute(SESSION_LOCK_SQL)
        except self._db_error as e:
            self._log(f"{kind}: a new worker connection could not take HAF's lock on haf_stats: {str(e).strip()}")
            self._close(worker)
            raise
        finally:
            self._forward_notices(worker)
        return worker

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


def _critical(stage_seconds: float, group_seconds: Mapping[str, float | None]) -> str:
    """The longest of the batch's staging ("staging") and its groups."""
    critical, longest = "staging", stage_seconds
    for group, seconds in group_seconds.items():
        if seconds is not None and seconds > longest:
            critical, longest = group, seconds
    return critical


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

        _coordinator = ParallelCoordinator(
            parallelism_from_env(), psycopg2.connect, psycopg2.Error, split_staging_seconds_from_env()
        )
    _coordinator.process(conn, first_block, last_block)
