"""Both block drivers check hivemind before anything else in the batch runs (#123).

While hivemind is behind, the batch is rolled back and asked for again -- every 5 s under
haf_app_driver.py, every second in the legacy loop. Anything placed before the check runs
on every one of those tries and is then thrown away: prepare_rollup_refreshes, outside
massive sync, can rebuild whole rollups. tests/ci_driver_hivemind_retry.py shows the check
works; it cannot see where in the procedure it sits, so this pins the order.
"""

from __future__ import annotations

import re
from pathlib import Path

SQL = (Path(__file__).resolve().parents[2] / "db" / "haf_stats_app.sql").read_text(encoding="utf-8")


def _body(procedure: str) -> str:
    start = SQL.index(f"CREATE OR REPLACE PROCEDURE haf_stats_app.{procedure}(")
    begin = SQL.index("$$", start) + 2
    return SQL[begin:SQL.index("$$", begin)]


def _code(body: str) -> str:
    return re.sub(r"--[^\n]*", "", body)


def _first(body: str, call: str) -> int:
    position = body.find(call)
    assert position >= 0, f"{call} not found"
    return position


def test_process_blocks_checks_hivemind_first() -> None:
    body = _code(_body("process_blocks"))
    check = _first(body, "haf_stats_app.require_content_source(")
    for later in ("hive.get_current_stage_name(", "SET synchronous_commit", "haf_stats_app.prepare_rollup_refreshes(",
                  "haf_stats_app.process_block_range(", "UPDATE haf_stats_app.app_status"):
        assert check < _first(body, later), f"process_blocks runs {later} before require_content_source"


def test_main_checks_hivemind_first_in_each_iteration() -> None:
    body = _code(_body("main"))
    loop = body[_first(body, "LOOP"):]
    check = _first(loop, "haf_stats_app.hivemind_behind(_block_range.last_block)")
    assert _first(loop, "hive.app_next_iteration(") < check
    for later in ("hive.get_current_stage_name(", "haf_stats_app.prepare_rollup_refreshes(",
                  "haf_stats_app.process_block_range(", "UPDATE haf_stats_app.app_status"):
        assert check < _first(loop, later), f"main() runs {later} before hivemind_behind"
    # The not-yet branch rolls back before it sleeps, then asks again.
    branch = loop[check:_first(loop, "haf_stats_app.prepare_rollup_refreshes(")]
    assert re.search(r"ROLLBACK;.*pg_sleep\(.*CONTINUE;", branch, re.S), branch
