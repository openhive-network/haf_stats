"""Files loaded with --single-transaction must actually be loadable that way. (#79)

WHY THIS EXISTS. `install_app` re-runs on every `docker compose up -d` and
haf-stats-api is not restarted with it, so a redeploy replays DROP/CREATE underneath
live traffic. The files that define request-reachable functions are therefore loaded
via `run_sql_file_atomic`, which adds `--single-transaction`.

WHAT THIS MODULE IS, AND IS NOT. It is a FAST PRE-FILTER, not the oracle. The oracle is
PostgreSQL: `docker/docker-compose-ci.yml` loads the endpoint schema with the same flag
against a real server on every pipeline, so any statement the server refuses inside a
transaction block fails there, by definition and without anyone maintaining a list. That
lane also asserts psql printed no `there is no transaction in progress` warning, which is
the observable signature of a file committing early.

An earlier version of this module tried to be the oracle instead, by enumerating
forbidden spellings. A review mutated it ~90 ways: 46 mutations that genuinely broke the
guarantee survived, and 11 legal edits failed. Both numbers came from the same mistake --
matching raw text with regexes and calling the result a guarantee. What is left here is
only what a text check can honestly do:

  * discovery that FAILS CLOSED, so the set of protected files cannot silently shrink
  * a code-only view, so a comment or a string can neither cause nor hide a match
  * the couple of shell-level invariants the flag depends on

The two regexes below are a convenience, not a contract. If one misses a spelling, the
CI lane still catches it; that is the right division of labour.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.unit.test_sql_comment_balance import DOLQ

# A closing brace at the start of a line ends a shell function. Named because the body
# of these functions contains ${file}, so splitting on a bare "}" stops far too early.
CLOSING_BRACE = "\n}"

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "scripts" / "install_app.sh"
COMMON = ROOT / "scripts" / "common.sh"
CI_COMPOSE = ROOT / "docker" / "docker-compose-ci.yml"

# The literal call form the guard can resolve. Anything else fails closed -- see
# test_every_atomic_call_is_in_a_form_the_guard_can_resolve.
ATOMIC_CALL = re.compile(r'run_sql_file_atomic\s+"\$\{SCRIPT_DIR\}/\.\./([^"]+)"')

# Convenience only; PostgreSQL in the CI lane is the authority.
HOSTILE = re.compile(
    r"^[^\S\n]*(CREATE\s+(UNIQUE\s+)?INDEX\s+CONCURRENTLY|DROP\s+INDEX\s+CONCURRENTLY"
    r"|REFRESH\s+MATERIALIZED\s+VIEW\s+CONCURRENTLY"
    r"|VACUUM|REINDEX|CLUSTER|DISCARD|ALTER\s+SYSTEM|ALTER\s+TYPE[^;\n]*\bADD\s+VALUE"
    r"|CREATE\s+DATABASE|DROP\s+DATABASE|CREATE\s+TABLESPACE|DROP\s+TABLESPACE"
    r"|CREATE\s+SUBSCRIPTION|DROP\s+SUBSCRIPTION|ALTER\s+SUBSCRIPTION)\b",
    re.IGNORECASE | re.MULTILINE)

# `END` is a synonym for COMMIT and `ABORT` for ROLLBACK, and every one of these takes
# optional trailing words. Requiring the keyword be followed immediately by `;` let
# `END TRANSACTION;`, `BEGIN WORK;` and `COMMIT AND CHAIN;` through the check whose
# entire purpose is the fail-open case.
TXN_CONTROL = re.compile(
    r"^[^\S\n]*(BEGIN|COMMIT|END|ROLLBACK|ABORT|START\s+TRANSACTION|SAVEPOINT"
    r"|RELEASE(\s+SAVEPOINT)?|PREPARE\s+TRANSACTION)\b[^;\n]*;",
    re.IGNORECASE | re.MULTILINE)

# psql meta-commands. `\c` reconnects (the transaction is simply gone) and `\i` pulls in
# another file -- including, potentially, one that manages its own transaction.
META_COMMAND = re.compile(r"^[^\S\n]*\\(c|connect|i|include|ir|include_relative)\b",
                          re.IGNORECASE | re.MULTILINE)


def _code_only(text: str) -> str:
    """The SQL with comments, string literals and dollar-quoted bodies blanked out.

    Newlines and column positions are preserved, so line numbers and `^\\s*` anchoring
    still mean what they say. Matching raw text instead produced BOTH halves of this
    module's worst review result: a `/* ... */` OpenAPI description beginning with the
    word VACUUM reddened the pipeline, while `/* x */ CREATE INDEX CONCURRENTLY` slipped
    past `^\\s*`. Blanking fixes both at once -- the comment becomes whitespace, so the
    statement after it IS at the start of the line.
    """
    out = list(text)
    i, n = 0, len(text)

    def blank(lo: int, hi: int) -> None:
        for k in range(lo, min(hi, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if text.startswith("--", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
            continue
        if text.startswith("/*", i):
            depth, j = 1, i + 2          # PostgreSQL nests block comments
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
            continue
        m = DOLQ.match(text, i)
        if m:
            tag = m.group(0)
            end = text.find(tag, m.end())
            end = n if end == -1 else end + len(tag)
            blank(i, end)
            i = end
            continue
        if text[i] == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            blank(i, j)
            i = j
            continue
        i += 1
    return "".join(out)


def _hits(text: str, pattern: re.Pattern) -> list:
    code = _code_only(text)
    return [(code.count("\n", 0, m.start()) + 1, " ".join(m.group(1).split()).upper())
            for m in pattern.finditer(code)]


def _atomically_loaded() -> list[Path]:
    """Files loaded through run_sql_file_atomic, with shell comments stripped first.

    Stripping matters: a commented-out call used to satisfy every test in this module
    while the real call sat next to it loading the file NON-atomically.
    """
    lines = [l for l in INSTALL.read_text(encoding="utf-8").splitlines()
             if not l.lstrip().startswith("#")]
    paths = ATOMIC_CALL.findall("\n".join(lines))
    assert paths, "no file is loaded atomically -- has run_sql_file_atomic been removed?"
    return [ROOT / p for p in paths]


def test_every_atomic_call_is_in_a_form_the_guard_can_resolve():
    """Fail CLOSED. A call the discovery regex cannot read is unprotected, silently.

    `run_sql_file_atomic "$P"` or a loop over an array loads the file atomically while
    this module never looks at it -- so an unsafe file could be wrapped with nothing
    complaining. Requiring the literal form keeps the guard's view and reality identical.
    """
    lines = [l for l in INSTALL.read_text(encoding="utf-8").splitlines()
             if not l.lstrip().startswith("#")]
    body = "\n".join(lines)
    invocations = len(re.findall(r"\brun_sql_file_atomic\b", body))
    # One occurrence is the guard's own mention in a comment-free context? No -- the
    # helper is DEFINED in common.sh, so every occurrence here is a call.
    assert invocations == len(ATOMIC_CALL.findall(body)), (
        f"{invocations} run_sql_file_atomic call(s) in install_app.sh but only "
        f"{len(ATOMIC_CALL.findall(body))} in the literal "
        f'run_sql_file_atomic "${{SCRIPT_DIR}}/../<path>" form. A call built from a '
        f"variable or a loop is invisible to every check in this module -- write it "
        f"literally, or teach the guard the new form.")


@pytest.mark.parametrize("path", _atomically_loaded(), ids=lambda p: p.name)
def test_no_statement_that_postgres_refuses_in_a_transaction(path: Path):
    """A fast duplicate of what the CI lane proves against a real server."""
    hits = _hits(path.read_text(encoding="utf-8"), HOSTILE)
    assert not hits, (
        f"{path.name} is loaded with --single-transaction but contains a statement "
        f"PostgreSQL refuses inside a transaction block, at line(s) {hits}. psql aborts "
        f"the file, so the install fails outright. Either drop the statement or load "
        f"this file with run_sql_file -- and accept the redeploy window.")


@pytest.mark.parametrize("path", _atomically_loaded(), ids=lambda p: p.name)
def test_the_file_does_not_manage_its_own_transaction(path: Path):
    """The fail-OPEN case: no error, no log, and the atomicity silently gone."""
    text = path.read_text(encoding="utf-8")
    hits = _hits(text, TXN_CONTROL) + _hits(text, META_COMMAND)
    assert not hits, (
        f"{path.name} is loaded with --single-transaction but issues its own "
        f"transaction control (or a psql meta-command that ends one) at line(s) {hits}. "
        f"A COMMIT -- or a bare END;, or \\c -- ends psql's transaction early: the load "
        f"still SUCCEEDS and reports nothing, and the window #79 closed is back.")


def test_the_self_managing_file_is_not_loaded_atomically():
    """db/sync_status.sql is the live example of the trap above."""
    sync = ROOT / "db" / "sync_status.sql"
    keywords = [kw for _line, kw in _hits(sync.read_text(encoding="utf-8"), TXN_CONTROL)]
    assert keywords, (
        "db/sync_status.sql no longer manages its own transaction; if it now relies on "
        "the caller, load it with run_sql_file_atomic or it has lost its atomicity")

    # BEGIN without COMMIT is the worst of the three states: psql -f reaches EOF with
    # the transaction still open, the connection closes, and the entire file is rolled
    # back -- silently, with a zero exit.
    assert any(k.startswith("BEGIN") for k in keywords) and            any(k.startswith("COMMIT") or k.startswith("END") for k in keywords), (
        f"db/sync_status.sql opens a transaction it does not close: {keywords}. psql "
        f"rolls the whole file back at EOF and exits 0, so the install silently "
        f"applies nothing.")
    assert sync not in _atomically_loaded(), (
        "db/sync_status.sql opens its own transaction; loading it with "
        "--single-transaction makes its COMMIT end psql's transaction early")


def _all_installed_sql() -> list[Path]:
    """Every SQL file install_app.sh loads, atomically or not."""
    lines = [l for l in INSTALL.read_text(encoding="utf-8").splitlines()
             if not l.lstrip().startswith("#")]
    paths = re.findall(r'run_sql_file(?:_atomic)?\s+"\$\{SCRIPT_DIR\}/\.\./([^"]+)"',
                       "\n".join(lines))
    return [ROOT / p for p in paths if (ROOT / p).exists()]


@pytest.mark.parametrize("path", _all_installed_sql(), ids=lambda p: p.name)
def test_a_file_that_opens_a_transaction_also_closes_it(path: Path):
    """Generalises the sync_status.sql case, because the next one will be a different file.

    A file with BEGIN and no COMMIT is the worst of the three states. psql -f reaches
    EOF with the transaction still open, the connection closes, the server rolls the
    ENTIRE file back -- and psql exits 0. The install reports success having applied
    nothing, and there is no warning anywhere to notice.

    Checked for every installed file, not just the atomic ones: a non-atomic file with
    a stray BEGIN has exactly the same failure, and pinning one known file by name only
    protects that file.
    """
    keywords = [kw for _line, kw in _hits(path.read_text(encoding="utf-8"), TXN_CONTROL)]
    if not keywords:
        return                                  # relies on the caller; nothing to check

    opens = sum(1 for k in keywords if k.startswith(("BEGIN", "START")))
    closes = sum(1 for k in keywords if k.startswith(("COMMIT", "END", "ROLLBACK", "ABORT")))
    assert opens == closes, (
        f"{path.name} manages its own transaction but opens {opens} and closes "
        f"{closes}: {keywords}. If a BEGIN is left open, psql rolls the whole file back "
        f"at EOF and still exits 0 -- the install applies nothing and reports success.")


def test_the_endpoint_surface_is_protected_and_not_empty():
    """The point of #79, pinned."""
    schema = ROOT / "endpoints" / "endpoint_schema.sql"
    assert schema in _atomically_loaded(), (
        "the endpoint schema is no longer loaded atomically; a redeploy would replay "
        "DROP/CREATE for every endpoint under live traffic (#79)")

    # Otherwise emptying the file makes every parametrised test above vacuously true.
    code = _code_only(schema.read_text(encoding="utf-8"))
    drops = len(re.findall(r"^\s*DROP\s+FUNCTION\b", code, re.IGNORECASE | re.MULTILINE))
    assert drops > 20, f"only {drops} DROP FUNCTION in the endpoint schema -- has it moved?"

    defined_elsewhere = sorted(
        p.name for p in (ROOT / "db").glob("*.sql")
        if re.search(r"CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+haf_stats_endpoints\.",
                     p.read_text(encoding="utf-8"), re.IGNORECASE))
    assert not defined_elsewhere, (
        f"PostgREST-facing functions are now defined outside the atomically-loaded "
        f"endpoint schema, in {defined_elsewhere}. Those get the redeploy window back.")


def test_the_atomic_helper_passes_the_flag_unconditionally():
    """The whole change is one flag, so assert the psql line itself, not a substring.

    A substring test over the function body passed on a typo'd flag, on the flag left
    only in a comment, and on the flag behind an env-var conditional defaulting to off.
    """
    text = COMMON.read_text(encoding="utf-8")
    fn = text.split("run_sql_file_atomic()", 1)
    assert len(fn) == 2, "run_sql_file_atomic is gone from scripts/common.sh"
    body = fn[1].split(CLOSING_BRACE, 1)[0]

    calls = [l.strip() for l in body.splitlines()
             if l.strip().startswith("psql_cmd") and not l.strip().startswith("#")]
    assert calls == ['psql_cmd --single-transaction -f "${file}"'], (
        f"run_sql_file_atomic's psql invocation is {calls!r}. It must be exactly "
        f'psql_cmd --single-transaction -f "${{file}}" -- the flag applies to psql\'s '
        f"ACTION LIST, so SQL on stdin is silently not wrapped, and a conditional or "
        f"typo'd flag leaves the word present while the behaviour is gone.")

    # Without ON_ERROR_STOP, psql sends COMMIT on an aborted transaction, the server
    # turns it into a rollback, and psql exits 0: an install that did nothing and
    # reported success. Checked against psql_cmd's INVOCATION, not the file -- a
    # substring test over the whole of common.sh is satisfied by the comment above.
    psql_fn = text.split("psql_cmd()", 1)
    assert len(psql_fn) == 2, "psql_cmd is gone from scripts/common.sh"
    invocation = [l for l in psql_fn[1].split(CLOSING_BRACE, 1)[0].splitlines()
                  if l.strip() and not l.strip().startswith("#")]
    assert any("ON_ERROR_STOP" in l for l in invocation), (
        "psql_cmd no longer passes ON_ERROR_STOP; with --single-transaction a failed "
        "load rolls back and psql still exits 0 -- an install that did nothing and "
        "reported success")


def test_the_ci_lane_is_the_real_oracle():
    """PostgreSQL, not this module, is what proves the file is transaction-loadable.

    The stub lane loads the endpoint schema with the same flag against a real server on
    every pipeline. If that stops, this module's regexes become the only check -- and a
    review already showed what they are worth on their own.
    """
    ci = CI_COMPOSE.read_text(encoding="utf-8")
    assert "--single-transaction -f /endpoint_schema.sql" in ci, (
        "docker-compose-ci.yml no longer loads the endpoint schema with "
        "--single-transaction, so no lane proves a real PostgreSQL accepts it")
    assert "there is no transaction in progress" in ci, (
        "the CI lane no longer asserts psql printed no early-COMMIT warning, which is "
        "the only check that observes the fail-open case instead of guessing spellings")
