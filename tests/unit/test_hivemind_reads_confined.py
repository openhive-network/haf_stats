"""Only the hivemind content source may read hivemind's tables (#118).

On the hivemind source, process_content_stats waits for hivemind inside the block
driver's transaction, and it waits BEFORE reading any hivemind table so that the wait
holds no lock hivemind's massive sync needs (tests/ci_hivemind_wait_locks.sql checks that
against the real functions). That holds only while nothing else in the iteration reads
hivemind_app: a processor that ran before process_content_stats and read, say,
hivemind_app.hive_communities would hold its lock through the wait again.

So every SQL reference to a hivemind_app relation outside comments must be in
db/process_content_stats.sql (the source itself) or db/builtin_roles.sql (the GRANTs that
let it read). A new one elsewhere fails here and has to be placed after the wait.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ALLOWED = {"db/process_content_stats.sql", "db/builtin_roles.sql"}
SCANNED = ("db", "endpoints", "scripts")
REFERENCE = re.compile(r"\bhivemind_app\s*\.\s*[A-Za-z_\"]")


def _code(text: str) -> str:
    """SQL with `--` line comments and `/* */` block comments (nesting) removed.

    Quoted strings are kept, since dynamic SQL names relations inside them.
    """
    out: list[str] = []
    i = 0
    depth = 0
    n = len(text)
    while i < n:
        if depth:
            if text.startswith("/*", i):
                depth += 1
                i += 2
            elif text.startswith("*/", i):
                depth -= 1
                i += 2
            else:
                i += 1
            continue
        if text.startswith("--", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            depth = 1
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def references(text: str) -> list[str]:
    return [m.group(0) for m in REFERENCE.finditer(_code(text))]


def test_hivemind_tables_are_read_only_by_the_content_source() -> None:
    found: dict[str, list[str]] = {}
    for top in SCANNED:
        for path in sorted((REPO / top).rglob("*.sql")):
            rel = path.relative_to(REPO).as_posix()
            refs = references(path.read_text(encoding="utf-8"))
            if refs:
                found[rel] = refs
    outside = {rel: refs for rel, refs in found.items() if rel not in ALLOWED}
    assert not outside, (
        "hivemind_app is referenced outside the hivemind content source; a read before "
        f"process_content_stats' wait would hold its lock through the wait (#118): {outside}"
    )
    # Non-vacuous: the scan does see the source's own reads.
    assert "db/process_content_stats.sql" in found


def test_comments_are_ignored_and_code_is_not() -> None:
    assert references("-- reads hivemind_app.hive_posts\nSELECT 1;") == []
    assert references("/* hivemind_app.hive_posts /* nested */ still */ SELECT 1;") == []
    assert references("SELECT * FROM hivemind_app.hive_posts;") == ["hivemind_app.h"]
    assert references("EXECUTE 'SELECT 1 FROM hivemind_app.hive_communities';") == ["hivemind_app.h"]
