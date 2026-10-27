"""Every ALTER TABLE the installer executes must be guarded by a catalog test (#96).

An install replays one-time schema upgrades -- `ADD COLUMN IF NOT EXISTS`, a CHECK constraint
swap -- for deployments that predate them. PostgreSQL takes the table's ACCESS EXCLUSIVE lock
BEFORE it evaluates `IF [NOT] EXISTS`, and install_app.sh sets no lock_timeout, so on a node
where the upgrade already happened the statement still asks for a lock that conflicts with every
SELECT. An install that runs while a slow request or a processor batch holds the table waits --
and every reader arriving afterwards queues behind the waiting ALTER. With #94's 30 s
statement_timeout on haf_stats_user that surfaces as HTTP 500s: #95's failure mode, reached from
a different statement.

db/schema_migration.sql's `apply_schema_migration` takes the catalog test and the DDL, and runs
no DDL at all when the upgrade is already applied. The checks here keep that arrangement intact:

  * no installed file runs an ALTER TABLE outside such a call -- neither as a statement nor as a
    string a DO block EXECUTEs -- and install_app.sh runs none inline;
  * both chains that load db/ files -- install_app.sh and the endpoint-tests stub lane -- load the
    definition before its first caller (getting that wrong made pipeline 179712 red);
  * every call runs before the file tests/ci_lock_holder.sql uses as its "past every migration"
    marker, and that file really gives the marker function a new OID;
  * the tables the guarded DDL names are exactly the tables the holder locks and its healthcheck
    counts, so a migration on a seventh table cannot run unwatched;
  * every guarded upgrade is undone by tests/ci_break_schema.sql and checked by
    tests/ci_install_verify.sql, so its DDL really runs in CI;
  * install-test wires those pieces together with the exact depends_on conditions.

HOW THE SCANNER READS SQL. It masks -- comments, /* */ comments (nesting, as PostgreSQL does),
single-quoted literals (E'' escapes included), double-quoted identifiers and `AS $tag$ ... $tag$`
routine bodies, replacing them with spaces so offsets and line numbers survive. Then it makes two
passes: an ALTER TABLE left in the masked text is a statement the installer runs, and a LITERAL
containing ALTER TABLE must sit inside the parentheses of an apply_schema_migration(...) call --
which is what catches `DO $$ BEGIN EXECUTE 'ALTER TABLE ...'; END $$`.

A top-level `DO $$ ... $$` body is deliberately NOT masked: the installer executes those. A
dollar-quoted string that is not a routine body is read as code too, so DDL inside one is flagged
even when it is guarded -- conservative, and nothing in db/ writes it that way.

WHAT THIS CANNOT DO, stated rather than implied: it reads text. It cannot tell whether a call's
`_needed` argument is the right catalog test. install-test covers that where it is observable:
break-schema + ci_install_verify.sql catch a guard that is wrongly FALSE (its upgrade is not
redone), tests/ci_lock_holder.sql catches one wrongly TRUE on a statement that takes ACCESS
EXCLUSIVE, and tests/ci_install_no_upgrade.sh catches one wrongly TRUE on any statement. Nor does
it read routine bodies: an ALTER TABLE inside a function that the install then CALLS passes here.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.unit.test_compose_contract import _require_yaml
from tests.unit.test_sql_idempotency import INSTALL_SH, ROOT, _installed_sql_files

GUARD = "apply_schema_migration"
DEFINER = "schema_migration.sql"
MARKER_FN = "refresh_top_accounts_alltime"
ALTER = re.compile(r"\bALTER\s+TABLE\b", re.IGNORECASE)
CALL = re.compile(r"\b%s\s*\(" % GUARD)
RUN_SQL = re.compile(r'^\s*run_sql_file(?:_atomic)?\s+"\$\{?SCRIPT_DIR\}?/\.\./([A-Za-z0-9_/]+\.sql)"')
SQL_NAME = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z0-9_]+\.sql)\b")
DOLQ = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")
IDENT = re.compile(r"[A-Za-z0-9_$]")
TABLE = r"[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*"
DDL_TABLE = re.compile(r"^\s*(?:ALTER\s+TABLE|DELETE\s+FROM|DROP\s+TABLE)\s+(%s)\b" % TABLE, re.IGNORECASE)
COMPOSE_INSTALL = ROOT / "docker" / "docker-compose-ci-install.yml"
COMPOSE_STUB = ROOT / "docker" / "docker-compose-ci.yml"
HOLDER = ROOT / "tests" / "ci_lock_holder.sql"
BREAK = ROOT / "tests" / "ci_break_schema.sql"
VERIFY = ROOT / "tests" / "ci_install_verify.sql"
NO_UPGRADE = ROOT / "tests" / "ci_install_no_upgrade.sh"


def _scan(text: str) -> tuple[str, list[tuple[int, int]]]:
    """(text with comments, literals, quoted identifiers and routine bodies blanked out,
    [(start, end) of every single-quoted literal outside a routine body]).

    Blanking keeps length and newlines, so offsets and line numbers still point at the source.
    """
    out = list(text)
    literals: list[tuple[int, int]] = []
    i, n = 0, len(text)

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    def quoted(start: int, quote: str, backslash: bool) -> int:
        j = start + 1
        while j < n:
            if backslash and text[j] == "\\":
                j += 2
                continue
            if text[j] == quote:
                if j + 1 < n and text[j + 1] == quote:   # doubled quote inside
                    j += 2
                    continue
                return j + 1
            j += 1
        return n

    while i < n:
        if text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
            continue
        if text.startswith("/*", i):
            depth, j = 1, i + 2
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
        if text[i] == '"':
            j = quoted(i, '"', False)
            blank(i, j)
            i = j
            continue
        if text[i] == "'":
            # E'...' takes backslash escapes; a plain literal does not.
            escaped = i > 0 and text[i - 1] in "eE" and (i < 2 or not IDENT.match(text[i - 2]))
            j = quoted(i, "'", escaped)
            literals.append((i, j))
            blank(i, j)
            i = j
            continue
        m = DOLQ.match(text, i)
        if m and not (i > 0 and IDENT.match(text[i - 1])):
            tag = m.group(0)
            end = text.find(tag, m.end())
            end = n if end < 0 else end + len(tag)
            # Only a ROUTINE body is masked: `AS $tag$ ... $tag$`. A top-level DO block's body is
            # executed by the installer, so its DDL must stay visible. Read what precedes the tag
            # from the MASKED text, so `AS -- note` + newline + `$$` is still a routine body.
            if re.search(r"\bAS\s*$", "".join(out[max(0, i - 200):i]), re.IGNORECASE):
                blank(i, end)
                i = end
                continue
            i = m.end()
            continue
        i += 1
    return "".join(out), literals


def _mask(text: str) -> str:
    return _scan(text)[0]


def _line(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def _call_spans(masked: str) -> list[tuple[int, int]]:
    """(start, end) of every apply_schema_migration(...) call, parentheses matched on masked text."""
    spans = []
    for m in CALL.finditer(masked):
        depth, j = 0, m.end() - 1
        while j < len(masked):
            if masked[j] == "(":
                depth += 1
            elif masked[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        spans.append((m.start(), j + 1))
    return spans


def _unguarded(text: str) -> list[tuple[int, str]]:
    """(offset, why) of every ALTER TABLE this SQL would run outside apply_schema_migration."""
    masked, literals = _scan(text)
    spans = _call_spans(masked)
    found = [(m.start(), "statement") for m in ALTER.finditer(masked)]
    found += [
        (a, "string outside %s(...)" % GUARD)
        for a, b in literals
        if ALTER.search(text[a:b]) and not any(s <= a and b <= e for s, e in spans)
    ]
    return sorted(found)


def _install_lines() -> list[str]:
    """install_app.sh lines that are not comments -- shell `#` or SQL `--` inside a heredoc."""
    return [
        line for line in INSTALL_SH.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith(("#", "--"))
    ]


def _install_order() -> list[str]:
    """Repo-relative paths (db/x.sql, endpoints/y.sql) in the order install_app.sh runs them.

    _installed_sql_files() returns them SORTED, which says nothing about execution order -- an
    earlier version of the ordering check compared indexes into that sorted list and "passed" only
    because the defining file happened to sort first. Commented-out lines are skipped: they do not
    run, and counting them let a commented-out definer satisfy "defined before its callers".
    """
    order = [m.group(1) for line in _install_lines() for m in [RUN_SQL.match(line)] if m]
    assert order, "no run_sql_file calls found; the install_app.sh parser needs updating"
    return order


def _names(order: list[str]) -> list[str]:
    return [rel.rsplit("/", 1)[-1] for rel in order]


def _executed_files() -> list[Path]:
    """Every .sql file install_app.sh runs, from either parser (neither alone saw every spelling)."""
    paths = {p.resolve() for p in _installed_sql_files()}
    paths |= {(ROOT / rel).resolve() for rel in _install_order() if (ROOT / rel).is_file()}
    return sorted(paths)


def _calls() -> list[tuple[str, int, str, str]]:
    """(file, line, table, DDL) for every apply_schema_migration call in an executed file."""
    calls = []
    for path in _executed_files():
        if path.name == DEFINER:
            continue
        text = path.read_text(encoding="utf-8")
        masked, literals = _scan(text)
        for s, e in _call_spans(masked):
            ddl = [
                text[a + 1:b - 1].replace("''", "'")
                for a, b in literals
                if s <= a and b <= e and DDL_TABLE.match(text[a + 1:b - 1])
            ]
            assert len(ddl) == 1, (
                "%s:%d: cannot tell which table this %s call migrates -- pass its DDL as ONE plain "
                "'ALTER TABLE <schema.table> ...', 'DELETE FROM <schema.table> ...' or "
                "'DROP TABLE <schema.table>' literal"
                % (path.name, _line(text, s), GUARD)
            )
            calls.append((path.name, _line(text, s), DDL_TABLE.match(ddl[0]).group(1).lower(), ddl[0]))
    assert calls, "no %s calls found - every check built on them would be vacuous" % GUARD
    return calls


def _services() -> dict:
    return _require_yaml().safe_load(COMPOSE_INSTALL.read_text(encoding="utf-8"))["services"]


@pytest.mark.parametrize("path", _executed_files(), ids=lambda p: p.name)
def test_every_executed_alter_table_is_lock_guarded(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    found = ["%s:%d (%s)" % (path.name, _line(text, pos), why) for pos, why in _unguarded(text)]
    assert not found, (
        "ALTER TABLE run directly asks for its lock on every install -- ACCESS EXCLUSIVE for most "
        "forms -- and readers queue behind it (#96). Pass it to haf_stats_app.%s with a catalog "
        "test instead:\n  %s" % (GUARD, "\n  ".join(found))
    )


def test_install_app_runs_no_alter_table_inline() -> None:
    inline = [line.strip() for line in _install_lines() if ALTER.search(line)]
    assert not inline, (
        "install_app.sh runs ALTER TABLE inline, where no scan of db/ can see it (#96). Put it in "
        "a db/ file through haf_stats_app.%s:\n  %s" % (GUARD, "\n  ".join(inline))
    )


def test_the_install_order_parser_sees_every_file() -> None:
    """A file loaded in a spelling RUN_SQL does not match would go unscanned and unordered."""
    seen = set(_names(_install_order())) | {p.name for p in _installed_sql_files()}
    missed = sorted({m.group(1) for line in _install_lines() for m in SQL_NAME.finditer(line)} - seen)
    assert not missed, (
        "install_app.sh names %s on a line neither run_sql_file parser matched; teach "
        "RUN_SQL that spelling" % ", ".join(missed)
    )


def test_the_guard_is_defined_before_any_caller_in_install_app() -> None:
    by_name = {p.name: p for p in _executed_files()}
    order = _names(_install_order())
    assert DEFINER in order, "%s is not run by install_app.sh" % DEFINER
    callers = [
        n for n in order
        if n in by_name and n != DEFINER and CALL.search(_mask(by_name[n].read_text(encoding="utf-8")))
    ]
    assert callers, "nothing calls haf_stats_app.%s - this check would be vacuous" % GUARD
    assert order.index(DEFINER) < order.index(callers[0]), (
        "install_app.sh runs %s (position %d) after its first caller %s (position %d)"
        % (DEFINER, order.index(DEFINER), callers[0], order.index(callers[0]))
    )


def test_the_stub_lane_loads_the_guard_before_its_callers() -> None:
    """The endpoint-tests lane psql's db/ files directly, without db/haf_stats_app.sql.

    Leaving the definition out of that chain fails it with `function haf_stats_app.
    apply_schema_migration(boolean, unknown, unknown) does not exist` -- how pipeline 179712 went red.
    """
    stub = _require_yaml().safe_load(COMPOSE_STUB.read_text(encoding="utf-8"))["services"]["setup"]
    command = stub["command"] if isinstance(stub["command"], str) else " ".join(stub["command"])
    loaded = re.findall(r"-f /([A-Za-z0-9_]+\.sql)", command)
    assert DEFINER in loaded, "%s is not loaded by the stub lane's setup service" % DEFINER
    callers = [
        n for n in loaded
        if n != DEFINER and (ROOT / "db" / n).is_file()
        and CALL.search(_mask((ROOT / "db" / n).read_text(encoding="utf-8")))
    ]
    assert callers, "the stub lane loads no caller of %s - this check would be vacuous" % GUARD
    assert loaded.index(DEFINER) < min(loaded.index(n) for n in callers), (
        "the stub lane loads %s after its first caller" % DEFINER
    )


def test_every_guarded_call_runs_before_the_lock_holders_marker() -> None:
    """tests/ci_lock_holder.sql stops watching when refresh_top_accounts_alltime() gets a new OID.

    That only means "past every migration" if the file that re-creates the function runs after
    every caller, and DROPs it first (CREATE OR REPLACE alone keeps the OID, and the holder would
    then fail at its deadline).
    """
    holder = HOLDER.read_text(encoding="utf-8")
    assert re.findall(r"p\.proname = '([a-z_]+)'", holder) == [MARKER_FN, MARKER_FN], (
        "ci_lock_holder.sql must read the marker %s() both before the LOCK and in its loop" % MARKER_FN
    )
    drop = re.compile(r"^DROP FUNCTION IF EXISTS haf_stats_app\.%s\b" % MARKER_FN, re.MULTILINE)
    create = re.compile(r"^CREATE (?:OR REPLACE )?FUNCTION haf_stats_app\.%s\s*\(" % MARKER_FN, re.MULTILINE)
    definers = [
        p.name for p in _executed_files()
        if drop.search(_mask(p.read_text(encoding="utf-8")))
        and create.search(_mask(p.read_text(encoding="utf-8")))
    ]
    assert len(definers) == 1, (
        "exactly one installed file must DROP and then CREATE haf_stats_app.%s at top level, "
        "found %s" % (MARKER_FN, definers or "none")
    )
    order = _names(_install_order())
    marker_at = order.index(definers[0])
    late = sorted({f for f, _, _, _ in _calls() if order.index(f) >= marker_at})
    assert not late, (
        "%s runs at or after %s, which re-creates the lock holder's marker, so the holder would "
        "stop watching before these migrations run" % (", ".join(late), definers[0])
    )


def test_the_lock_holder_watches_every_table_the_guarded_ddl_names() -> None:
    migrated = {table for _, _, table, _ in _calls()}

    locks = re.findall(r"\bLOCK\s+TABLE\s+([^;]*?)\s+IN\s+(\w+(?:\s+\w+)?)\s+MODE", _mask(HOLDER.read_text(encoding="utf-8")),
                       re.IGNORECASE)
    assert len(locks) == 1, "ci_lock_holder.sql must take exactly one LOCK TABLE, found %d" % len(locks)
    tables, mode = locks[0]
    assert mode.upper().split() == ["ACCESS", "SHARE"], (
        "the holder must hold what a reader holds (ACCESS SHARE), not %s: a stronger mode blocks "
        "the install's own CREATE INDEX and changes what it observes" % mode
    )
    locked = {t.strip().lower() for t in tables.split(",")}
    assert locked == migrated, (
        "ci_lock_holder.sql locks %s but the guarded DDL migrates %s"
        % (sorted(locked), sorted(migrated))
    )

    test = _services()["lock-holder"]["healthcheck"]["test"]
    test = test if isinstance(test, str) else " ".join(test)
    counted = {t.lower() for t in re.findall(r"'(%s)'::regclass" % TABLE, test, re.IGNORECASE)}
    wanted = re.findall(r"COUNT\(DISTINCT relation\) = (\d+)", test, re.IGNORECASE)
    assert counted == migrated and wanted == [str(len(migrated))], (
        "the lock-holder healthcheck must wait for ACCESS SHARE on exactly the %d migrated tables "
        "%s; it names %s and waits for %s" % (len(migrated), sorted(migrated), sorted(counted), wanted)
    )


def test_break_schema_and_verify_exercise_every_guarded_upgrade() -> None:
    """Without break-schema only comment_registry.community's DDL ever ran in CI. Keep it that way
    for every NEW upgrade too: each has to be undone before install-again and checked after it."""
    broken = re.sub(r"\s+", " ", _mask(BREAK.read_text(encoding="utf-8")))
    break_raw = re.sub(r"\s+", " ", BREAK.read_text(encoding="utf-8"))
    verify_raw = re.sub(r"\s+", " ", VERIFY.read_text(encoding="utf-8"))
    gaps = []
    for f, line, table, ddl in _calls():
        where = "%s:%d" % (f, line)
        add = re.search(r"\bADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+(\w+)", ddl, re.IGNORECASE)
        drop = re.search(r"\bDROP\s+COLUMN\s+IF\s+EXISTS\s+(\w+)", ddl, re.IGNORECASE)
        con = re.search(r"\b(?:ADD|DROP|VALIDATE)\s+CONSTRAINT\s+(?:IF\s+EXISTS\s+)?(\w+)", ddl, re.IGNORECASE)
        rename = re.search(r"\bRENAME\s+COLUMN\s+(\w+)\s+TO\s+(\w+)", ddl, re.IGNORECASE)
        if add or drop:
            col = (add or drop).group(1)
            undo = "DROP" if add else "ADD"
            if not re.search(r"ALTER TABLE %s\b[^;]*\b%s COLUMN %s\b" % (re.escape(table), undo, col), broken, re.I):
                gaps.append("%s: ci_break_schema.sql does not %s COLUMN %s on %s" % (where, undo, col, table))
            for name, text, present in (("ci_break_schema.sql", break_raw, not add),
                                        ("ci_install_verify.sql", verify_raw, bool(add))):
                row = "('%s', '%s', %s)" % (table, col, "TRUE" if present else "FALSE")
                if row not in text:
                    gaps.append("%s: %s does not check %s" % (where, name, row))
        elif con:
            name = con.group(1)
            for verb in ("DROP", "ADD"):
                if not re.search(r"\b%s CONSTRAINT %s\b" % (verb, name), broken, re.I):
                    gaps.append("%s: ci_break_schema.sql does not %s CONSTRAINT %s" % (where, verb, name))
            if name not in verify_raw:
                gaps.append("%s: ci_install_verify.sql does not check %s" % (where, name))
        elif re.match(r"\s*DROP\s+TABLE\b", ddl, re.IGNORECASE):
            # A table replaced by a new shape: break-schema must put the old shape back, and
            # verify must look at the table the install recreated.
            if not re.search(r"\bCREATE TABLE %s\b" % re.escape(table), broken, re.I):
                gaps.append("%s: ci_break_schema.sql does not re-create %s in the shape the DROP replaces"
                            % (where, table))
            if table not in verify_raw:
                gaps.append("%s: ci_install_verify.sql does not check %s" % (where, table))
        elif rename:
            # A column rewritten in place under a new name (ALTER COLUMN ... TYPE ... USING, then
            # RENAME): break-schema must put the table back in the old shape, and both files must
            # check that the old column is there before and the new one after.
            old, new = rename.groups()
            if not re.search(r"\bCREATE TABLE %s\b[^;]*\b%s\b" % (re.escape(table), old), broken, re.I):
                gaps.append("%s: ci_break_schema.sql does not re-create %s with its old column %s"
                            % (where, table, old))
            for name, text, col, present in (("ci_break_schema.sql", break_raw, old, True),
                                             ("ci_break_schema.sql", break_raw, new, False),
                                             ("ci_install_verify.sql", verify_raw, new, True),
                                             ("ci_install_verify.sql", verify_raw, old, False)):
                row = "('%s', '%s', %s)" % (table, col, "TRUE" if present else "FALSE")
                if row not in text:
                    gaps.append("%s: %s does not check %s" % (where, name, row))
        elif ddl.lstrip().upper().startswith("DELETE"):
            if not re.search(r"\bINSERT INTO %s\b" % re.escape(table), broken, re.I):
                gaps.append("%s: ci_break_schema.sql writes no row for the DELETE on %s to remove" % (where, table))
        else:
            gaps.append("%s: a kind of upgrade this test does not know; teach it, and break-schema" % where)
    assert not gaps, "\n  ".join(["guarded upgrades CI never runs:"] + gaps)


def test_install_test_wires_the_runtime_checks() -> None:
    """Parsed, not grepped: a comment saying `lock-holder:` satisfied the grep version, and a
    `service_started` condition in place of `service_completed_successfully` let the holder's
    verdict gate nothing."""
    svc = _services()

    def deps(name: str) -> dict:
        d = svc[name].get("depends_on")
        assert isinstance(d, dict), "%s: depends_on must be the mapping form with conditions" % name
        return {k: v.get("condition") for k, v in d.items()}

    done = "service_completed_successfully"
    assert deps("break-schema") == {"seed-repair": done}
    assert deps("install-again") == {"break-schema": done}, "install-again must run AFTER break-schema"
    assert deps("lock-holder") == {"install-again": done}
    assert deps("install-under-lock") == {"lock-holder": "service_healthy"}, (
        "install-under-lock must start only once the holder's locks are HELD"
    )
    assert deps("verify") == {"install-under-lock": done, "lock-holder": done}, (
        "verify must wait for the install under lock AND for the holder's verdict (its exit code)"
    )

    for service, script in (("break-schema", "ci_break_schema.sql"), ("lock-holder", "ci_lock_holder.sql")):
        command = " ".join(svc[service]["command"]) if isinstance(svc[service]["command"], list) else svc[service]["command"]
        assert "-f /%s" % script in command, "%s does not run %s" % (service, script)
        assert "../tests/%s:/%s:ro" % (script, script) in svc[service].get("volumes", []), (
            "%s does not mount %s" % (service, script)
        )
    assert svc["install-under-lock"]["command"] == ["bash", "/ci_install_no_upgrade.sh"]
    assert "../tests/ci_install_no_upgrade.sh:/ci_install_no_upgrade.sh:ro" in svc["install-under-lock"]["volumes"]


def test_the_no_upgrade_check_greps_for_what_the_helper_prints() -> None:
    script = NO_UPGRADE.read_text(encoding="utf-8")
    grepped = re.findall(r"grep -F '([^']+)' \"\$log\"", script)
    assert len(grepped) == 1, "ci_install_no_upgrade.sh must grep its install log for the helper's prefix"
    assert "/app/docker_entrypoint.sh install_app" in script and "PIPESTATUS[0]" in script, (
        "ci_install_no_upgrade.sh must run the real install_app verb and keep its exit code"
    )
    notices = re.findall(r"RAISE NOTICE '([^']*)'", (ROOT / "db" / DEFINER).read_text(encoding="utf-8"))
    assert len(notices) == 2 and all(n.startswith(grepped[0]) for n in notices), (
        "every NOTICE apply_schema_migration prints when it runs or waits for DDL must start with "
        "%r, or install-under-lock stops seeing it: %s" % (grepped[0], notices)
    )


def test_the_scanner_reads_sql_the_way_psql_does() -> None:
    """Each case below was a wrong verdict in an earlier version of this file."""
    def flagged(sql: str) -> bool:
        return bool(_unguarded(sql))

    guarded = (
        "SELECT haf_stats_app.apply_schema_migration(\n"
        "    NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attname = 'x'),\n"
        "    'ALTER TABLE t.u ADD COLUMN IF NOT EXISTS x INT',\n"
        "    't.x'\n"
        ");\n"
    )
    assert not flagged(guarded)

    # a bare statement is flagged
    assert flagged(guarded + "ALTER TABLE t ADD COLUMN IF NOT EXISTS y INT;\n")

    # ... and so is the same DDL EXECUTEd from a string in a DO block (it passed before)
    assert flagged("DO $$ BEGIN EXECUTE 'ALTER TABLE t ADD COLUMN IF NOT EXISTS y INT'; END $$;\n")

    # a parenthesis inside a literal must not confuse anything (it broke the paren scanner)
    assert not flagged(guarded.replace("attname = 'x'", "def LIKE '%CHECK (direction%'"))

    # an E'' literal's \' does not end it, so it cannot knock the masker out of step
    assert flagged("SELECT E'it\\'s';\nALTER TABLE t ADD COLUMN y INT;\nSELECT 'x';\n")
    # ... and neither can a quote inside a quoted identifier
    assert flagged('SELECT 1 AS "it\'s";\nALTER TABLE t ADD COLUMN y INT;\nSELECT \'x\';\n')

    # a /* inside a dollar-quoted body must not blind the rest of the file
    assert flagged(
        "CREATE FUNCTION f() RETURNS TEXT LANGUAGE sql AS $b$ SELECT 'a /* b'::TEXT $b$;\n"
        "ALTER TABLE t ADD COLUMN IF NOT EXISTS zz INT;\n"
    ), "a /* inside a routine body hid a real statement"

    # an ALTER inside a routine body is NOT executed at load time -- also when a comment sits
    # between AS and the body (that was flagged: `before` was read from the unmasked text)
    assert not flagged("CREATE FUNCTION g() RETURNS VOID LANGUAGE plpgsql AS $$ BEGIN ALTER TABLE t ADD COLUMN q INT; END $$;\n")
    assert not flagged("CREATE FUNCTION g() RETURNS VOID LANGUAGE plpgsql AS -- note\n$$ BEGIN ALTER TABLE t ADD COLUMN q INT; END $$;\n")

    # ... but a top-level DO block's body IS
    assert flagged("DO $$ BEGIN ALTER TABLE t ADD COLUMN q INT; END $$;\n"), "DO block DDL must stay visible"

    # comments never hide or create a finding
    assert not flagged("-- ALTER TABLE t ADD COLUMN x INT;\n")
    assert not flagged("/* ALTER TABLE t /* nested */ ADD COLUMN x INT; */\n")
