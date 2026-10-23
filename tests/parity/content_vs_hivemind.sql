-- =============================================================================
-- content_vs_hivemind.sql -- post/comment counts checked against hivemind (#63).
--
-- Two accuracy defects reached production and were found by hand, not by CI:
--   * #42: get_network_content_volume reported posts AND comments at exactly 2.000x for
--     ~2020 through 2025-08 (a non-idempotent backfill upsert);
--   * #45: get_account_content_stats over-reported posts by ~19% over the same era.
-- The CI replay is 2016 history and predates both, so only a check on a real node can
-- see this class. hivemind, where it is co-located in the same database, is an
-- independent oracle: it counts the same creations from its own processing.
--
-- What is compared, both EXACTLY (measured equal on a 1.28.8 node on 2026-10-23: 22 days
-- from 2016-06 to 2026-10 and 200 authors over 30 days, no difference at all):
--   (a) network: haf_stats_backend.network_content_daily posts/comments per day against
--       hivemind_app.hive_posts rows created in that day's blocks (depth = 0 is a post,
--       depth > 0 a comment); the last 14 complete days plus the 15th of every third
--       month back to 2016-06;
--   (b) accounts: account_content_daily summed over the last 30 complete days for up to
--       200 authors who posted on the last complete day, against hivemind's rows for the
--       same author and window (matched by NAME: hivemind's account ids are its own).
-- hive_posts keeps deleted content (counter_deleted) as rows, so both sides count
-- creations; there is no expected gap.
--
-- Only days that BOTH apps have fully processed are compared (the day before the lower of
-- their two context heads), so a node that is still syncing, or a reversible block at the
-- head, does not produce a false alarm.
--
-- READ-ONLY: no writes, no temporary tables, no locks beyond reads. On a 1.28.8 node it
-- takes well under a minute: every hivemind lookup goes through hive_posts'
-- block_num_created or (author_id, created_at) index, with block numbers passed as
-- literals so the planner can use them.
--
-- SKIPS CLEANLY when hivemind_app is absent (CI, standalone haf_stats). If hivemind_app
-- is present but lacks a column used here, it FAILS and names the column: a silent skip
-- would hide exactly the drift this exists to catch.
--
-- Run it on a node:
--   psql -X -v ON_ERROR_STOP=1 -d haf_block_log -f tests/parity/content_vs_hivemind.sql
-- (also guard 8 of scripts/run_verification.sh). To run it on a schedule, e.g. weekly
-- with pg_cron, wrap the DO block in a function -- left to the operator, since a failure
-- needs someone to read it.
-- =============================================================================
\set ON_ERROR_STOP on

DO $guard$
DECLARE
    _missing TEXT;
    _haf_stats_head INT;
    _hivemind_head INT;
    _last_day DATE;
    _day DATE;
    _days DATE[];
    _from INT;
    _to INT;
    _ours_posts BIGINT;
    _ours_comments BIGINT;
    _hm_posts BIGINT;
    _hm_comments BIGINT;
    _bad TEXT[] := ARRAY[]::TEXT[];
    _authors INT[];
    _name TEXT;
    _account_id INT;
    _author_id INT;
    _checked_days INT := 0;
    _checked_accounts INT := 0;
BEGIN
    IF (SELECT count(*) FROM information_schema.tables
        WHERE table_schema = 'hivemind_app' AND table_name IN ('hive_posts', 'hive_accounts')) < 2 THEN
        RAISE NOTICE 'content oracle: hivemind_app not present on this node - skipping.';
        RETURN;
    END IF;

    SELECT string_agg(format('%s.%s', r.t, r.c), ', ' ORDER BY r.t, r.c) INTO _missing
    FROM (VALUES ('hive_posts', 'author_id'), ('hive_posts', 'depth'), ('hive_posts', 'created_at'),
                 ('hive_posts', 'block_num_created'), ('hive_accounts', 'id'), ('hive_accounts', 'name')) AS r(t, c)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns ic
                      WHERE ic.table_schema = 'hivemind_app' AND ic.table_name = r.t AND ic.column_name = r.c);
    IF _missing IS NOT NULL THEN
        RAISE EXCEPTION 'content oracle: hivemind_app is present but lacks %; this check needs updating for its schema', _missing;
    END IF;

    SELECT current_block_num INTO _haf_stats_head FROM hafd.contexts WHERE name = 'haf_stats';
    SELECT current_block_num INTO _hivemind_head FROM hafd.contexts WHERE name = 'hivemind_app';
    IF _haf_stats_head IS NULL OR _hivemind_head IS NULL OR LEAST(_haf_stats_head, _hivemind_head) < 1 THEN
        RAISE NOTICE 'content oracle: a context head is missing (haf_stats %, hivemind %) - skipping.', _haf_stats_head, _hivemind_head;
        RETURN;
    END IF;
    SELECT (b.created_at::DATE - 1) INTO _last_day
    FROM hive.blocks_view b WHERE b.num = LEAST(_haf_stats_head, _hivemind_head);

    -- (a) network, per day -------------------------------------------------------------
    SELECT array_agg(d ORDER BY d) INTO _days FROM (
        SELECT generate_series(_last_day - 13, _last_day, INTERVAL '1 day')::DATE AS d
        UNION
        SELECT m::DATE + 14 FROM generate_series(DATE '2016-06-01', _last_day - 14, INTERVAL '3 months') AS m
    ) AS s;

    FOREACH _day IN ARRAY _days LOOP
        SELECT b.from_block, b.to_block INTO _from, _to FROM haf_stats_app.block_range_for_dates(_day, _day) AS b;
        CONTINUE WHEN _from IS NULL;
        SELECT COALESCE(n.posts, 0), COALESCE(n.comments, 0) INTO _ours_posts, _ours_comments
        FROM (SELECT 1) AS one LEFT JOIN haf_stats_backend.network_content_daily n ON n.day = _day;
        EXECUTE format(
            'SELECT count(*) FILTER (WHERE depth = 0), count(*) FILTER (WHERE depth > 0)
             FROM hivemind_app.hive_posts WHERE block_num_created BETWEEN %s AND %s', _from, _to)
            INTO _hm_posts, _hm_comments;
        _checked_days := _checked_days + 1;
        IF _ours_posts <> _hm_posts OR _ours_comments <> _hm_comments THEN
            _bad := _bad || format('network %s: posts %s vs hivemind %s, comments %s vs hivemind %s',
                                   _day, _ours_posts, _hm_posts, _ours_comments, _hm_comments);
        END IF;
    END LOOP;

    -- (b) accounts, last 30 complete days ------------------------------------------------
    SELECT b.from_block, b.to_block INTO _from, _to FROM haf_stats_app.block_range_for_dates(_last_day, _last_day) AS b;
    IF _from IS NOT NULL THEN
        EXECUTE format(
            'SELECT array_agg(author_id) FROM (SELECT DISTINCT author_id FROM hivemind_app.hive_posts
              WHERE block_num_created BETWEEN %s AND %s LIMIT 200) AS a', _from, _to)
            INTO _authors;
        FOREACH _author_id IN ARRAY COALESCE(_authors, ARRAY[]::INT[]) LOOP
            EXECUTE 'SELECT name FROM hivemind_app.hive_accounts WHERE id = $1' INTO _name USING _author_id;
            SELECT a.id INTO _account_id FROM hafd.accounts AS a WHERE a.name = _name;
            CONTINUE WHEN _account_id IS NULL;
            SELECT COALESCE(SUM(c.posts), 0), COALESCE(SUM(c.comments), 0) INTO _ours_posts, _ours_comments
            FROM haf_stats_backend.account_content_daily c
            WHERE c.account_id = _account_id AND c.day BETWEEN _last_day - 29 AND _last_day;
            EXECUTE format(
                'SELECT count(*) FILTER (WHERE depth = 0), count(*) FILTER (WHERE depth > 0)
                 FROM hivemind_app.hive_posts WHERE author_id = %s AND created_at >= %L AND created_at < %L',
                _author_id, _last_day - 29, _last_day + 1)
                INTO _hm_posts, _hm_comments;
            _checked_accounts := _checked_accounts + 1;
            IF _ours_posts <> _hm_posts OR _ours_comments <> _hm_comments THEN
                _bad := _bad || format('account %s (%s..%s): posts %s vs hivemind %s, comments %s vs hivemind %s',
                                       _name, _last_day - 29, _last_day, _ours_posts, _hm_posts, _ours_comments, _hm_comments);
            END IF;
        END LOOP;
    END IF;

    IF cardinality(_bad) > 0 THEN
        RAISE EXCEPTION 'content oracle: % mismatch(es) with hivemind across % days and % accounts checked (#42/#45 class):%',
            cardinality(_bad), _checked_days, _checked_accounts,
            E'\n  ' || array_to_string(_bad[1:20], E'\n  ')
            || CASE WHEN cardinality(_bad) > 20 THEN format(E'\n  ... and %s more', cardinality(_bad) - 20) ELSE '' END;
    END IF;
    IF _checked_days = 0 THEN
        RAISE EXCEPTION 'content oracle: hivemind is present but no day could be compared (last complete day %); the check did not run', _last_day;
    END IF;
    RAISE NOTICE 'content oracle: % days and % accounts match hivemind exactly (through %)', _checked_days, _checked_accounts, _last_day;
END
$guard$;
