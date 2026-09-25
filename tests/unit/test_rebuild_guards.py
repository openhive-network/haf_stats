"""Every destructive rebuild script refuses to run while a block processor is live (#98).

All eight `rebuild_*.sh` scripts TRUNCATE their tables and replay them -- from block 1
by default, or from `community_start_block()` in the community-registry case.
Five replay through an ADDITIVE upsert (`col = tbl.col + EXCLUDED.col`), so a processor
appending head blocks during the replay is counted twice -- issue #42 -- and anything it
wrote before the TRUNCATE is gone. Four of the eight carried no guard at all until #98.

Two things changed here and the tests changed shape with them:

* The guard moved into `scripts/common.sh`. It used to be copy-pasted into four scripts,
  which is what #85 cost: the generic HAF driver changed what a live processor looks like
  (`CALL ... process_blocks`, idle between ranges), one predicate went stale, and it had
  to be fixed in four files. So the predicate is asserted ONCE, where it lives.
* The per-script assertions are now BEHAVIOURAL. The old ones grepped each script for
  guard text, which cannot tell a guard that runs from one that is never called, sits
  after the TRUNCATE, or fails open when psql returns nothing. Every script below is run
  under a stub `psql` that answers its reads, and the assertion is on what it did: did
  it destroy data, and with what exit status.

NOT COVERED, stated plainly:

* The SQL text itself. Nothing here runs against PostgreSQL, so an arm of the predicate
  that matches no real backend would pass -- that is what the static assertions on
  common.sh are for, and they are a weaker instrument.
* Destruction that no regex can name. DESTRUCTIVE lists verbs, so a rebuild script that
  called a FUNCTION which truncates -- `SELECT haf_stats_app.reset_everything()` -- would
  destroy data above the guard with this suite green. Reading the .sql a script loads with
  -f is covered; reading the body of a stored function is not.
* PRIVILEGE. Nothing here runs as a role other than the processor's. For a backend owned
  by another role, pg_stat_activity shows `query` as '<insufficient privilege>' and NULLs
  `state` unless the reader holds pg_read_all_stats/pg_monitor or is superuser, so the two
  query arms of the predicate go dead -- while `application_name`, which the guard leads
  with, stays visible to every role. The guard therefore still works; what a foreign role
  loses is the fallback for a processor image predating the tag. (An earlier version of
  this list said all three arms die and the count returns 0. That was wrong.)
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, stub_bin, write_exec

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"
COMMON = SCRIPTS / "common.sh"

# Discovered, not hardcoded: a new rebuild script must not get zero coverage by default.
ALL_REBUILDS = sorted(SCRIPTS.glob("rebuild_*.sh"))

# Every script's replay is one batch under the stub, so these resolve in milliseconds.
# The timeout is a HANG detector: wait_for_postgres is an unbounded `until pg_isready`,
# and a stub that fails to answer a read leaves the script spinning.
TIMEOUT = 60

APP_BLOCK = "100"

# What counts as destroying data. A blacklist of VERBS, not a whitelist of spellings,
# because two rounds of review walked through the whitelist: the literal `TRUNCATE TABLE`
# missed `TRUNCATE tbl` (equally legal SQL), and anchoring on the schema then missed a
# quoted identifier (`"haf_stats_backend".x`), a search_path-relative name, and the zeroing
# `UPDATE ... SET col = 0` that rebuild_content_volume.sh ALREADY issues. Each of those
# destroyed data above the guard with every test in this file green.
#
# The price of a blacklist is prose: these scripts print the word TRUNCATE in operator
# messages. So it is applied to STATEMENTS -- the stub's log, where prose never appears,
# and script text with its `echo`/`log`/`printf` lines removed.
DESTRUCTIVE = re.compile(
    r"\b(?:TRUNCATE\b|DELETE\s+FROM\b|UPDATE\b"
    r"|DROP\s+(?:TABLE|SCHEMA|MATERIALIZED\s+VIEW|VIEW|INDEX|SEQUENCE)\b"
    r"|ALTER\s+TABLE[^;]*?\bDROP\b)",
    re.IGNORECASE,
)

# A leading redirection is legal and common (`>&2 echo "..."`), and a continued call keeps
# talking on its next physical line. Both were treated as statements, so a message
# mentioning TRUNCATE above the guard turned the suite RED on correct code -- and this
# delta itself added continued consequence lines that say "TRUNCATE".
_SAYS = re.compile(r"^\s*(?:[0-9]?>>?&?[0-9]*\s*)*(?:echo|log|printf)\b")
_HEREDOC = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")


def _statements(script: Path) -> str:
    """The script's code with everything that only TALKS to the operator removed.

    Line-based stripping is not enough: `_strip_logical_lines` twenty lines below already
    follows backslash continuations and says why, and a heredoc body is prose that no
    regex over single lines can tell from SQL.
    """
    kept, lines, i = [], _code(script).splitlines(), 0
    while i < len(lines):
        line = lines[i]
        heredoc = _HEREDOC.search(line)
        talking = bool(_SAYS.match(line))
        if talking:
            while i < len(lines) and lines[i].rstrip().endswith(chr(92)):
                i += 1
            i += 1
            continue
        if heredoc:
            terminator = heredoc.group(1)
            kept.append(line[:heredoc.start()])
            i += 1
            while i < len(lines) and lines[i].strip() != terminator:
                i += 1
            i += 1
            continue
        kept.append(line)
        i += 1
    return chr(10).join(kept)


def _first_destructive(text: str) -> int:
    match = DESTRUCTIVE.search(text)
    assert match is not None, "no destructive statement found; re-check this suite"
    return match.start()


def _strip_logical_lines(body: str, commands: tuple[str, ...]) -> str:
    """Remove each named command and its continuation lines.

    Following the backslashes matters: three of the eight scripts already spell the
    post-replay call across continued lines, and a stripper that deletes only the first
    line leaves the consequence text behind as a command of its own -- `command not found`,
    exit 127, and a failure in the one test whose docstring says every other result here is
    suspect. That is a false alarm on the loudest siren in the file.
    """
    out, lines, i = [], body.splitlines(), 0
    while i < len(lines):
        line = lines[i]
        if any(line.startswith(c) for c in commands):
            while lines[i].rstrip().endswith(chr(92)):
                i += 1
            i += 1
            continue
        out.append(line)
        i += 1
    return chr(10).join(out) + chr(10)


def _code(path: Path) -> str:
    """The file with comment lines removed.

    Assertions below forbid strings that the comments explaining WHY they are forbidden
    necessarily contain, so they have to look at code only.
    """
    return chr(10).join(
        line for line in path.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    )


# --------------------------------------------------------------------------------------
# The predicate, asserted once, where it now lives.
# --------------------------------------------------------------------------------------

# The whole predicate, not its arms one substring at a time. Two mutations that a grep
# cannot see, both found by review: `AND FALSE` prepended (the guard matches nothing and
# every test still passed), and `state NOT IN ('idle')` -- the #85 regression in a
# different spelling, where an assertion looking for the literal `state <> 'idle'` sails
# past it. A whole-block compare rejects any added clause however it is written.
LIVE_PROCESSOR_MATCH = chr(10).join([
    '_LIVE_PROCESSOR_MATCH="',
    '          AND (',
    "               application_name = 'haf_stats_block_processing'",
    "            OR BTRIM(query) ILIKE 'CALL%haf_stats_app.main%'",
    "            OR BTRIM(query) ILIKE 'CALL%haf_stats_app.process_blocks%'",
    '          )"',
])


GUARD_FUNCTIONS = (
    "count_live_processors",
    "report_live_processors",
    "_read_live_processor_count",
    "refuse_if_processor_live",
    "refuse_if_processor_started_during_rebuild",
)


def _definitions_of(name: str, text: str) -> int:
    """Count function definitions of `name`, in every spelling bash accepts.

    Both forms, and with the brace on either line: `name() {`, `name()` + `{`,
    `function name {`, `function name() {`. The parentheses or the `function` keyword are
    what make it a definition -- without requiring one of them, a plain CALL at the start
    of a line counts as a definition, which made every rebuild script look like it
    redefined the guard.
    """
    escaped = re.escape(name)
    pattern = (
        r"^[ \t]*(?:" + escaped + r"[ \t]*\([ \t]*\)"
        r"|function[ \t]+" + escaped + r"(?:[ \t]*\([ \t]*\))?"
        r")[ \t]*\{?[ \t]*$"
    )
    return len(re.findall(pattern, text, re.MULTILINE))


def _assignments_to(name: str, text: str) -> int:
    """Count assignments to `name`, INCLUDING `+=`, `declare` and `printf -v`."""
    return len(re.findall(
        r"^[ \t]*(?:(?:declare|typeset|local|export|readonly)[ \t]+(?:-[A-Za-z]+[ \t]+)?)?"
        + re.escape(name) + r"[ \t]*\+?=",
        text, re.MULTILINE,
    )) + len(re.findall(r"\bprintf[ \t]+-v[ \t]+" + re.escape(name) + r"\b", text))


@pytest.mark.parametrize("name", GUARD_FUNCTIONS)
def test_each_guard_function_is_defined_exactly_once(name):
    """Last definition wins, so "the right text is present" is not the same as "the right
    text runs".

    The whole-block compares below are containment checks: appending a second
    `count_live_processors` that returns a plausible query leaves the asserted block
    untouched and makes production count zero forever. Counting a literal `name() {` is
    not enough either -- `name()` with the brace on the next line, and `function name {`,
    are the same definition in three spellings, and two of them passed this test.
    """
    assert _definitions_of(name, _code(COMMON)) == 1, (
        f"{name} is defined more than once in common.sh; the last one wins"
    )


def test_the_predicate_is_assigned_exactly_once():
    """`+=` is an assignment. Appending `_LIVE_PROCESSOR_MATCH+=" AND FALSE"` leaves the
    asserted block intact, makes the predicate match nothing, and passed every test in
    this file."""
    assert _assignments_to("_LIVE_PROCESSOR_MATCH", _code(COMMON)) == 1, (
        "_LIVE_PROCESSOR_MATCH is assigned more than once in common.sh; the last one wins"
    )


def test_the_predicate_is_exactly_what_this_suite_was_written_against():
    """#85: the driver tags its connection and idles between ranges, so the predicate must
    match on the tag and must not filter on `state`. The legacy `CALL ... main` arm stays
    for a processor container still running an older image, which tags nothing.

    _code(), not the raw file: the comments above the predicate necessarily quote it.
    """
    assert LIVE_PROCESSOR_MATCH in _code(COMMON), (
        "the live-processor predicate is not what this suite was written against"
    )


def test_the_guard_uses_the_tag_the_processor_actually_sets():
    """The two literals are written in different files and nothing made them agree.

    Renaming the tag in process_blocks.sh and in its own test -- the natural "update the
    test with the code" move -- left the whole suite green with the driver arm of this
    guard permanently unable to fire. So read the tag from the processor and require the
    guard to use THAT value.
    """
    # _statements(), not _code(): _code strips whole-line comments only, so a `log` line
    # mentioning application_name=haf_stats_block_processing satisfied a literal search
    # while the URI itself had been parameterised to a different tag -- the exact
    # regression this test names, passing.
    processor = _statements(SCRIPTS / "process_blocks.sh")
    uri = re.findall(r"application_name=([A-Za-z0-9_]+)", processor)
    pgappname = re.findall(r"""PGAPPNAME=["']?([A-Za-z0-9_]+)["']?""", processor)
    # Each site must still be LITERAL and present: swapping the driver URI's literal for
    # ${_DRIVER_APPNAME} left one literal, one distinct value and a driver arm that could
    # never fire. But "at least one, all agreeing" rather than "exactly one" -- a second
    # legitimately tagged connection (process_blocks.sh already contemplates one for the
    # healthcheck) is a correct edit and must not be a failure.
    assert uri, "no literal application_name= in the driver URI"
    assert pgappname, "no literal PGAPPNAME= for the legacy loop"
    tags = set(uri) | set(pgappname)
    assert len(tags) == 1, f"process_blocks.sh tags its connection inconsistently: {tags}"
    tag = tags.pop()
    assert f"application_name = '{tag}'" in _code(COMMON), (
        f"the guard does not match the tag process_blocks.sh sets ({tag})"
    )


# Compared WHOLE rather than grepped, following tests/unit/test_uninstall_app.py: a
# substring search cannot tell a query that counts the right backends from one whose
# scoping was dropped from the counting arm and left in the reporting arm, which is what a
# careless edit produces. Both clauses are load-bearing in opposite directions --
# pg_stat_activity is CLUSTER-wide, so without `datname` an unrelated HAF app's main()
# blocks every rebuild here and the operator's only remedy is to stop someone else's app;
# without `pid <> pg_backend_pid()` this query counts ITSELF and nothing ever runs.
COUNT_QUERY = chr(10).join([
    'count_live_processors() {',
    '    psql_cmd -Atc "',
    '        SELECT COUNT(*)',
    '        FROM pg_stat_activity',
    '        WHERE pid <> pg_backend_pid()',
    '          AND datname = current_database()',
    '          ${_LIVE_PROCESSOR_MATCH}',
    '    "',
    '}',
])


def test_the_count_query_is_scoped_to_this_database_and_excludes_itself():
    assert COUNT_QUERY in _code(COMMON), (
        "the live-processor count query is not what this suite was written against"
    )


def test_the_remedy_does_not_promise_stop_processing_alone():
    """stop_processing() sets a column the driver never reads, and hive.app_pause() leaves
    the driver connected. The instruction an operator is given has to work under both
    loops, so it leads with stopping the container."""
    code = _code(COMMON)
    assert "stop the haf-stats-process container" in code
    assert "the equivalent is" not in code


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_no_script_keeps_its_own_copy_of_the_predicate(script: Path):
    """The point of #98 is one home for it. A second copy is how #85 happened.

    A script can opt out of the shared guard without holding a copy of it: appending
    `_LIVE_PROCESSOR_MATCH+=" AND FALSE"` after it sources common.sh neutralises the
    predicate for that script alone, and a literal `_LIVE_PROCESSOR_MATCH=` search does
    not see `+=`. So this counts assignments and definitions the way bash does.
    """
    body = _code(script)
    assert _assignments_to("_LIVE_PROCESSOR_MATCH", body) == 0, (
        f"{script.name} assigns the shared predicate; it would apply to this script alone"
    )
    for name in GUARD_FUNCTIONS:
        assert _definitions_of(name, body) == 0, (
            f"{script.name} defines its own {name}, overriding the shared one"
        )


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_the_guard_is_called_before_the_first_truncate(script: Path):
    """Ordering, which no substring search can see: a guard below the TRUNCATE guards
    nothing. Behavioural coverage proves this too -- this states it where it reads."""
    code = _statements(script)
    assert "refuse_if_processor_live" in code, f"{script.name} never calls the guard"
    assert code.index("refuse_if_processor_live") < _first_destructive(code), (
        f"{script.name} destroys data before it checks for a processor"
    )


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_the_post_replay_recheck_is_called_with_its_own_consequence(script: Path):
    """The pre-flight check is TOCTOU over a multi-minute replay. The consequence differs
    per script -- an additive upsert double-counts, a membership set does not -- so the
    caller supplies the sentence."""
    code = _statements(script)
    call = "refuse_if_processor_started_during_rebuild"
    assert call in code, f"{script.name} does not re-check after its replay"
    after = code[code.index(call) + len(call):].lstrip()
    if after.startswith(chr(92)):  # a line continuation, then the first line of the text
        after = after[1:].lstrip()
    assert after.startswith('"'), (
        f"{script.name} calls the re-check with no consequence line: {after[:60]!r}"
    )
    # After the FIRST destructive statement, not the last: rebuild_content_volume.sh
    # re-checks and only then reseals its rollup, which truncates again inside the
    # publishing transaction, and deletes from account_content_daily after that.
    assert _first_destructive(code) < code.index(call)


# --------------------------------------------------------------------------------------
# Behaviour, under a stub psql.
# --------------------------------------------------------------------------------------

@pytest.fixture
def bash():
    return require_bash()


def make_psql(tmp_path, answers: list[str], count_exit: int = 0) -> Path:
    """A stub psql that answers every read a rebuild script performs.

    `answers` is consumed one entry per live-processor COUNT, in order, so a test can say
    "none at the pre-flight check, one at the re-check". Entries past the end come back
    EMPTY, which is itself a case worth reaching: it is what a reset connection looks like.

    `count_exit` is the exit status psql reports AFTER answering the count -- 0 normally,
    non-zero for the case where the row was transmitted and the connection then went bad
    (a failover, a postmaster restart, a PgBouncer drop). psql documents exit 2 for exactly
    that. Until this parameter existed the stub always exited 0, so no test in this file
    could see a guard that ignores psql's exit status, and one shipped in the first draft.
    """
    bindir = stub_bin(tmp_path)
    log = tmp_path / "sql.log"
    counter = tmp_path / "counter"
    counter.write_text("1\n", encoding="utf-8")
    answer_file = tmp_path / "answers"
    answer_file.write_text(chr(10).join(answers) + chr(10), encoding="utf-8")

    write_exec(
        bindir / "psql",
        "#!/bin/sh\n"
        "cmd=''\n"
        "prev=''\n"
        'for a in "$@"; do\n'
        # -f as well as -c, and the FILE'S CONTENTS, not just its path: logging the path
        # alone added no detection at all -- destruction moved into a .sql file stayed
        # invisible to every assertion that reads this log, which is what the first
        # version of this line claimed to fix.
        '  case "$prev" in\n'
        '    -c|-Atc) cmd="$cmd$a" ;;\n'
        '    -f) cmd="$cmd -f $a $(cat "$a" 2>/dev/null)" ;;\n'
        "  esac\n"
        '  prev="$a"\n'
        "done\n"
        # ONE LINE PER INVOCATION: the statement carries its own newlines, and a raw
        # printf would write one log line per SQL line, making "did it TRUNCATE before
        # it refused?" impossible to express as an ordering assertion.
        f'printf "%s\\n" "$(printf \'%s\' "$cmd" | tr \'\\n\' \' \')" >> "{log.as_posix()}"\n'
        "case \"$cmd\" in\n"
        "  *COUNT*pg_stat_activity*)\n"
        f'    n=$(cat "{counter.as_posix()}")\n'
        f'    echo $((n + 1)) > "{counter.as_posix()}"\n'
        f'    sed -n "${{n}}p" "{answer_file.as_posix()}"\n'
        f"    exit {count_exit}\n"
        "    ;;\n"
        "  *pg_stat_activity*)\n"
        '    echo "  pid 4242  user=haf_stats_owner  application_name=haf_stats_block_processing'
        '  state=idle  since 2026-09-24 00:00:00"\n'
        "    ;;\n"
        # rebuild_community_registry.sh derives its lower bound from the app rather than
        # from genesis, and require_number refuses an empty answer -- so without this arm
        # every case for that script would pass for the wrong reason.
        '  *community_start_block*) echo "1" ;;\n'
        f'  *app_status*) echo "{APP_BLOCK}" ;;\n'
        f'  *hafd.blocks*) echo "{APP_BLOCK}" ;;\n'
        "  *) : ;;\n"
        "esac\n"
        "exit 0\n",
    )
    return log


def run_rebuild(bash, script: Path, tmp_path, answers: list[str], count_exit: int = 0,
                env_extra: dict | None = None):
    log = make_psql(tmp_path, answers, count_exit=count_exit)
    env = clean_env(tmp_path / "bin")
    env.update(env_extra or {})
    proc = subprocess.run(
        [bash, str(script)],
        capture_output=True, text=True, timeout=TIMEOUT,
        env=env,
    )
    statements = log.read_text(encoding="utf-8") if log.exists() else ""
    return proc, statements


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
@pytest.mark.parametrize("knob", ["BATCH_SIZE", "FROM_BLOCK", "TO_BLOCK"])
@pytest.mark.parametrize("bad", ["09", "abc"], ids=["leading-zero", "not-a-number"])
def test_it_refuses_a_bad_range_input_without_destroying_anything(bash, script, tmp_path,
                                                                 knob, bad):
    """A rebuild must not destroy anything it cannot then rebuild.

    `TO_BLOCK=09` on the four scripts this MR newly guarded used to TRUNCATE, replay ZERO
    batches and exit 0 reporting success: bash reads `09` as octal, `(( 09 < 1 ))` is an
    error returning 1, and errexit is suppressed inside an `if`, so the range check passed
    and `while (( first <= TO_BLOCK ))` was false on the first test. The final refresh then
    ran over the empty table. The four that already called require_number refused it.

    This is the same failure shape as the missing processor guard -- destructive work on an
    input the script never checked -- which is why it is fixed here rather than filed.

    Every operator-settable knob is parametrized, not TO_BLOCK alone: with only TO_BLOCK
    covered, deleting a script's `require_number "BATCH_SIZE"` line left this suite green
    (found by negative control). FROM_BLOCK is refused two different ways -- the four
    newly guarded scripts validate it, the four that TRUNCATE the whole table reject any
    value but 1 -- and both must exit 2 naming the knob, without destroying anything.
    """
    proc, statements = run_rebuild(bash, script, tmp_path, ["0"] * 6,
                                   env_extra={knob: bad})
    assert proc.returncode == 2, f"exit {proc.returncode}: {proc.stdout}{proc.stderr}"
    assert not DESTRUCTIVE.search(statements), "it destroyed data on an input it rejected"
    assert knob in proc.stderr


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_it_truncates_when_no_processor_is_connected(bash, script, tmp_path):
    """The control. Without it, a guard that refuses unconditionally would pass every
    other test in this file."""
    proc, statements = run_rebuild(bash, script, tmp_path, ["0"] * 6)
    assert proc.returncode == 0, proc.stderr
    assert DESTRUCTIVE.search(statements)


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_it_refuses_and_truncates_nothing_while_a_processor_is_live(bash, script, tmp_path):
    proc, statements = run_rebuild(bash, script, tmp_path, ["1"] * 6)
    assert proc.returncode == 2, f"exit {proc.returncode}: {proc.stderr}"
    assert not DESTRUCTIVE.search(statements), "it truncated anyway"
    assert "refusing to rebuild" in proc.stderr


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_the_refusal_names_the_session_holding_it(bash, script, tmp_path):
    """An operator who HAS stopped the container must not be told to stop the container:
    the guard keys on the CONNECTION, so it also matches a backend orphaned by an abrupt
    stop, which lingers until TCP keepalive reaps it."""
    proc, _ = run_rebuild(bash, script, tmp_path, ["1"] * 6)
    assert "pid 4242" in proc.stderr
    assert "pg_terminate_backend" in proc.stderr


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_it_fails_closed_when_the_count_cannot_be_read(bash, script, tmp_path):
    """An empty answer is what a reset connection or a restarting server looks like.

    `if (( $(count) > 0 ))` would make that `(( > 0 ))` -- an arithmetic syntax error
    returning 1, with set -e suppressed inside an `if` condition -- and the script would
    conclude "no processor" and TRUNCATE under a live writer. So would
    `local n="$(count)"`, where `local`'s own exit status hides psql's.
    """
    proc, statements = run_rebuild(bash, script, tmp_path, [""] * 6)
    assert proc.returncode != 0
    assert not DESTRUCTIVE.search(statements), "an unreadable count let it truncate"
    assert "live_processor_count" in proc.stderr


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_it_fails_closed_when_psql_answers_the_count_and_then_dies(bash, script, tmp_path):
    """psql prints the count and THEN exits non-zero: the row was transmitted and the
    connection went bad (failover, postmaster restart, PgBouncer drop).

    The answer says "no processor" and the exit status says "do not believe me". Believing
    the answer means truncating under a writer that may well be live -- so the exit status
    wins. This caught a real regression: reading the count through a helper that ECHOES it
    back discards psql's status, because bash unsets errexit inside a command substitution
    unless `shopt -s inherit_errexit`. That form truncated and exited 0 here, where the
    same script on develop aborted before the TRUNCATE.
    """
    proc, statements = run_rebuild(bash, script, tmp_path, ["0"] * 6, count_exit=1)
    assert proc.returncode != 0, "a failed psql was treated as a clean 'no processor'"
    assert not DESTRUCTIVE.search(statements), "it truncated on an unreliable count"


@pytest.mark.parametrize("script", ALL_REBUILDS, ids=lambda p: p.name)
def test_it_refuses_when_a_processor_starts_during_the_replay(bash, script, tmp_path):
    """Clean at the pre-flight check, live at the re-check: the container came back under
    its restart policy mid-replay. The TRUNCATE has already happened by then -- that is
    why the message tells the operator to stop it and re-run rather than implying the
    data is fine."""
    proc, statements = run_rebuild(bash, script, tmp_path, ["0", "1", "1", "1", "1", "1"])
    assert proc.returncode == 2, f"exit {proc.returncode}: {proc.stderr}"
    assert DESTRUCTIVE.search(statements)
    assert "STARTED DURING" in proc.stderr
    assert "re-run this script" in proc.stderr


def test_the_harness_sees_an_unguarded_script_truncate_under_a_live_processor(bash, tmp_path):
    """A negative control for this file, committed rather than run once by hand.

    Every behavioural test above is only worth its green if the stub can tell a guarded
    script from an unguarded one. This builds the unguarded one: rebuild_custom_json.sh
    with both guard calls stripped -- exactly what it was before #98 -- and shows it
    destroy data and exit 0 while a processor is connected. That is the bug, reproduced.

    What it does NOT cover, since it reads as though it covers everything: the stripped
    script issues no count query at all, so nothing here exercises the answers file, the
    counter or the dispatch. This proves the harness lets an unguarded script run; the
    paired "processor connected" tests above prove it stops a guarded one.

    If this ever starts failing, the harness has stopped distinguishing the two cases and
    every other result in this file is suspect.
    """
    sandbox = tmp_path / "scripts"
    sandbox.mkdir()
    for name in ("common.sh", "arg_guard.sh"):
        (sandbox / name).write_text((SCRIPTS / name).read_text(encoding="utf-8"),
                                    encoding="utf-8", newline=chr(10))
    body = (SCRIPTS / "rebuild_custom_json.sh").read_text(encoding="utf-8")
    for call in ("refuse_if_processor_live", "refuse_if_processor_started_during_rebuild"):
        assert call in body, f"{call!r} is gone; this control no longer models the pre-#98 script"
    body = _strip_logical_lines(body, ("refuse_if_processor_live",
                                       "refuse_if_processor_started_during_rebuild"))
    unguarded = sandbox / "rebuild_unguarded.sh"
    write_exec(unguarded, body)

    log = make_psql(tmp_path, ["1"] * 6)
    proc = subprocess.run(
        [bash, str(unguarded)],
        capture_output=True, text=True, timeout=TIMEOUT,
        env=clean_env(tmp_path / "bin"),
    )
    statements = log.read_text(encoding="utf-8")
    assert proc.returncode == 0, proc.stderr
    assert DESTRUCTIVE.search(statements)


@pytest.mark.parametrize("context", [
    "refuse_if_processor_live",
    "if refuse_if_processor_live; then echo MARKER; fi",
    "refuse_if_processor_live || echo MARKER",
    'out="$(refuse_if_processor_live; echo MARKER)"',
], ids=["plain", "if-condition", "or-chain", "command-substitution"])
@pytest.mark.parametrize("answers,count_exit", [
    ([""] * 4, 0),
    (["0"] * 4, 1),
    # The refusal path itself, not just the two fail-closed ones. Without it, changing the
    # live-processor branch's `exit 2` to `return 2` left this test green -- it never
    # reached that branch, because both other cases exit inside _read_live_processor_count.
    (["1"] * 4, 0),
], ids=["count-unreadable", "psql-answers-then-dies", "processor-live"])
def test_the_guard_exits_even_where_errexit_is_suppressed(
    bash, tmp_path, context, answers, count_exit,
):
    """The guard must not depend on `set -e` to stop the script.

    Bash suppresses errexit inside an `if` condition, the left side of `||`, and a command
    substitution. A guard whose only way of stopping is a failed assignment therefore
    RETURNS SUCCESS in all three, and the caller proceeds to the TRUNCATE. All sixteen call
    sites in scripts/ are plain statements today, but this is the shared primitive now, so
    the contract has to hold wherever it is called from.

    Both failure modes are run through each context: a count that cannot be read, and a
    psql that answers and then exits non-zero. The second is the one that needs psql's
    exit status checked EXPLICITLY -- relying on the failed assignment leaves the guard
    returning success wherever bash has suppressed errexit.

    LIMITS OF THE `command-substitution` CASE, because it reads stronger than it is: there
    the guard's `exit 2` ends the SUBSHELL, and the probe stops only because `set -e` fails
    the assignment -- the very dependency this test is about. It is kept because it pins
    that the guard does not print PROCEEDED, and because a guard that `return`s instead of
    exiting fails it. The form it cannot cover is `if out="$(guard)"`, where `if` swallows
    the subshell's status: no function can stop its caller doing that, and common.sh says
    so.
    """
    make_psql(tmp_path, answers, count_exit=count_exit)
    probe = tmp_path / "probe.sh"
    write_exec(
        probe,
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        f'source "{(SCRIPTS / "common.sh").as_posix()}"\n'
        f"{context}\n"
        'echo "PROCEEDED"\n',
    )
    proc = subprocess.run(
        [bash, str(probe)],
        capture_output=True, text=True, timeout=TIMEOUT,
        env=clean_env(tmp_path / "bin"),
    )
    assert proc.returncode != 0, f"the guard returned success: {proc.stdout!r}"
    assert "PROCEEDED" not in proc.stdout
    if "$(" not in context:  # in a substitution MARKER is captured, so its absence proves nothing
        assert "MARKER" not in proc.stdout


@pytest.mark.parametrize("call", [
    "refuse_if_processor_started_during_rebuild",
    'refuse_if_processor_started_during_rebuild ""',
    "refuse_if_processor_started_during_rebuild \"   \"",
], ids=["no-arguments", "one-empty-argument", "whitespace-only"])
def test_the_recheck_refuses_a_call_with_nothing_to_say(bash, tmp_path, call):
    """An empty argument passes an argument-COUNT check, the static "starts with a quote"
    check, and every behavioural test -- and then prints a blank line between "STARTED
    DURING the rebuild." and "Stop it and re-run this script.". That is a refusal that
    does not say what went wrong, on the one path this function exists for.

    `set -u` does not make the no-argument case redundant: the function reads "$@", not
    "$1", and "$@" with no positional parameters expands to nothing rather than erroring.
    """
    make_psql(tmp_path, ["0"] * 4)
    probe = tmp_path / "probe_empty.sh"
    write_exec(
        probe,
        "#!/bin/bash\n"
        f'source "{(SCRIPTS / "common.sh").as_posix()}"\n'
        f"{call}\n"
        'echo "PROCEEDED"\n',
    )
    proc = subprocess.run(
        [bash, str(probe)],
        capture_output=True, text=True, timeout=TIMEOUT,
        env=clean_env(tmp_path / "bin"),
    )
    assert proc.returncode == 2, proc.stdout + proc.stderr
    assert "PROCEEDED" not in proc.stdout
    assert "consequence line" in proc.stderr
