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

import functools
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
# The argument list is optional: endpoints/endpoint_schema.sql and most of db/ write
# `DROP FUNCTION IF EXISTS s.f;`, which drops the sole overload of that name and errors
# loudly if there are several. Requiring `(` made the parser see 1 of 26 endpoint DROPs.
DROP_FN = re.compile(
    r"(?i)^[ \t]*DROP\s+(?:FUNCTION|PROCEDURE)\s+IF\s+EXISTS\s+([a-z0-9_\".]+)\s*\(?",
    re.MULTILINE)

# A CREATE OR REPLACE whose signature genuinely never changes may opt out of needing a
# preceding DROP by carrying this marker in the comment block directly above it.
STABLE_SIGNATURE_MARKER = "-- idempotency: stable signature"

# On-disk SQL files install_app.sh deliberately does not run, each with the reason.
NOT_INSTALLED: dict[str, str] = {
    "docker/block-processing-healthcheck.sql": "read-only probe run by the container healthcheck",
    "scripts/uninstall_verify.sql": "run by uninstall_app.sh after the schemas are dropped",
}
# `.sql` tokens in install_app.sh's code that name a file without building a path to it
# (log text, RAISE messages, SQL comments in a heredoc), each with where it appears.
INSTALLER_PROSE_SQL: dict[str, str] = {
    "db/haf_stats_app.sql": "a log message on the non-forking context check",
    "process_*.sql": "an SQL comment in the snapshot-refresh cron heredoc",
    "db/process_*.sql": "a RAISE NOTICE when cron scheduling is skipped",
    "db/builtin_roles.sql": "a RAISE EXCEPTION in the sync_status() privilege check",
}
# Referenced by install_app.sh but produced at build time, so absent from a checkout.
GENERATED_SQL = {"db/version.sql": "written by the Docker build; guarded by [ -f ]"}
# Ratchet on the installer-derived list (generated files excluded). A change that
# makes the extractor see fewer files has to edit this number, in review.
INSTALLED_SQL_FILE_COUNT = 27

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
# "a leading identifier is the parameter name" heuristic, which takes DOUBLE in a bare
# `DOUBLE PRECISION` for a parameter name and silently keeps `precision`.
# Longest first, so TIMESTAMP WITH TIME ZONE wins over TIMESTAMP.
MULTIWORD_TYPES = sorted(
    (
        "timestamp without time zone", "timestamp with time zone",
        "time without time zone", "time with time zone",
        "character varying", "char varying", "bit varying", "double precision",
    ),
    key=len, reverse=True,
)


# A path the installer builds from a shell expansion: `${SCRIPT_DIR}/../db/x.sql`,
# `"${SCRIPT_DIR}"/../db/x_*.sql`, `$(dirname "$0")/../db/x.sql`, `${DB_DIR}/x.sql`,
# `$SCRIPT_DIR/../db/x.sql`. Anchored on the expansion rather than on the literal
# `${SCRIPT_DIR}/`, which each of those other spellings bypassed with a non-idempotent
# file and the suite green. A bare `db/x.sql` -- prose, or a path relative to a `cd` --
# is not matched; test_every_sql_token_in_the_installer_is_accounted_for catches it.
_INSTALLER_SQL_PATH = re.compile(
    r"""(?:[})"']|\$[A-Za-z_][A-Za-z0-9_]*)/((?:\.\./)*[A-Za-z0-9_.*-]+(?:/[A-Za-z0-9_.*-]+)*\.sql)\b""")
# Any `.sql` word in shell code, path or prose.
_INSTALLER_SQL_TOKEN = re.compile(r"[A-Za-z0-9_.*/-]*\.sql\b")


HEREDOC = re.compile(r"""<<(-?)[ \t]*(['"]?)([A-Za-z_]\w*)\2""")
_CODE, _COMMENT, _LITERAL, _HEREDOC_BODY = range(4)


def _line(text: str, at: int) -> int:
    return text.count("\n", 0, at) + 1


def _shell_lex(shell: str) -> tuple[bytearray, dict[int, tuple[int, int]]]:
    """What each character of shell is (_CODE, _COMMENT, _LITERAL, _HEREDOC_BODY), and the
    (start, end) of every heredoc body keyed by the offset of its <<.

    Enough of bash for install_app.sh: quotes (ANSI-C $'...' included), $( ) nested in
    double quotes, word-initial # comments and heredocs. A string, $( or heredoc left open fails."""
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
        elif shell.startswith("$'", i):
            e = i + 2
            while e < n and shell[e] != "'":
                e += 2 if shell[e] == "\\" else 1
            if e >= n:
                raise AssertionError(f"line {_line(shell, i)}: unterminated $'...' shell string")
            kind[i:e + 1] = bytes([_LITERAL]) * (e + 1 - i)
            i = e + 1
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


def _installer_code(script: str) -> str:
    """A shell script with its `#` comments blanked -- whole-line and trailing alike --
    and everything else, quoted strings and heredoc bodies included, kept in place."""
    return _blanked(script, _shell_lex(script)[0], {_COMMENT})


def _installer_sql_paths(script: str) -> list[str]:
    """Every SQL path a shell script builds, outside its `#` comments."""
    return sorted(set(_INSTALLER_SQL_PATH.findall(_installer_code(script))))


def _unextracted_sql_tokens(script: str) -> list[str]:
    """`.sql` words in a shell script's code that are not a path the extractor reads."""
    code = _installer_code(script)
    built = {m.end(1) for m in _INSTALLER_SQL_PATH.finditer(code)}
    return [m.group(0) for m in _INSTALLER_SQL_TOKEN.finditer(code) if m.end() not in built]


def _resolve_installer_path(rel: str) -> list[Path]:
    """The files an installer path names: a `../` path is relative to scripts/ (every
    expansion install_app.sh roots paths in is its own directory); anything else is
    tried against the repository root, then scripts/. Globs expand. [] if unresolved."""
    bases = (ROOT / "scripts",) if rel.startswith("../") else (ROOT, ROOT / "scripts")
    for base in bases:
        hits = sorted(p.resolve() for p in base.glob(rel) if p.is_file()) if "*" in rel \
            else [p for p in [(base / rel).resolve()] if p.is_file()]
        if hits:
            return hits
    return []


def _installed_sql_files() -> list[Path]:
    """The files install_app.sh actually executes.

    Derived from the script rather than globbed, so the scanner cannot drift from the
    installer -- which is exactly how endpoints/endpoint_schema.sql went unscanned while
    being the largest file installed. The tests at the end of this file cross-check the
    result against the files on disk, so an installer spelling the extractor misses is a
    failure rather than a file silently left unscanned.
    """
    script = INSTALL_SH.read_text(encoding="utf-8")
    return sorted({p for rel in _installer_sql_paths(script) for p in _resolve_installer_path(rel)})


_DOLLAR_TAG = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")


def _lex_sql(text: str) -> tuple[str, str | None, tuple[tuple[int, int], ...]]:
    """`text` with comments blanked, the construct left open at end of input (or None),
    and the (start, end) span of every top-level $tag$ string, tags included.

    Length- and line-preserving: every comment character becomes a space (newlines
    kept), so offsets in the result are offsets in the source.

    Literal-aware, as PostgreSQL's lexer is: `/*`, `--` or `$$` inside '...', E'...',
    "..." or a $tag$ string opens nothing. Without this one `'/*'` in a string blanked
    the rest of endpoint_schema.sql and every check on it passed on zero statements.
    The $tag$ spans come from this same pass for the same reason: a second scanner that
    re-found them without string state paired the `$$` in `SELECT '$$';` with the next
    real function body, swapping code and bodies so that no definition was checked.

    A $tag$ body is usually PL/pgSQL, whose comments must go too, so it is lexed the same
    way -- unless that leaves something open (a plain string like $d$it's$d$, or Python
    in a plpython3u body), in which case it is kept verbatim, which is what it is.
    """
    out: list[str] = []
    spans: list[tuple[int, int]] = []
    i, depth, n = 0, 0, len(text)

    def blank(s: str) -> str:
        return "".join("\n" if c == "\n" else " " for c in s)

    while i < n:
        c = text[i]
        if depth:
            if text.startswith("/*", i):
                depth += 1
                out.append("  ")
                i += 2
            elif text.startswith("*/", i):
                depth -= 1
                out.append("  ")
                i += 2
            else:
                out.append(blank(c))
                i += 1
        elif text.startswith("/*", i):
            depth = 1
            out.append("  ")
            i += 2
        elif text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif c in "'\"":
            escapes = c == "'" and i > 0 and text[i - 1] in "eE" \
                and not (i > 1 and (text[i - 2].isalnum() or text[i - 2] in "_$"))
            j = i + 1
            while True:
                if j >= n:
                    left_open = "string literal" if c == "'" else "quoted identifier"
                    return "".join(out) + text[i:], left_open, tuple(spans)
                if escapes and text[j] == "\\":
                    j += 2
                elif text[j] == c:
                    if text.startswith(c, j + 1):
                        j += 2
                    else:
                        break
                else:
                    j += 1
            out.append(text[i:j + 1])
            i = j + 1
        elif c == "$" and (m := _DOLLAR_TAG.match(text, i)) \
                and not (i and (text[i - 1].isalnum() or text[i - 1] in "_$")):
            tag = m.group(0)
            close = text.find(tag, m.end())
            if close == -1:
                return "".join(out) + text[i:], f"{tag} string", tuple(spans)
            body = text[m.end():close]
            lexed, body_open, _ = _lex_sql(body)
            out.append(tag + (body if body_open else lexed) + tag)
            spans.append((i, close + len(tag)))
            i = close + len(tag)
        else:
            out.append(c)
            i += 1
    return "".join(out), ("block comment" if depth else None), tuple(spans)


# Every check reads the same few files; lex each once. Nested bodies call _lex_sql
# directly, so they do not evict the files.
_lexed = functools.lru_cache(maxsize=8)(_lex_sql)


def _lex_comments(text: str) -> tuple[str, str | None]:
    """`text` with comments blanked, plus the construct left open at end of input (or None)."""
    return _lexed(text)[:2]


def _strip_comments(text: str) -> str:
    """Blank out /* ... */ (nesting-aware, as PostgreSQL nests them) and -- to end of line,
    leaving string literals, quoted identifiers and $tag$ strings intact.

    Line-only stripping was not enough: a DROP written as PROSE inside a block comment
    satisfied the assertion, which is the same "asserting against the documentation
    instead of the code" trap this suite has hit before.
    """
    return _lex_comments(text)[0]


def _dollar_quoted_spans(text: str) -> tuple[tuple[int, int], ...]:
    """(start, end) of every top-level $tag$ string in `text`, as PostgreSQL lexes them."""
    return _lexed(text)[2]


def _code_text(text: str) -> str:
    """`text` with comments AND $tag$ strings blanked, keeping offsets and line structure.

    Statements inside a function body are NOT executed by the installer -- they run when
    the function is called. Scanning them made this test flag a CREATE INDEX on an
    ON COMMIT DROP temp table inside a function, which is correct code.
    """
    stripped, _, spans = _lexed(text)
    out, prev = [], 0
    for start, end in spans:
        out += [stripped[prev:start], "".join("\n" if c == "\n" else " " for c in stripped[start:end])]
        prev = end
    return "".join(out) + stripped[prev:]


# The word before a top-level $tag$ string, wherever one appears in an installed file:
# a function body (AS), an anonymous block (DO) or a COMMENT ON ... IS text (IS).
_DOLLAR_STRING_OPENERS = ("AS", "DO", "IS")


def _misplaced_dollar_strings(raw: str) -> list[str]:
    """Blanked $tag$ strings that do not follow a word in _DOLLAR_STRING_OPENERS.

    A length canary cannot see a lexer that mistakes code for a body: swapping the two
    keeps about as much text. But a swap opens a "body" after `END;` or inside a quote,
    which this does see.
    """
    text = _code_text(raw)
    misplaced = []
    for start, _ in _dollar_quoted_spans(raw):
        end = start
        while end and text[end - 1].isspace():
            end -= 1
        m = re.search(r"\w+$", text[max(0, end - 64):end])
        word = m.group(0) if m else ""
        if word.upper() not in _DOLLAR_STRING_OPENERS:
            misplaced.append(f"line {raw.count(chr(10), 0, start) + 1}: {raw[start:start + 40]!r}")
    return misplaced


def _sql_code(path: Path) -> tuple[str, str]:
    """(raw text, text with comments and function bodies blanked) for an installed file.

    Fails if the lexer ends inside a comment or literal: from that point on it saw no
    code at all, and every check below would pass on what remained.
    """
    raw = path.read_text(encoding="utf-8")
    left_open = _lexed(raw)[1]
    assert left_open is None, (
        f"{path.name}: an unterminated {left_open} -- everything after it is invisible to "
        f"this scanner. Either the file is broken or the lexer here misreads it.")
    return raw, _code_text(raw)


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
        if low == mw:
            return TYPE_ALIASES.get(mw, mw) + suffix

    # A leading identifier is the parameter NAME only if something follows it.
    # A quoted name is still a name. endpoints/endpoint_schema.sql writes
    # `"from_date" TEXT = NULL` throughout, which the unquoted-only pattern left as the
    # non-type `"from_date" text`. (#73 ended up using paren-less DROPs, which carry no
    # argument list at all, so it is the file's existing quoted-parameter style -- not
    # #73 -- that this has to parse.)
    # `$` is legal after an identifier's first character, and "" escapes a quote.
    parts = a.split()
    if len(parts) > 1 and re.fullmatch(r'[a-z_][a-z0-9_$]*|"(?:[^"]|"")*"', parts[0], re.I):
        a = " ".join(parts[1:])
    a = a.strip().lower()
    return TYPE_ALIASES.get(a, a) + suffix


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


def _identifier(name: str) -> str:
    """A possibly-qualified name as PostgreSQL resolves it: unquoted parts fold to lower
    case, quoted parts are kept verbatim. "Assert_Op_Types" and assert_op_types are two
    different functions, so a DROP of one is a silent no-op under IF EXISTS for the other.
    """
    return ".".join(p[1:-1].replace('""', '"') if p.startswith('"') else p.lower()
                    for p in re.findall(r'"(?:[^"]|"")*"|[^."]+', name))


def _signatures(pattern, text: str) -> list[tuple[str, tuple[str, ...] | None, int]]:
    """(name, argument types, offset) per match. Types are None for a DROP without an
    argument list, which drops whichever single overload exists."""
    out = []
    for m in pattern.finditer(text):
        types = None
        if text[m.end() - 1] == "(":
            types = _signature_of(_balanced_args(text, m.end() - 1))
        out.append((_identifier(m.group(1)), types, m.start()))
    return out


def _create_offset(m: re.Match) -> int:
    """Offset of the CREATE keyword in a line-anchored match."""
    return m.start() + len(m.group(0)) - len(m.group(0).lstrip(" \t"))


def _unparsed_function_definitions(raw: str, text: str) -> list[str]:
    """Definitions a loose scan of the RAW file finds that the strict patterns did not
    parse, other than those `text` (aligned with `raw`) has blanked as comment or body."""
    parsed = {_create_offset(m) for p in (CREATE_FN, CREATE_OR_REPLACE_FN)
              for m in p.finditer(text)}
    return [f"line {raw.count(chr(10), 0, m.start()) + 1}: {' '.join(m.group(0).split())}"
            for m in ANY_CREATE_FN.finditer(raw)
            if m.start() not in parsed and not text[m.start()].isspace()]


def _has_stable_signature_marker(raw: str, line_start: int) -> bool:
    for line in reversed(raw[:line_start].split("\n")[:-1]):
        line = line.strip()
        if not line.startswith("--"):
            return False
        if line.startswith(STABLE_SIGNATURE_MARKER):
            return True
    return False


def _function_coverage(raw: str, text: str) -> tuple[int, int, list[str]]:
    """(plain CREATEs, CREATE OR REPLACEs that are covered, the uncovered ones).

    CREATE OR REPLACE succeeds on a re-install only while the signature AND return type
    are unchanged; on the upgrade that changes either, it creates a second overload or
    aborts. So it is covered only by a DROP of the name before it -- any argument list,
    since its job is to clear the stale overload, not the current one -- or by an
    explicit marker saying the signature is stable.
    """
    drops = _signatures(DROP_FN, text)
    plain = _signatures(CREATE_FN, text)
    covered, uncovered = 0, []
    for name, types, pos in _signatures(CREATE_OR_REPLACE_FN, text):
        if any(d[0] == name and d[2] < pos for d in drops) \
                or _has_stable_signature_marker(raw, pos):
            covered += 1
        else:
            uncovered.append(f"{name}({', '.join(types or ())})")
    return len(plain), covered, uncovered


def _unpaired_plain_creates(text: str) -> list[str]:
    """Plain CREATE FUNCTION/PROCEDUREs with no earlier DROP of the same signature."""
    drops = _signatures(DROP_FN, text)
    problems = []
    for name, types, pos in _signatures(CREATE_FN, text):
        # A DROP without an argument list removes the one overload of that name -- and
        # errors loudly if there are several -- so it matches any signature.
        matching = [d for d in drops if d[0] == name and d[1] in (types, None)]
        if not matching:
            got = sorted({d[1] for d in drops if d[0] == name})
            problems.append(
                f"{name}({', '.join(types) or ''}) is never dropped at that signature"
                + (f" (dropped instead: {got})" if got else ""))
        elif not any(d[2] < pos for d in matching):
            problems.append(
                f"{name}({', '.join(types) or ''}) is dropped only AFTER it is created, "
                f"so every install creates it and then destroys it")
    return problems


# Kinds checked by _non_idempotent_objects, with FUNCTION/PROCEDURE checked above.
_OBJECT_KINDS = ("TYPE", "SCHEMA", "TABLE", "INDEX", "VIEW", "MATERIALIZED VIEW",
                 "SEQUENCE", "TRIGGER", "POLICY", "EXTENSION", "DOMAIN", "AGGREGATE",
                 "COLLATION", "RULE", "STATISTICS")
_CHECKED_KINDS = frozenset(_OBJECT_KINDS) | {"FUNCTION", "PROCEDURE"}

# Any statement that starts with CREATE -- at a line start or after a `;`. Used only to
# prove the line-anchored patterns, and the kind list, saw everything.
_ANY_CREATE_STATEMENT = re.compile(
    r"(?i)(?:^|;)\s*(?P<create>CREATE)\s+(?:OR\s+REPLACE\s+)?(?:UNLOGGED\s+|UNIQUE\s+)?"
    r"(?P<kind>MATERIALIZED\s+VIEW|\w+)", re.MULTILINE)


def _object_pattern(kind: str) -> re.Pattern:
    """A CREATE <kind> without IF NOT EXISTS; group 1 is the object name.

    CONCURRENTLY is optional and precedes IF NOT EXISTS; an index may also be UNNAMED
    (CREATE INDEX ON tbl (...)), where PostgreSQL derives the name. The first cut
    captured "CONCURRENTLY" and "ON" as object names.
    """
    return re.compile(
        r"(?i)^[ \t]*CREATE\s+(?:UNLOGGED\s+|UNIQUE\s+)?%s\s+(?:CONCURRENTLY\s+)?"
        r"(?!IF\s+NOT\s+EXISTS)(?!ON\b)(?!CONCURRENTLY\b)([a-z0-9_.\"]+)"
        % kind.replace(" ", r"\s+"), re.MULTILINE)


def _non_idempotent_objects(text: str) -> list[tuple[str, str]]:
    """(kind, name) of every CREATE with neither IF NOT EXISTS nor an earlier DROP.

    No exemption for CREATE TABLE/VIEW ... AS SELECT: nothing rebuilds those. A second
    CREATE TABLE x AS raises 42P07 like any other, and CREATE VIEW has no IF NOT EXISTS
    form at all (CREATE OR REPLACE VIEW is not matched by these patterns).
    """
    problems = []
    for kind in _OBJECT_KINDS:
        for m in _object_pattern(kind).finditer(text):
            name = m.group(1)
            if re.search(r"(?i)DROP\s+%s\s+IF\s+EXISTS\s+%s\b"
                         % (kind.replace(" ", r"\s+"), re.escape(name)), text[:m.start()]):
                continue
            problems.append((kind, name))
    return problems


def _unchecked_creates(text: str) -> list[str]:
    """CREATE statements the line-anchored patterns cannot see, or of a kind they do not
    check. Both used to be skipped silently: `SELECT 1; CREATE TYPE ...` on one line, and
    every CREATE DOMAIN / OPERATOR / CAST."""
    out = []
    for m in _ANY_CREATE_STATEMENT.finditer(text):
        kind = " ".join(m.group("kind").upper().split())
        create = m.start("create")
        anchored = not text[text.rfind("\n", 0, create) + 1:create].strip()
        if kind not in _CHECKED_KINDS:
            out.append(f"CREATE {kind}: not a kind this scanner checks")
        elif not anchored:
            out.append(f"CREATE {kind}: not at the start of a line")
    return out


# Not every object kind has an IF NOT EXISTS form. Offering it for TRIGGER, POLICY,
# VIEW or TYPE prescribes invalid SQL -- the same defect as the DROP UNIQUE INDEX
# message this file used to emit.
_REMEDIES = {
    "TYPE": "CREATE TYPE has no IF NOT EXISTS form: DROP TYPE IF EXISTS it first.",
    "DOMAIN": "CREATE DOMAIN has no IF NOT EXISTS form: DROP DOMAIN IF EXISTS it first.",
    "VIEW": "Use CREATE OR REPLACE VIEW, or DROP VIEW IF EXISTS it first "
            "(there is no CREATE VIEW IF NOT EXISTS).",
    "MATERIALIZED VIEW": "Use CREATE MATERIALIZED VIEW IF NOT EXISTS, or DROP it first.",
    "TRIGGER": "Use CREATE OR REPLACE TRIGGER (PG14+), or DROP TRIGGER IF EXISTS it "
               "first (there is no CREATE TRIGGER IF NOT EXISTS).",
    "POLICY": "DROP POLICY IF EXISTS it first (there is no CREATE POLICY IF NOT EXISTS "
              "and no CREATE OR REPLACE POLICY).",
    "AGGREGATE": "Use CREATE OR REPLACE AGGREGATE, or DROP AGGREGATE IF EXISTS it first.",
    "RULE": "Use CREATE OR REPLACE RULE, or DROP RULE IF EXISTS it first.",
}


def _remedy_for(kind: str) -> str:
    return _REMEDIES.get(kind, f"Use CREATE {kind} IF NOT EXISTS, or DROP it first.")


_INSTALLED = _installed_sql_files()


@pytest.mark.parametrize("path", _INSTALLED, ids=lambda p: p.name)
def test_the_comment_stripper_did_not_swallow_the_file(path: Path) -> None:
    """A stripper that mistakes a literal for a comment opener makes real code invisible,
    and every check below then passes on nothing. _sql_code fails on a construct left
    open at end of file; this catches one that closes far too late. The floor is well
    under the leanest file today (sync_status.sql keeps 14% of its non-blank text)."""
    raw, _ = _sql_code(path)
    kept = len(re.sub(r"\s", "", _strip_comments(raw))) / max(1, len(re.sub(r"\s", "", raw)))
    assert kept >= 0.10, (
        f"{path.name}: only {kept:.0%} of the non-blank text survives comment stripping")


@pytest.mark.parametrize("path", _INSTALLED, ids=lambda p: p.name)
def test_every_blanked_body_is_where_a_body_goes(path: Path) -> None:
    """The canary for the text the checks actually read: every $tag$ string blanked from
    it must open where PostgreSQL takes a body. One that does not means code was blanked
    as a body, and the checks would pass on whatever was left."""
    misplaced = _misplaced_dollar_strings(path.read_text(encoding="utf-8"))
    assert not misplaced, (
        f"{path.name}: $tag$ strings blanked as bodies that do not follow "
        f"{' or '.join(_DOLLAR_STRING_OPENERS)}: {misplaced}. Either the lexer misreads "
        f"the file, or a new place for a dollar string belongs in _DOLLAR_STRING_OPENERS.")


@pytest.mark.parametrize("path", _INSTALLED, ids=lambda p: p.name)
def test_the_parser_recognises_every_function_definition(path: Path) -> None:
    """A definition the patterns miss is not merely unmatched -- it is UNCHECKED, and the
    file then passes with zero findings. This turns every parser blind spot into a loud
    failure instead of a silent pass, which is the single guard the first version most
    needed. The loose scan reads the RAW file, so it does not inherit a stripper failure."""
    raw, text = _sql_code(path)
    unparsed = _unparsed_function_definitions(raw, text)
    assert not unparsed, (
        f"{path.name}: function/procedure definitions found by a loose scan but not "
        f"parsed by the strict patterns, so silently unchecked: {unparsed}. Fix the "
        f"patterns rather than the SQL.")


@pytest.mark.parametrize("path", _INSTALLED, ids=lambda p: p.name)
def test_every_function_definition_is_checked(path: Path) -> None:
    """Every definition is either a plain CREATE (paired by signature below) or a
    CREATE OR REPLACE with a DROP of its name before it or a stable-signature marker.

    Plain CREATEs alone were 5 of 79 definitions: deleting the DROP that clears
    refresh_network_vote_periods' legacy 1-arg overload, or any of the endpoint DROPs
    that clear a stale parameter list, left the suite green.
    """
    raw, text = _sql_code(path)
    plain, covered, uncovered = _function_coverage(raw, text)
    total = len(ANY_CREATE_FN.findall(text))
    assert not uncovered and plain + covered == total, (
        f"{path.name}: {plain} plain + {covered} covered CREATE OR REPLACE != {total} "
        f"definitions. No DROP FUNCTION IF EXISTS of the name before: {uncovered}. "
        f"Add one, or mark a signature that will never change with "
        f"'{STABLE_SIGNATURE_MARKER}' directly above the CREATE.")


@pytest.mark.parametrize("path", _INSTALLED, ids=lambda p: p.name)
def test_every_created_function_is_dropped_with_its_own_signature(path: Path) -> None:
    """A plain CREATE FUNCTION/PROCEDURE needs a DROP for the signature it creates, and
    the DROP must come FIRST.

    Matched on normalised argument TYPES, not on arity: DROP (BOOLEAN,BOOLEAN) followed
    by CREATE (INT,INT) is the #60 bug exactly, and an arity match waves it through.
    """
    problems = _unpaired_plain_creates(_sql_code(path)[1])
    assert not problems, (
        f"{path.name}: not re-runnable -- a second install aborts with 'already exists "
        f"with same argument types': {problems}. Add DROP FUNCTION IF EXISTS for that "
        f"exact signature before the CREATE, or use CREATE OR REPLACE where the return "
        f"type is stable."
    )


def test_the_regression_that_prompted_this_file_is_covered() -> None:
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


def test_the_legacy_vote_periods_overload_is_dropped_by_its_own_signature() -> None:
    """install_app.sh calls refresh_network_vote_periods with ONE argument. The 2-arg
    CREATE OR REPLACE leaves a legacy 1-arg overload in place, and the call is then
    ambiguous. Any DROP of the name satisfies the generic coverage check; only the DROP
    of exactly (DATE), before the CREATE, removes that overload."""
    text = _code_text((ROOT / "db" / "process_content_stats.sql").read_text(encoding="utf-8"))
    name = "haf_stats_app.refresh_network_vote_periods"
    creates = [pos for n, _, pos in _signatures(CREATE_OR_REPLACE_FN, text) if n == name]
    assert creates, f"{name} is no longer created in process_content_stats.sql"
    assert any(n == name and t == ("date",) and pos < creates[0]
               for n, t, pos in _signatures(DROP_FN, text)), (
        f"process_content_stats.sql must DROP FUNCTION IF EXISTS {name}(DATE) before "
        f"creating the 2-arg form, or install_app.sh's 1-arg call is ambiguous")


@pytest.mark.parametrize("path", _INSTALLED, ids=lambda p: p.name)
def test_every_create_statement_is_one_the_scanner_checks(path: Path) -> None:
    """The object-kind counterpart of the function guard: a CREATE the line-anchored
    patterns cannot see, or of a kind they do not check, fails here instead of passing."""
    unchecked = _unchecked_creates(_sql_code(path)[1])
    assert not unchecked, (
        f"{path.name}: {unchecked}. Put each statement on its own line, and teach "
        f"_OBJECT_KINDS (and _REMEDIES, where IF NOT EXISTS does not exist) a new kind.")


@pytest.mark.parametrize("path", _INSTALLED, ids=lambda p: p.name)
def test_other_object_types_are_created_idempotently(path: Path) -> None:
    """CREATE TYPE/TABLE/SCHEMA/INDEX/VIEW/SEQUENCE/TRIGGER/POLICY/EXTENSION/DOMAIN/...

    CREATE TYPE and CREATE DOMAIN have NO `IF NOT EXISTS` form at all, so they *require*
    a preceding DROP -- the highest-risk class, and one the first version did not scan.
    """
    problems = _non_idempotent_objects(_sql_code(path)[1])
    assert not problems, (
        f"{path.name}: a re-install aborts on {[f'{k} {n}' for k, n in problems]}. "
        + " ".join(sorted({_remedy_for(k) for k, _ in problems}))
    )


def _repo_relative(rel: str) -> str:
    base = ROOT / "scripts" if rel.startswith("../") else ROOT
    return (base / rel).resolve().relative_to(ROOT).as_posix()


def test_every_sql_path_the_installer_builds_resolves() -> None:
    """A path the extractor finds but cannot resolve is a file it does not scan -- a
    `${DB_DIR}/x.sql` spelling, say. Only build-time generated files may be absent."""
    unresolved = [rel for rel in _installer_sql_paths(INSTALL_SH.read_text(encoding="utf-8"))
                  if not _resolve_installer_path(rel) and _repo_relative(rel) not in GENERATED_SQL]
    assert not unresolved, (
        f"install_app.sh builds {unresolved}, which this scanner cannot resolve to a file "
        f"and therefore does not check. Extend _resolve_installer_path.")


def test_every_sql_token_in_the_installer_is_accounted_for() -> None:
    """Every `.sql` word in install_app.sh's code is a path the extractor reads, or prose
    named in INSTALLER_PROSE_SQL. A file run through a spelling the extractor does not
    read -- relative to a `cd`, say -- fails here instead of going unscanned."""
    tokens = _unextracted_sql_tokens(INSTALL_SH.read_text(encoding="utf-8"))
    unknown = sorted(set(tokens) - set(INSTALLER_PROSE_SQL))
    assert not unknown, (
        f"install_app.sh names {unknown}, which the extractor does not read as a path, so "
        f"a file run that way is not scanned. Root the path in ${{SCRIPT_DIR}}, or, if it "
        f"is prose, add it to INSTALLER_PROSE_SQL.")
    stale = sorted(set(INSTALLER_PROSE_SQL) - set(tokens))
    assert not stale, f"INSTALLER_PROSE_SQL entries install_app.sh no longer contains: {stale}"


def _on_disk_sql_files(root: Path) -> set[str]:
    """Root-relative .sql files at any depth, outside tests/ and dot-directories."""
    return {p.relative_to(root).as_posix() for p in root.glob("**/*.sql")
            if p.relative_to(root).parts[0] != "tests"
            and not any(part.startswith(".") for part in p.relative_to(root).parts)}


def test_every_sql_file_on_disk_is_installed_or_named_as_not_installed() -> None:
    """The other direction: a file install_app.sh runs in a spelling the extractor misses
    shows up here as on disk but not installed. Recursive, so a file under a new
    directory (sql/, db/sub/) is not outside the comparison."""
    installed = {p.relative_to(ROOT).as_posix() for p in _INSTALLED}
    on_disk = _on_disk_sql_files(ROOT) - set(GENERATED_SQL)
    assert on_disk - installed == set(NOT_INSTALLED), (
        f"on disk but not found in install_app.sh: {sorted(on_disk - installed - set(NOT_INSTALLED))}; "
        f"NOT_INSTALLED entries that are installed or gone: "
        f"{sorted(set(NOT_INSTALLED) - (on_disk - installed))}")


def test_the_installed_file_count_is_pinned() -> None:
    count = len([p for p in _INSTALLED if p.relative_to(ROOT).as_posix() not in GENERATED_SQL])
    assert count == INSTALLED_SQL_FILE_COUNT, (
        f"install_app.sh now yields {count} SQL files, not {INSTALLED_SQL_FILE_COUNT}. If a "
        f"file was added or removed on purpose, update INSTALLED_SQL_FILE_COUNT.")


def test_the_installed_file_list_includes_the_endpoints_schema() -> None:
    """Derived from install_app.sh, so it cannot drift from the installer. The first
    version globbed db/*.sql and therefore never scanned the largest installed file."""
    names = {p.name for p in _INSTALLED}
    assert "endpoint_schema.sql" in names, (
        "endpoints/endpoint_schema.sql is executed by install_app.sh and must be scanned"
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
        # Quoted parameter names -- the style endpoint_schema.sql uses throughout.
        # (Not produced by #73, which used paren-less DROPs.)
        ('"from_date" TEXT = NULL', ("text",)),
        ('"page" INT = 1, "page_size" INT = 20', ("integer", "integer")),
        ('"g" INT', ("integer",)),
        ('"g" CHARACTER VARYING = NULL', ("character varying",)),
        # Multi-word ELEMENT types keep their array-ness. Without these, dropping the
        # suffix from the multi-word branch collapsed DOUBLE PRECISION[] onto
        # DOUBLE PRECISION and passed a DROP PostgreSQL cannot resolve -- #60 again.
        ("DOUBLE PRECISION[]", ("double precision[]",)),
        ("v DOUBLE PRECISION[]", ("double precision[]",)),
        ("TIMESTAMP WITH TIME ZONE[]", ("timestamp with time zone[]",)),
        ("CHARACTER VARYING[]", ("character varying[]",)),
        ("TIME WITH TIME ZONE", ("time with time zone",)),
        ("TIME WITHOUT TIME ZONE", ("time without time zone",)),
        # Argument modes are keywords, and lowercase DDL is legal.
        ("out b text", ()),
        ("variadic parts text[]", ("text[]",)),
        ("inout a integer", ("integer",)),
        # Names the identifier pattern must still recognise as names.
        ('"my""arg" DOUBLE PRECISION', ("double precision",)),
        ("a$b INT", ("integer",)),
    ],
)
def test_the_signature_parser(arglist, expected) -> None:
    assert _signature_of(arglist) == expected


def test_block_comments_are_stripped() -> None:
    """A DROP written as prose inside /* */ must not count as a statement."""
    text = "/* we used to\nDROP FUNCTION IF EXISTS s.f(INT);\nbut no longer */\nSELECT 1;"
    assert "DROP FUNCTION" not in _strip_comments(text)


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT '/* not a comment';\nDROP FUNCTION IF EXISTS s.f;",
        'SELECT 1 AS "-- not a comment";\nDROP FUNCTION IF EXISTS s.f;',
        "SELECT $q$ /* $q$;\nDROP FUNCTION IF EXISTS s.f;",
        "SELECT E'it\\'s /*';\nDROP FUNCTION IF EXISTS s.f;",
        "SELECT 'it''s /*';\nDROP FUNCTION IF EXISTS s.f;",
    ],
)
def test_comment_openers_inside_literals_do_not_hide_code(sql) -> None:
    stripped, left_open = _lex_comments(sql)
    assert left_open is None
    assert len(stripped) == len(sql)
    assert [n for n, _, _ in _signatures(DROP_FN, stripped)] == ["s.f"]


def test_comments_inside_a_function_body_are_stripped_but_a_plain_string_body_is_kept() -> None:
    code = "DO $$ BEGIN -- DROP FUNCTION IF EXISTS s.f;\nEND $$;"
    assert "DROP" not in _strip_comments(code)
    prose = "COMMENT ON TABLE t IS $c$it's -- kept$c$;"
    assert _strip_comments(prose) == prose


@pytest.mark.parametrize("sql,construct", [
    ("SELECT 1; /* never closed\nDROP FUNCTION IF EXISTS s.f;", "block comment"),
    ("SELECT 'never closed;\nDROP FUNCTION IF EXISTS s.f;", "string literal"),
    ("DO $body$ BEGIN END;", "$body$ string"),
])
def test_an_unterminated_construct_is_reported(sql, construct) -> None:
    assert _lex_comments(sql)[1] == construct


@pytest.mark.parametrize("name,expected", [
    ("haf_stats_app.Assert_Op_Types", "haf_stats_app.assert_op_types"),
    ('"haf_stats_app"."Assert_Op_Types"', "haf_stats_app.Assert_Op_Types"),
    ('"haf_stats_app".f', "haf_stats_app.f"),
])
def test_identifiers_fold_case_only_when_unquoted(name, expected) -> None:
    assert _identifier(name) == expected


@pytest.mark.parametrize("sql,problems", [
    # A quoted mixed-case name is a different function from its lower-case spelling.
    ('DROP FUNCTION IF EXISTS s.assert_op_types(BOOLEAN);\n'
     'CREATE FUNCTION s."Assert_Op_Types"(b BOOLEAN) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;',
     1),
    ('DROP FUNCTION IF EXISTS s."Assert_Op_Types"(BOOLEAN);\n'
     'CREATE FUNCTION s."Assert_Op_Types"(b BOOLEAN) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;',
     0),
    # OUT parameters are not part of the signature DROP FUNCTION matches on.
    ("DROP FUNCTION IF EXISTS s.f(integer);\n"
     "CREATE FUNCTION s.f(a integer, OUT b text) AS $$ SELECT 'x' $$ LANGUAGE sql;", 0),
    ("DROP FUNCTION IF EXISTS s.f(integer, text);\n"
     "CREATE FUNCTION s.f(a integer, OUT b text) AS $$ SELECT 'x' $$ LANGUAGE sql;", 1),
    # A DROP without an argument list removes the sole overload, whatever it is.
    ("DROP FUNCTION IF EXISTS s.f;\n"
     "CREATE FUNCTION s.f(a integer) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;", 0),
])
def test_plain_creates_are_paired_by_name_and_signature(sql, problems) -> None:
    assert len(_unpaired_plain_creates(_code_text(sql))) == problems


_COR = "CREATE OR REPLACE FUNCTION s.f(a DATE, b DATE) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;"


@pytest.mark.parametrize("sql,uncovered", [
    (_COR, ["s.f(date, date)"]),
    ("DROP FUNCTION IF EXISTS s.f;\n" + _COR, []),
    # The legacy overload's DROP is what keeps a 1-arg call unambiguous.
    ("DROP FUNCTION IF EXISTS s.f(DATE);\n" + _COR, []),
    (_COR + "\nDROP FUNCTION IF EXISTS s.f;", ["s.f(date, date)"]),
    ("DROP FUNCTION IF EXISTS s.g;\n" + _COR, ["s.f(date, date)"]),
    (STABLE_SIGNATURE_MARKER + " -- signature fixed by an external caller\n" + _COR, []),
    # The marker covers only the definition directly below its comment block.
    (STABLE_SIGNATURE_MARKER + "\nSELECT 1;\n" + _COR, ["s.f(date, date)"]),
    ("/* " + STABLE_SIGNATURE_MARKER[3:] + " */\n" + _COR, ["s.f(date, date)"]),
])
def test_create_or_replace_needs_a_drop_of_its_name_or_a_marker(sql, uncovered) -> None:
    plain, covered, got = _function_coverage(sql, _code_text(sql))
    assert (plain, covered, got) == (0, 1 - len(uncovered), uncovered)


def test_the_function_guard_reads_the_raw_text() -> None:
    raw = "SELECT 1; CREATE FUNCTION s.f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;"
    assert len(_unparsed_function_definitions(raw, _code_text(raw))) == 1
    commented = "-- CREATE FUNCTION s.f() is gone\nSELECT 1;"
    assert _unparsed_function_definitions(commented, _strip_comments(commented)) == []


@pytest.mark.parametrize("sql,name", [
    ("CREATE UNIQUE INDEX foo ON t(a);", "foo"),
    ("CREATE UNIQUE INDEX CONCURRENTLY foo ON t(a);", "foo"),
    ("CREATE INDEX foo ON t(a);", "foo"),
])
def test_the_index_pattern_names_unique_and_concurrent_indexes(sql, name) -> None:
    assert [m.group(1) for m in _object_pattern("INDEX").finditer(sql)] == [name]


@pytest.mark.parametrize("sql,problems", [
    ("CREATE TABLE s.t AS SELECT 1 AS x;", [("TABLE", "s.t")]),
    ("CREATE TABLE IF NOT EXISTS s.t AS SELECT 1 AS x;", []),
    ("DROP TABLE IF EXISTS s.t;\nCREATE TABLE s.t AS WITH a AS (SELECT 1) SELECT * FROM a;", []),
    ("CREATE VIEW s.v AS SELECT 1;", [("VIEW", "s.v")]),
    ("CREATE OR REPLACE VIEW s.v AS SELECT 1;", []),
    ("CREATE MATERIALIZED VIEW s.m AS SELECT 1;", [("MATERIALIZED VIEW", "s.m")]),
    ("CREATE DOMAIN s.d AS int;", [("DOMAIN", "s.d")]),
    ("DROP DOMAIN IF EXISTS s.d;\nCREATE DOMAIN s.d AS int;", []),
    ("CREATE AGGREGATE s.a(int) (SFUNC = int4pl, STYPE = int);", [("AGGREGATE", "s.a")]),
])
def test_object_creation_needs_if_not_exists_or_a_drop(sql, problems) -> None:
    assert _non_idempotent_objects(sql) == problems


@pytest.mark.parametrize("sql,unchecked", [
    ("SELECT 1; CREATE TYPE s.t AS (a int);", ["CREATE TYPE: not at the start of a line"]),
    ("CREATE OPERATOR s.=== (LEFTARG = int, RIGHTARG = int, FUNCTION = int4eq);",
     ["CREATE OPERATOR: not a kind this scanner checks"]),
    ("CREATE CAST (int AS s.d) WITH INOUT;", ["CREATE CAST: not a kind this scanner checks"]),
    ("CREATE TABLE IF NOT EXISTS s.t (a int);\nCREATE OR REPLACE VIEW s.v AS SELECT 1;", []),
    ("GRANT CREATE ON SCHEMA s TO r;", []),
])
def test_every_create_kind_is_one_the_scanner_checks(sql, unchecked) -> None:
    assert _unchecked_creates(sql) == unchecked


@pytest.mark.parametrize("line,path", [
    ('run_sql_file "${SCRIPT_DIR}/../db/a.sql"', "../db/a.sql"),
    ('DB_DIR="${SCRIPT_DIR}/.."; run_sql_file "${DB_DIR}/db/a.sql"', "db/a.sql"),
    ('for f in "${SCRIPT_DIR}"/../db/new_*.sql; do run_sql_file "$f"; done', "../db/new_*.sql"),
    ('run_sql_file "${SCRIPT_DIR}/../db/new-thing.sql"', "../db/new-thing.sql"),
    ('run_sql_file "$(dirname "$0")/../db/a.sql"', "../db/a.sql"),
    ('run_sql_file "$SCRIPT_DIR/../db/a.sql"', "../db/a.sql"),
    ('run_sql_file $SCRIPT_DIR/../sql/a.sql', "../sql/a.sql"),
    ('run_sql_file "${SCRIPT_DIR}/../db/sub/a.sql"', "../db/sub/a.sql"),
    ('run_sql_file "${SCRIPT_DIR}/b.sql"', "b.sql"),
])
def test_the_installer_path_extractor_reads_every_spelling(line, path) -> None:
    assert _installer_sql_paths(line) == [path]


def test_installer_prose_and_comments_are_not_paths() -> None:
    script = ('# run_sql_file "${SCRIPT_DIR}/../db/a.sql"\n'
              'log "see db/haf_stats_app.sql"\n'
              "RAISE NOTICE 'per the db/process_*.sql headers';")
    assert _installer_sql_paths(script) == []


@pytest.mark.parametrize("script", [
    'cd "${SCRIPT_DIR}/.." && run_sql_file db/new.sql',
    'cd "${SCRIPT_DIR}/.." && run_sql_file "sql/new.sql"',
    'pushd scripts; run_sql_file ./new.sql',
])
def test_an_installer_path_relative_to_a_cd_is_not_accounted_for(script: str) -> None:
    assert _installer_sql_paths(script) == []
    assert set(_unextracted_sql_tokens(script)) - set(INSTALLER_PROSE_SQL)


def test_a_trailing_shell_comment_is_not_an_installer_reference() -> None:
    script = INSTALL_SH.read_text(encoding="utf-8")
    at = script.index("\nrun_sql_file") + 1
    at = script.index("\n", at)
    commented = script[:at] + '  # see foo.sql, run_sql_file "${SCRIPT_DIR}/../db/foo.sql"' + script[at:]
    assert _unextracted_sql_tokens(commented) == _unextracted_sql_tokens(script)
    assert _installer_sql_paths(commented) == _installer_sql_paths(script)
    assert _unextracted_sql_tokens('psql_cmd -f "$x"  # see foo.sql') == []


def test_a_hash_inside_a_quoted_string_is_not_a_comment() -> None:
    assert _unextracted_sql_tokens('log "issue #1: see foo.sql"') == ["foo.sql"]
    assert _unextracted_sql_tokens("log 'issue #1: see foo.sql'") == ["foo.sql"]
    assert _unextracted_sql_tokens("log $'issue\\'s #1: see foo.sql'") == ["foo.sql"]


def test_the_on_disk_side_sees_nested_directories(tmp_path: Path) -> None:
    for rel in ("db/a.sql", "db/sub/b.sql", "sql/c.sql", "scripts/d.sql",
                "tests/e.sql", ".aidev/f.sql"):
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_text("SELECT 1;", encoding="utf-8")
    assert _on_disk_sql_files(tmp_path) == {"db/a.sql", "db/sub/b.sql", "sql/c.sql", "scripts/d.sql"}


# --- mutations the checks above must catch -----------------------------------------

_ENDPOINTS = ROOT / "endpoints" / "endpoint_schema.sql"


def _findings(raw: str) -> list[str]:
    """What the per-file checks report for one file's text."""
    text = _code_text(raw)
    return (_unparsed_function_definitions(raw, text) + _function_coverage(raw, text)[2]
            + _unpaired_plain_creates(text) + _misplaced_dollar_strings(raw))


@pytest.mark.parametrize("literal", [
    "SELECT '$$';",
    "COMMENT ON SCHEMA haf_stats_endpoints IS 'price in $$';",
    "SELECT E'it\\'s $$';",
    'SELECT 1 AS "$$";',
])
def test_a_dollar_pair_inside_a_literal_does_not_hide_a_missing_drop(literal: str) -> None:
    """A `$$` inside a literal once paired with the next real function body, blanking
    every definition after it. Deleting a DROP below it must still be reported: the
    first, the one the mutation review deleted, and the last."""
    raw = _ENDPOINTS.read_text(encoding="utf-8")
    assert _findings(raw) == []
    drops = [m.group(0) for m in re.finditer(r"(?m)^DROP FUNCTION IF EXISTS [^;]+;\n", raw)]
    assert len(drops) == len(_signatures(DROP_FN, _code_text(raw)))
    sample = [drops[0], "DROP FUNCTION IF EXISTS haf_stats_endpoints.root;\n", drops[-1]]
    survived = [d.strip() for d in sample
                if not _findings(literal + "\n" + raw.replace(d, "", 1))]
    assert not survived, f"deleting these with {literal!r} on top went unreported: {survived}"


def test_dollar_bodies_with_quotes_and_escape_strings_stay_bodies() -> None:
    sql = ("SELECT E'it\\'s $$ -- not a tag';\n"
           "DROP FUNCTION IF EXISTS s.f;\n"
           "CREATE OR REPLACE FUNCTION s.f() RETURNS text AS $$\n"
           "  SELECT 'it''s' || E'\\'' || '$' || $q$DROP FUNCTION IF EXISTS s.g;$q$;\n"
           "$$ LANGUAGE sql;\n")
    text = _code_text(sql)
    assert [n for n, _, _ in _signatures(DROP_FN, text)] == ["s.f"]
    assert _findings(sql) == []
    assert _findings(sql.replace("DROP FUNCTION IF EXISTS s.f;\n", "")) == ["s.f()"]


def test_a_body_blanked_out_of_place_is_reported() -> None:
    """A dollar string blanked where no body goes -- the shape a body/code swap leaves."""
    assert _misplaced_dollar_strings("SELECT $$x$$;") == ["line 1: '$$x$$;'"]
    assert _misplaced_dollar_strings("COMMENT ON TABLE t IS 'x';\nSELECT $c$x$c$;") == ["line 2: '$c$x$c$;'"]


def test_a_comment_on_text_in_a_dollar_string_is_where_a_body_goes() -> None:
    sql = ("COMMENT ON TABLE t IS $c$text$c$;\n"
           "DROP FUNCTION IF EXISTS s.f;\n"
           "CREATE OR REPLACE FUNCTION s.f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;\n")
    assert _findings(sql) == []
    assert _findings(sql.replace("DROP FUNCTION IF EXISTS s.f;\n", "")) == ["s.f()"]
    assert _misplaced_dollar_strings("DO $$ BEGIN END $$;\nCREATE FUNCTION s.f() RETURNS int "
                                     "AS $b$ SELECT 1 $b$ LANGUAGE sql;") == []
