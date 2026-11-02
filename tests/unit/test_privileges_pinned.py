"""Every GRANT/REVOKE the installer runs on a haf_stats object is reflected in the
committed tests/expected_privileges.txt (#82).

reinstall-test compares what an install actually produced with that committed list
(tests/privileges.sql). That catches a privilege the list has and the install lost -- but
when a change is intended, the list is regenerated FROM the install, so on its own the
list would absorb whatever the install did. Review of !121 put two mutations straight
through it: a new `REVOKE ... FROM public` placed above a DROP-and-recreate (undone on
every install), and a blanket REVOKE at the top of a schema. Both leave the install, and
therefore a regenerated list, unchanged.

This test closes that loop statically, with no database: it replays every GRANT/REVOKE on
a haf_stats object in the install sources -- the .sql files install_app.sh runs, in the
order its run_sql_file lines run them, then the SQL inlined in install_app.sh itself --
and requires the committed list to show the result. A REVOKE the install silently undoes
now disagrees with the list, whichever way the list was produced.

It checks ONE direction: what the sources grant must be in the list, and a REVOKE of
PUBLIC EXECUTE must hold. It cannot see a GRANT deleted from the sources (reinstall-test
then fails: the list still has it) or an extra entry in the list (that is a reviewed
diff of tests/expected_privileges.txt).

Scope and limits, stated rather than implied:
  * objects in haf_stats_app / haf_stats_backend / haf_stats_endpoints only -- grants on
    HAF's own schemas (hive, hafd) follow the HAF version;
  * function names are matched without their argument list. No haf_stats function is
    overloaded today; test_function_names_are_not_overloaded fails the day one is;
  * `ON ALL FUNCTIONS/TABLES IN SCHEMA` is applied to every listed object of that kind,
    including ones created after the statement runs; the install's own first-install
    check in reinstall-test is what sees an object such a grant never reached;
  * a grant to an object's own owner is not checked (tests/privileges.sql leaves owner
    entries out);
  * role memberships (db/builtin_roles.sql) are conditional DO blocks; the committed list
    pins them, this test does not replay them;
  * a GRANT/REVOKE on a haf_stats object that the parser cannot read -- a column list,
    GRANT OPTION FOR, a quoted role, a statement built with format() -- FAILS the test
    instead of being skipped: a blind spot that reports nothing is worse than no test;
  * in install_app.sh only the -c "..." or heredoc body of a psql call is read as SQL. A
    haf_stats GRANT/REVOKE anywhere else in its non-comment text (a variable later passed
    to psql, say) fails, and so does a psql word in a call form the extractor does not read.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

import pytest

from tests.unit.test_sql_idempotency import INSTALL_SH, ROOT, _installed_sql_files, _strip_comments

EXPECTED = ROOT / "tests" / "expected_privileges.txt"
SCHEMAS = ("haf_stats_app", "haf_stats_backend", "haf_stats_endpoints")
ALL_TABLE_PRIVS = {"SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN"}
ALL_SEQUENCE_PRIVS = {"USAGE", "SELECT", "UPDATE"}
PRIV_WORD = r"(?:ALL|EXECUTE|SELECT|INSERT|UPDATE|DELETE|TRUNCATE|REFERENCES|TRIGGER|USAGE|CREATE|MAINTAIN)"

STATEMENT = re.compile(
    r"\b(?P<verb>GRANT|REVOKE)\s+(?P<privs>(?:ALL(?:\s+PRIVILEGES)?|[A-Z]+)(?:\s*,\s*[A-Z]+)*)\s+"
    r"ON\s+(?P<kind>FUNCTION|PROCEDURE|ROUTINE|TABLE|SEQUENCE|SCHEMA|"
    r"ALL\s+FUNCTIONS\s+IN\s+SCHEMA|ALL\s+TABLES\s+IN\s+SCHEMA)?\s*"
    r"(?P<name>[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)?)\s*(?P<args>\([^)]*\))?\s+"
    r"(?P<dir>TO|FROM)\s+(?P<roles>[a-z_][a-z0-9_]*(?:\s*,\s*[a-z_][a-z0-9_]*)*)",
    re.IGNORECASE,
)
# Anything shaped like a GRANT/REVOKE touching a haf_stats object: an optional GRANT OPTION
# FOR, a privilege word, anything (column lists included) up to ON with no TO/FROM before
# it, then a haf_stats schema. Compared with what STATEMENT parsed, so a statement the
# parser cannot read is reported, not skipped. "no TO/FROM before ON" keeps prose in RAISE
# messages and OpenAPI descriptions ("grant SELECT to haf_stats_user on ...") out.
CANDIDATE = re.compile(
    r"\b(?:GRANT|REVOKE)\s+(?:GRANT\s+OPTION\s+FOR\s+)?" + PRIV_WORD
    + r"\b(?:(?!\b(?:TO|FROM)\b)[^;'])*?\bON\b[^;']*?\bhaf_stats_(?:app|backend|endpoints)\b",
    re.IGNORECASE,
)
# A GRANT/REVOKE ... ON whose object is filled in at run time: inside a string literal
# (single- or dollar-quoted), ON is followed by a format() placeholder (%s, %I, %L, %1$s)
# or by the end of the literal ('... ON ' || name). The object cannot be resolved
# statically, so it is reported rather than trusted.
LITERAL = re.compile(r"'(?:[^']|'')*'|\$([A-Za-z_]*)\$.*?\$\1\$", re.DOTALL)
DYNAMIC_IN_LITERAL = re.compile(
    r"\b(?:GRANT|REVOKE)\b[^;]*?\bON\s+"
    r"(?:(?:FUNCTION|PROCEDURE|ROUTINE|TABLE|SEQUENCE|SCHEMA|ALL\s+\w+\s+IN\s+SCHEMA)\s+)?"
    r"(?:%(?:\d+\$)?[sIL]|\s*(?:'|\$[A-Za-z_]*\$)$)",
    re.IGNORECASE,
)
RUN_SQL = re.compile(r'^\s*run_sql_file(?:_atomic)?\s+"\$\{SCRIPT_DIR\}/((?:\.\./)?[A-Za-z0-9_/]+\.sql)"', re.MULTILINE)


@dataclass
class Stmt:
    verb: str
    privs: frozenset
    kind: str
    obj: str
    roles: tuple
    where: str


@dataclass
class Listing:
    acl: dict = field(default_factory=dict)      # key -> set of "grantee:PRIV" (grant option stripped)
    owner: dict = field(default_factory=dict)    # key -> owner
    default: set = field(default_factory=set)    # keys printed as <default>


def _norm_kind(kind: str | None) -> str:
    k = " ".join((kind or "TABLE").upper().split())
    return {"PROCEDURE": "FUNCTION", "ROUTINE": "FUNCTION"}.get(k, k)


def _privs(raw: str, kind: str) -> frozenset:
    p = {x.strip().upper() for x in raw.split(",")}
    if p & {"ALL", "ALL PRIVILEGES"}:
        if "FUNCTION" in kind:
            return frozenset({"EXECUTE"})
        if kind == "SCHEMA":
            return frozenset({"USAGE", "CREATE"})
        if kind == "SEQUENCE":
            return frozenset(ALL_SEQUENCE_PRIVS)
        return frozenset(ALL_TABLE_PRIVS)
    return frozenset(p)


def parse(text: str, where: str) -> tuple[list[Stmt], list[str]]:
    """Statements in text order, plus haf_stats GRANT/REVOKE text the parser did not read."""
    stmts, spans = [], []
    for m in STATEMENT.finditer(text):
        kind = _norm_kind(m.group("kind"))
        name = m.group("name").lower()
        schema = name if kind in ("SCHEMA", "ALL FUNCTIONS IN SCHEMA", "ALL TABLES IN SCHEMA") else name.split(".")[0]
        if schema not in SCHEMAS:
            continue
        spans.append((m.start(), m.end()))
        roles = tuple("PUBLIC" if r.strip().lower() == "public" else r.strip().lower() for r in m.group("roles").split(","))
        stmts.append(Stmt(m.group("verb").upper(), _privs(m.group("privs"), kind), kind, name, roles, where))
    unparsed = [
        " ".join(c.group(0).split())[:160]
        for c in CANDIDATE.finditer(text)
        if not any(a <= c.start() < b for a, b in spans)
    ]
    for lit in LITERAL.finditer(text):
        for d in DYNAMIC_IN_LITERAL.finditer(lit.group(0)):
            unparsed.append("(object built at run time) " + " ".join(d.group(0).split())[:160])
    return stmts, unparsed


def _install_order() -> list:
    """The installed .sql files in the order install_app.sh's run_sql_file lines run them."""
    body = INSTALL_SH.read_text(encoding="utf-8")
    order = {}
    for m in RUN_SQL.finditer(body):  # anchored at line start: a commented-out run line does not count
        rel = m.group(1)
        rel = rel[3:] if rel.startswith("../") else "scripts/" + rel  # ${SCRIPT_DIR} is scripts/
        order.setdefault(rel, m.start())
    files = _installed_sql_files()
    missing = [f for f in files if f.relative_to(ROOT).as_posix() not in order]
    assert not missing, f"installed .sql files with no run_sql_file line to order them by: {missing}"
    return sorted((f for f in files if f.relative_to(ROOT).as_posix() in order),
                  key=lambda f: order[f.relative_to(ROOT).as_posix()])


# A psql invocation in command position, matched over shell text with comments, quoted
# strings and heredoc bodies blanked, so prose never matches: after a command separator or a keyword that takes a command,
# then any run of `time`, `!` and VAR=value prefixes. Every psql word in that text must be
# one of these -- a form or wrapper it does not read fails rather than being skipped.
PSQL_CALL = re.compile(
    r"(?:^|\$\(|[;&|(]|\b(?:if|elif|then|do|else|while|until)\b)"
    r"(?:[ \t]*(?:time(?:[ \t]+-p)?|!|[A-Za-z_]\w*=[^\s;&|()]*)(?=[ \t]))*"
    r"[ \t]*(?P<cmd>psql(?:_cmd)?)\b",
    re.MULTILINE,
)
PSQL_WORD = re.compile(r"\bpsql\w*")
SHELL_WORD = re.compile(r"""(?:[^\s"'<>;|&()]+|"(?:[^"\\]|\\.)*"|'[^']*')+""")
HEREDOC = re.compile(r"""<<(-?)[ \t]*(['"]?)([A-Za-z_]\w*)\2""")
_END = "__end_of_extracted_sql__"
_CODE, _COMMENT, _LITERAL, _HEREDOC_BODY = range(4)


def _line(text: str, at: int) -> int:
    return text.count("\n", 0, at) + 1


def _shell_lex(shell: str) -> tuple[bytearray, dict[int, tuple[int, int]]]:
    """What each character of shell is (_CODE, _COMMENT, _LITERAL, _HEREDOC_BODY), and the
    (start, end) of every heredoc body keyed by the offset of its <<.

    Enough of bash for install_app.sh: quotes, $( ) nested in double quotes, word-initial
    # comments and heredocs. A string, $( or heredoc left open fails."""
    kind = bytearray(len(shell))
    bodies: dict[int, tuple[int, int]] = {}
    stack = ["cmd"]  # "cmd" at the top, "sub" in $( ) or ( ), "dq" in a double-quoted string
    pending: list[tuple[int, bool, str]] = []
    i, n = 0, len(shell)
    while i < n:
        c, top = shell[i], stack[-1]
        if top == "dq":
            if shell.startswith("$(", i):
                stack.append("sub")
                i += 2
                continue
            step = 2 if c == "\\" else 1
            for k in range(i, min(i + step, n)):
                kind[k] = _LITERAL
            if c == '"':
                stack.pop()
            i += step
            continue
        if c == "\\":
            i += 2
        elif c == "#" and (i == 0 or shell[i - 1] in " \t\n;&|()"):
            e = shell.find("\n", i)
            e = n if e < 0 else e
            kind[i:e] = bytes([_COMMENT]) * (e - i)
            i = e
        elif c == "'":
            e = shell.find("'", i + 1)
            if e < 0:
                raise AssertionError(f"line {_line(shell, i)}: unterminated single-quoted shell string")
            kind[i:e + 1] = bytes([_LITERAL]) * (e + 1 - i)
            i = e + 1
        elif c == '"':
            kind[i] = _LITERAL
            stack.append("dq")
            i += 1
        elif shell.startswith("$(", i) or c == "(":
            stack.append("sub")
            i += 2 if c == "$" else 1
        elif c == ")":
            if top == "sub":  # at the top level, a bare ) closes a case pattern
                stack.pop()
            i += 1
        elif shell.startswith("<<<", i):
            i += 3
        elif (h := HEREDOC.match(shell, i)):
            pending.append((i, h.group(1) == "-", h.group(3)))
            i = h.end()
        elif c == "\n" and pending:
            at = i + 1
            for op, strip_tabs, tag in pending:
                start = at
                while True:
                    e = shell.find("\n", at)
                    e = n if e < 0 else e
                    line = shell[at:e]
                    if (line.lstrip("\t") if strip_tabs else line) == tag:
                        break
                    if e == n:
                        raise AssertionError(f"line {_line(shell, op)}: heredoc <<{tag} is never closed")
                    at = e + 1
                kind[start:at] = bytes([_HEREDOC_BODY]) * (at - start)
                bodies[op] = (start, at)
                at = e + 1
            pending = []
            i = at - 1
        else:
            i += 1
    if pending:
        op, _, tag = pending[0]
        raise AssertionError(f"line {_line(shell, op)}: heredoc <<{tag} is never closed")
    if stack != ["cmd"]:
        raise AssertionError(f"shell text ends inside an open {'double-quoted string' if stack[-1] == 'dq' else '$( or ('}")
    return kind, bodies


def _blanked(text: str, kind: bytearray, blank: set[int]) -> str:
    """text with every character of a kind in blank turned to a space, newlines kept."""
    return "".join(" " if kind[k] in blank and ch != "\n" else ch for k, ch in enumerate(text))


def _dq_body(shell: str, i: int) -> tuple[str, int]:
    """The bash double-quoted string opening at shell[i], unescaped, and the index past it."""
    out, j = [], i + 1
    while j < len(shell):
        c = shell[j]
        if c == "\\" and shell[j + 1:j + 2] in ('"', "\\", "$", "`"):
            out.append(shell[j + 1])
            j += 2
        elif c == '"':
            return "".join(out), j + 1
        else:
            out.append(c)
            j += 1
    raise AssertionError(f"line {shell.count(chr(10), 0, i) + 1}: unterminated double-quoted psql argument")


def _left_open(sql: str) -> bool:
    """Whether the SQL lexer ends sql inside a literal, quoted identifier, $tag$ string or
    block comment. Probed through _strip_comments alone: a -- comment appended after it is
    kept only from inside a string, and a bare word is blanked only inside a comment."""
    return _END in _strip_comments(f"{sql}\n--{_END}") or _END not in _strip_comments(f"{sql}\n{_END}")


def _psql_bodies(shell: str) -> tuple[list[tuple[int, str, tuple[int, int]]], bytearray]:
    """(line, SQL, span) for every psql call in shell text, plus _shell_lex's kinds."""
    kind, heredocs = _shell_lex(shell)
    code = _blanked(shell, kind, {_COMMENT, _LITERAL, _HEREDOC_BODY})
    calls = list(PSQL_CALL.finditer(code))
    called = {m.start("cmd") for m in calls}
    for w in PSQL_WORD.finditer(code):
        assert w.start() in called, (
            f"line {_line(shell, w.start())}: `{w.group(0)}` is not in a form PSQL_CALL reads as a psql "
            f"call -- a new wrapper or command form; teach PSQL_CALL and install_sh_sql_bodies it")
    bodies = []
    for m in calls:
        line_no = _line(shell, m.start("cmd"))
        found, i = [], m.end()
        while True:
            while i < len(shell) and shell[i] in " \t":
                i += 1
            if (h := HEREDOC.match(shell, i)):
                start, end = heredocs[i]
                found.append((shell[start:end], (start, end)))
                i = h.end()
            elif (w := SHELL_WORD.match(shell, i)):
                if re.fullmatch(r"-[A-Za-z]*c", w.group(0)):
                    i = w.end()
                    while i < len(shell) and shell[i] in " \t":
                        i += 1
                    assert shell[i:i + 1] == '"', f"line {line_no}: psql -c argument is not a double-quoted string"
                    start = i
                    body, i = _dq_body(shell, i)
                    found.append((body, (start, i)))
                else:
                    i = w.end()
            else:
                break
        assert len(found) == 1, f"line {line_no}: a psql call with {len(found)} SQL bodies (-c \"...\" or a heredoc); expected one"
        assert not _left_open(found[0][0]), (
            f"line {line_no}: the SQL lexer ends this psql body inside a literal or comment -- "
            f"everything after the opening is invisible to it")
        bodies.append((line_no, *found[0]))
    return bodies, kind


def install_sh_sql_bodies(shell: str) -> list[tuple[int, str]]:
    """(line, SQL) for every psql call in shell text: its -c "..." argument or its heredoc.

    Only these reach the SQL lexer. Run over the whole script, a shell apostrophe
    (log "can't wait") opened a literal that hid, or revived, the comments after it. A call
    with neither form, a body the lexer ends inside a literal or comment, or a psql word
    PSQL_CALL does not read as a call, fails.
    """
    return [(line_no, sql) for line_no, sql, _ in _psql_bodies(shell)[0]]


def install_sh_statements(shell: str) -> tuple[list[Stmt], list[str]]:
    """parse() over each SQL body install_app.sh inlines, comments stripped per body; and,
    as unparsed, every haf_stats GRANT/REVOKE in the shell text no body claimed -- a
    variable that is later passed to psql, a heredoc fed to something else."""
    stmts, unparsed = [], []
    bodies, kind = _psql_bodies(shell)
    for line_no, sql, _ in bodies:
        s, u = parse(_strip_comments(sql), f"scripts/install_app.sh:{line_no}")
        stmts += s
        unparsed += [f"scripts/install_app.sh:{line_no}: {x}" for x in u]
    claimed = bytearray(kind)
    for _, _, (start, end) in bodies:
        claimed[start:end] = bytes([_COMMENT]) * (end - start)
    rest = _blanked(shell, claimed, {_COMMENT})
    unparsed += [
        f"scripts/install_app.sh:{_line(rest, c.start())}: (outside any psql SQL body) {' '.join(c.group(0).split())[:160]}"
        for c in CANDIDATE.finditer(rest)
    ]
    return stmts, unparsed


def source_statements() -> tuple[list[Stmt], list[str]]:
    stmts, unparsed = [], []
    for f in _install_order():
        rel = f.relative_to(ROOT).as_posix()
        s, u = parse(_strip_comments(f.read_text(encoding="utf-8")), rel)
        stmts += s
        unparsed += [f"{rel}: {x}" for x in u]
    s, u = install_sh_statements(INSTALL_SH.read_text(encoding="utf-8"))
    stmts += s
    unparsed += u
    return stmts, unparsed


def read_listing(lines: list[str]) -> Listing:
    out = Listing()
    for line in lines:
        head, *fields = [x.strip() for x in line.split(" | ")]
        kind, _, obj = head.partition(" ")
        if kind not in ("function", "table", "sequence", "matview", "schema"):
            continue
        if kind == "function":
            obj = obj.split("(")[0]
        key = ("table" if kind == "matview" else kind, obj)
        f = dict(x.split("=", 1) for x in fields)
        out.owner[key] = f.get("owner")
        acl = f.get("acl", "")
        if acl == "<default>":
            out.default.add(key)
            acl = ""
        elif acl == "<owner only>":
            acl = ""
        out.acl[key] = {e.rstrip("*") for e in acl.split(",") if e}
    return out


def _keys(st: Stmt, listing: Listing) -> list:
    if st.kind == "ALL FUNCTIONS IN SCHEMA":
        return [k for k in listing.acl if k[0] == "function" and k[1].split(".")[0] == st.obj]
    if st.kind == "ALL TABLES IN SCHEMA":
        # PostgreSQL's ALL TABLES covers tables, views and matviews -- not sequences.
        return [k for k in listing.acl if k[0] == "table" and k[1].split(".")[0] == st.obj]
    kind = {"FUNCTION": "function", "SCHEMA": "schema", "SEQUENCE": "sequence"}.get(st.kind, "table")
    if kind == "table" and ("sequence", st.obj) in listing.acl:
        kind = "sequence"  # GRANT ... ON name (no keyword) may name a sequence
    return [(kind, st.obj)]


def check(stmts: list[Stmt], listing: Listing) -> list[str]:
    """Replay stmts in order and report every way the listing disagrees with the result."""
    want: dict = {}            # key -> {grantee: set(privs)} as the sources leave it
    revoked_public: dict = {}  # key -> statement that revoked EXECUTE from PUBLIC, not re-granted
    errors = []
    for st in stmts:
        for key in _keys(st, listing):
            if key not in listing.acl:
                errors.append(f"{st.where}: {st.verb} on {key[1]}, which tests/expected_privileges.txt does not list")
                continue
            for role in st.roles:
                slot = want.setdefault(key, {}).setdefault(role, set())
                if st.verb == "GRANT":
                    slot |= st.privs
                    if role == "PUBLIC":
                        revoked_public.pop(key, None)
                else:
                    slot -= st.privs
                    if role == "PUBLIC" and key[0] == "function" and "EXECUTE" in st.privs:
                        revoked_public[key] = st
    for key, grants in want.items():
        owner = listing.owner.get(key)
        for role, privs in grants.items():
            if role == owner:
                continue
            for priv in privs:
                if role == "PUBLIC" and priv == "EXECUTE" and key[0] == "function" and key in listing.default:
                    continue  # <default> on a function: PUBLIC EXECUTE is PostgreSQL's built-in default
                if f"{role}:{priv}" not in listing.acl[key]:
                    errors.append(f"{key[0]} {key[1]}: the sources grant {priv} to {role}, the list does not show it")
    for key, st in revoked_public.items():
        if key in listing.default or "PUBLIC:EXECUTE" in listing.acl[key]:
            errors.append(
                f"{key[0]} {key[1]}: {st.where} revokes EXECUTE from PUBLIC, but the list shows PUBLIC can "
                f"execute it -- the install undoes the REVOKE (a DROP after it?), or the list was "
                f"regenerated over a lost REVOKE"
            )
    return errors


def _expected_lines() -> list[str]:
    return [l for l in EXPECTED.read_text(encoding="utf-8").splitlines() if l.strip()]


# --------------------------------------------------------------------------- the real check

def test_every_source_grant_and_revoke_is_reflected_in_the_committed_list() -> None:
    stmts, _ = source_statements()
    assert len(stmts) >= 25, f"only {len(stmts)} statements parsed; the parser or the file list broke"
    errors = check(stmts, read_listing(_expected_lines()))
    assert not errors, "\n".join(errors)


def test_every_haf_stats_grant_or_revoke_in_the_sources_is_parsed() -> None:
    _, unparsed = source_statements()
    assert not unparsed, "GRANT/REVOKE statements the parser could not read:\n" + "\n".join(unparsed)


def test_files_replay_in_installer_order() -> None:
    """db/haf_stats_app.sql is named in a comment above db/builtin_roles.sql's run line; the
    order must come from the run lines, where builtin_roles.sql runs first."""
    names = [f.name for f in _install_order()]
    assert names.index("builtin_roles.sql") < names.index("haf_stats_app.sql")
    assert names[-1] == "endpoint_schema.sql"


def test_the_committed_list_is_sorted_and_unique() -> None:
    lines = _expected_lines()
    assert lines == sorted(lines, key=lambda s: s.encode()), "tests/expected_privileges.txt must be in C (byte) order"
    assert len(lines) == len(set(lines)), "tests/expected_privileges.txt has duplicate lines"


def test_function_names_are_not_overloaded() -> None:
    names = [l.split("(")[0] for l in _expected_lines() if l.startswith("function ")]
    dupes = sorted({n for n in names if names.count(n) > 1})
    assert not dupes, f"overloaded functions {dupes}: test_privileges_pinned matches by name only; tighten it"


# --------------------------------------------------------------------------- the checker itself

LISTING = [
    "function haf_stats_app.f(x integer) | owner=haf_stats_owner | secdef=false | acl=PUBLIC:EXECUTE,haf_stats_user:EXECUTE",
    "function haf_stats_app.g() | owner=haf_stats_owner | secdef=false | acl=<default>",
    "function haf_stats_endpoints.e() | owner=haf_stats_owner | secdef=false | acl=PUBLIC:EXECUTE,haf_stats_user:EXECUTE",
    "function haf_stats_app.locked() | owner=haf_stats_owner | secdef=false | acl=<owner only>",
    "table haf_stats_backend.t | owner=haf_stats_owner | acl=haf_stats_user:SELECT",
    "table haf_stats_app.a | owner=haf_stats_owner | acl=haf_stats_user:SELECT",
    "sequence haf_stats_app.s | owner=haf_stats_owner | acl=<default>",
    "schema haf_stats_app | owner=haf_stats_owner | acl=haf_stats_user:USAGE",
]


def _run(sql: str) -> list[str]:
    stmts, unparsed = parse(sql, "fixture.sql")
    assert not unparsed, unparsed
    return check(stmts, read_listing(LISTING))


@pytest.mark.parametrize(
    "sql",
    [
        "GRANT EXECUTE ON FUNCTION haf_stats_app.f(INT) TO haf_stats_user;",
        "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;",
        "REVOKE EXECUTE ON FUNCTION haf_stats_app.locked() FROM public;",
        "GRANT SELECT ON haf_stats_backend.t TO haf_stats_user;",
        "GRANT USAGE ON SCHEMA haf_stats_app TO haf_stats_user;",
        "EXECUTE 'GRANT EXECUTE ON FUNCTION haf_stats_app.f(INT) TO haf_stats_owner';",  # owner: not checked
        "REVOKE EXECUTE ON FUNCTION haf_stats_app.g() FROM public; GRANT EXECUTE ON FUNCTION haf_stats_app.g() TO public;",
        # ALL TABLES does not reach the <default> sequence in the same schema.
        "GRANT SELECT ON ALL TABLES IN SCHEMA haf_stats_app TO haf_stats_user;",
        # Prose, not a statement: no TO/FROM may come before ON.
        "RAISE NOTICE 'grant SELECT to haf_stats_user on whichever haf_stats_backend table applies';",
    ],
)
def test_consistent_sources_pass(sql) -> None:
    assert _run(sql) == []


@pytest.mark.parametrize(
    "sql, needle",
    [
        # #82 class 2 as reviewed: a NEW REVOKE the install undoes (the list still shows PUBLIC).
        ("REVOKE EXECUTE ON FUNCTION haf_stats_app.f(INT) FROM public;", "revokes EXECUTE from PUBLIC"),
        ("REVOKE ALL ON FUNCTION haf_stats_app.g() FROM PUBLIC;", "revokes EXECUTE from PUBLIC"),
        # A grant the list does not show (lost to a DROP, or the list regenerated over it).
        ("GRANT EXECUTE ON FUNCTION haf_stats_app.g() TO haf_stats_user;", "grant EXECUTE to haf_stats_user"),
        ("GRANT INSERT ON haf_stats_backend.t TO haf_stats_user;", "grant INSERT to haf_stats_user"),
        ("GRANT ALL ON haf_stats_backend.t TO haf_stats_user;", "grant INSERT to haf_stats_user"),
        ("GRANT CREATE ON SCHEMA haf_stats_app TO haf_stats_user;", "grant CREATE to haf_stats_user"),
        ("GRANT USAGE ON SEQUENCE haf_stats_app.s TO haf_stats_user;", "grant USAGE to haf_stats_user"),
        ("GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_app TO haf_stats_user;", "haf_stats_app.g"),
        ("EXECUTE 'GRANT EXECUTE ON FUNCTION haf_stats_app.g() TO haf_stats_user';", "grant EXECUTE to haf_stats_user"),
        # A statement about an object the list does not have at all.
        ("GRANT EXECUTE ON FUNCTION haf_stats_app.gone() TO haf_stats_user;", "does not list"),
    ],
)
def test_inconsistent_sources_fail(sql, needle) -> None:
    errors = _run(sql)
    assert any(needle in e for e in errors), errors


@pytest.mark.parametrize(
    "sql",
    [
        'GRANT EXECUTE ON FUNCTION haf_stats_app.f(INT) TO "Quoted Role";',
        "GRANT SELECT (day) ON haf_stats_backend.t TO PUBLIC;",
        "REVOKE GRANT OPTION FOR SELECT ON haf_stats_backend.t FROM haf_stats_user;",
        "EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM public', 'haf_stats_app.f(INT)');",
        "EXECUTE format('GRANT INSERT ON %1$s TO haf_stats_user', 'haf_stats_backend.t');",
        "EXECUTE format($f$GRANT INSERT ON %s TO haf_stats_user$f$, 'haf_stats_backend.t');",
        "EXECUTE 'GRANT INSERT ON ' || 'haf_stats_backend.t' || ' TO haf_stats_user';",
    ],
)
def test_an_unparseable_statement_is_reported_not_skipped(sql) -> None:
    _, unparsed = parse(sql, "fixture.sql")
    assert unparsed, sql


# --------------------------------------------------------------------------- install_app.sh's inline SQL

def _install_sh_with(block: str) -> str:
    """install_app.sh with block inserted directly before step 7's grants."""
    shell = INSTALL_SH.read_text(encoding="utf-8")
    at = shell.index("\n# 7. ") + 1
    return shell[:at] + block + "\n" + shell[at:]


def test_the_step_7_grants_are_extracted_as_sql() -> None:
    bodies = [sql for _, sql in install_sh_sql_bodies(INSTALL_SH.read_text(encoding="utf-8"))]
    assert any("ALTER DEFAULT PRIVILEGES FOR ROLE haf_stats_owner IN SCHEMA haf_stats_endpoints" in b for b in bodies)
    assert not any("log " in b or "run_sql_file" in b for b in bodies), "shell text reached the SQL lexer"


@pytest.mark.parametrize(
    "block",
    [
        'log "can\'t wait"',
        # The reviewed mutation: an apostrophe earlier in the shell must not revive a REVOKE
        # commented out inside an inline block.
        'log "can\'t wait"\npsql_cmd -c "\n    -- REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user;\n    SELECT 1;\n"',
        "log \"can't wait\"\npsql_cmd <<'SQL'\n    /* REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user; */\n"
        "    -- GRANT INSERT ON haf_stats_backend.app_config TO haf_stats_user;\n    SELECT 1;\nSQL",
        # A shell comment is not a psql call, whatever it quotes.
        "# psql_cmd -c \"REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user;\"",
        'true  # psql_cmd -c "GRANT INSERT ON haf_stats_backend.app_config TO haf_stats_user;"',
        # Nor is prose in a quoted string.
        'log "psql_cmd output: grant SELECT to haf_stats_user on haf_stats_backend if needed"',
    ],
)
def test_shell_text_and_commented_sql_do_not_change_the_parsed_statements(block: str) -> None:
    assert install_sh_statements(_install_sh_with(block)) == install_sh_statements(INSTALL_SH.read_text(encoding="utf-8"))


@pytest.mark.parametrize(
    "block",
    [
        'log "can\'t wait"\npsql_cmd -c "REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user;"',
        'x="$(psql_cmd -Atq -c "REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user")"',
        "psql_cmd -v v=\"${V}\" <<'SQL'\n    REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user;\nSQL",
        'time psql_cmd -c "REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user;"',
        'if false; then :\nelif psql_cmd -c "REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user;"; then :\nfi',
        "PGOPTIONS='-c statement_timeout=0' psql_cmd -c \"REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user;\"",
        '! psql_cmd -c "REVOKE SELECT ON haf_stats_backend.app_config FROM haf_stats_user;" || die',
    ],
)
def test_live_inline_sql_is_parsed(block: str) -> None:
    stmts, _ = install_sh_statements(_install_sh_with(block))
    assert [(s.verb, s.obj, s.roles) for s in stmts] == [("REVOKE", "haf_stats_backend.app_config", ("haf_stats_user",))]


@pytest.mark.parametrize(
    "block, needle",
    [
        ('psql_cmd -c "SELECT \'unterminated;"', "inside a literal or comment"),
        ("psql_cmd <<'SQL'\n    /* never closed\nSQL", "inside a literal or comment"),
        ('psql_cmd -f "${SCRIPT_DIR}/x.sql"', "0 SQL bodies"),
        ("psql_cmd <<'SQL'\n    SELECT 1;\n", "never closed"),
    ],
)
def test_unreadable_inline_sql_fails_loudly(block: str, needle: str) -> None:
    with pytest.raises(AssertionError, match=needle):
        install_sh_sql_bodies(_install_sh_with(block))


def _install_sh_findings(shell: str) -> list[str]:
    """What the two source tests report for shell as install_app.sh's text, on its own."""
    stmts, unparsed = install_sh_statements(shell)
    return unparsed + check(stmts, read_listing(_expected_lines()))


GRANT = "GRANT INSERT ON haf_stats_backend.app_config TO haf_stats_user;"


def test_install_sh_alone_has_no_findings() -> None:
    assert _install_sh_findings(INSTALL_SH.read_text(encoding="utf-8")) == []


@pytest.mark.parametrize(
    "block",
    [
        f'time psql_cmd -c "{GRANT}"',
        f'if false; then :\nelif psql_cmd -c "{GRANT}"; then :\nfi',
        f"PGOPTIONS='-c statement_timeout=0' psql_cmd -c \"{GRANT}\"",
        f'! psql_cmd -c "{GRANT}" || die',
        f'GRANT_SQL="{GRANT}"; psql_cmd -c "$GRANT_SQL"',
        f"GRANT_SQL=\"$(cat <<'SQL'\n    {GRANT}\nSQL\n)\"\npsql_cmd -c \"$GRANT_SQL\"",
    ],
)
def test_a_live_grant_in_any_shell_form_is_reported(block: str) -> None:
    findings = _install_sh_findings(_install_sh_with(block))
    assert any("haf_stats_backend" in f for f in findings), findings


def test_a_grant_outside_any_psql_body_is_reported_with_its_line() -> None:
    shell = _install_sh_with(f'GRANT_SQL="{GRANT}"; psql_cmd -c "$GRANT_SQL"')
    line_no = shell[:shell.index("GRANT_SQL=")].count("\n") + 1
    _, unparsed = install_sh_statements(shell)
    assert [u.split(": (")[0] for u in unparsed] == [f"scripts/install_app.sh:{line_no}"], unparsed


@pytest.mark.parametrize(
    "block, needle",
    [
        (f'psql_cmd_x -c "{GRANT}"', "`psql_cmd_x` is not in a form PSQL_CALL reads"),
        (f'exec psql_cmd -c "{GRANT}"', "`psql_cmd` is not in a form PSQL_CALL reads"),
    ],
)
def test_a_psql_word_outside_a_known_call_form_fails_loudly(block: str, needle: str) -> None:
    with pytest.raises(AssertionError, match=re.escape(needle)):
        install_sh_sql_bodies(_install_sh_with(block))
