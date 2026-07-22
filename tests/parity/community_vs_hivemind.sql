-- =============================================================================
-- community_vs_hivemind.sql — oracle check for issue #47.
--
-- haf_stats derives community membership from raw operations because it must run on any
-- HAF node, including ones without hivemind. But hivemind IS a HAF app and, where it is
-- deployed, it lives in the SAME database under hivemind_app — which makes it available
-- as an ORACLE even though it is deliberately not our data source.
--
-- This is the one check that can prove the derivation right on real community data. The
-- app's own tests cannot: the CI replay is 2016 chain history and communities did not
-- exist until block 37,500,000, so every automated test of the community path runs on
-- synthetic fixtures.
--
-- READ-ONLY. Safe to run against a production node; it takes no locks and writes nothing.
--
-- SKIPS CLEANLY when hivemind_app is absent (the normal case for a standalone haf_stats
-- deployment and for CI) — same "probe information_schema, no-op if missing" posture as
-- refresh_hp_distribution_snapshot uses for balance_tracker. All hivemind access is via
-- EXECUTE so the SQL never has to resolve hivemind_app names on a node without it.
--
-- The two sides count DIFFERENT things by design, and that is the whole reason this
-- reports rather than demanding equality:
--   * ours     = content CREATIONS, counted at creation (what account_content_daily
--                counts, which is what makes the endpoint's personal-blog bucket
--                reconcile with get_account_content_stats)
--   * hivemind = content that is currently LIVE (counter_deleted = 0)
-- So ours >= hivemind's is EXPECTED; the excess is deleted content. The reverse is not
-- explainable and is the actual bug signal, so only that direction fails.
-- =============================================================================
\set ON_ERROR_STOP on

DO $$
DECLARE
    _have_hivemind BOOLEAN;
    _sample CONSTANT INT := 200;   -- accounts compared; keeps this cheap on a live node
    _unknown_communities BIGINT;
    _missing_registrations BIGINT;
    _title_mismatches BIGINT;
    _undercounts BIGINT;
    _worst TEXT;
    _compared BIGINT;
    _excess BIGINT;
    _missing_columns TEXT;
    _our_head_block INT;
    _our_head_time TIMESTAMP;
    _hm_in_range BIGINT;
BEGIN
    SELECT COUNT(*) = 3 INTO _have_hivemind
    FROM information_schema.tables
    WHERE table_schema = 'hivemind_app'
      AND table_name IN ('hive_posts', 'hive_communities', 'hive_accounts');

    IF NOT _have_hivemind THEN
        RAISE NOTICE 'community oracle: hivemind_app not present on this node - skipping (the raw-op derivation is the source of truth here; this check is only available where hivemind is co-located).';
        RETURN;
    END IF;

    -- Verify hivemind's shape before querying it. Every hivemind reference below is
    -- dynamic SQL, so a renamed or missing column would otherwise surface as a bare
    -- "column ... does not exist" from inside an EXECUTE, on someone's production node,
    -- with nothing naming what changed.
    --
    -- This check exists because the CI stub (tests/hivemind_oracle_fixture.sql) is one we
    -- wrote ourselves from hivemind's create_tables.sql: it proves these queries are
    -- internally consistent, NOT that they match a real hivemind_app. This is the only
    -- part of the oracle that can catch that difference, so it names exactly what is
    -- missing rather than failing the run.
    SELECT STRING_AGG(FORMAT('%s.%s', t, c), ', ' ORDER BY t, c) INTO _missing_columns
    FROM (VALUES
        ('hive_posts', 'author_id'), ('hive_posts', 'community_id'),
        ('hive_posts', 'depth'), ('hive_posts', 'counter_deleted'),
        ('hive_posts', 'created_at'),
        ('hive_communities', 'id'), ('hive_communities', 'name'),
        ('hive_communities', 'title'), ('hive_communities', 'created_at'),
        ('hive_accounts', 'id'), ('hive_accounts', 'name')
    ) AS required(t, c)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns ic
        WHERE ic.table_schema = 'hivemind_app'
          AND ic.table_name = required.t
          AND ic.column_name = required.c
    );

    IF _missing_columns IS NOT NULL THEN
        RAISE NOTICE 'community oracle: hivemind_app is present but does not expose the columns this check reads (missing: %). Skipping rather than failing - hivemind''s schema has moved and tests/parity/community_vs_hivemind.sql needs updating to match it.',
            _missing_columns;
        RETURN;
    END IF;

    -- Everything below must compare LIKE FOR LIKE. hivemind on a production node is synced
    -- to the chain tip, while haf_stats only knows what it has processed - and they are
    -- routinely far apart: during the initial sync, and for the whole catch-up after the
    -- documented repair (stop processor -> rebuild -> restart, which the README budgets at
    -- 2-4h). Comparing our processed head against hivemind's tip would report every active
    -- author as an undercount and fail the verification run for a node that is simply behind.
    SELECT COALESCE(MIN(last_processed_block), 0) INTO _our_head_block
    FROM haf_stats_app.app_status;

    SELECT created_at INTO _our_head_time FROM hafd.blocks WHERE num = _our_head_block;

    IF _our_head_time IS NULL THEN
        RAISE NOTICE 'community oracle: cannot resolve the timestamp of our processed head block % - skipping.', _our_head_block;
        RETURN;
    END IF;

    -- Only skip on an empty table when hivemind ALSO has nothing in our processed range.
    -- Skipping unconditionally would turn a total derivation failure - we produced nothing
    -- while hivemind has plenty - into a silent pass, which is exactly the case this check
    -- exists to catch.
    IF NOT EXISTS (SELECT 1 FROM haf_stats_backend.account_community_daily) THEN
        EXECUTE FORMAT($q$
            SELECT COUNT(*) FROM hivemind_app.hive_posts hp
            WHERE hp.community_id IS NOT NULL AND hp.counter_deleted = 0
              AND hp.created_at <= %L
        $q$, _our_head_time) INTO _hm_in_range;

        IF _hm_in_range > 0 THEN
            RAISE EXCEPTION 'community oracle: account_community_daily is EMPTY, but hivemind has % community post(s)/comment(s) at or before our processed head (block %, %). Either the community dimension was never backfilled (run scripts/rebuild_content_volume.sh) or the derivation is producing nothing at all.',
                _hm_in_range, _our_head_block, _our_head_time;
        END IF;

        RAISE NOTICE 'community oracle: neither side has community content at or before our processed head (block %) - nothing to compare.', _our_head_block;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------
    -- 1. Every community we attribute content to must be one hivemind knows.
    --    A community we invented would mean our name pattern or registration gate is
    --    wrong, and every post we filed under it is misattributed.
    -- ---------------------------------------------------------------------
    EXECUTE $q$
        SELECT COUNT(*)
        FROM (SELECT DISTINCT community FROM haf_stats_backend.account_community_daily) ours
        WHERE NOT EXISTS (
            SELECT 1 FROM hivemind_app.hive_communities hc WHERE hc.name = ours.community
        )
    $q$ INTO _unknown_communities;

    -- ---------------------------------------------------------------------
    -- 2. Registration coverage. A community hivemind registered but we did not means we
    --    would file its posts under the personal-blog bucket instead — silent
    --    under-reporting, so this fails rather than warns.
    -- ---------------------------------------------------------------------
    EXECUTE FORMAT($q$
        SELECT COUNT(*)
        FROM hivemind_app.hive_communities hc
        WHERE hc.created_at <= %L
          AND NOT EXISTS (
            SELECT 1 FROM haf_stats_backend.community_registry cr WHERE cr.community = hc.name
        )
    $q$, _our_head_time) INTO _missing_registrations;

    -- ---------------------------------------------------------------------
    -- 3. Titles. This is the direct test of the owner/admin gate in
    --    process_community_registry: hivemind applies the same authorization rules, so
    --    where we recorded a title it must be hivemind's. Communities we have no title
    --    for (no updateProps seen) are skipped, as is hivemind's '' default.
    -- ---------------------------------------------------------------------
    EXECUTE $q$
        SELECT COUNT(*)
        FROM haf_stats_backend.community_registry cr
        JOIN hivemind_app.hive_communities hc ON hc.name = cr.community
        WHERE cr.title IS NOT NULL
          AND hc.title <> ''
          AND cr.title IS DISTINCT FROM hc.title
    $q$ INTO _title_mismatches;

    -- ---------------------------------------------------------------------
    -- 4. Per-(account, community) counts over a sample of the most active community
    --    authors. Ours counts creations and hivemind counts live content, so ours must
    --    be >= hivemind's; an UNDERCOUNT means we failed to attribute content hivemind
    --    did — a broken root resolution, or a registration we missed.
    -- ---------------------------------------------------------------------
    EXECUTE FORMAT($q$
        WITH
        -- Sampled from BOTH sides, not just ours. A sample drawn only from accounts we
        -- already credited with community activity cannot see the worst failure mode there
        -- is: an account whose content we attributed to NOTHING while hivemind attributed
        -- it to a community (a wholesale root-resolution or registration miss). Those
        -- accounts have no row on our side at all, so only hivemind can nominate them.
        sample_accounts AS (
            SELECT name FROM (
                SELECT a.name
                FROM haf_stats_backend.account_community_daily acd
                JOIN hafd.accounts a ON a.id = acd.account_id
                GROUP BY a.name
                ORDER BY SUM(acd.posts) + SUM(acd.comments) DESC
                LIMIT %1$s
            ) ours_top
            UNION
            SELECT name FROM (
                SELECT ha.name
                FROM hivemind_app.hive_posts hp
                JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
                WHERE hp.community_id IS NOT NULL
                  AND hp.counter_deleted = 0
                  AND hp.created_at <= %2$L
                GROUP BY ha.name
                ORDER BY COUNT(*) DESC
                LIMIT %1$s
            ) theirs_top
        ),
        ours AS (
            SELECT a.name, acd.community,
                   SUM(acd.posts)::BIGINT    AS posts,
                   SUM(acd.comments)::BIGINT AS comments
            FROM haf_stats_backend.account_community_daily acd
            JOIN hafd.accounts a ON a.id = acd.account_id
            WHERE a.name IN (SELECT name FROM sample_accounts)
            GROUP BY a.name, acd.community
        ),
        theirs AS (
            SELECT ha.name, hc.name AS community,
                   COUNT(*) FILTER (WHERE hp.depth = 0)::BIGINT AS posts,
                   COUNT(*) FILTER (WHERE hp.depth > 0)::BIGINT AS comments
            FROM hivemind_app.hive_posts hp
            JOIN hivemind_app.hive_communities hc ON hc.id = hp.community_id
            JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
            WHERE hp.counter_deleted = 0
              AND hp.created_at <= %2$L
              AND ha.name IN (SELECT name FROM sample_accounts)
            GROUP BY ha.name, hc.name
        ),
        joined AS (
            SELECT COALESCE(o.name, t.name)           AS name,
                   COALESCE(o.community, t.community) AS community,
                   COALESCE(o.posts, 0)     AS our_posts,
                   COALESCE(o.comments, 0)  AS our_comments,
                   COALESCE(t.posts, 0)     AS hm_posts,
                   COALESCE(t.comments, 0)  AS hm_comments
            FROM ours o
            FULL JOIN theirs t ON t.name = o.name AND t.community = o.community
        )
        SELECT
            COUNT(*) FILTER (WHERE our_posts < hm_posts OR our_comments < hm_comments),
            COUNT(*),
            COALESCE(SUM((our_posts - hm_posts) + (our_comments - hm_comments)), 0),
            COALESCE((
                SELECT FORMAT('%%s/%%s ours=%%s+%%s hivemind=%%s+%%s',
                              name, community, our_posts, our_comments, hm_posts, hm_comments)
                FROM joined
                WHERE our_posts < hm_posts OR our_comments < hm_comments
                ORDER BY (hm_posts - our_posts) + (hm_comments - our_comments) DESC
                LIMIT 1
            ), '(none)')
        FROM joined
    $q$, _sample, _our_head_time) INTO _undercounts, _compared, _excess, _worst;

    -- FULL JOIN + COALESCE(...,0) is what makes the missing-account case visible: an
    -- account hivemind credits and we do not appears with our_posts = 0, which is an
    -- undercount rather than a silently absent row.

    IF _unknown_communities <> 0 OR _missing_registrations <> 0
       OR _title_mismatches <> 0 OR _undercounts <> 0 THEN
        RAISE EXCEPTION E'community derivation disagrees with hivemind:\n'
            '  % community name(s) we attribute content to are unknown to hivemind\n'
            '  % hivemind community/ies we never registered (their posts fall to the personal-blog bucket)\n'
            '  % title(s) differ from hivemind (check the owner/admin gate in process_community_registry)\n'
            '  % (account, community) pair(s) where we counted FEWER than hivemind - worst: %',
            _unknown_communities, _missing_registrations, _title_mismatches, _undercounts, _worst;
    END IF;

    RAISE NOTICE 'community oracle OK: % (account, community) pairs across the top % community authors match hivemind, with +% creations we count that hivemind no longer shows live (deleted content, as expected); community names, registrations and titles all agree.',
        _compared, _sample, _excess;
END;
$$;
