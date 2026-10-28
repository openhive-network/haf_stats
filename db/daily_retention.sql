SET ROLE haf_stats_owner;

-- Retention of the per-account daily rows (issue #124).
--
-- active_users_daily and account_custom_json_daily hold one row per account per day (per class,
-- per custom_json id). Since the custom_json bots of late 2021 that is several hundred thousand
-- rows a day in each, and nothing the API serves needs them at day grain for long:
--   * every DAU/WAU/MAU figure comes from active_users_period_counts, and transaction_count's
--     whole months from active_users_account_monthly; only the partial-month edge days of a
--     transaction_count range read active_users_daily;
--   * the footprint endpoints read account_custom_json_daily for one account at a time.
-- So both keep their rows only for a recent window, app_config.daily_retention_days (default 35).
-- Everything before it is final in the rollups and is deleted from active_users_daily; for
-- custom_json it is kept at month grain in account_custom_json_monthly, with the RC each day was
-- priced at when it was rolled up.
--
-- The window ends at a month start: the first day kept is DATE_TRUNC('month', d - N) for the day
-- d a batch's rollup refresh starts from, so between N and N + 31 days are kept, the month in
-- progress always among them, and a month is either all daily or all monthly. That first day is
-- recorded per table in daily_retention_floor; the refreshes never restate a period that starts
-- before it (process_active_users.sql), and the endpoints read the monthly rows before it.
--
-- A day leaves the window only once everything derived from it is final:
--   * its active_users_period_counts day/week/month rows and its active_users_account_monthly
--     month. They are refreshed up to the day a batch's refresh starts from, and N >= 7 keeps the
--     week of that day, as well as its month, inside the window. During massive sync the refreshes
--     are deferred (defer_rollup_refresh, db/deferred_rollup_refreshes.sql) and recorded from the first
--     batch's day; then the periods before the new first day are restated here, once, and the
--     record moves up to it - as prune_content_presence (db/process_content_stats.sql) does for
--     the content presence sets;
--   * for custom_json, its rc_exact. The processor sets it for every op its transaction recorded
--     an RC for. A day whose network_custom_json_daily rows are not all exact while its blocks do
--     record RC (rows built before the column, or by a range too big to split) is first filled by
--     haf_stats_app.backfill_rc_exact (db/exact_rc.sql); what that leaves NULL stays NULL.
--
-- So a refresh from genesis (refresh_active_users_periods(<genesis>, NULL)) restates only from the
-- first kept day: the rollups are the only record of the periods before it.

-- ---------------------------------------------------------------------------
-- Configuration and state
-- ---------------------------------------------------------------------------

-- At least 7, so the week a refresh starts in is never partly pruned (see above). Guarded: no
-- ACCESS EXCLUSIVE lock on a node that already has this column (#96).
SELECT haf_stats_app.apply_schema_migration(
    NOT EXISTS (
        SELECT 1
        FROM pg_attribute AS a
        WHERE
            a.attrelid = 'haf_stats_app.app_config'::REGCLASS
            AND a.attname = 'daily_retention_days'
            AND NOT a.attisdropped
    ),
    'ALTER TABLE haf_stats_app.app_config
     ADD COLUMN IF NOT EXISTS daily_retention_days INT NOT NULL DEFAULT 35 CHECK (daily_retention_days >= 7)',
    'app_config.daily_retention_days'
);

-- The first day each daily table still holds, a month start. Days before it are final in the
-- rollups and absent from the table. No row: nothing pruned yet.
CREATE TABLE IF NOT EXISTS haf_stats_app.daily_retention_floor (
    daily_table TEXT PRIMARY KEY,
    kept_from DATE NOT NULL
);

-- The endpoints read it to know which ranges the daily rows still cover.
GRANT SELECT ON haf_stats_app.daily_retention_floor TO haf_stats_user;

-- The first day to keep when everything up to _day is processed; NULL for a NULL _day.
DROP FUNCTION IF EXISTS haf_stats_app.daily_retention_keep_from;
CREATE OR REPLACE FUNCTION haf_stats_app.daily_retention_keep_from(_day DATE)
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
    SELECT DATE_TRUNC('month', _day - c.daily_retention_days)::DATE
    FROM haf_stats_app.app_config AS c
$$;

DROP FUNCTION IF EXISTS haf_stats_app.set_daily_retention_floor;
CREATE OR REPLACE FUNCTION haf_stats_app.set_daily_retention_floor(_daily_table TEXT, _kept_from DATE)
RETURNS VOID
LANGUAGE sql
VOLATILE
AS $$
    INSERT INTO haf_stats_app.daily_retention_floor AS f (daily_table, kept_from)
    VALUES (_daily_table, _kept_from)
    ON CONFLICT (daily_table) DO UPDATE SET kept_from = EXCLUDED.kept_from
$$;

-- ---------------------------------------------------------------------------
-- active_users_daily
-- ---------------------------------------------------------------------------

-- Restates the active-user rollups a deferred refresh still owes for the days before _keep, and
-- moves the record up to _keep. A no-op when nothing is deferred from before _keep.
DROP FUNCTION IF EXISTS haf_stats_app.finalize_active_users_before;
CREATE OR REPLACE FUNCTION haf_stats_app.finalize_active_users_before(_keep DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _deferred DATE := (
        SELECT d.dirty_from FROM haf_stats_app.deferred_rollup_refreshes AS d
        WHERE d.processor = 'process_active_users'
    );
BEGIN
    IF _deferred IS NULL OR _deferred >= _keep THEN
        RETURN;
    END IF;
    PERFORM haf_stats_app.refresh_active_users_periods(_deferred, _keep - 1);
    PERFORM haf_stats_app.refresh_active_users_account_monthly(_deferred, _keep - 1);
    UPDATE haf_stats_app.deferred_rollup_refreshes SET dirty_from = _keep
    WHERE processor = 'process_active_users';
END;
$$;

-- Deletes active_users_daily's rows before _keep, once its rollups are final for them.
DROP FUNCTION IF EXISTS haf_stats_app.prune_active_users_daily;
CREATE OR REPLACE FUNCTION haf_stats_app.prune_active_users_daily(_keep DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _floor DATE := (
        SELECT f.kept_from FROM haf_stats_app.daily_retention_floor AS f
        WHERE f.daily_table = 'active_users_daily'
    );
    _lo DATE := COALESCE(_floor, '-infinity'::DATE);
BEGIN
    IF _keep IS NULL OR _keep <= _floor THEN
        RETURN;
    END IF;

    PERFORM haf_stats_app.finalize_active_users_before(_keep);

    -- The key leads with op_class, so the delete names every class of those days (the op counter
    -- has a row for each class a membership row exists for): one range scan per class over just
    -- the deleted days, instead of a scan of the whole table.
    DELETE FROM haf_stats_backend.active_users_daily AS au
    WHERE au.op_class = ANY (ARRAY(
            SELECT DISTINCT o.op_class FROM haf_stats_backend.active_user_ops_daily AS o
            WHERE o.day >= _lo AND o.day < _keep))
      AND au.day >= _lo
      AND au.day < _keep;

    PERFORM haf_stats_app.set_daily_retention_floor('active_users_daily', _keep);
END;
$$;

-- ---------------------------------------------------------------------------
-- account_custom_json_daily
-- ---------------------------------------------------------------------------

-- The days in [_from, _to) whose rc_exact a backfill could still fill: a custom_json rollup row
-- of the day is not exact, and the day's blocks record RC. network_custom_json_daily stands in for
-- account_custom_json_daily here, which has no index on day: both are written from the same ops
-- by the same batches, and by backfill_rc_exact together. Empty on a HAF without rc_cost.
DROP FUNCTION IF EXISTS haf_stats_app.custom_json_rc_unsettled_days;
CREATE OR REPLACE FUNCTION haf_stats_app.custom_json_rc_unsettled_days(_from DATE, _to DATE)
RETURNS SETOF DATE
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    _day DATE;
    _first INT;
    _last INT;
BEGIN
    IF NOT haf_stats_app.rc_cost_available() THEN
        RETURN;
    END IF;
    FOR _day IN
        SELECT DISTINCT n.day FROM haf_stats_backend.network_custom_json_daily AS n
        WHERE n.day >= _from AND n.day < _to AND n.rc_exact IS NULL
        ORDER BY n.day
    LOOP
        SELECT r.from_block, r.to_block INTO _first, _last
        FROM haf_stats_app.block_range_for_dates(_day, _day) AS r;
        -- Planned only here, after rc_cost_available(): a HAF without the column never plans it.
        IF EXISTS (
            SELECT 1 FROM hafd.transactions AS t
            WHERE t.block_num BETWEEN _first AND _last AND t.rc_cost IS NOT NULL
        ) THEN
            RETURN NEXT _day;
        END IF;
    END LOOP;
END;
$$;

-- The daily rows leaving account_custom_json_daily, staged per transaction for
-- merge_retired_custom_json below.
DROP FUNCTION IF EXISTS haf_stats_app.stage_retired_custom_json;
CREATE OR REPLACE FUNCTION haf_stats_app.stage_retired_custom_json()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF to_regclass('pg_temp.haf_stats_retired_custom_json') IS NOT NULL THEN
        TRUNCATE haf_stats_retired_custom_json;
        RETURN;
    END IF;
    CREATE TEMP TABLE haf_stats_retired_custom_json (
        account_id INT NOT NULL,
        day DATE NOT NULL,
        custom_json_type_id SMALLINT NOT NULL,
        op_count INT NOT NULL,
        op_bytes BIGINT NOT NULL,
        rc_exact BIGINT
    ) ON COMMIT DROP;
END;
$$;

-- The staged rows into account_custom_json_monthly: each day priced as the endpoints price it (the
-- exact RC where the row has it, else op_count * base_rc + op_bytes * byte_rc at the custom_json
-- rate effective that day), then summed per month. rc stays NUMERIC, so a sum over whole months is
-- the sum the endpoints would take over the days. A month's rows are always staged together (the
-- floor is a month start), so its monthly row is written whole: one already there (from an
-- interrupted upgrade, or from before a rebuild_custom_json.sh replay) is replaced, not added to.
DROP FUNCTION IF EXISTS haf_stats_app.merge_retired_custom_json;
CREATE OR REPLACE FUNCTION haf_stats_app.merge_retired_custom_json()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    WITH day_rate AS MATERIALIZED (
        SELECT d.day, r.base_rc, r.byte_rc
        FROM (SELECT DISTINCT g.day FROM haf_stats_retired_custom_json AS g) AS d
        CROSS JOIN LATERAL haf_stats_app.rc_rate(18::SMALLINT, d.day) AS r
    )
    INSERT INTO haf_stats_backend.account_custom_json_monthly AS m
        (account_id, month, custom_json_type_id, op_count, op_bytes, rc, exact_ops)
    SELECT g.account_id, DATE_TRUNC('month', g.day)::DATE, g.custom_json_type_id,
           SUM(g.op_count), SUM(g.op_bytes),
           SUM(COALESCE(g.rc_exact, g.op_count * r.base_rc + g.op_bytes * r.byte_rc)),
           COALESCE(SUM(g.op_count) FILTER (WHERE g.rc_exact IS NOT NULL), 0)
    FROM haf_stats_retired_custom_json AS g
    JOIN day_rate AS r ON r.day = g.day
    GROUP BY g.account_id, DATE_TRUNC('month', g.day)::DATE, g.custom_json_type_id
    ON CONFLICT (account_id, month, custom_json_type_id) DO UPDATE SET
        op_count = EXCLUDED.op_count,
        op_bytes = EXCLUDED.op_bytes,
        rc = EXCLUDED.rc,
        exact_ops = EXCLUDED.exact_ops;
END;
$$;

-- Moves account_custom_json_daily's rows before _keep into account_custom_json_monthly, once their
-- rc_exact is final.
DROP FUNCTION IF EXISTS haf_stats_app.roll_up_account_custom_json;
CREATE OR REPLACE FUNCTION haf_stats_app.roll_up_account_custom_json(_keep DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _floor DATE := (
        SELECT f.kept_from FROM haf_stats_app.daily_retention_floor AS f
        WHERE f.daily_table = 'account_custom_json_daily'
    );
    _day DATE;
BEGIN
    IF _keep IS NULL OR _keep <= _floor THEN
        RETURN;
    END IF;

    FOR _day IN SELECT u FROM haf_stats_app.custom_json_rc_unsettled_days(COALESCE(_floor, '-infinity'::DATE), _keep) AS u LOOP
        PERFORM haf_stats_app.backfill_rc_exact(_day);
    END LOOP;

    -- No index on day, so this is a scan of the table, which holds at most two months.
    PERFORM haf_stats_app.stage_retired_custom_json();
    WITH gone AS (
        DELETE FROM haf_stats_backend.account_custom_json_daily AS acj
        WHERE acj.day < _keep
        RETURNING acj.account_id, acj.day, acj.custom_json_type_id, acj.op_count, acj.op_bytes, acj.rc_exact
    )
    INSERT INTO haf_stats_retired_custom_json SELECT * FROM gone;
    PERFORM haf_stats_app.merge_retired_custom_json();

    PERFORM haf_stats_app.set_daily_retention_floor('account_custom_json_daily', _keep);
END;
$$;

-- ---------------------------------------------------------------------------
-- Per batch (process_block_range, db/process_block_range.sql)
--
-- On the batches that cross a rollup refresh's 1200-block bucket, and from the day that refresh
-- starts from (process_active_users): everything before it is processed and refreshed, or
-- recorded for a deferred refresh, which the prune restates first. Called after every processor,
-- because the rc_exact backfill restages the batch's temp tables for the day it fills. Returns at
-- once while the window has not moved, which is every call but about one a month.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.process_daily_retention;
CREATE OR REPLACE FUNCTION haf_stats_app.process_daily_retention(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _refresh_lo DATE;
    _keep DATE;
BEGIN
    IF (_last_block / 1200) = ((_first_block - 1) / 1200) THEN
        RETURN;
    END IF;
    SELECT b.created_at::DATE INTO _refresh_lo
    FROM hafd.blocks AS b WHERE b.num = GREATEST(((_first_block - 1) / 1200) * 1200, 1);
    IF _refresh_lo IS NULL THEN
        SELECT b.created_at::DATE INTO _refresh_lo FROM hafd.blocks AS b WHERE b.num = _first_block;
    END IF;

    _keep := haf_stats_app.daily_retention_keep_from(_refresh_lo);
    PERFORM haf_stats_app.prune_active_users_daily(_keep);
    PERFORM haf_stats_app.roll_up_account_custom_json(_keep);
END;
$$;

-- ---------------------------------------------------------------------------
-- Upgrade in place
--
-- A node that ran an earlier version holds the whole history at day grain, active_users_daily
-- keyed (day, op_class, account_id) with the idx_aud_opclass_day index beside it - hundreds of
-- millions of rows on a full node, mid-replay ones with every rollup refresh still deferred. The
-- install converts it in steps that each commit, so an interrupted install resumes where it
-- stopped:
--   1. the active-user rollups owed for the days before the window: a deferred refresh's, or a
--      whole history's where a rollup is empty (what install_app.sh's step 8 would otherwise
--      rebuild from genesis, after the rows are gone), restated a month at a time, the deferred
--      record moved up after each;
--   2. active_users_daily, while still on the old key, copied as its kept rows into a table on
--      (op_class, day, account_id) that replaces it - the reorder, the prune and the index drop in
--      one rewrite of the kept rows only; on the new key, pruned as a batch prunes it;
--   3. for a table not yet pruned: the custom_json days with rc_exact left to fill, one backfill
--      transaction each; the monthly rows, built from the daily ones a range of accounts at a
--      time; then account_custom_json_daily replaced by a copy of its kept rows.
-- Later installs find the floor recorded and only do what a batch would (a no-op until the window
-- moves). The end state is a fresh replay's: the same rows in the same tables and keys.
--
-- _commit FALSE runs it all in the caller's transaction (tests/ci_daily_retention.sql).
-- ---------------------------------------------------------------------------

-- active_users_daily rebuilt on (op_class, day, account_id) with its rows from _keep on (all of them
-- for a NULL _keep). The old table and its idx_aud_opclass_day go with the DROP.
DROP FUNCTION IF EXISTS haf_stats_app.rekey_active_users_daily;
CREATE OR REPLACE FUNCTION haf_stats_app.rekey_active_users_daily(_keep DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    CREATE TABLE haf_stats_backend.active_users_daily_kept (
        day DATE NOT NULL,
        op_class SMALLINT NOT NULL,
        account_id INT NOT NULL,
        ops INT NOT NULL DEFAULT 0,
        PRIMARY KEY (op_class, day, account_id)
    );
    INSERT INTO haf_stats_backend.active_users_daily_kept (day, op_class, account_id, ops)
    SELECT au.day, au.op_class, au.account_id, au.ops
    FROM haf_stats_backend.active_users_daily AS au
    WHERE au.day >= COALESCE(_keep, '-infinity'::DATE)
    ORDER BY au.op_class, au.day, au.account_id;

    PERFORM haf_stats_app.apply_schema_migration(
        TRUE,
        'DROP TABLE haf_stats_backend.active_users_daily;
         ALTER TABLE haf_stats_backend.active_users_daily_kept RENAME TO active_users_daily;
         ALTER INDEX haf_stats_backend.active_users_daily_kept_pkey RENAME TO active_users_daily_pkey',
        'active_users_daily: re-keyed on (op_class, day, account_id), rows before the retention window dropped'
    );
    GRANT SELECT ON haf_stats_backend.active_users_daily TO haf_stats_user;
    IF _keep IS NOT NULL THEN
        PERFORM haf_stats_app.set_daily_retention_floor('active_users_daily', _keep);
    END IF;
END;
$$;

-- The monthly rows of the accounts [_lo_id, _hi_id]'s daily rows before _keep; their count.
DROP FUNCTION IF EXISTS haf_stats_app.roll_up_account_custom_json_accounts;
CREATE OR REPLACE FUNCTION haf_stats_app.roll_up_account_custom_json_accounts(
    _keep DATE,
    _lo_id INT,
    _hi_id INT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    _n BIGINT;
BEGIN
    PERFORM haf_stats_app.stage_retired_custom_json();
    INSERT INTO haf_stats_retired_custom_json
    SELECT acj.account_id, acj.day, acj.custom_json_type_id, acj.op_count, acj.op_bytes, acj.rc_exact
    FROM haf_stats_backend.account_custom_json_daily AS acj
    WHERE acj.account_id BETWEEN _lo_id AND _hi_id
      AND acj.day < _keep;
    GET DIAGNOSTICS _n = ROW_COUNT;
    PERFORM haf_stats_app.merge_retired_custom_json();
    RETURN _n;
END;
$$;

-- account_custom_json_daily replaced by a copy of its rows from _keep on.
DROP FUNCTION IF EXISTS haf_stats_app.prune_account_custom_json_daily_by_copy;
CREATE OR REPLACE FUNCTION haf_stats_app.prune_account_custom_json_daily_by_copy(_keep DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    CREATE TABLE haf_stats_backend.account_custom_json_daily_kept (
        account_id INT NOT NULL,
        day DATE NOT NULL,
        custom_json_type_id SMALLINT NOT NULL,
        op_count INT NOT NULL DEFAULT 0,
        op_bytes BIGINT NOT NULL DEFAULT 0,
        rc_exact BIGINT,
        PRIMARY KEY (account_id, day, custom_json_type_id)
    );
    INSERT INTO haf_stats_backend.account_custom_json_daily_kept
        (account_id, day, custom_json_type_id, op_count, op_bytes, rc_exact)
    SELECT acj.account_id, acj.day, acj.custom_json_type_id, acj.op_count, acj.op_bytes, acj.rc_exact
    FROM haf_stats_backend.account_custom_json_daily AS acj
    WHERE acj.day >= _keep
    ORDER BY acj.account_id, acj.day, acj.custom_json_type_id;

    PERFORM haf_stats_app.apply_schema_migration(
        TRUE,
        'DROP TABLE haf_stats_backend.account_custom_json_daily;
         ALTER TABLE haf_stats_backend.account_custom_json_daily_kept RENAME TO account_custom_json_daily;
         ALTER INDEX haf_stats_backend.account_custom_json_daily_kept_pkey RENAME TO account_custom_json_daily_pkey',
        'account_custom_json_daily: rows before the retention window moved to account_custom_json_monthly'
    );
    GRANT SELECT ON haf_stats_backend.account_custom_json_daily TO haf_stats_user;
    PERFORM haf_stats_app.set_daily_retention_floor('account_custom_json_daily', _keep);
END;
$$;

DROP PROCEDURE IF EXISTS haf_stats_app.upgrade_daily_retention;
CREATE OR REPLACE PROCEDURE haf_stats_app.upgrade_daily_retention(_commit BOOLEAN DEFAULT TRUE)
LANGUAGE plpgsql
AS $$
DECLARE
    _keep DATE := haf_stats_app.daily_retention_keep_from((
        SELECT b.created_at::DATE FROM hafd.blocks AS b
        WHERE b.num = (SELECT MAX(s.last_processed_block) FROM haf_stats_app.app_status AS s)));
    _owed DATE;
    _from DATE;
    _to DATE;
    _day DATE;
    _max_id INT;
    _lo_id INT := 0;
    _rows BIGINT := 0;
    _step CONSTANT INT := 50000;
BEGIN
    -- 1. Nothing is processed yet, or nothing is old enough: no rollup owes anything.
    IF _keep IS NOT NULL
       AND _keep > COALESCE((SELECT f.kept_from FROM haf_stats_app.daily_retention_floor AS f
                             WHERE f.daily_table = 'active_users_daily'), '-infinity'::DATE) THEN
        IF NOT EXISTS (SELECT 1 FROM haf_stats_backend.active_users_period_counts)
           OR NOT EXISTS (SELECT 1 FROM haf_stats_backend.active_users_account_monthly) THEN
            _owed := (SELECT MIN(o.day) FROM haf_stats_backend.active_user_ops_daily AS o);
            -- Recorded as a deferred refresh, so what is left of it after the window's days (from
            -- _keep to the head) runs with the other deferred refreshes, and step 8 of
            -- install_app.sh finds the rollup no longer empty.
            INSERT INTO haf_stats_app.deferred_rollup_refreshes AS d (processor, dirty_from)
            SELECT 'process_active_users', _owed WHERE _owed IS NOT NULL
            ON CONFLICT (processor) DO UPDATE SET dirty_from = EXCLUDED.dirty_from
            WHERE EXCLUDED.dirty_from < d.dirty_from;
        END IF;
        _from := (SELECT d.dirty_from FROM haf_stats_app.deferred_rollup_refreshes AS d
                  WHERE d.processor = 'process_active_users');
        WHILE _from < _keep LOOP
            _to := LEAST((DATE_TRUNC('month', _from) + INTERVAL '1 month' - INTERVAL '1 day')::DATE, _keep - 1);
            PERFORM haf_stats_app.finalize_active_users_before(_to + 1);
            RAISE NOTICE 'haf_stats: active-user rollups final through %', _to;
            IF _commit THEN COMMIT; END IF;
            _from := _to + 1;
        END LOOP;
    END IF;

    -- 2.
    IF (SELECT pg_get_constraintdef(c.oid) FROM pg_constraint AS c
        WHERE c.conrelid = 'haf_stats_backend.active_users_daily'::REGCLASS AND c.contype = 'p')
       IS DISTINCT FROM 'PRIMARY KEY (op_class, day, account_id)' THEN
        PERFORM haf_stats_app.rekey_active_users_daily(_keep);
    ELSE
        PERFORM haf_stats_app.prune_active_users_daily(_keep);
    END IF;
    IF _commit THEN COMMIT; END IF;

    -- 3.
    IF _keep IS NULL THEN
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM haf_stats_app.daily_retention_floor AS f WHERE f.daily_table = 'account_custom_json_daily') THEN
        PERFORM haf_stats_app.roll_up_account_custom_json(_keep);
        IF _commit THEN COMMIT; END IF;
        RETURN;
    END IF;

    FOR _day IN SELECT u FROM haf_stats_app.custom_json_rc_unsettled_days('-infinity'::DATE, _keep) AS u LOOP
        PERFORM haf_stats_app.backfill_rc_exact(_day);
        RAISE NOTICE 'haf_stats: rc_exact settled for %', _day;
        IF _commit THEN COMMIT; END IF;
    END LOOP;

    _max_id := (SELECT acj.account_id FROM haf_stats_backend.account_custom_json_daily AS acj
                ORDER BY acj.account_id DESC LIMIT 1);
    WHILE _lo_id <= _max_id LOOP
        _rows := _rows + haf_stats_app.roll_up_account_custom_json_accounts(_keep, _lo_id, _lo_id + _step - 1);
        RAISE NOTICE 'haf_stats: account_custom_json_monthly built for accounts below % of %, from % daily rows so far',
            _lo_id + _step, _max_id + 1, _rows;
        IF _commit THEN COMMIT; END IF;
        _lo_id := _lo_id + _step;
    END LOOP;

    IF _rows > 0 THEN
        PERFORM haf_stats_app.prune_account_custom_json_daily_by_copy(_keep);
    ELSE
        PERFORM haf_stats_app.set_daily_retention_floor('account_custom_json_daily', _keep);
    END IF;
    IF _commit THEN COMMIT; END IF;
END;
$$;

-- Top level, so its COMMITs end each step's transaction (install_app.sh loads this file with a
-- plain psql -f).
CALL haf_stats_app.upgrade_daily_retention();

RESET ROLE;
