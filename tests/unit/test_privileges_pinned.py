"""Every GRANT/REVOKE the installer runs on a haf_stats object is reflected in the
committed tests/expected_privileges.txt (#82).

reinstall-test compares what an install actually produced with that committed list
(tests/privileges.sql). That catches a privilege the list has and the install lost -- but
when a change is intended, the list is regenerated FROM the install, so on its own the
list would absorb whatever the install did. Review of !121 put two mutations straight
through it: a new `REVOKE ... FROM public` placed above a DROP-and-recreate (undone on
every install), and a blanket REVOKE at the top of a schema. Both leave the install, and
therefore a regenerated list, unchanged.

This test closes that loop statically, with no database: it replays every GRANT/REVOKE in
the install sources, in install order, and requires the committed list to show the
result. A REVOKE the install silently undoes now disagrees with the list, whichever way
the list was produced.

Scope and limits, stated rather than implied:
  * objects in haf_stats_app / haf_stats_backend / haf_stats_endpoints only -- grants on
    HAF's own schemas (hive, hafd) follow the HAF version;
  * function names are matched without their argument list. No haf_stats function is
    overloaded today; test_function_names_are_not_overloaded fails the day one is, so the
    matching can be tightened then;
  * a grant to an object's own owner is not checked, because tests/privileges.sql leaves
    owner entries out;
  * role memberships (db/builtin_roles.sql) are conditional DO blocks; the committed list
    pins them, this test does not replay them;
  * an unparseable GRANT/REVOKE on a haf_stats object FAILS the test instead of being
    skipped: a blind spot that reports nothing is worse than no test.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

import pytest

from tests.unit.test_sql_idempotency import INSTALL_SH, ROOT, _installed_sql_files, _strip_comments

EXPECTED = ROOT / "tests" / "expected_privileges.txt"
SCHEMAS = ("haf_stats_app", "haf_stats_backend", "haf_stats_endpoints")
ALL_TABLE_PRIVS = {"SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN"}

STATEMENT = re.compile(
    r"\b(?P<verb>GRANT|REVOKE)\s+(?P<privs>(?:ALL(?:\s+PRIVILEGES)?|[A-Z]+)(?:\s*,\s*[A-Z]+)*)\s+"
    r"ON\s+(?P<kind>FUNCTION|PROCEDURE|ROUTINE|TABLE|SEQUENCE|SCHEMA|"
    r"ALL\s+FUNCTIONS\s+IN\s+SCHEMA|ALL\s+TABLES\s+IN\s+SCHEMA)?\s*"
    r"(?P<name>[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)?)\s*(?P<args>\([^)]*\))?\s+"
    r"(?P<dir>TO|FROM)\s+(?P<roles>[a-z_][a-z0-9_]*(?:\s*,\s*[a-z_][a-z0-9_]*)*)",
    re.IGNORECASE,
)
# Anything shaped like a GRANT/REVOKE (privilege list, then ON) touching a haf_stats object.
# Compared with what STATEMENT parsed, so a statement the parser cannot read is reported,
# not skipped. Requiring "<privileges> ON" keeps prose in RAISE messages and OpenAPI
# descriptions ("grant SELECT to haf_stats_user on ...") out.
CANDIDATE = re.compile(
    r"\b(GRANT|REVOKE)\s+(?:ALL|EXECUTE|SELECT|INSERT|UPDATE|DELETE|TRUNCATE|REFERENCES|TRIGGER|USAGE|CREATE)"
    r"\b[A-Z ,]*?\s+ON\b[^;']*?\bhaf_stats_(?:app|backend|endpoints)\b",
    re.IGNORECASE,
)


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
    functions_by_schema: dict = field(default_factory=dict)


def _norm_kind(kind: str | None) -> str:
    k = " ".join((kind or "TABLE").upper().split())
    return {"PROCEDURE": "FUNCTION", "ROUTINE": "FUNCTION"}.get(k, k)


def _privs(raw: str, kind: str) -> frozenset:
    p = {x.strip().upper() for x in raw.split(",")}
    if p & {"ALL", "ALL PRIVILEGES"}:
        return frozenset({"EXECUTE"} if "FUNCTION" in kind else {"USAGE", "CREATE"} if kind == "SCHEMA" else ALL_TABLE_PRIVS)
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
    return stmts, unparsed


def _install_order() -> list:
    body = INSTALL_SH.read_text(encoding="utf-8")
    files = _installed_sql_files()

    def pos(p):
        rel = p.relative_to(ROOT).as_posix()
        i = body.find(rel)
        return i if i >= 0 else body.find(p.name)

    return sorted(files, key=pos)


def source_statements() -> tuple[list[Stmt], list[str]]:
    stmts, unparsed = [], []
    for f in _install_order():
        s, u = parse(_strip_comments(f.read_text(encoding="utf-8")), f.relative_to(ROOT).as_posix())
        stmts += s
        unparsed += [f"{f.relative_to(ROOT).as_posix()}: {x}" for x in u]
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
            schema = obj.split(".")[0]
            out.functions_by_schema.setdefault(schema, []).append(obj)
        key = (kind if kind in ("function", "schema") else "table", obj)
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


def _key(st: Stmt):
    if st.kind == "FUNCTION":
        return ("function", st.obj)
    if st.kind == "SCHEMA":
        return ("schema", st.obj)
    return ("table", st.obj)


def check(stmts: list[Stmt], listing: Listing) -> list[str]:
    """Replay stmts in order and report every way the listing disagrees with the result."""
    want: dict = {}          # key -> {grantee: set(privs)} as the sources leave it
    revoked_public: dict = {}  # key -> statement that revoked from PUBLIC and was not re-granted
    errors = []
    for st in stmts:
        if st.kind in ("ALL FUNCTIONS IN SCHEMA", "ALL TABLES IN SCHEMA"):
            kind = "function" if "FUNCTIONS" in st.kind else "table"
            keys = [(kind, o) for (k, o) in listing.acl if k == kind and o.split(".")[0] == st.obj]
        else:
            keys = [_key(st)]
        for key in keys:
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

def test_every_source_grant_and_revoke_is_reflected_in_the_committed_list():
    stmts, _ = source_statements()
    assert len(stmts) >= 25, f"only {len(stmts)} statements parsed; the parser or the file list broke"
    errors = check(stmts, read_listing(_expected_lines()))
    assert not errors, "\n".join(errors)


def test_every_haf_stats_grant_or_revoke_in_the_sources_is_parsed():
    _, unparsed = source_statements()
    assert not unparsed, "GRANT/REVOKE statements the parser could not read:\n" + "\n".join(unparsed)


def test_the_committed_list_is_sorted_and_unique():
    lines = _expected_lines()
    assert lines == sorted(lines, key=lambda s: s.encode()), "tests/expected_privileges.txt must be in C (byte) order"
    assert len(lines) == len(set(lines)), "tests/expected_privileges.txt has duplicate lines"


def test_function_names_are_not_overloaded():
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
    ],
)
def test_consistent_sources_pass(sql):
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
        ("GRANT CREATE ON SCHEMA haf_stats_app TO haf_stats_user;", "grant CREATE to haf_stats_user"),
        ("GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_app TO haf_stats_user;", "haf_stats_app.g"),
        ("EXECUTE 'GRANT EXECUTE ON FUNCTION haf_stats_app.g() TO haf_stats_user';", "grant EXECUTE to haf_stats_user"),
        # A statement about an object the list does not have at all.
        ("GRANT EXECUTE ON FUNCTION haf_stats_app.gone() TO haf_stats_user;", "does not list"),
    ],
)
def test_inconsistent_sources_fail(sql, needle):
    errors = _run(sql)
    assert any(needle in e for e in errors), errors


def test_an_unparseable_statement_is_reported_not_skipped():
    _, unparsed = parse("GRANT EXECUTE ON FUNCTION haf_stats_app.f(INT) TO \"Quoted Role\";", "fixture.sql")
    assert unparsed
