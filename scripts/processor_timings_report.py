#!/usr/bin/env python3
"""Per-processor timings of a block-processing run, as a JSON report and a table.

    processor_timings_report.py --log DRIVER_LOG --out REPORT.json
        --first-block N --last-block M --sync-seconds S
        [--deferred-log DEFERRED_LOG --deferred-seconds D]

DRIVER_LOG is haf_app_driver.py's output (with --server-messages=INFO) for a run with
haf_stats.processor_timings = on (db/process_block_range.sql): one
`haf_stats_processor_timing {...}` line per processor per batch, one per rollup refresh
a processor ran, and one `haf_stats_operation_counts {...}` line per batch. Every other
line is ignored. The batches must cover blocks N..M exactly, each with every processor
timed once and its operations counted once; anything else -- no timings at all, a line
that is not JSON, a negative time, a missing or unknown step, a refresh credited to the
wrong processor, a gap or an overlap -- exits 1 naming the problem and writes no report.

The report holds each processor's and each refresh's wall time over the whole run and per
1,000,000 blocks (a batch counts towards the million its first block is in), the rows
each processor read by op type, and the run's wall time as measured by the caller. A
refresh runs inside its processor, so its seconds are also part of that processor's.

During massive sync the processors skip their refreshes and record them instead, and
haf_stats_app.run_deferred_rollup_refreshes() runs each once afterwards
(db/haf_stats_app.sql). DEFERRED_LOG is that call's output, with one
`haf_stats_deferred_refresh_timing {...}` line per refresh it ran, and D its wall time;
the report then holds each one's seconds as well. They are outside the sync wall time.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

#: The steps db/process_block_range.sql calls, in call order.
PROCESSORS: tuple[str, ...] = (
    "prepare_batch_ops",
    "process_financial",
    "prepare_batch_authored_ops",
    "process_account_cohorts",
    "process_active_users",
    "process_community_registry",
    "process_content_stats",
    "process_content_cohorts",
    "prepare_batch_exact_rc",
    "prepare_batch_rollup_ops",
    "process_custom_json",
    "process_network_ops",
    "process_network_custom_json",
    "process_witness_blocks",
)

#: Each rollup/period/retention refresh, and the processor it runs inside. A refresh runs
#: only on a batch that crosses its block boundary, so a batch may time none of them.
REFRESHES: dict[str, str] = {
    "refresh_financial_monthly": "process_financial",
    "refresh_account_cohort_retention": "process_account_cohorts",
    "refresh_active_users_periods": "process_active_users",
    "refresh_active_users_account_monthly": "process_active_users",
    "refresh_network_vote_periods": "process_content_stats",
    "refresh_network_content_periods": "process_content_stats",
    "refresh_engagement_touched": "process_content_stats",
    "refresh_author_cohort_retention": "process_content_cohorts",
}

#: The "reads" entry that stands for every non-virtual op type.
NON_VIRTUAL = "non_virtual"

BUCKET_BLOCKS = 1_000_000

_LINE = re.compile(r"\b(haf_stats_processor_timing|haf_stats_operation_counts) (.*?)\s*$")
_DEFERRED_LINE = re.compile(r"\bhaf_stats_deferred_refresh_timing (.*?)\s*$")


class TimingsError(Exception):
    """The timings cannot make a report: empty, malformed, or not covering the range."""


@dataclass(frozen=True)
class _Timing:
    first_block: int
    last_block: int
    step: str
    within: str | None
    seconds: float
    reads: tuple[str, ...]


@dataclass(frozen=True)
class _Count:
    op_type: str
    virtual: bool
    rows: int


@dataclass(frozen=True)
class _Counts:
    first_block: int
    last_block: int
    seconds: float
    counts: tuple[_Count, ...]


def _field(record: Mapping[str, Any], key: str, kind: type | tuple[type, ...], where: str) -> Any:
    value = record.get(key)
    if (kind is not bool and isinstance(value, bool)) or not isinstance(value, kind):
        raise TimingsError(f"{where}: '{key}' is {value!r}")
    return value


def _seconds(record: Mapping[str, Any], where: str) -> float:
    value = float(_field(record, "seconds", (int, float), where))
    if value < 0:
        raise TimingsError(f"{where}: 'seconds' is negative ({value})")
    return value


def _range(record: Mapping[str, Any], where: str) -> tuple[int, int]:
    first = _field(record, "first_block", int, where)
    last = _field(record, "last_block", int, where)
    if first < 1 or last < first:
        raise TimingsError(f"{where}: block range {first}..{last}")
    return first, last


def _timing(record: Mapping[str, Any], where: str) -> _Timing:
    first, last = _range(record, where)
    step = _field(record, "step", str, where)
    within = record.get("within")
    if step in PROCESSORS:
        if within is not None:
            raise TimingsError(f"{where}: processor {step} is timed within {within!r}")
    elif step in REFRESHES:
        if within != REFRESHES[step]:
            raise TimingsError(f"{where}: {step} is timed within {within!r}, not {REFRESHES[step]}")
    else:
        raise TimingsError(f"{where}: unknown step {step!r}")
    reads = _field(record, "reads", list, where)
    if not all(isinstance(r, str) for r in reads):
        raise TimingsError(f"{where}: 'reads' is {reads!r}")
    return _Timing(first, last, step, within, _seconds(record, where), tuple(reads))


def _counts(record: Mapping[str, Any], where: str) -> _Counts:
    first, last = _range(record, where)
    counts = []
    for c in _field(record, "counts", list, where):
        if not isinstance(c, dict):
            raise TimingsError(f"{where}: a count is {c!r}")
        rows = _field(c, "rows", int, where)
        if rows < 0:
            raise TimingsError(f"{where}: 'rows' is negative ({rows})")
        counts.append(_Count(_field(c, "op_type", str, where), _field(c, "virtual", bool, where), rows))
    return _Counts(first, last, _seconds(record, where), tuple(counts))


def parse_log(lines: Iterable[str]) -> tuple[list[_Timing], list[_Counts]]:
    """The timing and operation-count records in a driver log, validated one by one.

    :raises TimingsError: a record is not JSON, or is not the shape its line names.
    """
    timings: list[_Timing] = []
    counts: list[_Counts] = []
    for number, line in enumerate(lines, 1):
        m = _LINE.search(line)
        if m is None:
            continue
        where = f"line {number}"
        try:
            record = json.loads(m.group(2))
        except json.JSONDecodeError as exc:
            raise TimingsError(f"{where}: not JSON ({exc})") from exc
        if not isinstance(record, dict):
            raise TimingsError(f"{where}: not a JSON object")
        if m.group(1) == "haf_stats_processor_timing":
            timings.append(_timing(record, where))
        else:
            counts.append(_counts(record, where))
    return timings, counts


def parse_deferred_log(lines: Iterable[str]) -> dict[str, float]:
    """Each deferred refresh's seconds, from run_deferred_rollup_refreshes()'s output.

    :raises TimingsError: a line is not JSON, names a step that is not a refresh, times one
        twice, or there is no line at all.
    """
    seconds: dict[str, float] = {}
    for number, line in enumerate(lines, 1):
        m = _DEFERRED_LINE.search(line)
        if m is None:
            continue
        where = f"deferred log line {number}"
        try:
            record = json.loads(m.group(1))
        except json.JSONDecodeError as exc:
            raise TimingsError(f"{where}: not JSON ({exc})") from exc
        if not isinstance(record, dict):
            raise TimingsError(f"{where}: not a JSON object")
        step = _field(record, "step", str, where)
        if step not in REFRESHES:
            raise TimingsError(f"{where}: unknown refresh {step!r}")
        if step in seconds:
            raise TimingsError(f"{where}: {step} is timed twice")
        seconds[step] = _seconds(record, where)
    if not seconds:
        raise TimingsError("no deferred refresh timings: did the run record any, and was "
                           "haf_stats.processor_timings on for run_deferred_rollup_refreshes()?")
    return seconds


_Batch = tuple[tuple[int, int], dict[str, _Timing], _Counts]


def _batches(timings: list[_Timing], counts: list[_Counts], first_block: int, last_block: int) -> list[_Batch]:
    by_batch: dict[tuple[int, int], dict[str, _Timing]] = defaultdict(dict)
    for t in timings:
        batch = by_batch[(t.first_block, t.last_block)]
        if t.step in batch:
            raise TimingsError(f"batch {t.first_block}..{t.last_block}: {t.step} is timed twice")
        batch[t.step] = t
    counts_by_batch: dict[tuple[int, int], _Counts] = {}
    for c in counts:
        key = (c.first_block, c.last_block)
        if key in counts_by_batch:
            raise TimingsError(f"batch {key[0]}..{key[1]}: operations are counted twice")
        counts_by_batch[key] = c
    if not by_batch:
        raise TimingsError("no processor timings: was haf_stats.processor_timings on, and the driver's "
                           "--server-messages INFO, for the run?")
    for key in by_batch.keys() | counts_by_batch.keys():
        missing = [p for p in PROCESSORS if p not in by_batch.get(key, {})]
        if missing:
            raise TimingsError(f"batch {key[0]}..{key[1]}: no timing for {', '.join(missing)}")
        if key not in counts_by_batch:
            raise TimingsError(f"batch {key[0]}..{key[1]}: no operation counts")
    expected = first_block
    for first, last in sorted(by_batch):
        if first != expected:
            raise TimingsError(f"batch {first}..{last} follows block {expected - 1}: "
                               + ("a gap" if first > expected else "an overlap"))
        expected = last + 1
    if expected != last_block + 1:
        raise TimingsError(f"the batches end at block {expected - 1}, not {last_block}")
    return [(key, by_batch[key], counts_by_batch[key]) for key in sorted(by_batch)]


def _rounded(seconds: float) -> float:
    return round(seconds, 3)


def _rows_read(reads: tuple[str, ...], per_type: Mapping[str, int], non_virtual: int) -> dict[str, int]:
    return {r: (non_virtual if r == NON_VIRTUAL else per_type.get(r, 0)) for r in reads}


def build_report(timings: list[_Timing], counts: list[_Counts], *, first_block: int, last_block: int,
                 sync_seconds: float, deferred: Mapping[str, float] | None = None,
                 deferred_seconds: float | None = None) -> dict[str, Any]:
    """The report for one run: totals, the per-million split and the rows read, and, given
    ``deferred`` (parse_deferred_log) and its wall time, the deferred refreshes' seconds.

    :raises TimingsError: the records do not tile ``first_block..last_block`` with every
        processor timed and the operations counted once per batch, or a wall time is
        negative.
    """
    if sync_seconds < 0 or (deferred_seconds is not None and deferred_seconds < 0):
        raise TimingsError("a wall time is negative")
    batches = _batches(timings, counts, first_block, last_block)
    steps = PROCESSORS + tuple(REFRESHES)
    totals: dict[str, float] = dict.fromkeys(steps, 0.0)
    calls: dict[str, int] = dict.fromkeys(steps, 0)
    rows_read: dict[str, dict[str, int]] = {p: defaultdict(int) for p in PROCESSORS}
    operations: dict[str, int] = defaultdict(int)
    instrumentation = 0.0
    buckets: dict[int, dict[str, Any]] = {}
    for (first, _last), by_step, batch_counts in batches:
        per_type: dict[str, int] = defaultdict(int)
        non_virtual = 0
        for c in batch_counts.counts:
            per_type[c.op_type] += c.rows
            operations[c.op_type] += c.rows
            if not c.virtual:
                non_virtual += c.rows
        instrumentation += batch_counts.seconds
        index = (first - 1) // BUCKET_BLOCKS
        bucket = buckets.setdefault(index, {
            "first_block": index * BUCKET_BLOCKS + 1,
            "last_block": (index + 1) * BUCKET_BLOCKS,
            "batches": 0,
            "seconds": dict.fromkeys(steps, 0.0),
        })
        bucket["batches"] += 1
        for step, t in by_step.items():
            totals[step] += t.seconds
            calls[step] += 1
            bucket["seconds"][step] += t.seconds
            if step in rows_read:
                for op_type, rows in _rows_read(t.reads, per_type, non_virtual).items():
                    rows_read[step][op_type] += rows
    processing = sum(totals[p] for p in PROCESSORS)
    per_million = []
    for index in sorted(buckets):
        bucket = buckets[index]
        bucket["processing_seconds"] = _rounded(sum(bucket["seconds"][p] for p in PROCESSORS))
        bucket["seconds"] = {s: _rounded(v) for s, v in bucket["seconds"].items()}
        per_million.append(bucket)

    def entry(step: str) -> dict[str, Any]:
        return {"seconds": _rounded(totals[step]), "calls": calls[step],
                "share": round(totals[step] / processing, 4) if processing else 0.0}

    blocks = last_block - first_block + 1
    return {
        "first_block": first_block,
        "last_block": last_block,
        "batches": len(batches),
        "sync_wall_seconds": _rounded(sync_seconds),
        "blocks_per_second": round(blocks / sync_seconds, 1) if sync_seconds > 0 else None,
        "processing_seconds": _rounded(processing),
        "instrumentation_seconds": _rounded(instrumentation),
        "processors": {p: entry(p) for p in PROCESSORS},
        "refreshes": {r: {**entry(r), "within": REFRESHES[r]} for r in REFRESHES},
        "per_million": per_million,
        "rows_read": {p: dict(sorted(r.items())) for p, r in rows_read.items()},
        "operations": dict(sorted(operations.items())),
        "deferred_refreshes": None if deferred is None else {
            "wall_seconds": _rounded(deferred_seconds or 0.0),
            "seconds": {r: _rounded(deferred.get(r, 0.0)) for r in REFRESHES},
        },
    }


def summary_table(report: Mapping[str, Any]) -> str:
    """The report's seconds per processor and per refresh, total and per million blocks, as text."""
    buckets = report["per_million"]
    heads = [f"{b['first_block'] // BUCKET_BLOCKS}M-{b['last_block'] // BUCKET_BLOCKS}M" for b in buckets]
    width = max(len(s) for s in (*PROCESSORS, *(f"  {r}" for r in REFRESHES), "all processors"))

    def row(label: str, entry: Mapping[str, Any], step: str) -> str:
        return (f"{label:<{width}}  {entry['seconds']:>9.2f}  {entry['share']:>6.1%}  {entry['calls']:>6}  "
                + "  ".join(f"{b['seconds'][step]:>9.2f}" for b in buckets))

    lines = [f"{'step':<{width}}  {'total s':>9}  {'share':>6}  {'calls':>6}  "
             + "  ".join(f"{h:>9}" for h in heads)]
    for p in PROCESSORS:
        lines.append(row(p, report["processors"][p], p))
        for r, parent in REFRESHES.items():
            if parent == p:
                lines.append(row(f"  {r}", report["refreshes"][r], r))
    lines.append(f"{'all processors':<{width}}  {report['processing_seconds']:>9.2f}  {'':>6}  {'':>6}  "
                 + "  ".join(f"{b['processing_seconds']:>9.2f}" for b in buckets))
    lines.append("(indented: refreshes, whose seconds are also in the processor above them)")
    lines.append(f"sync wall {report['sync_wall_seconds']:.1f}s over {report['batches']} batches"
                 f" (blocks {report['first_block']}..{report['last_block']}),"
                 f" instrumentation {report['instrumentation_seconds']:.1f}s")
    deferred = report.get("deferred_refreshes")
    if deferred is not None:
        lines.append(f"deferred refreshes, after the sync: {deferred['wall_seconds']:.1f}s wall")
        lines += [f"  {r:<{width - 2}}  {s:>9.2f}" for r, s in deferred["seconds"].items()]
    lines.append("rows read:")
    for p in PROCESSORS:
        read = report["rows_read"][p]
        if read:
            lines.append(f"  {p}: " + ", ".join(f"{op} {rows}" for op, rows in read.items()))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--log", required=True, type=Path, help="haf_app_driver.py's output")
    parser.add_argument("--out", required=True, type=Path, help="where the JSON report goes")
    parser.add_argument("--first-block", required=True, type=int)
    parser.add_argument("--last-block", required=True, type=int)
    parser.add_argument("--sync-seconds", required=True, type=float, help="the timed run's wall time")
    parser.add_argument("--deferred-log", type=Path, help="run_deferred_rollup_refreshes()'s output")
    parser.add_argument("--deferred-seconds", type=float, help="that call's wall time")
    args = parser.parse_args(argv)
    if (args.deferred_log is None) != (args.deferred_seconds is None):
        parser.error("--deferred-log and --deferred-seconds go together")
    try:
        with args.log.open(encoding="utf-8", errors="replace") as log:
            timings, counts = parse_log(log)
        deferred = None
        if args.deferred_log is not None:
            with args.deferred_log.open(encoding="utf-8", errors="replace") as log:
                deferred = parse_deferred_log(log)
        report = build_report(timings, counts, first_block=args.first_block, last_block=args.last_block,
                              sync_seconds=args.sync_seconds, deferred=deferred,
                              deferred_seconds=args.deferred_seconds)
    except (OSError, TimingsError) as exc:
        print(f"no report: {exc}", file=sys.stderr)
        return 1
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(summary_table(report))
    print(f"report: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
