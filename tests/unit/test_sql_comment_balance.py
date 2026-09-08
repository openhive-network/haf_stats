"""PostgreSQL's lexer and the OpenAPI generator's must agree about where comments begin.

WHY THIS EXISTS. `endpoints/endpoint_schema.sql` carries its OpenAPI annotations in
`/** openapi:paths ... */` blocks. Two different parsers read that file:

  * `scripts/process_openapi.py` is LINE-BASED. It opens a block only on a line matching
    `^\\s*/\\*\\*\\s*openapi...$` and closes only on `^\\s*\\*/\\s*$` (:538 and :517). It
    never models nesting and never sees a delimiter in the MIDDLE of a line.
  * PostgreSQL nests `/* */` and honours either sequence anywhere it is not already
    inside a string, dollar-quoted body or line comment.

So a mid-line comment terminator inside an annotation ENDS the block for psql while
staying invisible to the generator. The regenerated document comes out byte-identical,
`openapi-drift` stays green, sqlfluff never looks (`.sqlfluffignore`'s single line is
this very file), and the first parser to disagree is psql, two stages later.

Two real incidents:

  * pipeline 178917 -- a description cited fixtures with a glob containing a
    comment-close sequence. psql reported `unterminated /* comment` at line 8207,
    ~7500 lines from the cause.
  * commit ece235b (db/refresh_rc_op_stats.sql) -- a comment NAMED the dollar-quote tag
    it was written inside, ending the string early. install_app aborted exit 3.

WHAT IS ASSERTED, and what an earlier version of this file got wrong.

  * Block-comment balance, including a stray `*/` at depth 0 (a syntax error in psql,
    not a no-op).
  * Per-annotation agreement with the generator. NOT raw set-equality of every comment
    line: that banned ordinary block comments from the file and failed with a message
    blaming a mid-line delimiter that did not exist.
  * Dollar-tag balance WITHIN EACH BODY, recursively. The first version compared a tag
    against the body `str.find` had already terminated at the first occurrence, which is
    a tautology -- it could not fail, and it passed on the very commit it cited. ece235b
    nests `$ddl$` inside `$sampler$`, so a top-level-only walk never examines it; the
    property that actually catches it is that every tag appears an even number of times
    inside the body that contains it.

The lexer models `--`, nesting `/* */`, `'...'` with `''` doubling, `"..."`, and
`$tag$`. It does NOT model E'' backslash escapes; there are no `\\'` sequences in this
repo's SQL, and a bare backslash is not an escape under `standard_conforming_strings`.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "endpoints" / "endpoint_schema.sql"

# Verbatim from scripts/process_openapi.py:538 and :517 -- the generator's entire notion
# of where an annotation begins and ends. Copied rather than imported because that file
# is fetched at run time (gitignored). COMMON_CI_REF is pinned to a commit, so these
# cannot drift silently -- but re-check them whenever that pin moves.
GEN_OPEN = re.compile(r"^\s*\/\*\*\s*openapi(?::((?:\w+)(?::\w+)*))?\s*$")
GEN_CLOSE = re.compile(r"^\s*\*\/\s*$")

DOLQ = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")


class Lexed:
    def __init__(self):
        self.opens: list[int] = []          # lines where depth went 0->1
        self.closes: list[int] = []         # lines where depth went 1->0
        self.nested_opens: list[int] = []   # lines where depth went 1+ -> 2+
        self.stray_closes: list[int] = []   # `*/` seen at depth 0 -- a psql syntax error
        self.depth = 0
        self.unclosed: list[int] = []
        self.bodies: list[tuple[str, int, str]] = []   # (tag, start_line, body_text)


def _lex(text: str) -> Lexed:
    r = Lexed()
    stack: list[int] = []
    i, line, n = 0, 1, len(text)

    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
            continue

        if r.depth > 0:
            if text.startswith("/*", i):
                r.depth += 1
                stack.append(line)
                r.nested_opens.append(line)
                i += 2
                continue
            if text.startswith("*/", i):
                r.depth -= 1
                start = stack.pop()
                if r.depth == 0:
                    r.closes.append(line)
                i += 2
                continue
            i += 1
            continue

        if text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue

        if text.startswith("/*", i):
            r.depth = 1
            stack.append(line)
            r.opens.append(line)
            i += 2
            continue

        if text.startswith("*/", i):
            # Not a no-op: PostgreSQL raises `syntax error at or near "*/"`.
            r.stray_closes.append(line)
            i += 2
            continue

        m = DOLQ.match(text, i)
        if m:
            tag = m.group(0)
            start = line
            end = text.find(tag, m.end())
            if end == -1:
                r.unclosed.append(start)
                # treat the rest as body so the walk terminates
                r.bodies.append((tag, start, text[m.end():]))
                break
            r.bodies.append((tag, start, text[m.end():end]))
            line += text.count("\n", i, end + len(tag))
            i = end + len(tag)
            continue

        if ch == "'":
            i += 1
            while i < n:
                if text[i] == "\n":
                    line += 1
                elif text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue

        if ch == '"':
            i += 1
            while i < n:
                if text[i] == "\n":
                    line += 1
                elif text[i] == '"':
                    i += 1
                    break
                i += 1
            continue

        i += 1

    r.unclosed.extend(stack)
    return r


def _sql_files():
    files = (sorted((ROOT / "db").glob("*.sql"))
             + sorted((ROOT / "endpoints").glob("*.sql"))
             + sorted((ROOT / "tests").glob("*.sql"))
             + sorted((ROOT / "scripts").glob("*.sql")))
    assert files, "no SQL files found"
    return files


def _tag_parity(tag_body_pairs, path_name, trail=""):
    """Recursively assert every dollar tag appears an even number of times in its body.

    This is what catches ece235b. A body that mentions its own tag an odd number of
    times terminates where the author did not intend; PostgreSQL stops at the first
    occurrence and parses the remainder as code.
    """
    for tag, start, body in tag_body_pairs:
        where = "%s (opened line %d)%s" % (tag, start, trail)
        for inner in sorted(set(DOLQ.findall(body))):
            inner_tag = "$%s$" % inner
            count = body.count(inner_tag)
            assert count % 2 == 0, (
                "%s: dollar tag %s appears %d times (odd) inside the body of %s. "
                "A dollar-quoted body is literal text, so PostgreSQL ends the string at "
                "the FIRST occurrence -- usually a comment that names the tag it is "
                "written inside." % (path_name, inner_tag, count, where)
            )
        inner_lexed = _lex(body)
        if inner_lexed.bodies:
            _tag_parity(inner_lexed.bodies, path_name, trail=" inside %s" % tag)


@pytest.mark.parametrize("path", _sql_files(), ids=lambda p: p.name)
def test_block_comments_are_balanced(path: Path):
    """Every block comment opens and closes exactly once, under PostgreSQL's nesting."""
    r = _lex(path.read_text(encoding="utf-8"))
    assert not r.stray_closes, (
        "%s: `*/` with no open block comment at line(s) %s. PostgreSQL raises "
        "`syntax error at or near \"*/\"` -- it is not ignored."
        % (path.name, r.stray_closes)
    )
    assert not r.unclosed, (
        "%s: block comment opened at line(s) %s and never closed. If a description "
        "contains a comment-close sequence it ends the block early and everything after "
        "it parses as SQL." % (path.name, r.unclosed)
    )
    assert r.depth == 0, "%s: final comment depth %d" % (path.name, r.depth)


@pytest.mark.parametrize("path", _sql_files(), ids=lambda p: p.name)
def test_no_dollar_tag_is_named_inside_its_own_body(path: Path):
    """The ece235b class, checked recursively so nested bodies are reached."""
    r = _lex(path.read_text(encoding="utf-8"))
    _tag_parity(r.bodies, path.name)


def test_postgres_and_the_generator_agree_on_every_annotation_block():
    """The assertion that would have caught pipeline 178917.

    For each block the generator recognises, PostgreSQL must open a comment on that same
    line and close it on the generator's matching close line, with no nesting in between.
    Deliberately NOT a set-equality over all comments: ordinary block comments elsewhere
    in the file are legal and must not fail this.
    """
    text = SCHEMA.read_text(encoding="utf-8")
    r = _lex(text)

    gen_opens, gen_closes = [], []
    for num, line in enumerate(text.split("\n"), start=1):
        if GEN_OPEN.match(line):
            gen_opens.append(num)
        elif GEN_CLOSE.match(line):
            gen_closes.append(num)

    assert gen_opens, "no annotation blocks found -- this test is not testing anything"
    assert len(gen_opens) == len(gen_closes), (
        "generator sees %d opens but %d closes" % (len(gen_opens), len(gen_closes)))

    missing_open = sorted(set(gen_opens) - set(r.opens))
    assert not missing_open, (
        "the generator starts an annotation at line(s) %s where PostgreSQL is not "
        "opening a comment -- an earlier annotation was ended early, most likely by a "
        "comment-close sequence inside a description." % missing_open)

    missing_close = sorted(set(gen_closes) - set(r.closes))
    assert not missing_close, (
        "the generator ends an annotation at line(s) %s where PostgreSQL is not closing "
        "a comment. If PostgreSQL is still nested there, a description contains a "
        "comment-OPEN sequence." % missing_close)

    inside = [ln for ln in r.nested_opens
              if any(o < ln < c for o, c in zip(gen_opens, gen_closes))]
    assert not inside, (
        "a comment-open sequence appears INSIDE an annotation block at line(s) %s. "
        "PostgreSQL nests, so the block does not end where the generator thinks it "
        "does." % inside)
