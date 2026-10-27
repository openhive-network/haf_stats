-- =============================================================================
-- content_volume_rebuild_consistency.sql — drift guard for issue #42.
--
-- The content-volume rebuild path haf_stats_app.process_content_volume (used by
-- scripts/rebuild_content_volume.sh) is a NARROW DUPLICATE of the comment-op
-- classification inside haf_stats_app.process_content_stats (the live path). If
-- the two ever diverge, a rebuild would silently produce different history than
-- the live processor. This guard proves they agree: it replays the whole chain
-- through process_content_volume and asserts it reproduces, byte-for-byte, the
-- network_content_daily / network_author_daily / comment_registry rows the live
-- processor already wrote. It then reseals the rollup exactly as the script does
-- and asserts that reproduces network_content_period_counts too — so the step
-- that actually publishes to the endpoint is covered, not just the daily tables.
-- Any mismatch RAISEs and fails CI.
--
-- Non-destructive: the whole thing runs inside a REPEATABLE READ transaction that
-- is ROLLED BACK at the end, so the live tables are left exactly as found (whether
-- the check passes or fails).
--
-- Concurrency: this TRUNCATEs and replays the content tables under ACCESS EXCLUSIVE
-- locks. A processor parked at the chain head (the CI stack, whose haf node stops at
-- REPLAY_STOP_AT_BLOCK) never writes again and is harmless, so we do NOT refuse to run
-- merely because a haf_stats_app.main backend exists. Instead we take the locks up
-- front under a lock_timeout: if the processor is genuinely still writing, we fail fast
-- with a clear message instead of stalling for the length of the replay or deadlocking.
-- =============================================================================
\set ON_ERROR_STOP on

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout = '60s';

-- Exact fingerprint of every table process_content_volume must NOT touch. The whole
-- reason the narrow function exists is that the live process_content_stats shares one
-- scan with votes/engagement, so re-running IT to rebuild would re-double them. md5 over
-- the ordered rows (not COUNT/SUM, which an offsetting swap could evade) so any insert,
-- delete, or update anywhere in these tables is caught.
--
-- account_content_daily is deliberately NOT fingerprinted here: process_content_volume now
-- rebuilds its content columns (posts/comments/replies_received) too, so it is an EXPECTED
-- write. Its correctness — content reproduced, votes preserved — is asserted separately
-- below (see _live_account snapshot + the account drift checks).
CREATE OR REPLACE FUNCTION pg_temp.sibling_fingerprint()
RETURNS TEXT LANGUAGE sql STABLE AS $fn$
    SELECT concat_ws('|',
        (SELECT md5(COALESCE(string_agg(t::TEXT, E'\n' ORDER BY t::TEXT), ''))
           FROM haf_stats_backend.post_engagement t),
        (SELECT md5(COALESCE(string_agg(t::TEXT, E'\n' ORDER BY t::TEXT), ''))
           FROM haf_stats_backend.network_vote_daily t),
        (SELECT md5(COALESCE(string_agg(t::TEXT, E'\n' ORDER BY t::TEXT), ''))
           FROM haf_stats_backend.network_voter_daily t),
        (SELECT md5(COALESCE(string_agg(t::TEXT, E'\n' ORDER BY t::TEXT), ''))
           FROM haf_stats_backend.engagement_touched_days t),
        (SELECT md5(COALESCE(string_agg(t::TEXT, E'\n' ORDER BY t::TEXT), ''))
           FROM haf_stats_backend.network_vote_period_counts t),
        (SELECT md5(COALESCE(string_agg(t::TEXT, E'\n' ORDER BY t::TEXT), ''))
           FROM haf_stats_backend.engagement_period_counts t)
    );
$fn$;

DO $$
DECLARE
    _to_block      INT;
    _first         INT;
    _last          INT;
    _batch         CONSTANT INT := 100000;
    _daily_diff    BIGINT;
    _author_diff   BIGINT;
    _registry_diff BIGINT;
    _period_diff   BIGINT;
    _account_diff       BIGINT;
    _community_diff     BIGINT;
    _community_over     BIGINT;
    _acct_posts_delta   BIGINT;
    _acct_comments_delta BIGINT;
    _acct_replies_gap   BIGINT;
    _dead_deleted       BIGINT;
    _siblings_before TEXT;
    _siblings_after  TEXT;
BEGIN
    SELECT COALESCE(MAX(last_processed_block), 0) INTO _to_block
    FROM haf_stats_app.app_status;

    IF _to_block < 1 THEN
        RAISE EXCEPTION 'content_volume rebuild consistency: app has processed no blocks (last_processed_block=%)', _to_block;
    END IF;

    -- Take the write locks before doing anything. Fails fast (lock_timeout above) if the
    -- processor is still actively writing, rather than stalling or deadlocking mid-replay.
    BEGIN
        LOCK TABLE haf_stats_backend.network_content_daily,
                   haf_stats_backend.network_author_daily,
                   haf_stats_backend.comment_registry,
                   haf_stats_backend.account_content_daily
              IN ACCESS EXCLUSIVE MODE;
    EXCEPTION WHEN lock_not_available THEN
        RAISE EXCEPTION 'content_volume rebuild consistency: could not lock the content tables within lock_timeout — the haf_stats processor is still actively writing them.'
            USING HINT = 'Stop it first (stop the haf-stats-process container; stop_processing() only stops the legacy CALL main() loop), then re-run verification.';
    END;

    _siblings_before := pg_temp.sibling_fingerprint();

    -- Snapshot the live-processor result before touching anything. comment_registry is
    -- included deliberately: it is the cross-batch create-vs-edit state the live
    -- processor probes when it resumes after a rebuild, so "the rebuild reproduces the
    -- live tables" is only true if the registry lands in the same state too.
    CREATE TEMP TABLE _live_daily    ON COMMIT DROP AS
        SELECT * FROM haf_stats_backend.network_content_daily;
    CREATE TEMP TABLE _live_author   ON COMMIT DROP AS
        SELECT * FROM haf_stats_backend.network_author_daily;
    CREATE TEMP TABLE _live_registry ON COMMIT DROP AS
        SELECT * FROM haf_stats_backend.comment_registry;
    -- All columns, so the post-rebuild comparison proves BOTH that the content columns are
    -- reproduced AND that votes_cast/votes_received survive the zero+rebuild untouched.
    CREATE TEMP TABLE _live_account ON COMMIT DROP AS
        SELECT account_id, day, posts, comments, votes_cast, votes_received, replies_received
        FROM haf_stats_backend.account_content_daily;
    -- The community dimension (#47) is written by the same shared classified rows, so it is
    -- subject to the identical drift risk and is rebuilt (not preserved) by this path.
    CREATE TEMP TABLE _live_community ON COMMIT DROP AS
        SELECT * FROM haf_stats_backend.account_community_daily;

    -- Corrupt the content columns first (simulate the stale raw-op over-report this rebuild
    -- exists to repair). The zeroing below must wipe it and the additive replay must restore
    -- the snapshot exactly: this proves the rebuild REPLACES pre-existing content rather than
    -- adding to it, so an over-reported deployment is genuinely repaired, not just reproduced.
    -- Votes are left alone so their preservation is still verified against the untouched snapshot.
    UPDATE haf_stats_backend.account_content_daily
       SET posts = posts * 2 + 13, comments = comments * 2 + 13, replies_received = replies_received * 2 + 13;

    -- Rebuild via the content-only path, exactly as rebuild_content_volume.sh does: clear
    -- the three network tables and zero account_content_daily's content columns (votes are
    -- preserved, not truncated), then replay ascending non-overlapping batches from block 1
    -- (comment_registry carries create/edit state across batches).
    TRUNCATE haf_stats_backend.network_content_daily;
    TRUNCATE haf_stats_backend.network_author_daily;
    TRUNCATE haf_stats_backend.comment_registry;
    TRUNCATE haf_stats_backend.account_community_daily;
    UPDATE haf_stats_backend.account_content_daily
       SET posts = 0, comments = 0, replies_received = 0;

    _first := 1;
    WHILE _first <= _to_block LOOP
        _last := LEAST(_first + _batch - 1, _to_block);
        PERFORM haf_stats_app.process_content_volume(_first, _last);
        _first := _last + 1;
    END LOOP;

    -- Symmetric set difference (both directions) on the full row, so a differing
    -- count, an extra row, or a missing row all register as drift.
    SELECT COUNT(*) INTO _daily_diff FROM (
        (SELECT day, posts, comments, edits FROM haf_stats_backend.network_content_daily
         EXCEPT
         SELECT day, posts, comments, edits FROM _live_daily)
        UNION ALL
        (SELECT day, posts, comments, edits FROM _live_daily
         EXCEPT
         SELECT day, posts, comments, edits FROM haf_stats_backend.network_content_daily)
    ) d;

    -- The live processor keeps only the recent end of the author set (prune_content_presence,
    -- db/process_content_stats.sql) while the rebuild restores all of it, so the two are
    -- compared from the live set's oldest day on. Everything from there must match exactly.
    SELECT COUNT(*) INTO _author_diff FROM (
        (SELECT day, author_id FROM haf_stats_backend.network_author_daily
         WHERE day >= COALESCE((SELECT MIN(day) FROM _live_author), DATE '-infinity')
         EXCEPT
         SELECT day, author_id FROM _live_author)
        UNION ALL
        (SELECT day, author_id FROM _live_author
         EXCEPT
         SELECT day, author_id FROM haf_stats_backend.network_author_daily)
    ) a;

    -- The registry must land in the SAME state the live processor had at _to_block,
    -- or the processor misclassifies edits as creates when it resumes. `community` is
    -- compared too (IS NOT DISTINCT semantics via EXCEPT, which treats NULLs as equal):
    -- the rebuild re-derives it from scratch, so a resolver that only works on the live
    -- path would surface here.
    SELECT COUNT(*) INTO _registry_diff FROM (
        (SELECT author_id, permlink, community FROM haf_stats_backend.comment_registry
         EXCEPT
         SELECT author_id, permlink, community FROM _live_registry)
        UNION ALL
        (SELECT author_id, permlink, community FROM _live_registry
         EXCEPT
         SELECT author_id, permlink, community FROM haf_stats_backend.comment_registry)
    ) r;

    SELECT COUNT(*) INTO _community_diff FROM (
        (SELECT account_id, day, community, posts, comments
           FROM haf_stats_backend.account_community_daily
         EXCEPT
         SELECT account_id, day, community, posts, comments FROM _live_community)
        UNION ALL
        (SELECT account_id, day, community, posts, comments FROM _live_community
         EXCEPT
         SELECT account_id, day, community, posts, comments
           FROM haf_stats_backend.account_community_daily)
    ) c;

    IF _daily_diff <> 0 OR _author_diff <> 0 OR _registry_diff <> 0 OR _community_diff <> 0 THEN
        RAISE EXCEPTION 'content_volume rebuild drift: % differing network_content_daily row(s), % differing network_author_daily row(s), % differing comment_registry row(s), % differing account_community_daily row(s) through block %. process_content_volume has diverged from process_content_stats.',
            _daily_diff, _author_diff, _registry_diff, _community_diff, _to_block;
    END IF;

    -- The community buckets can never exceed the totals they are subtracted from: the
    -- endpoint derives "Personal blog / No community" as account_content_daily minus these,
    -- so a violation here would make that bucket go negative.
    SELECT COUNT(*) INTO _community_over FROM (
        SELECT acd.account_id, acd.day
        FROM haf_stats_backend.account_community_daily acd
        GROUP BY acd.account_id, acd.day
        HAVING SUM(acd.posts) > COALESCE((
                   SELECT t.posts FROM haf_stats_backend.account_content_daily t
                   WHERE t.account_id = acd.account_id AND t.day = acd.day), -1)
            OR SUM(acd.comments) > COALESCE((
                   SELECT t.comments FROM haf_stats_backend.account_content_daily t
                   WHERE t.account_id = acd.account_id AND t.day = acd.day), -1)
    ) o;

    IF _community_over <> 0 THEN
        RAISE EXCEPTION 'account_community_daily exceeds account_content_daily for % (account, day) pair(s); get_account_community_activity would report a negative personal-blog bucket.',
            _community_over;
    END IF;

    -- account_content_daily: process_content_volume now rebuilds its content columns.
    -- (1) The whole table must be byte-identical to the pre-corruption live snapshot. In CI the
    -- live processor IS the current creates-only code, so the rebuild reproduces the content
    -- columns exactly (the same classified/registry guarantee that makes network_content_daily
    -- byte-identical), the injected over-report is wiped by the zeroing and replaced (proving
    -- repair, not just reproduction), and the vote columns — never corrupted — must be
    -- untouched. A differing, missing, or extra row all register. This comparison runs BEFORE
    -- the script's dead-row DELETE (exercised separately below), so an unexpected all-zero row
    -- the rebuild might produce surfaces as drift here instead of being silently swept.
    SELECT COUNT(*) INTO _account_diff FROM (
        (SELECT account_id, day, posts, comments, votes_cast, votes_received, replies_received
           FROM haf_stats_backend.account_content_daily
         EXCEPT
         SELECT account_id, day, posts, comments, votes_cast, votes_received, replies_received
           FROM _live_account)
        UNION ALL
        (SELECT account_id, day, posts, comments, votes_cast, votes_received, replies_received
           FROM _live_account
         EXCEPT
         SELECT account_id, day, posts, comments, votes_cast, votes_received, replies_received
           FROM haf_stats_backend.account_content_daily)
    ) x;

    -- (2) Structural invariant, independent of the snapshot: account posts/comments regroup
    -- the SAME classified rows network_counts counts (author_id is never NULL — comment_keys
    -- INNER-JOINs accounts), so summing per-account back over all authors reproduces the
    -- per-day network total exactly. replies_received credits the parent author via a further
    -- INNER join, so it can only be <= network.comments (equality holds while every reply's
    -- parent resolves, which is not structurally guaranteed) — assert that bound, not equality.
    SELECT
        (SELECT COALESCE(SUM(posts), 0)    FROM haf_stats_backend.account_content_daily)
      - (SELECT COALESCE(SUM(posts), 0)    FROM haf_stats_backend.network_content_daily),
        (SELECT COALESCE(SUM(comments), 0) FROM haf_stats_backend.account_content_daily)
      - (SELECT COALESCE(SUM(comments), 0) FROM haf_stats_backend.network_content_daily),
        (SELECT COALESCE(SUM(replies_received), 0) FROM haf_stats_backend.account_content_daily)
      - (SELECT COALESCE(SUM(comments), 0)         FROM haf_stats_backend.network_content_daily)
    INTO _acct_posts_delta, _acct_comments_delta, _acct_replies_gap;

    IF _account_diff <> 0 OR _acct_posts_delta <> 0 OR _acct_comments_delta <> 0 OR _acct_replies_gap > 0 THEN
        RAISE EXCEPTION 'account_content_daily rebuild drift: % row(s) differ from the live snapshot (content not reproduced or votes not preserved); SUM(posts)-network=%, SUM(comments)-network=%, SUM(replies_received)-network.comments=% (must be <= 0). process_content_volume account path has diverged from process_content_stats.',
            _account_diff, _acct_posts_delta, _acct_comments_delta, _acct_replies_gap;
    END IF;

    -- (3) Exercise rebuild_content_volume.sh's final dead-row DELETE and prove it is not
    -- over-broad. The live processor never writes an all-zero row and the rebuild above
    -- reproduced the live table, so this must remove exactly zero rows. If a metric column is
    -- ever added and the DELETE predicate is not updated to match, a row non-zero only in that
    -- new column matches this predicate and is removed → _dead_deleted > 0 → CI fails here.
    DELETE FROM haf_stats_backend.account_content_daily
     WHERE posts = 0 AND comments = 0 AND replies_received = 0
       AND votes_cast = 0 AND votes_received = 0;
    GET DIAGNOSTICS _dead_deleted = ROW_COUNT;
    IF _dead_deleted <> 0 THEN
        RAISE EXCEPTION 'content_volume dead-row DELETE removed % account_content_daily row(s); the live processor never writes all-zero rows, so the predicate in rebuild_content_volume.sh is too broad (a metric column it does not account for?).',
            _dead_deleted;
    END IF;

    -- Reseal the rollup exactly as rebuild_content_volume.sh does. This is the step that
    -- actually publishes to get_network_content_volume (the endpoint reads ONLY this
    -- table), so leaving it unexercised would let a broken reseal ship green.
    --
    -- The oracle is an INDEPENDENT re-derivation from the rebuilt daily tables, NOT the
    -- rollup the live processor left behind. Comparing against the stored rollup would be
    -- wrong: process_content_stats only refreshes it when a batch crosses a ~1200-block
    -- boundary and LIVE batches are 1 block, so 1199 of every 1200 live batches skip the
    -- refresh and the stored rollup legitimately lags the daily tables by up to 1200 blocks
    -- at the chain head. Demanding row-for-row equality with it would raise a bogus "drift"
    -- on any live node (it would pass in CI only by the accident that 10000-block MASSIVE
    -- batches always cross a boundary). Re-deriving the expected aggregate tests
    -- refresh_network_content_periods on its own terms and is immune to that lag.
    TRUNCATE haf_stats_backend.network_content_period_counts;
    PERFORM haf_stats_app.refresh_network_content_periods(
        (SELECT MIN(day) FROM haf_stats_backend.network_content_daily), NULL);

    CREATE TEMP TABLE _expected_periods ON COMMIT DROP AS
    WITH grains(period_type) AS (VALUES ('day'), ('week'), ('month')),
    counts AS (
        SELECT g.period_type,
               DATE_TRUNC(g.period_type, d.day)::DATE AS period,
               SUM(d.posts)::BIGINT                   AS posts,
               SUM(d.comments)::BIGINT                AS comments
        FROM grains g
        CROSS JOIN haf_stats_backend.network_content_daily d
        GROUP BY 1, 2
    ),
    authors AS (
        SELECT g.period_type,
               DATE_TRUNC(g.period_type, a.day)::DATE   AS period,
               COUNT(DISTINCT a.author_id)::BIGINT      AS unique_authors
        FROM grains g
        CROSS JOIN haf_stats_backend.network_author_daily a
        GROUP BY 1, 2
    )
    SELECT COALESCE(c.period_type, u.period_type) AS period_type,
           COALESCE(c.period, u.period)           AS period,
           COALESCE(c.posts, 0)                   AS posts,
           COALESCE(c.comments, 0)                AS comments,
           COALESCE(u.unique_authors, 0)          AS unique_authors
    FROM counts c
    FULL JOIN authors u ON u.period_type = c.period_type AND u.period = c.period;

    SELECT COUNT(*) INTO _period_diff FROM (
        (SELECT period_type, period, posts, comments, unique_authors
           FROM haf_stats_backend.network_content_period_counts
         EXCEPT
         SELECT period_type, period, posts, comments, unique_authors FROM _expected_periods)
        UNION ALL
        (SELECT period_type, period, posts, comments, unique_authors FROM _expected_periods
         EXCEPT
         SELECT period_type, period, posts, comments, unique_authors
           FROM haf_stats_backend.network_content_period_counts)
    ) p;

    IF _period_diff <> 0 THEN
        RAISE EXCEPTION 'content_volume reseal drift: % network_content_period_counts row(s) differ from an independent re-aggregation of the rebuilt daily tables. refresh_network_content_periods did not roll the rebuilt history up correctly.',
            _period_diff;
    END IF;

    -- process_content_volume must stay NARROW: it may write the content tables (network +
    -- account content) but NOT votes or engagement (re-running the shared processor would
    -- have re-doubled those). account_content_daily is verified above, not fingerprinted here.
    _siblings_after := pg_temp.sibling_fingerprint();
    IF _siblings_after IS DISTINCT FROM _siblings_before THEN
        RAISE EXCEPTION 'content_volume rebuild touched sibling tables it must not write (votes/engagement). before=[%] after=[%]',
            _siblings_before, _siblings_after;
    END IF;

    RAISE NOTICE 'content_volume rebuild consistency OK through block %: % day rows / % author rows / % registry rows / % rollup rows / % account rows / % community rows reproduced exactly (SUM(account.posts)==network, votes preserved, community <= totals); sibling vote/engagement tables untouched',
        _to_block,
        (SELECT COUNT(*) FROM haf_stats_backend.network_content_daily),
        (SELECT COUNT(*) FROM haf_stats_backend.network_author_daily),
        (SELECT COUNT(*) FROM haf_stats_backend.comment_registry),
        (SELECT COUNT(*) FROM haf_stats_backend.network_content_period_counts),
        (SELECT COUNT(*) FROM haf_stats_backend.account_content_daily),
        (SELECT COUNT(*) FROM haf_stats_backend.account_community_daily);
END;
$$;

-- Discard the rebuild; the live tables are left untouched.
ROLLBACK;
