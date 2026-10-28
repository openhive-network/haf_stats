#!/usr/bin/env python3
"""While hivemind is behind, both block drivers retry the range later, outside a transaction (#123).

Runs in the install lane (docker/docker-compose-ci-install.yml), inside the haf_stats image
against the installed app, so it exercises the SQL that ships and the haf_app_driver.py the
image ships. The stub HAF there streams no blocks, so for the time of this test it gets a
stand-in hive.app_next_iteration. Like HAF's, it claims the next 10 blocks after the haf_stats
context by moving the context (a write), and commits first only when the caller's transaction
has written something; it also counts its calls on a sequence (sequences are not rolled back).
hive.get_current_stage_name is stood in too when the stub lacks it, and so is the
hafd.contexts.loop column the driver reads a stage's alarm threshold from after a range.

The content source is set to hivemind, over empty hivemind_app tables of the shape the source
reads, with hivemind's context partway through the first range -- so a check against the
range's first block instead of its last would let the batch through.

  1. process_blocks (the driver's entry procedure) raises SQLSTATE 55R23 at once.
  2. The shipped driver rolls that range back, reconnects and asks again rather than exiting
     -- and, as a control, exits on an error outside the retried classes, so the code matters.
  3. The legacy CALL main() loop asks for the range again about once a second, sleeping with
     no transaction ID in between (nothing written, no row lock held) and logging the wait
     once. When hivemind reaches the range it logs that processing resumes, processes it and
     commits, then waits again for the next one, and stops on stop_processing().
  4. The shipped driver processes a range hivemind has reached.

Everything it sets up is undone at the end, before the uninstall that follows it; the rows the
processed ranges wrote go with the uninstall.
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

FAKE_ITERATION = """
CREATE PROCEDURE hive.app_next_iteration(
    _contexts hive.contexts_group, _blocks_range OUT hive.blocks_range,
    _override_max_batch INT = NULL, _limit INT = NULL, _wait BOOLEAN = TRUE)
LANGUAGE plpgsql AS $$
DECLARE
    _current INT;
BEGIN
    -- HAF's rule: commit only when the caller's transaction has written something.
    IF pg_current_xact_id_if_assigned() IS NOT NULL THEN
        COMMIT;
    END IF;
    PERFORM nextval('public.ci123_iterations');
    UPDATE hafd.contexts SET current_block_num = current_block_num + 10
    WHERE name = _contexts[1]
    RETURNING current_block_num INTO _current;
    _blocks_range := (_current - 9, _current)::hive.blocks_range;
END;
$$;
CREATE PROCEDURE hive.app_next_iteration(
    _context hafd.context_name, _blocks_range OUT hive.blocks_range,
    _override_max_batch INT = NULL, _limit INT = NULL, _wait BOOLEAN = TRUE)
LANGUAGE plpgsql AS $$
DECLARE
    _current INT;
BEGIN
    IF pg_current_xact_id_if_assigned() IS NOT NULL THEN
        COMMIT;
    END IF;
    PERFORM nextval('public.ci123_iterations');
    UPDATE hafd.contexts SET current_block_num = current_block_num + 10
    WHERE name = _context
    RETURNING current_block_num INTO _current;
    _blocks_range := (_current - 9, _current)::hive.blocks_range;
END;
$$;
"""
FAKE_STAGE = """
CREATE FUNCTION hive.get_current_stage_name(_context hafd.context_name)
RETURNS TEXT LANGUAGE sql AS $$ SELECT 'live'::TEXT $$;
"""
# What haf_app_driver.py reads after each processed range:
# ((loop).current_stage).processing_alarm_threshold. NULL here, so no alarm.
FAKE_LOOP = """
CREATE TYPE public.ci123_stage AS (processing_alarm_threshold INTERVAL);
CREATE TYPE public.ci123_loop AS (current_stage public.ci123_stage);
ALTER TABLE hafd.contexts ADD COLUMN loop public.ci123_loop;
"""
# The columns the hivemind source reads (prepare_batch_creations, hivemind_usable_through).
HIVEMIND_TABLES = {
    "hive_posts": "id BIGINT, author_id INT, permlink_id BIGINT, parent_id BIGINT, depth SMALLINT, "
                  "block_num_created INT, community_id INT",
    "hive_accounts": "id INT, name TEXT",
    "hive_permlink_data": "id BIGINT, permlink TEXT",
    "hive_communities": "id INT, name TEXT",
}

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


def run_driver(module, stop_after_a_range=False):
    """The shipped run() and its real loop()/iterate(); only connect() is replaced, because
    the stub has no application registry to read. By default the second connect -- the
    retry's -- asks the driver to stop, so run() returns once it has reconnected; with
    stop_after_a_range it stops once one range has been processed and committed."""

    class Probe(module.Driver):
        connects = 0
        ranges = 0

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

        def iterate(self):
            blocks = super().iterate()
            if blocks is not None:
                self.ranges += 1
                if stop_after_a_range:
                    self.stop_requested = True
            return blocks

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
    created_loop = False
    created_iteration = False
    created_hivemind_context = False
    created_schema = False
    created_tables: list[str] = []
    saved_sources = None
    saved_continue = None
    position = None
    processed = None
    loop_pid = None
    thread = None

    def context(name):
        return one(cur, "SELECT current_block_num FROM hafd.contexts WHERE name = %s", (name,))

    def last_processed():
        return one(cur, "SELECT MAX(last_processed_block) FROM haf_stats_app.app_status")

    def hivemind_at(block):
        cur.execute("UPDATE hafd.contexts SET current_block_num = %s, irreversible_block = %s "
                    "WHERE name = 'hivemind_app'", (block, block))

    try:
        cur.execute("SELECT source FROM haf_stats_app.content_source_config")
        saved_sources = [r[0] for r in cur.fetchall()]
        saved_continue = one(cur, "SELECT haf_stats_app.continue_processing()")
        position = context("haf_stats")
        processed = last_processed()
        if processed > position:
            raise SystemExit(f"setup: app_status is at {processed}, past the haf_stats context at {position}")
        first, last = position + 1, position + 10
        partway = position + 5
        behind = (f"hivemind has not reached block {last} (usable through {partway}); "
                  f"blocks {first}..{last} are left for a retry")

        cur.execute("CREATE SEQUENCE public.ci123_iterations")
        cur.execute("SELECT nextval('public.ci123_iterations')")  # last_value readable from 1
        # Stand-ins only where the stub has nothing of its own, so the cleanup drops only them.
        if one(cur, "SELECT EXISTS (SELECT 1 FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace "
                    "WHERE n.nspname = 'hive' AND p.proname = 'app_next_iteration')"):
            raise SystemExit("setup: the stub now has hive.app_next_iteration; this test's stand-in would replace it")
        if one(cur, "SELECT EXISTS (SELECT 1 FROM hafd.contexts WHERE name = 'hivemind_app')"):
            raise SystemExit("setup: the stub now has a hivemind_app context; this test would delete it")
        cur.execute(FAKE_ITERATION)
        created_iteration = True
        if one(cur, "SELECT to_regprocedure('hive.get_current_stage_name(hafd.context_name)') IS NULL"):
            cur.execute(FAKE_STAGE)
            created_stage = True
        if not one(cur, "SELECT EXISTS (SELECT 1 FROM information_schema.columns "
                        "WHERE table_schema = 'hafd' AND table_name = 'contexts' AND column_name = 'loop')"):
            cur.execute(FAKE_LOOP)
            created_loop = True
        if one(cur, "SELECT to_regnamespace('hivemind_app') IS NULL"):
            cur.execute("CREATE SCHEMA hivemind_app")
            created_schema = True
        for table, columns in HIVEMIND_TABLES.items():
            if one(cur, "SELECT to_regclass(%s) IS NULL", (f"hivemind_app.{table}",)):
                cur.execute(f"CREATE TABLE hivemind_app.{table} ({columns})")
                created_tables.append(table)
        cur.execute("CREATE INDEX ci123_hive_posts_block_num_created ON hivemind_app.hive_posts (block_num_created)")
        cur.execute("DELETE FROM haf_stats_app.content_source_config")
        cur.execute("INSERT INTO haf_stats_app.content_source_config (source) VALUES ('hivemind')")
        cur.execute(
            "INSERT INTO hafd.contexts (name, current_block_num, irreversible_block) "
            "VALUES ('hivemind_app', %s, %s)", (partway, partway))
        created_hivemind_context = True

        # 1. process_blocks reports hivemind behind at once, as 55R23.
        conn = connect()
        c = conn.cursor()
        c.execute("BEGIN")
        c.execute("SET LOCAL haf_stats.hivemind_wait_timeout = '5'")
        started = time.monotonic()
        error = None
        try:
            c.execute("CALL haf_stats_app.process_blocks(%s::hive.blocks_range)", (f"({first},{last})",))
        except psycopg2.Error as e:
            error = e
        elapsed = time.monotonic() - started
        conn.close()
        check(error is not None and error.pgcode == "55R23" and behind in str(error),
              f"process_blocks raises 55R23 naming the range and hivemind's {partway} "
              f"(got {getattr(error, 'pgcode', None)}: {str(error).strip() if error else 'no error'})")
        check(isinstance(error, psycopg2.OperationalError),
              f"psycopg2 raises 55R23 as OperationalError, a class the driver retries (got {type(error).__name__})")
        check(elapsed < 2, f"process_blocks reported it without waiting ({elapsed:.1f} s)")

        # 2. The shipped driver retries it.
        module = load_driver()
        before = iterations(cur)
        probe, rc, raised, log = run_driver(module)
        print(log, end="")
        check(raised is None and rc == 0,
              f"the driver did not exit on 55R23 (run() returned {rc}, raised {raised!r})")
        check(probe.connects == 2, f"the driver reconnected to retry (connects: {probe.connects})")
        check(f"database connection problem: haf_stats: {behind}" in log,
              "the driver logged the range as left for a retry")
        check(iterations(cur) - before == 1, f"one iteration before the retry ({iterations(cur) - before})")
        check(context("haf_stats") == position, "the driver's retry left the haf_stats context where it was")

        # Control: an error outside the retried classes ends the driver, so the code is what
        # makes the difference. With no hivemind context the check raises P0001.
        cur.execute("DELETE FROM hafd.contexts WHERE name = 'hivemind_app'")
        probe, rc, raised, log = run_driver(module)
        check(isinstance(raised, psycopg2.Error) and getattr(raised, "pgcode", None) == "P0001" and probe.connects == 1,
              f"control: the driver exits on P0001 without a retry (raised {raised!r}, connects {probe.connects})")
        cur.execute(
            "INSERT INTO hafd.contexts (name, current_block_num, irreversible_block) "
            "VALUES ('hivemind_app', %s, %s)", (partway, partway))

        # 3. The legacy loop.
        loop_conn = connect()
        loop_pid = loop_conn.get_backend_pid()
        # As for the driver: a wait inside the batch then ends in an error, not a hung lane.
        loop_conn.cursor().execute("SET haf_stats.hivemind_wait_timeout = '5'")
        loop_error: list[BaseException] = []

        def legacy():
            try:
                loop_conn.cursor().execute("CALL haf_stats_app.main('haf_stats')")
            except BaseException as e:  # noqa: BLE001
                loop_error.append(e)

        before = iterations(cur)
        started = time.monotonic()
        thread = threading.Thread(target=legacy, daemon=True)
        thread.start()
        sleeping, with_xid = 0, 0
        deadline = started + 30
        while time.monotonic() < deadline and iterations(cur) - before < 4 and thread.is_alive():
            cur.execute("SELECT wait_event, backend_xid IS NOT NULL FROM pg_stat_activity WHERE pid = %s", (loop_pid,))
            row = cur.fetchone()
            if row and row[0] == "PgSleep":
                sleeping += 1
                with_xid += int(row[1])
            time.sleep(0.1)
        tries = iterations(cur) - before
        elapsed = time.monotonic() - started
        check(tries >= 4, f"main() asked for the range again while hivemind was behind ({tries} tries in {elapsed:.1f} s)")
        check(tries <= 2 * elapsed + 2, f"main() slept between tries ({tries} tries in {elapsed:.1f} s)")
        check(sleeping > 0 and with_xid == 0,
              f"main() slept between tries with no transaction ID ({sleeping} samples asleep, {with_xid} with one)")
        check(context("haf_stats") == position and last_processed() == processed,
              "main()'s retries left the haf_stats context and app_status where they were")

        # hivemind reaches the range: main() processes and commits it, then waits for the next.
        hivemind_at(last)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and last_processed() != last and thread.is_alive():
            time.sleep(0.2)
        check(last_processed() == last and context("haf_stats") == last,
              f"main() processed {first}..{last} once hivemind reached it "
              f"(app_status {last_processed()}, context {context('haf_stats')}, error {loop_error!r})")

        # Stop it once it is waiting for the next range, so that wait has been logged.
        resumed_at = iterations(cur)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and thread.is_alive():
            cur.execute("SELECT wait_event FROM pg_stat_activity WHERE pid = %s", (loop_pid,))
            row = cur.fetchone()
            if iterations(cur) > resumed_at and row and row[0] == "PgSleep":
                break
            time.sleep(0.1)
        cur.execute("SELECT haf_stats_app.stop_processing()")
        thread.join(15)
        if thread.is_alive():
            check(False, "main() stopped on stop_processing()")
        else:
            check(not loop_error, f"main() returned without an error ({loop_error!r})")
        check(context("haf_stats") == last, "main() left the next range unclaimed when it stopped")
        notices = list(loop_conn.notices)
        waits = [n for n in notices if "waiting for hivemind to reach block" in n]
        resumes = [n for n in notices if f"hivemind has reached block {last}; processing resumes" in n]
        check(len(waits) == 2 and f"block {last} (usable through {partway})" in waits[0],
              f"main() logged each wait once, with hivemind's position ({waits})")
        check(len(resumes) == 1, f"main() logged once that processing resumes ({len(resumes)} times)")
        loop_conn.close()

        # 4. The shipped driver processes a range hivemind has reached.
        hivemind_at(last + 10)
        cur.execute("UPDATE haf_stats_app.app_status SET continue_processing = TRUE")
        probe, rc, raised, log = run_driver(module, stop_after_a_range=True)
        print(log, end="")
        check(raised is None and rc == 0 and probe.connects == 1 and probe.ranges == 1,
              f"the driver processed a range hivemind had reached (rc {rc}, raised {raised!r}, "
              f"connects {probe.connects}, ranges {probe.ranges})")
        check(last_processed() == last + 10 and context("haf_stats") == last + 10,
              f"the driver committed {last + 1}..{last + 10} (app_status {last_processed()}, "
              f"context {context('haf_stats')})")
    finally:
        if thread is not None and thread.is_alive():
            cur.execute("SELECT pg_terminate_backend(%s)", (loop_pid,))
            thread.join(15)
        if created_iteration:
            cur.execute("DROP PROCEDURE hive.app_next_iteration(hive.contexts_group, INT, INT, BOOLEAN)")
            cur.execute("DROP PROCEDURE hive.app_next_iteration(hafd.context_name, INT, INT, BOOLEAN)")
        if created_stage:
            cur.execute("DROP FUNCTION hive.get_current_stage_name(hafd.context_name)")
        cur.execute("DROP SEQUENCE IF EXISTS public.ci123_iterations")
        if created_loop:
            cur.execute("ALTER TABLE hafd.contexts DROP COLUMN loop")
            cur.execute("DROP TYPE public.ci123_loop")
            cur.execute("DROP TYPE public.ci123_stage")
        cur.execute("DROP INDEX IF EXISTS hivemind_app.ci123_hive_posts_block_num_created")
        for table in created_tables:
            cur.execute(f"DROP TABLE hivemind_app.{table}")
        if created_schema:
            cur.execute("DROP SCHEMA hivemind_app")
        if created_hivemind_context:
            cur.execute("DELETE FROM hafd.contexts WHERE name = 'hivemind_app'")
        if position is not None:
            cur.execute("UPDATE hafd.contexts SET current_block_num = %s WHERE name = 'haf_stats'", (position,))
        if processed is not None:
            cur.execute("UPDATE haf_stats_app.app_status SET last_processed_block = %s", (processed,))
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
    print("\n#123: both block drivers retry a range hivemind has not reached, outside a transaction, "
          "and process it once hivemind has", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
