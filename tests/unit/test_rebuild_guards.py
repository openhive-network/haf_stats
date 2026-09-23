"""The rebuild scripts must be able to SEE the block processor (#85).

Four of the eight destructive rebuild scripts refuse to run while a processor is
connected (the other four carry no guard at all -- see UNGUARDED below). Before
#85 they looked for `state <> 'idle' AND query ILIKE 'CALL%haf_stats_app.main%'`. Under
the generic HAF driver both halves are false whenever the processor is live -- it runs
`CALL haf_stats_app.process_blocks(...)`, and it idles between ranges by design -- so the
guard would have reported "no processor" and let a TRUNCATE-and-replay-from-genesis run
against a live writer. That is the #42 double-count corruption the guard exists to
prevent, and three independent reviewers found it.

These are static assertions on the shell source rather than behavioural tests because the
guard is a SQL string handed to psql: there is no lane that runs these scripts against a
database, and a string test that cannot drift is worth more than no test at all.
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]

# Discovered, not hardcoded: a new rebuild script must not get zero coverage by default.
ALL_REBUILDS = sorted((REPO / "scripts").glob("rebuild_*.sh"))

# The four that TRUNCATE without any live-processor guard. PRE-EXISTING and not touched by
# #85 -- rebuild_custom_json.sh in particular TRUNCATEs and replays additively, which is
# the same #42 class the guard exists for -- so they are listed rather than fixed here, and
# the list is closed: a NEW unguarded script fails test_every_rebuild_script_is_accounted_for.
UNGUARDED = {
    "rebuild_account_cohorts.sh",
    "rebuild_content_cohorts.sh",
    "rebuild_custom_json.sh",
    "rebuild_financial.sh",
}

REBUILDS = [p for p in ALL_REBUILDS if p.name not in UNGUARDED]


def test_every_rebuild_script_is_accounted_for():
    """Either it carries the guard, or it is on the known-unguarded list."""
    missing = [p.name for p in ALL_REBUILDS
               if p.name not in UNGUARDED and "count_live_processors" not in p.read_text(encoding="utf-8")]
    assert not missing, f"rebuild scripts with no live-processor guard and not on the list: {missing}"
    stale = [n for n in UNGUARDED if n not in {p.name for p in ALL_REBUILDS}]
    assert not stale, f"UNGUARDED names a script that no longer exists: {stale}"


@pytest.mark.parametrize("script", REBUILDS, ids=lambda p: p.name)
def test_the_guard_matches_the_driver_backend(script: Path):
    body = script.read_text(encoding="utf-8")
    assert "application_name = 'haf_stats_block_processing'" in body, (
        f"{script.name}'s live-processor guard cannot see a driver backend"
    )


def _code(script: Path) -> str:
    """The script with comment lines removed.

    The assertion below forbids a string that the comment explaining WHY it is forbidden
    necessarily contains, so it has to look at code only.
    """
    return chr(10).join(
        line for line in script.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    )


@pytest.mark.parametrize("script", REBUILDS, ids=lambda p: p.name)
def test_the_guard_does_not_skip_idle_backends(script: Path):
    """The driver idles between ranges, so `state <> 'idle'` hides a live processor for
    most of the wall clock."""
    assert "state <> 'idle'" not in _code(script), (
        f"{script.name} filters out idle backends, which is what the driver looks like"
    )


@pytest.mark.parametrize("script", REBUILDS, ids=lambda p: p.name)
def test_the_guard_still_matches_the_legacy_loop(script: Path):
    """A rebuild script from a new image may run against a processor container still on
    an older one, which tags nothing."""
    body = script.read_text(encoding="utf-8")
    assert "CALL%haf_stats_app.main%" in body
    assert "CALL%haf_stats_app.process_blocks%" in body


@pytest.mark.parametrize("script", REBUILDS, ids=lambda p: p.name)
def test_the_remedy_does_not_promise_stop_processing_alone(script: Path):
    """stop_processing() sets a column the driver never reads. The instruction an operator
    is given has to work under both loops, so it leads with stopping the container.

    _code(), not the raw file: every one of these scripts says the same thing in a header
    COMMENT, so reading the file whole made this assertion unfailable. Mutation testing
    caught it -- reverting the operator message to the pre-#85 wording, and deleting the
    message outright, both passed.
    """
    code = _code(script)
    assert "stop the haf-stats-process container" in code
    # And the message must not offer either alternative as if it cleared this check:
    # stop_processing() does not touch the driver, and a paused driver stays connected.
    assert "the equivalent is" not in code
