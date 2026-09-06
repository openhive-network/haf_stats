"""Every SQL file install_app.sh runs must survive being installed twice (#60).

install_app.sh is advertised as re-runnable and haf_api_node re-runs it on every stack
start. A statement that only works on a fresh database does not fail once -- it fails on
the operator's SECOND `up`, and everything gated on
`service_completed_successfully` stays down.

That is not hypothetical. db/op_type_registry.sql dropped assert_op_types() and
assert_op_types(BOOLEAN) -- the two HISTORICAL signatures -- then created
assert_op_types(BOOLEAN, BOOLEAN) with a plain CREATE FUNCTION. Every install after the
first aborted with `already exists with same argument types`; psql_cmd sets
ON_ERROR_STOP=on, so install_app.sh exited 3. On testapi -- whose node module file does carry
`restart: on-failure`, unlike this repo's own compose files -- it took 33 restarts before
anyone looked, recovered only by dropping the function by hand.

STATIC, deliberately, and the limit is stated rather than implied: these checks read the
TEXT of the SQL, not its effect. Proving idempotency properly means installing twice
against a real database, which needs the CI compose stack.

WHAT THIS FILE LEARNED FROM ITS OWN REVIEW. The first version matched DROPs to CREATEs on
(name, ARITY). A mutation pass put 20 of 24 deliberate breakages straight through it,
including two that were the #60 bug with one cosmetic change:

  * changing the argument TYPES instead of their COUNT -- DROP (BOOLEAN,BOOLEAN) /
    CREATE (INT,INT) -- passed clean. Signature drift changes types at least as often as
    it changes arity;
  * the same bug in endpoints/endpoint_schema.sql passed, because only db/*.sql was
    scanned. That file is 7,000+ lines and install_app.sh runs it through the same
    psql_cmd under the same ON_ERROR_STOP.

It also REJECTED correct code: a properly paired DROP/CREATE using NUMERIC(10,2), because
the DROP pattern stopped at the first `)`.

So: match on normalised TYPES, take the file list from install_app.sh itself, and -- most
importantly -- fail loudly when the parser does not recognise a definition, instead of
silently not checking it. A blind spot that reports nothing is worse than no test.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
INSTALL_SH = ROOT / "scripts" / "install_app.sh"

# Loose scan: used ONLY to prove the strict patterns below saw everything.
ANY_CREATE_FN = re.compile(
    r"(?i)\bcreate\s+(?:or\s+replace\s+)?(?:function|procedure)\s", re.MULTILINE)
CREATE_FN = re.compile(
    r"(?i)^[ \t]*CREATE\s+(?:FUNCTION|PROCEDURE)\s+([a-z0-9_\".]+)\s*\(", re.MULTILINE)
CREATE_OR_REPLACE_FN = re.compile(
    r"(?i)^[ \t]*CREATE\s+OR\s+REPLACE\s+(?:FUNCTION|PROCEDURE)\s+([a-z0-9_\".]+)\s*\(",
    re.MULTILINE)
DROP_FN = re.compile(
    r"(?i)^[ \t]*DROP\s+(?:FUNCTION|PROCEDURE)\s+IF\s+EXISTS\s+([a-z0-9_\".]+)\s*\(",
    re.MULTILINE)

# PostgreSQL spells the same type several ways; a DROP and a CREATE may disagree on
# spelling while naming the same signature. Normalising avoids false alarms without
# pretending to be a type checker.
TYPE_ALIASES = {
    "bool": "boolean", "int": "integer", "int4": "integer", "int2": "smallint",
    "int8": "bigint", "float4": "real", "float8": "double precision",
    "varchar": "character varying", "char": "character", "decimal": "numeric",
    "timestamptz": "timestamp with time zone", "timetz": "time with time zone",
    # The bare spellings ARE the "without time zone" types. pg_dump and \df print the
    # long form, which is where a DROP list gets copied from, so without these the two
    # spellings of one type normalised differently and flagged each other.
    "timestamp": "timestamp without time zone", "time": "time without time zone",
    # NATIONAL is discarded sugar -- these ARE character varying / character, and no
    # PostgreSQL catalog ever prints the NATIONAL spelling. They were briefly listed in
    # MULTIWORD_TYPES, which normalised a real type to a name the other side of the
    # pair could not match, regressing correct code.
    "national character varying": "character varying",
    "national char varying": "character varying",
    "char varying": "character varying",
    "national character": "character", "nchar": "character",
    "varbit": "bit varying", "dec": "numeric",
    "serial4": "serial", "serial8": "bigserial",
}

# Types whose canonical name is several words. These must be recognised BEFORE the
# "a leading identifier is the parameter name" heuristic, which cannot tell
# `v DOUBLE PRECISION` from `DOUBLE PRECISION` and silently kept `precision`.
# Longest first, so TIMESTAMP WITH TIME ZONE wins over TIMESTAMP.
MULTIWORD_TYPES = sorted(
    (
        "timestamp without time zone", "timestamp with time zone",
        "time without time zone", "time with time zone",
        "character varying", "char varying", "bit varying", "double precision",
    ),
    key=len, reverse=True,
)


def _installed_sql_files() -> list[Path]:
    """The files install_app.sh actually executes.

    Derived from the script rather than globbed, so the scanner cannot drift from the
    installer -- which is exactly how endpoints/endpoint_schema.sql went unscanned while
    being the largest file installed.
    """
    body = INSTALL_SH.read_text(encoding="utf-8")
    rel = set(re.findall(r'\$\{SCRIPT_DIR\}/\.\./([A-Za-z0-9_/]+\.sql)', body))
    rel |= set(re.findall(r'\$\{SCRIPT_DIR\}/([A-Za-z0-9_/]+\.sql)', body))
    files = []
    for r in sorted(rel):
        for base in (ROOT, ROOT / "scripts"):
            p = (base / r).resolve()
            if p.is_file():
                files.append(p)
                break
    assert files, "no installed .sql files found; the install_app.sh parser needs updating"
    # version.sql is generated at build time and is legitimately absent from a checkout.
    return files


def _strip_comments(text: str) -> str:
    """Remove /* ... */ (nesting-aware, as PostgreSQL nests them) and -- to end of line.

    Line-only stripping was not enough: a DROP written as PROSE inside a block comment
    satisfied the assertion, which is the same "asserting against the documentation
    instead of the code" trap this suite has hit before.
    """
    out, i, depth, n = [], 0, 0, len(text)
    while i < n:
        if text.startswith("/*", i):
            depth += 1
            i += 2
        elif text.startswith("*/", i) and depth:
            depth -= 1
            i += 2
        elif depth:
            out.append("\n" if text[i] == "\n" else " ")
            i += 1
        elif text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _strip_function_bodies(text: str) -> str:
    """Blank out $tag$ ... $tag$ bodies, keeping line structure.

    Statements inside a function body are NOT executed by the installer -- they run when
    the function is called. Scanning them made this test flag a CREATE INDEX on an
    ON COMMIT DROP temp table inside a function, which is correct code.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        m = re.compile(r"\$([a-zA-Z_][a-zA-Z0-9_]*)?\$").match(text, i)
        if m:
            close = text.find(m.group(0), m.end())
            if close == -1:
                out.append(text[i:])
                break
            body = text[i:close + len(m.group(0))]
            out.append("".join("\n" if c == "\n" else " " for c in body))
            i = close + len(m.group(0))
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _split_args(arglist: str) -> list[str]:
    """Top-level arguments. Tracks (), [], {} AND quote state.

    Without quote/brace tracking, a comma inside DEFAULT '{a,b}' counted as an argument
    separator, inflating the arity so it matched a stale DROP -- turning a real bug into
    a pass.
    """
    args, depth, buf, quote = [], 0, [], None
    for ch in arglist:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            buf.append(ch)
        elif ch in "([{":
            depth += 1
            buf.append(ch)
        elif ch in ")]}":
            depth -= 1
            buf.append(ch)
        elif ch == "," and depth == 0:
            args.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if "".join(buf).strip():
        args.append("".join(buf))
    return [a.strip() for a in args if a.strip()]


def _arg_type(arg: str) -> str:
    """The normalised TYPE of one argument, discarding mode, name and DEFAULT.

    Returns "" for an OUT parameter, which callers drop: PostgreSQL identifies a
    function by its IN/INOUT/VARIADIC argument types only, so an OUT parameter is not
    part of the signature DROP FUNCTION matches on. Counting them made this test demand
    a DROP for a function that does not exist -- accepted by IF EXISTS, leaving the real
    one in place, with the suite green.
    """
    # `=` is a documented synonym for DEFAULT, and this repo writes it
    # (db/process_account_cohorts.sql, db/process_content_cohorts.sql). Stripping only
    # DEFAULT normalised `_from_month DATE = NULL` to the non-type `date = null`.
    a = re.sub(r"(?i)(\bDEFAULT\b|=).*$", "", arg).strip()
    mode = re.match(r"(?i)^(IN|OUT|INOUT|VARIADIC)\s+", a)
    if mode:
        if mode.group(1).upper() == "OUT":
            return ""
        a = a[mode.end():].strip()

    a = re.sub(r"\(.*?\)", "", a)            # NUMERIC(10,2) -> NUMERIC
    a = re.sub(r"\s+", " ", a).strip()

    # INTERVAL takes field qualifiers (INTERVAL DAY TO SECOND). pg_proc.proargtypes is
    # an oidvector, so typmods are discarded and every one of them is just `interval`.
    # Unnamed these normalised to `day to second` and named to `interval day to second`
    # -- the same DROP/CREATE spelling asymmetry this parser exists to remove.
    a = re.sub(r"(?i)\b(INTERVAL)\s+(?:YEAR|MONTH|DAY|HOUR|MINUTE|SECOND)"
               r"(?:\s+TO\s+(?:MONTH|DAY|HOUR|MINUTE|SECOND))?\s*$", r"\1", a).strip()

    # Array-ness is part of the identity: f(text) and f(text[]) are different
    # functions. But DIMENSIONALITY and SIZE are not -- PostgreSQL does not honour
    # them, so text[], text[][] and text[4] are one type and a DROP naming any of them
    # resolves the others. Collapse the whole run to a single [].
    suffix = ""
    while True:
        stripped = re.sub(r"\[\s*\d*\s*\]$", "", a.strip())
        if stripped == a.strip():
            break
        suffix = "[]"
        a = stripped
    a = a.strip()

    low = a.lower()
    for mw in MULTIWORD_TYPES:
        # Still resolved through TYPE_ALIASES: `char varying` is a real spelling whose
        # canonical name is `character varying`, and the heuristic below would strip
        # CHAR as if it were the parameter name and leave the non-type `varying`.
        if low == mw or low.endswith(" " + mw):
            return TYPE_ALIASES.get(mw, mw) + suffix

    # A leading identifier is the parameter NAME only if something follows it.
    # A quoted name is still a name. endpoints/endpoint_schema.sql writes
    # `"from_date" TEXT = NULL` throughout, which the unquoted-only pattern left as the
    # non-type `"from_date" text`. That shape is what #73's remediation will produce.
    parts = a.split()
    if len(parts) > 1 and re.fullmatch(r'[a-z_][a-z0-9_]*|"[^"]*"', parts[0], re.I):
        a = " ".join(parts[1:])
    a = a.strip().lower()
    return TYPE_ALIASES.get(a, a) + suffix


# Not every object kind has an IF NOT EXISTS form. Offering it for TRIGGER, POLICY,
# VIEW or TYPE prescribes invalid SQL -- the same defect as the DROP UNIQUE INDEX
# message this file used to emit.
_REMEDIES = {
    "TYPE": "CREATE TYPE has no IF NOT EXISTS form: DROP TYPE IF EXISTS it first.",
    "VIEW": "Use CREATE OR REPLACE VIEW, or DROP VIEW IF EXISTS it first "
            "(there is no CREATE VIEW IF NOT EXISTS).",
    "MATERIALIZED VIEW": "Use CREATE MATERIALIZED VIEW IF NOT EXISTS, or DROP it first.",
    "TRIGGER": "Use CREATE OR REPLACE TRIGGER (PG14+), or DROP TRIGGER IF EXISTS it "
               "first (there is no CREATE TRIGGER IF NOT EXISTS).",
    "POLICY": "DROP POLICY IF EXISTS it first (there is no CREATE POLICY IF NOT EXISTS "
              "and no CREATE OR REPLACE POLICY).",
}


def _remedy_for(kind: str) -> str:
    return _REMEDIES.get(kind, f"Use CREATE {kind} IF NOT EXISTS, or DROP it first.")


def _signature_of(arglist: str) -> tuple:
    """The tuple PostgreSQL would match a DROP against: OUT parameters removed."""
    return tuple(t for t in (_arg_type(a) for a in _split_args(arglist)) if t)


def _balanced_args(text: str, open_paren: int) -> str:
    depth = 0
    for i in range(open_paren, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:i]
    raise AssertionError("unbalanced parentheses at offset %d" % open_paren)


def _signatures(pattern, text: str) -> list[tuple[str, tuple[str, ...], int]]:
    out = []
    for m in pattern.finditer(text):
        args = _balanced_args(text, text.index("(", m.end() - 1))
        types = _signature_of(args)
        out.append((m.group(1).lower().replace('"', ""), types, m.start()))
    return out


@pytest.mark.parametrize("path", _installed_sql_files(), ids=lambda p: p.name)
def test_the_parser_recognises_every_function_definition(path: Path):
    """A definition the patterns miss is not merely unmatched -- it is UNCHECKED, and the
    file then passes with zero findings. This turns every parser blind spot into a loud
    failure instead of a silent pass, which is the single guard the first version most
    needed."""
    text = _strip_function_bodies(_strip_comments(path.read_text(encoding="utf-8")))
    loose = len(ANY_CREATE_FN.findall(text))
    strict = len(CREATE_FN.findall(text)) + len(CREATE_OR_REPLACE_FN.findall(text))
    assert loose == strict, (
        f"{path.name}: {loose} function/procedure definitions found by a loose scan but "
        f"only {strict} parsed by the strict patterns -- {loose - strict} would be "
        f"silently unchecked. Fix the patterns rather than the count."
    )


@pytest.mark.parametrize("path", _installed_sql_files(), ids=lambda p: p.name)
def test_every_created_function_is_dropped_with_its_own_signature(path: Path):
    """A plain CREATE FUNCTION/PROCEDURE needs a DROP for the signature it creates, and
    the DROP must come FIRST.

    Matched on normalised argument TYPES, not on arity: DROP (BOOLEAN,BOOLEAN) followed
    by CREATE (INT,INT) is the #60 bug exactly, and an arity match waves it through.
    """
    text = _strip_function_bodies(_strip_comments(path.read_text(encoding="utf-8")))
    drops = _signatures(DROP_FN, text)
    problems = []
    for name, types, pos in _signatures(CREATE_FN, text):
        matching = [d for d in drops if d[0] == name and d[1] == types]
        if not matching:
            got = sorted({d[1] for d in drops if d[0] == name})
            problems.append(
                f"{name}({', '.join(types) or ''}) is never dropped at that signature"
                + (f" (dropped instead: {got})" if got else ""))
        elif not any(d[2] < pos for d in matching):
            problems.append(
                f"{name}({', '.join(types) or ''}) is dropped only AFTER it is created, "
                f"so every install creates it and then destroys it")
    assert not problems, (
        f"{path.name}: not re-runnable -- a second install aborts with 'already exists "
        f"with same argument types': {problems}. Add DROP FUNCTION IF EXISTS for that "
        f"exact signature before the CREATE, or use CREATE OR REPLACE where the return "
        f"type is stable."
    )


def test_the_regression_that_prompted_this_file_is_covered():
    """Pins the specific signature AND that it is still created, so a future edit has to
    keep the pair in step. (The generic test above subsumes the first half; this one
    names what to look at.)"""
    text = _strip_comments((ROOT / "db" / "op_type_registry.sql").read_text(encoding="utf-8"))
    drops = {(n, t) for n, t, _ in _signatures(DROP_FN, text)}
    creates = {(n, t) for n, t, _ in _signatures(CREATE_FN, text)}
    sig = ("haf_stats_app.assert_op_types", ("boolean", "boolean"))
    assert sig in creates, "assert_op_types(BOOLEAN, BOOLEAN) is no longer created here"
    assert sig in drops, (
        "op_type_registry.sql must drop the two-argument assert_op_types it creates; "
        "without it every re-install aborts (#60)")


@pytest.mark.parametrize("path", _installed_sql_files(), ids=lambda p: p.name)
def test_other_object_types_are_created_idempotently(path: Path):
    """CREATE TYPE/TABLE/SCHEMA/INDEX/VIEW/SEQUENCE/TRIGGER/POLICY/EXTENSION.

    CREATE TYPE has NO `IF NOT EXISTS` form at all, so it *requires* a preceding DROP --
    the highest-risk class, and one the first version did not scan.
    """
    text = _strip_function_bodies(_strip_comments(path.read_text(encoding="utf-8")))
    # No "UNIQUE INDEX": the exemption search is built from the same string, so it
    # looked for `DROP UNIQUE INDEX IF EXISTS`, which is a syntax error -- the only way
    # to satisfy the assertion was IF NOT EXISTS or invalid SQL. Indexes drop with
    # DROP INDEX regardless of uniqueness, and the INDEX pattern below already matches
    # CREATE UNIQUE INDEX via the optional qualifier.
    kinds = ("TYPE", "SCHEMA", "TABLE", "INDEX", "VIEW",
             "MATERIALIZED VIEW", "SEQUENCE", "TRIGGER", "POLICY", "EXTENSION")
    problems = []
    for kind in kinds:
        # CONCURRENTLY is optional and precedes IF NOT EXISTS; an index may also be
        # UNNAMED (CREATE INDEX ON tbl (...)), where PostgreSQL derives the name. The
        # first cut captured "CONCURRENTLY" and "ON" as object names.
        pat = re.compile(
            r"(?i)^[ \t]*CREATE\s+(?:UNLOGGED\s+|UNIQUE\s+)?%s\s+(?:CONCURRENTLY\s+)?"
            r"(?!IF\s+NOT\s+EXISTS)(?!ON\b)(?!CONCURRENTLY\b)([a-z0-9_.\"]+)"
            % kind.replace(" ", r"\s+"), re.MULTILINE)
        for m in pat.finditer(text):
            name = m.group(1)
            # CREATE TABLE x AS SELECT / WITH is rebuilt wholesale; anchor to the
            # grammar rather than to " AS " appearing anywhere nearby, which previously
            # exempted GENERATED ALWAYS AS and DEFAULT CAST(0 AS NUMERIC).
            if re.match(r"(?i)\s*AS\s+(SELECT|WITH)\b", text[m.end():m.end() + 40]):
                continue
            if re.search(r"(?i)DROP\s+%s\s+IF\s+EXISTS\s+%s\b"
                         % (kind.replace(" ", r"\s+"), re.escape(name)), text[:m.start()]):
                continue
            problems.append(f"{kind} {name}")
    assert not problems, (
        f"{path.name}: a re-install aborts on {problems}. "
        + " ".join(sorted({_remedy_for(k.split()[0] if k.split()[0] != "MATERIALIZED"
                                       else "MATERIALIZED VIEW")
                           for k in problems}))
    )


# --- the parser's own unit tests ---------------------------------------------------
#
# Tested directly, not only through the corpus: every false PASS the mutation review
# found came from the counter, and the corpus happens not to contain the shapes that
# break it.

@pytest.mark.parametrize(
    "arglist,expected",
    [
        ("a INT, b INT", ("integer", "integer")),
        ("v NUMERIC(10,2), w INT", ("numeric", "integer")),
        ("codes TEXT DEFAULT '{a,b}'", ("text",)),
        ("flag BOOL DEFAULT TRUE, n INT4", ("boolean", "integer")),
        ("", ()),
        ("BOOLEAN, BOOLEAN", ("boolean", "boolean")),
        # An array is NOT its element type -- f(text) and f(text[]) are different
        # functions. This case previously expected ("text",), which made the test
        # accept a DROP that resolves nothing: #60 with an array type.
        ("VARIADIC parts TEXT[]", ("text[]",)),
        ("s VARCHAR(64)", ("character varying",)),
        # Multi-word types, in BOTH spellings. The DROP form omits the parameter name
        # -- it is what pg_dump emits -- and used to normalise to a different string
        # than the CREATE form, flagging correct code.
        ("DOUBLE PRECISION", ("double precision",)),
        ("v DOUBLE PRECISION", ("double precision",)),
        ("TIMESTAMP WITH TIME ZONE", ("timestamp with time zone",)),
        ("ts TIMESTAMP WITH TIME ZONE", ("timestamp with time zone",)),
        ("TIMESTAMPTZ", ("timestamp with time zone",)),
        # Distinct types that both used to collapse to "varying".
        ("CHARACTER VARYING", ("character varying",)),
        ("BIT VARYING", ("bit varying",)),
        # OUT parameters are not part of the identity DROP FUNCTION matches on.
        ("a integer, OUT b text", ("integer",)),
        ("INOUT a integer", ("integer",)),
        ("_from DATE, OUT lead_from DATE, OUT lead_to DATE", ("date",)),
        # `=` is a synonym for DEFAULT and this repo writes it. Stripping only DEFAULT
        # yielded the non-type `date = null`, and told the author to drop it by that name.
        ("_from_month DATE = NULL", ("date",)),
        ("_as_of TIMESTAMP, _from DATE = NULL", ("timestamp without time zone", "date")),
        # The bare spellings ARE the "without time zone" types.
        ("TIMESTAMP", ("timestamp without time zone",)),
        ("TIMESTAMP WITHOUT TIME ZONE", ("timestamp without time zone",)),
        ("TIME", ("time without time zone",)),
        # Dimensionality and size are not part of an array type's identity.
        ("TEXT[]", ("text[]",)),
        ("TEXT[][]", ("text[]",)),
        ("TEXT[4]", ("text[]",)),
        ("v INT4[]", ("integer[]",)),
        # NATIONAL is sugar; these are character varying / character. Listing them as
        # multi-word type NAMES regressed correct code from pass to fail.
        ("NATIONAL CHARACTER VARYING(10)", ("character varying",)),
        ("NATIONAL CHARACTER", ("character",)),
        ("CHAR VARYING", ("character varying",)),
        ("x CHAR VARYING", ("character varying",)),
        ("VARBIT", ("bit varying",)),
        ("DEC(10,2)", ("numeric",)),
        ("NCHAR(3)", ("character",)),
        # Typmods are discarded from a function's argument types.
        ("INTERVAL DAY TO SECOND", ("interval",)),
        ("x INTERVAL DAY TO SECOND", ("interval",)),
        ("INTERVAL HOUR TO MINUTE(3)", ("interval",)),
        ("INTERVAL", ("interval",)),
        # Quoted parameter names -- the style endpoint_schema.sql uses, and the shape
        # #73's remediation will produce.
        ('"from_date" TEXT = NULL', ("text",)),
        ('"page" INT = 1, "page_size" INT = 20', ("integer", "integer")),
        ('"g" INT', ("integer",)),
        ('"g" CHARACTER VARYING = NULL', ("character varying",)),
    ],
)
def test_the_signature_parser(arglist, expected):
    assert _signature_of(arglist) == expected


def test_block_comments_are_stripped():
    """A DROP written as prose inside /* */ must not count as a statement."""
    text = "/* we used to\nDROP FUNCTION IF EXISTS s.f(INT);\nbut no longer */\nSELECT 1;"
    assert "DROP FUNCTION" not in _strip_comments(text)


def test_the_installed_file_list_includes_the_endpoints_schema():
    """Derived from install_app.sh, so it cannot drift from the installer. The first
    version globbed db/*.sql and therefore never scanned the largest installed file."""
    names = {p.name for p in _installed_sql_files()}
    assert "endpoint_schema.sql" in names, (
        "endpoints/endpoint_schema.sql is executed by install_app.sh and must be scanned"
    )
