#!/usr/bin/env python3
"""While hivemind is behind, both block drivers retry the range later, outside a transaction (#123).

Runs in the install lane (docker/docker-compose-ci-install.yml), inside the haf_stats image
against the installed app, so it exercises the SQL that ships and the haf_app_driver.py the
image ships. The stub HAF there streams no blocks, so for the time of this test it gets a
stand-in hive.app_next_iteration that hands out blocks 6001..6010 on every call and counts
the calls on a sequence (sequences are not rolled back). Like HAF's, it claims the range by
moving the haf_stats context, which must be back where it was once a retry has rolled it back. hive.get_current_stage_name is stood
in too when the stub lacks it. The content source is set to hivemind, with a hivemind_app
context but no hive_posts index, so hivemind is usable through block 0.

  1. process_blocks (the driver's entry procedure) raises SQLSTATE 55H18 at once.
  2. The shipped driver, given that range, rolls it back, reconnects and asks again rather
     than exiting -- and, as a control, exits on an error outside the retried classes, so
     the code matters.
  3. The legacy CALL main() loop asks for the range again and again, and between tries
     sleeps with no transaction ID (nothing written, no row lock held); it logs the wait
     once, and stops on stop_processing().

Everything it sets up is undone at the end, before the uninstall that follows it.
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import os
import shutil
import sys
import threading
import time

import psycopg2

DSN = "host={} port={} dbname={} user={}".format(
    os.environ.get("POSTGRES_HOST", "postgres"),
    os.environ.get("POSTGRES_PORT", "5432"),
    os.environ.get("POSTGRES_DB", "haf_block_log"),
    os.environ.get("POSTGRES_USER", "postgres"),
)
FIRST, LAST = 6001, 6010
BEHIND = f"hivemind has not reached block {LAST}"

FAKE_ITERATION = f"""
CREATE PROCEDURE hive.app_next_iteration(
    _contexts hive.contexts_group, _blocks_range OUT hive.blocks_range,
    _override_max_batch INT = NULL, _limit INT = NULL, _wait BOOLEAN = TRUE)
LANGUAGE plpgsql AS $$
BEGIN
    -- HAF's rule: commit only when the caller's transaction has written something.
    IF pg_current_xact_id_if_assigned() IS NOT NULL THEN
        COMMIT;
    END IF;
    PERFORM nextval('public.ci123_iterations');
    -- Claims the range as HAF does, by moving the context; a write, so the transaction now
    -- has an ID until it commits or rolls back.
    UPDATE hafd.contexts SET current_block_num = {LAST} WHERE name = ANY(_contexts);
    _blocks_range := ({FIRST}, {LAST})::hive.blocks_range;
END;
$$;
CREATE PROCEDURE hive.app_next_iteration(
    _context hafd.context_name, _blocks_range OUT hive.blocks_range,
    _override_max_batch INT = NULL, _limit INT = NULL, _wait BOOLEAN = TRUE)
LANGUAGE plpgsql AS $$
BEGIN
    IF pg_current_xact_id_if_assigned() IS NOT NULL THEN
        COMMIT;
    END IF;
    PERFORM nextval('public.ci123_iterations');
    UPDATE hafd.contexts SET current_block_num = {LAST} WHERE name = _context;
    _blocks_range := ({FIRST}, {LAST})::hive.blocks_range;
END;
$$;
"""
FAKE_STAGE = """
CREATE FUNCTION hive.get_current_stage_name(_context hafd.context_name)
RETURNS TEXT LANGUAGE sql AS $$ SELECT 'live'::TEXT $$;
"""

failures: list[str] = []


def check(ok: bool, message: str) -> None:
    print(("ok   " if ok else "FAIL ") + message, flush=True)
    if not ok:
        failures.append(message)


def connect():
    conn = psycopg2.connect(DSN)
    conn.autocommit = True
    return conn


def one(cur, sql, args=None):
    cur.execute(sql, args)
    return cur.fetchone()[0]


def iterations(cur) -> int:
    return one(cur, "SELECT last_value FROM public.ci123_iterations")


def load_driver():
    path = shutil.which("haf_app_driver.py")
    if path is None:
        raise SystemExit("haf_app_driver.py is not on PATH in this image")
    spec = importlib.util.spec_from_file_location("haf_app_driver", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def driver_args():
    return argparse.Namespace(
        app="haf_stats", postgres_url=DSN, stop_at_block=None, lock=[], override_max_batch=None,
        poll_interval=1.0, safety_interval=15.0, live_log_interval=60.0, retry_delay=0.2,
        max_retry_delay=1.0, startup_marker="", log_file="", server_messages="INFO",
        process_python=None,
    )


def run_driver(module):
    """The shipped run() and its real loop()/iterate(); only connect() is replaced, because
    the stub has no application registry to read. The second connect -- the retry's --
    asks the driver to stop, so run() returns once it has reconnected."""

    class Probe(module.Driver):
        connects = 0

        def connect(self):
            self.connects += 1
            if self.connects > 1:
                self.stop_requested = True
            self.conn = connect()
            # Bounds a wait inside the batch, so the pre-#123 behaviour fails here instead of
            # hanging the lane.
            self.conn.cursor().execute("SET haf_stats.hivemind_wait_timeout = '5'")
            self.contexts = ["haf_stats"]
            self.lead = "haf_stats"
            self.procedure = "haf_stats_app.process_blocks"

    probe = Probe(driver_args())
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            rc = probe.run()
            raised = None
        except BaseException as e:  # noqa: BLE001 -- what escapes run() is the result
            rc, raised = None, e
    return probe, rc, raised, out.getvalue()


def main() -> int:
    admin = connect()
    cur = admin.cursor()
    created_stage = False
    saved_sources = None
    saved_continue = None
    position = None
    try:
        cur.execute("SELECT source FROM haf_stats_app.content_source_config")
        saved_sources = [r[0] for r in cur.fetchall()]
        saved_continue = one(cur, "SELECT haf_stats_app.continue_processing()")
        position = one(cur, "SELECT current_block_num FROM hafd.contexts WHERE name = 'haf_stats'")
        cur.execute("CREATE SEQUENCE public.ci123_iterations")
        cur.execute("SELECT nextval('public.ci123_iterations')")  # last_value readable from 1
        cur.execute(FAKE_ITERATION)
        if one(cur, "SELECT to_regprocedure('hive.get_current_stage_name(hafd.context_name)') IS NULL"):
            cur.execute(FAKE_STAGE)
            created_stage = True
        cur.execute("DELETE FROM haf_stats_app.content_source_config")
        cur.execute("INSERT INTO haf_stats_app.content_source_config (source) VALUES ('hivemind')")
        cur.execute(
            "INSERT INTO hafd.contexts (name, current_block_num, irreversible_block) "
            "VALUES ('hivemind_app', %s, %s)", (LAST, LAST))

        # 1. process_blocks reports hivemind behind at once, as 55H18.
        conn = connect()
        c = conn.cursor()
        c.execute("BEGIN")
        c.execute("SET LOCAL haf_stats.hivemind_wait_timeout = '5'")
        started = time.monotonic()
        error = None
        try:
            c.execute("CALL haf_stats_app.process_blocks(%s::hive.blocks_range)", (f"({FIRST},{LAST})",))
        except psycopg2.Error as e:
            error = e
        elapsed = time.monotonic() - started
        conn.close()
        check(error is not None and error.pgcode == "55H18" and BEHIND in str(error),
              f"process_blocks raises 55H18 while hivemind is behind (got {getattr(error, 'pgcode', None)}: "
              f"{str(error).strip() if error else 'no error'})")
        check(isinstance(error, psycopg2.OperationalError),
              f"psycopg2 raises 55H18 as OperationalError, a class the driver retries (got {type(error).__name__})")
        check(elapsed < 2, f"process_blocks reported it without waiting ({elapsed:.1f} s)")

        # 2. The shipped driver retries it.
        module = load_driver()
        before = iterations(cur)
        probe, rc, raised, log = run_driver(module)
        print(log, end="")
        check(raised is None and rc == 0,
              f"the driver did not exit on 55H18 (run() returned {rc}, raised {raised!r})")
        check(probe.connects == 2, f"the driver reconnected to retry (connects: {probe.connects})")
        check(f"database connection problem: haf_stats: {BEHIND}" in log,
              "the driver logged the range as left for a retry")
        check(iterations(cur) - before == 1, f"one iteration before the retry ({iterations(cur) - before})")
        check(one(cur, "SELECT current_block_num FROM hafd.contexts WHERE name = 'haf_stats'") == position,
              "the driver's retry left the haf_stats context where it was")

        # Control: an error outside the retried classes ends the driver, so the code is what
        # makes the difference. With no hivemind context the check raises P0001.
        cur.execute("DELETE FROM hafd.contexts WHERE name = 'hivemind_app'")
        probe, rc, raised, log = run_driver(module)
        check(isinstance(raised, psycopg2.Error) and getattr(raised, "pgcode", None) == "P0001" and probe.connects == 1,
              f"control: the driver exits on P0001 without a retry (raised {raised!r}, connects {probe.connects})")
        cur.execute(
            "INSERT INTO hafd.contexts (name, current_block_num, irreversible_block) "
            "VALUES ('hivemind_app', %s, %s)", (LAST, LAST))

        # 3. The legacy loop.
        loop_conn = connect()
        pid = loop_conn.get_backend_pid()
        loop_error: list[BaseException] = []

        def legacy():
            try:
                loop_conn.cursor().execute("CALL haf_stats_app.main('haf_stats')")
            except BaseException as e:  # noqa: BLE001
                loop_error.append(e)

        before = iterations(cur)
        thread = threading.Thread(target=legacy, daemon=True)
        thread.start()
        sleeping, with_xid = 0, 0
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and iterations(cur) - before < 4 and thread.is_alive():
            cur.execute("SELECT wait_event, backend_xid IS NOT NULL FROM pg_stat_activity WHERE pid = %s", (pid,))
            row = cur.fetchone()
            if row and row[0] == "PgSleep":
                sleeping += 1
                with_xid += int(row[1])
            time.sleep(0.1)
        tries = iterations(cur) - before
        check(tries >= 4, f"main() asked for the range again while hivemind was behind ({tries} tries in 30 s)")
        check(sleeping > 0 and with_xid == 0,
              f"main() slept between tries with no transaction ID ({sleeping} samples asleep, {with_xid} with one)")

        cur.execute("SELECT haf_stats_app.stop_processing()")
        thread.join(15)
        if thread.is_alive():
            check(False, "main() stopped on stop_processing()")
            cur.execute("SELECT pg_terminate_backend(%s)", (pid,))
            thread.join(15)
        else:
            check(not loop_error, f"main() returned without an error ({loop_error!r})")
        check(one(cur, "SELECT current_block_num FROM hafd.contexts WHERE name = 'haf_stats'") == position,
              "main()'s retries left the haf_stats context where it was")
        waits = [n for n in loop_conn.notices if f"waiting for hivemind to reach block {LAST}" in n]
        check(len(waits) == 1, f"main() logged the wait once ({len(waits)} times)")
        loop_conn.close()
    finally:
        cur.execute("DROP PROCEDURE IF EXISTS hive.app_next_iteration(hive.contexts_group, INT, INT, BOOLEAN)")
        cur.execute("DROP PROCEDURE IF EXISTS hive.app_next_iteration(hafd.context_name, INT, INT, BOOLEAN)")
        if created_stage:
            cur.execute("DROP FUNCTION hive.get_current_stage_name(hafd.context_name)")
        cur.execute("DROP SEQUENCE IF EXISTS public.ci123_iterations")
        cur.execute("DELETE FROM hafd.contexts WHERE name = 'hivemind_app'")
        if position is not None:
            cur.execute("UPDATE hafd.contexts SET current_block_num = %s WHERE name = 'haf_stats'", (position,))
        if saved_sources is not None:
            cur.execute("DELETE FROM haf_stats_app.content_source_config")
            for source in saved_sources:
                cur.execute("INSERT INTO haf_stats_app.content_source_config (source) VALUES (%s)", (source,))
        if saved_continue is not None:
            cur.execute("UPDATE haf_stats_app.app_status SET continue_processing = %s", (saved_continue,))
        admin.close()

    if failures:
        print(f"\n#123: {len(failures)} check(s) failed", flush=True)
        return 1
    print("\n#123: both block drivers retry a range hivemind has not reached, outside a transaction", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
