-- =============================================================================
-- content_vs_hivemind.sql -- post/comment counts checked against hivemind (#63).
--
-- Two accuracy defects reached production and were found by hand, not by CI:
--   * #42: get_network_content_volume reported posts AND comments at exactly 2.000x for
--     ~2020 through 2025-08 (a non-idempotent backfill upsert);
--   * #45: get_account_content_stats over-reported posts by ~19% (stale historical
--     account_content_daily rows; network counts were right).
-- The CI replay is 2016 history and predates both, so only a check on a real node sees
-- this class. hivemind, where it is co-located in the same database, is an independent
-- oracle: it records the same creations from its own processing.
--
-- WHAT IS COMPARED, and the rule for each (calibrated on every day 2016-03-24..2026-10-21
-- on a 1.28.8 node, 2026-10-23):
--   * POSTS: EXACT, per day and per author. They matched on every one of 3,864 days.
--   * COMMENTS: haf_stats >= hivemind, and per day at most 2% above it. hivemind's massive
--     sync drops a re-created reply whose parent is also deleted and re-created in the same
--     batch (hive/hivemind#394), so on 52 days of 2016-2021 it is short by up to 182
--     comments (1.33% of that day); haf_stats matches hived's post_count there. A count
--     BELOW hivemind's is never explained by that and always fails. Per author, the excess
--     may not exceed the network's excess over the same days (network = sum of authors).
--   Days: every complete day of the last 365, plus one day per month back to 2016-04 (the
--   day of the month is hashed from the run date, so successive runs cover different days).
--   Authors: up to 200 who posted on the last complete day, over the last 30 days; plus 20
--   who posted on each sampled monthly day, for that single day -- the #45 class lived in
--   old account rows that a recent window cannot see. The sample is hashed with the run
--   date (not the lowest ids), and a sampled author HAF does not know by name fails.
--   If no monthly day or monthly author could be compared, that also fails.
--   hivemind's rows are selected by block_num_created (its created_at is 3 s before the
--   block time, so a time window disagrees at day edges); haf_stats buckets by block time.
--
-- WHEN IT DOES NOT RUN, IT SAYS SO. A WARNING containing "NOT RUN" (exit status 0) when
-- hivemind is not in the live stage (massive sync drops the hive_posts indexes this uses
-- and advances its context head before its data) or an index is missing/invalid. An ERROR
-- when hivemind_app exists but this role cannot read it or the two hafd.contexts rows (a
-- missing haf_stats/hivemind_app context row reads the same), when a needed
-- column is missing, or when nothing could be compared. Only an absent hivemind_app is a
-- plain NOTICE skip.
--
-- READ-ONLY (no writes, no temp tables). ~100 s on a 1.28.8 node; capped by
-- statement_timeout below. Run it as haf_admin (or another member of
-- hive_applications_group that can read hivemind_app): hafd.contexts is row-level secured.
--
-- ON A NODE: run THIS FILE on its own, not scripts/run_verification.sh, whose other guards
-- take locks and rewrite tables inside rolled-back transactions. With haf_api_node:
--   docker exec -i haf-haf-1 psql -U haf_admin -d haf_block_log -X -v ON_ERROR_STOP=1 \
--       -f - < tests/parity/content_vs_hivemind.sql
-- (the image does not ship tests/; use a checkout of this repository). For a schedule,
-- run that command from the host's cron, capturing stderr (warnings and notices go there),
-- and alert on a non-zero exit or a "NOT RUN" warning. A non-zero exit is a mismatch
-- ("N mismatch(es)") or an operational error (timeout, lock timeout, role); read it first.
-- It is one ~100 s transaction holding read locks: not alongside a content rebuild.
-- =============================================================================
\set ON_ERROR_STOP on
SET statement_timeout = '5min';
SET lock_timeout = '5s';

DO $guard$
DECLARE
    _missing TEXT;
    _haf_stats_head INT;
    _hivemind_head INT;
    _hivemind_done INT;
    _stage TEXT;
    _last_day DATE;
    _day DATE;
    _days DATE[];
    _monthly DATE[];
    -- hashed, not DOY-stepped: a weekly cron would otherwise cycle through only 4 days
    _rot INT := 1 + (abs(hashtext(CURRENT_DATE::TEXT)) % 28);
    _from INT;
    _to INT;
    _ours_posts BIGINT;
    _ours_comments BIGINT;
    _hm_posts BIGINT;
    _hm_comments BIGINT;
    _bad TEXT[] := ARRAY[]::TEXT[];
    _excess TEXT[] := ARRAY[]::TEXT[];
    _authors INT[];
    _author_id INT;
    _name TEXT;
    _account_id INT;
    _checked_days INT := 0;
    _checked_accounts INT := 0;
    _checked_monthly_days INT := 0;
    _checked_monthly_accounts INT := 0;
    _unmapped TEXT[] := ARRAY[]::TEXT[];
    _net_excess JSONB := '{}';
    _excess_bound BIGINT;
BEGIN
    -- ---------------------------------------------------------------- can it run at all
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'hivemind_app') THEN
        RAISE NOTICE 'content oracle: no hivemind_app on this node - skipped (nothing to compare against).';
        RETURN;
    END IF;
    -- Schema first: the text form of has_table_privilege raises (not returns false) when the
    -- role lacks USAGE on the schema.
    IF NOT has_schema_privilege('hivemind_app', 'USAGE')
       OR NOT has_table_privilege('hivemind_app.hive_posts', 'SELECT')
       OR NOT has_table_privilege('hivemind_app.hive_accounts', 'SELECT')
       OR (to_regclass('hivemind_app.hive_state') IS NOT NULL
           AND NOT has_table_privilege('hivemind_app.hive_state', 'SELECT')) THEN
        RAISE EXCEPTION 'content oracle: hivemind_app exists but role % cannot read hive_posts/hive_accounts/hive_state; run it as haf_admin', current_user;
    END IF;

    SELECT string_agg(format('%s.%s', r.t, r.c), ', ' ORDER BY r.t, r.c) INTO _missing
    FROM (VALUES ('hive_posts', 'author_id'), ('hive_posts', 'depth'), ('hive_posts', 'created_at'),
                 ('hive_posts', 'block_num_created'), ('hive_accounts', 'id'), ('hive_accounts', 'name'),
                 ('hive_state', 'last_completed_block_num')) AS r(t, c)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns ic
                      WHERE ic.table_schema = 'hivemind_app' AND ic.table_name = r.t AND ic.column_name = r.c);
    IF _missing IS NOT NULL THEN
        RAISE EXCEPTION 'content oracle: hivemind_app is present but lacks %; this check needs updating for its schema', _missing;
    END IF;

    SELECT current_block_num INTO _haf_stats_head FROM hafd.contexts WHERE name = 'haf_stats';
    SELECT current_block_num INTO _hivemind_head FROM hafd.contexts WHERE name = 'hivemind_app';
    IF _haf_stats_head IS NULL OR _hivemind_head IS NULL THEN
        RAISE EXCEPTION 'content oracle: no haf_stats/hivemind_app row in hafd.contexts visible to role % (row-level security: needs hive_applications_group, so run it as haf_admin; or the app is not installed)', current_user;
    END IF;

    _stage := hive.get_current_stage_name('hivemind_app');
    IF _stage IS DISTINCT FROM 'live' THEN
        RAISE WARNING 'content oracle: NOT RUN - hivemind is in stage % (not live): its indexes and data lag its context head during massive sync', _stage;
        RETURN;
    END IF;
    IF (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'hivemind_app'
          AND c.relname IN ('hive_posts_block_num_created_idx', 'hive_posts_author_id_created_at_id_idx')
          AND i.indisvalid AND i.indisready) < 2 THEN
        RAISE WARNING 'content oracle: NOT RUN - hivemind_app.hive_posts lacks a valid block_num_created or (author_id, created_at) index; every lookup would be a full scan';
        RETURN;
    END IF;

    -- Bound by what BOTH apps have finished: hivemind's own completion marker as well as its
    -- context head (in massive sync the head is advanced before the batch is written).
    SELECT last_completed_block_num INTO _hivemind_done FROM hivemind_app.hive_state;
    SELECT (b.created_at::DATE - 1) INTO _last_day
    FROM hive.blocks_view b
    WHERE b.num = LEAST(_haf_stats_head, _hivemind_head, COALESCE(_hivemind_done, _hivemind_head));
    IF _last_day IS NULL OR _last_day < DATE '2016-04-01' THEN
        RAISE EXCEPTION 'content oracle: no complete day to compare (heads: haf_stats %, hivemind % / done %)',
            _haf_stats_head, _hivemind_head, _hivemind_done;
    END IF;

    -- ---------------------------------------------------------------- (a) network, per day
    SELECT array_agg(m::DATE + (_rot - 1) ORDER BY m) INTO _monthly
    FROM generate_series(DATE '2016-04-01', _last_day - 366, INTERVAL '1 month') AS m;
    SELECT array_agg(d ORDER BY d) INTO _days FROM (
        SELECT generate_series(_last_day - 364, _last_day, INTERVAL '1 day')::DATE AS d
        UNION SELECT unnest(_monthly)
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
        IF _day < _last_day - 364 THEN
            _checked_monthly_days := _checked_monthly_days + 1;
        END IF;
        _net_excess := _net_excess || jsonb_build_object(_day::TEXT, _ours_comments - _hm_comments);
        IF _ours_posts <> _hm_posts
           OR _ours_comments < _hm_comments
           OR _ours_comments - _hm_comments > floor(_hm_comments * 0.02) THEN
            _bad := _bad || format('network %s: posts %s vs hivemind %s, comments %s vs hivemind %s',
                                   _day, _ours_posts, _hm_posts, _ours_comments, _hm_comments);
        ELSIF _ours_comments > _hm_comments THEN
            _excess := _excess || format('%s: +%s comments', _day, _ours_comments - _hm_comments);
        END IF;
    END LOOP;

    -- ---------------------------------------------------------------- (b) accounts
    -- b1: recent window for authors active on the last day; b2: one sampled day per month.
    FOREACH _day IN ARRAY array_prepend(_last_day, _monthly) LOOP
        SELECT b.from_block, b.to_block INTO _from, _to FROM haf_stats_app.block_range_for_dates(_day, _day) AS b;
        CONTINUE WHEN _from IS NULL;
        -- OFFSET 0 keeps the planner on the block_num_created range for the sample. The
        -- sample is hashed with the run's rotation, so it is not always the lowest ids.
        EXECUTE format(
            'SELECT array_agg(author_id ORDER BY author_id) FROM (
                 SELECT author_id FROM (
                     SELECT DISTINCT author_id FROM (
                         SELECT author_id FROM hivemind_app.hive_posts
                         WHERE block_num_created BETWEEN %s AND %s OFFSET 0) AS r) AS d
                 ORDER BY hashtext(author_id::TEXT || %L), author_id LIMIT %s) AS a',
            _from, _to, _rot, CASE WHEN _day = _last_day THEN 200 ELSE 20 END)
            INTO _authors;
        IF _day = _last_day THEN
            SELECT b.from_block, b.to_block INTO _from, _to
            FROM haf_stats_app.block_range_for_dates(_last_day - 29, _last_day) AS b;
        END IF;
        -- No single author can be further above hivemind than the whole network is on the
        -- same days (network = sum of authors), so the per-author excess is bounded by it.
        SELECT COALESCE(SUM(GREATEST((_net_excess ->> g.d::DATE::TEXT)::BIGINT, 0)), 0) INTO _excess_bound
        FROM generate_series(CASE WHEN _day = _last_day THEN _last_day - 29 ELSE _day END, _day, INTERVAL '1 day') AS g(d);
        FOREACH _author_id IN ARRAY COALESCE(_authors, ARRAY[]::INT[]) LOOP
            EXECUTE 'SELECT name FROM hivemind_app.hive_accounts WHERE id = $1' INTO _name USING _author_id;
            _account_id := NULL;
            SELECT a.id INTO _account_id FROM hafd.accounts AS a WHERE a.name = _name;
            IF _account_id IS NULL THEN
                -- Every sampled author posted in an irreversible block, so HAF has the account.
                _unmapped := _unmapped || COALESCE(_name, format('hivemind id %s', _author_id));
                CONTINUE;
            END IF;
            SELECT COALESCE(SUM(c.posts), 0), COALESCE(SUM(c.comments), 0) INTO _ours_posts, _ours_comments
            FROM haf_stats_backend.account_content_daily c
            WHERE c.account_id = _account_id
              AND c.day BETWEEN CASE WHEN _day = _last_day THEN _last_day - 29 ELSE _day END AND _day;
            -- created_at narrows to the author index; block_num_created decides membership.
            EXECUTE format(
                'SELECT count(*) FILTER (WHERE depth = 0), count(*) FILTER (WHERE depth > 0)
                 FROM hivemind_app.hive_posts
                 WHERE author_id = %s AND created_at >= %L AND created_at < %L
                   AND block_num_created BETWEEN %s AND %s',
                _author_id,
                CASE WHEN _day = _last_day THEN _last_day - 30 ELSE _day - 1 END,
                _day + 2, _from, _to)
                INTO _hm_posts, _hm_comments;
            _checked_accounts := _checked_accounts + 1;
            IF _day <> _last_day THEN
                _checked_monthly_accounts := _checked_monthly_accounts + 1;
            END IF;
            IF _ours_posts <> _hm_posts OR _ours_comments < _hm_comments
               OR _ours_comments - _hm_comments > _excess_bound THEN
                _bad := _bad || format('account %s (%s): posts %s vs hivemind %s, comments %s vs hivemind %s',
                                       _name,
                                       CASE WHEN _day = _last_day THEN format('%s..%s', _last_day - 29, _last_day) ELSE _day::TEXT END,
                                       _ours_posts, _hm_posts, _ours_comments, _hm_comments);
            END IF;
        END LOOP;
    END LOOP;

    -- ---------------------------------------------------------------- verdict
    IF cardinality(_bad) > 0 THEN
        RAISE EXCEPTION 'content oracle: % mismatch(es) with hivemind across % days and % account checks (#42/#45 class):%',
            cardinality(_bad), _checked_days, _checked_accounts,
            E'\n  ' || array_to_string(_bad[1:20], E'\n  ')
            || CASE WHEN cardinality(_bad) > 20 THEN format(E'\n  ... and %s more', cardinality(_bad) - 20) ELSE '' END;
    END IF;
    IF cardinality(_unmapped) > 0 THEN
        RAISE EXCEPTION 'content oracle: % sampled hivemind author(s) not found in hafd.accounts by name: %',
            cardinality(_unmapped), array_to_string(_unmapped[1:20], ', ');
    END IF;
    -- The monthly half is the only one that sees old account rows (#45), so it is counted
    -- on its own: recent checks alone must not read as a pass.
    IF _checked_days = 0 OR _checked_accounts = 0
       OR (cardinality(_monthly) > 0 AND (_checked_monthly_days = 0 OR _checked_monthly_accounts = 0)) THEN
        RAISE EXCEPTION 'content oracle: compared % days (% monthly) and % account checks (% monthly) through %; a zero means a half of this check did not run',
            _checked_days, _checked_monthly_days, _checked_accounts, _checked_monthly_accounts, _last_day;
    END IF;
    IF cardinality(_excess) > 0 THEN
        RAISE NOTICE 'content oracle: % day(s) with haf_stats comments above hivemind, within 2%% (hivemind#394): %',
            cardinality(_excess), array_to_string(_excess[1:20], ', ');
    END IF;
    RAISE NOTICE 'content oracle: % days and % account checks agree with hivemind (posts exact, comments >= and within 2%%), through %',
        _checked_days, _checked_accounts, _last_day;
END
$guard$;
