"""Every db/*.sql must survive being installed twice (#60).

install_app.sh is advertised as re-runnable and haf_api_node re-runs it on every stack
start, with `restart: on-failure` on the setup service. A statement that only works on a
fresh database therefore does not fail once -- it crash-loops, and it takes the whole
module down with it because everything else gates on
`haf-stats-setup: service_completed_successfully`.

That is not hypothetical. db/op_type_registry.sql dropped assert_op_types() and
assert_op_types(BOOLEAN) -- the two HISTORICAL signatures -- and then created
assert_op_types(BOOLEAN, BOOLEAN) with a plain CREATE FUNCTION. Every install after the
first aborted with

    ERROR:  function "assert_op_types" already exists with same argument types

and psql_cmd sets ON_ERROR_STOP=on, so install_app.sh exited 3. testapi accumulated 33
restarts before anyone looked, recovered only by dropping the function by hand.

STATIC, deliberately. Proving idempotency properly means installing twice against a real
database, which needs the CI compose stack; this file is the cheap guard that runs on
every push and would have caught the actual bug. The gap is stated rather than implied:
these checks see the TEXT of the SQL, not its effect.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

DB = Path(__file__).resolve().parents[2] / "db"

# `CREATE FUNCTION x.y(...)` but not `CREATE OR REPLACE FUNCTION`.
CREATE_FN = re.compile(
    r"^CREATE\s+FUNCTION\s+([a-z0-9_]+\.[a-z0-9_]+)\s*\(", re.IGNORECASE | re.MULTILINE)
CREATE_OR_REPLACE_FN = re.compile(
    r"^CREATE\s+OR\s+REPLACE\s+FUNCTION\s+([a-z0-9_]+\.[a-z0-9_]+)\s*\(",
    re.IGNORECASE | re.MULTILINE)
DROP_FN = re.compile(
    r"^DROP\s+FUNCTION\s+IF\s+EXISTS\s+([a-z0-9_]+\.[a-z0-9_]+)\s*\(([^)]*)\)",
    re.IGNORECASE | re.MULTILINE)


def _sql_files() -> list[Path]:
    files = sorted(DB.glob("*.sql"))
    assert files, "no db/*.sql found; the glob needs updating"
    return files


def _strip_comments(text: str) -> str:
    """Line comments only. Enough here, and it keeps the parser honest about what it
    reads -- an earlier assertion elsewhere in this suite matched its own explanatory
    prose because it scanned raw text."""
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("--"))


def _arity(arglist: str) -> int:
    """Argument count, counting only top-level commas."""
    arglist = arglist.strip()
    if not arglist:
        return 0
    depth = 0
    n = 1
    for ch in arglist:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "," and depth == 0:
            n += 1
    return n


def _create_arity(text: str, start: int) -> int:
    """Arity of the CREATE FUNCTION whose '(' follows position `start`."""
    open_paren = text.index("(", start)
    depth = 0
    for i in range(open_paren, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return _arity(text[open_paren + 1:i])
    raise AssertionError("unbalanced parentheses after position %d" % start)


@pytest.mark.parametrize("path", _sql_files(), ids=lambda p: p.name)
def test_every_created_function_is_dropped_with_its_own_signature(path: Path):
    """A plain CREATE FUNCTION needs a DROP for the signature it is about to create.

    Matching on (name, arity) rather than exact types: it is what distinguishes the bug
    -- dropping (BOOLEAN) while creating (BOOLEAN, BOOLEAN) -- without this test needing
    to understand PostgreSQL's type aliases.
    """
    text = _strip_comments(path.read_text(encoding="utf-8"))
    dropped = {(m.group(1).lower(), _arity(m.group(2))) for m in DROP_FN.finditer(text)}

    missing = []
    for m in CREATE_FN.finditer(text):
        name = m.group(1).lower()
        arity = _create_arity(text, m.start())
        if (name, arity) not in dropped:
            missing.append(f"{name}/{arity} args")

    assert not missing, (
        f"{path.name}: created with a plain CREATE FUNCTION but never dropped at that "
        f"signature, so a re-install aborts with 'already exists with same argument "
        f"types': {missing}. Either add DROP FUNCTION IF EXISTS for that exact "
        f"signature, or use CREATE OR REPLACE where the return type is stable."
    )


def test_the_regression_that_prompted_this_file_is_covered():
    """Pin the specific signature, so a future edit to op_type_registry.sql that changes
    assert_op_types' arguments has to update the DROP as well -- the generic test above
    would then flag it, and this one names what to look at."""
    text = _strip_comments((DB / "op_type_registry.sql").read_text(encoding="utf-8"))
    dropped = {(m.group(1).lower(), _arity(m.group(2))) for m in DROP_FN.finditer(text)}
    assert ("haf_stats_app.assert_op_types", 2) in dropped, (
        "op_type_registry.sql must drop the two-argument assert_op_types it creates; "
        "without it every re-install aborts (#60)"
    )


@pytest.mark.parametrize("path", _sql_files(), ids=lambda p: p.name)
def test_schema_and_table_creation_is_idempotent(path: Path):
    """CREATE SCHEMA/TABLE without IF NOT EXISTS fails the same way on a second run.

    Excludes CREATE TABLE ... AS and temp tables, which are dropped-and-rebuilt by
    design elsewhere in these scripts.
    """
    text = _strip_comments(path.read_text(encoding="utf-8"))
    offenders = []
    for kind in ("SCHEMA", "TABLE"):
        pat = re.compile(
            r"^CREATE\s+(?:UNLOGGED\s+)?%s\s+(?!IF\s+NOT\s+EXISTS)([a-z0-9_.]+)" % kind,
            re.IGNORECASE | re.MULTILINE)
        for m in pat.finditer(text):
            name = m.group(1)
            tail = text[m.end():m.end() + 200].upper()
            if " AS " in tail.split(";")[0] or name.lower().startswith("tmp"):
                continue
            # A preceding DROP makes it idempotent by another route.
            if re.search(r"DROP\s+%s\s+IF\s+EXISTS\s+%s\b" % (kind, re.escape(name)),
                         text, re.IGNORECASE):
                continue
            offenders.append(f"{kind} {name}")
    assert not offenders, (
        f"{path.name}: not idempotent -- a re-install aborts on {offenders}. Use "
        f"IF NOT EXISTS, or drop it first."
    )
