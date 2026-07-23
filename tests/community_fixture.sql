-- Deterministic community-activity fixture (issue #47).
--
-- This is the ONLY place the community code path is executed against data, because the
-- real 5M-block replay the pattern tests run on is 2016 chain history: communities did
-- not exist until block 37,500,000 (2019), so that replay contains zero community
-- categories and zero hive-* accounts and can only ever prove the empty path.
--
-- Everything below therefore lives at/after that start block. Blocks stay inside ONE
-- 1200-block refresh bucket (37,500,000-37,501,199) so process_content_stats' boundary
-- hook never fires and the period rollups other tavern tests assert on are left alone.
-- The block rows carry the same vesting values as the other fixtures so they do not
-- move get_network_hp_distribution's VESTS/HP ratio (see ci_setup.sql).
--
-- Note on op ids: the stub numbers vote_operation as 1 (ci_setup.sql), but the
-- processors match the REAL chain ids numerically — 1 = comment_operation,
-- 17 = delete_comment_operation, 18 = custom_json_operation. The fixture uses the real
-- ids, which is what the code under test reads; only the human-readable name mapping in
-- hafd.operation_types differs, and nothing in this path joins it except the
-- account_created lookup, which is resolved BY NAME below.

INSERT INTO hafd.operation_types (id, name, is_virtual)
VALUES
    (17, 'hive::protocol::delete_comment_operation', FALSE),
    (100, 'hive::protocol::account_created_operation', TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO hafd.accounts (id, name)
VALUES
    (47001, 'hive-100001'),   -- the community account (its own initial owner)
    (47002, 'alice'),         -- promoted to admin mid-batch; posts + replies
    (47003, 'bob'),
    (47004, 'carol'),
    (47005, 'dave'),
    (47006, 'mallory'),       -- no role: their updateProps must be ignored
    (47007, 'erin'),          -- delete -> re-create spanning two days in ONE batch
    (47008, 'frank'),         -- root -> delete -> re-create as a REPLY, same day
    (47009, 'grace'),         -- community post re-created OUTSIDE any community
    (47010, 'heidi')          -- replies under grace's post, before and after the switch
ON CONFLICT (id) DO NOTHING;

-- Two days inside the SAME 1200-block refresh bucket. The day boundary at 37500030 is
-- deliberate: a batch that spans it must still credit each creation to its own day.
INSERT INTO hafd.blocks (num, created_at, total_vesting_shares, total_vesting_fund_hive)
SELECT n, '2019-10-01 12:00:00'::TIMESTAMP, 1000000000, 1000000000
FROM GENERATE_SERIES(37500000, 37500029) AS n
ON CONFLICT (num) DO NOTHING;

INSERT INTO hafd.blocks (num, created_at, total_vesting_shares, total_vesting_fund_hive)
SELECT n, '2019-10-02 12:00:00'::TIMESTAMP, 1000000000, 1000000000
FROM GENERATE_SERIES(37500030, 37500045) AS n
ON CONFLICT (num) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Community registration, roles and titles
-- ---------------------------------------------------------------------------

-- hive-100001 is created -> registered as a type-1 (topic) community, owner = itself.
INSERT INTO hafd.operations (id, op_type_id, body_value)
SELECT
    hafd.operation_id(37500001, 1),
    (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::account_created_operation'),
    JSONB_BUILD_OBJECT('new_account_name', 'hive-100001')
ON CONFLICT (id) DO NOTHING;

INSERT INTO hafd.operations (id, op_type_id, body_value)
VALUES
    -- The owner names the community.
    (hafd.operation_id(37500002, 1), 18, JSONB_BUILD_OBJECT(
        'id', 'community',
        'required_auths', '[]'::JSONB,
        'required_posting_auths', JSONB_BUILD_ARRAY('hive-100001'),
        'json', '["updateProps",{"community":"hive-100001","props":{"title":"Test Topic"}}]')),
    -- mallory holds no role: this rename MUST be dropped, or any account could retitle
    -- any community.
    (hafd.operation_id(37500003, 1), 18, JSONB_BUILD_OBJECT(
        'id', 'community',
        'required_auths', '[]'::JSONB,
        'required_posting_auths', JSONB_BUILD_ARRAY('mallory'),
        'json', '["updateProps",{"community":"hive-100001","props":{"title":"HACKED"}}]')),
    -- The owner promotes alice to admin...
    (hafd.operation_id(37500004, 1), 18, JSONB_BUILD_OBJECT(
        'id', 'community',
        'required_auths', '[]'::JSONB,
        'required_posting_auths', JSONB_BUILD_ARRAY('hive-100001'),
        'json', '["setRole",{"community":"hive-100001","account":"alice","role":"admin"}]')),
    -- ...and alice immediately uses it, IN THE SAME BATCH. This only works because the
    -- role/title pass replays in op order rather than as one set-based statement.
    (hafd.operation_id(37500005, 1), 18, JSONB_BUILD_OBJECT(
        'id', 'community',
        'required_auths', '[]'::JSONB,
        'required_posting_auths', JSONB_BUILD_ARRAY('alice'),
        'json', '["updateProps",{"community":"hive-100001","props":{"title":"Test Community"}}]')),
    -- custom_json.json is a free-form string; a malformed one is normal on-chain and must
    -- not abort the batch.
    (hafd.operation_id(37500006, 1), 18, JSONB_BUILD_OBJECT(
        'id', 'community',
        'required_auths', '[]'::JSONB,
        'required_posting_auths', JSONB_BUILD_ARRAY('alice'),
        'json', 'this is not json at all')),
    -- Well-formed JSON naming a community that was never registered: ignored.
    (hafd.operation_id(37500007, 1), 18, JSONB_BUILD_OBJECT(
        'id', 'community',
        'required_auths', '[]'::JSONB,
        'required_posting_auths', JSONB_BUILD_ARRAY('alice'),
        'json', '["updateProps",{"community":"hive-200002","props":{"title":"Ghost"}}]'))
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Content. Batch 1 (blocks 37500001-37500019) contains a root post AND its whole
-- 3-deep reply chain: the in-batch-parent case that a plain comment_registry lookup
-- gets wrong, since none of those parents are visible to the statement that writes them.
-- ---------------------------------------------------------------------------

INSERT INTO hafd.operations (id, op_type_id, body_value)
VALUES
    -- alice posts into the community.
    (hafd.operation_id(37500010, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'alice', 'permlink', 'p1',
        'parent_author', '', 'parent_permlink', 'hive-100001')),
    -- depth 1 -> 3, each parent created in this same batch.
    (hafd.operation_id(37500011, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'bob', 'permlink', 'c1',
        'parent_author', 'alice', 'parent_permlink', 'p1')),
    (hafd.operation_id(37500012, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'carol', 'permlink', 'c2',
        'parent_author', 'bob', 'parent_permlink', 'c1')),
    (hafd.operation_id(37500013, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'alice', 'permlink', 'c3',
        'parent_author', 'carol', 'parent_permlink', 'c2')),
    -- EDIT of p1 (same author+permlink): must not count a second post.
    (hafd.operation_id(37500014, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'alice', 'permlink', 'p1',
        'parent_author', '', 'parent_permlink', 'hive-100001')),
    -- Structurally valid community name that was never registered -> no community.
    (hafd.operation_id(37500015, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'bob', 'permlink', 'p2',
        'parent_author', '', 'parent_permlink', 'hive-200002')),
    -- Legacy tag category -> no community.
    (hafd.operation_id(37500016, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'carol', 'permlink', 'p3',
        'parent_author', '', 'parent_permlink', 'photography')),
    -- create -> delete -> re-create inside one batch: two creations of one key.
    (hafd.operation_id(37500017, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'alice', 'permlink', 'p4',
        'parent_author', '', 'parent_permlink', 'hive-100001')),
    (hafd.operation_id(37500018, 1), 17, JSONB_BUILD_OBJECT(
        'author', 'alice', 'permlink', 'p4')),
    (hafd.operation_id(37500019, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'alice', 'permlink', 'p4',
        'parent_author', '', 'parent_permlink', 'hive-100001'))
ON CONFLICT (id) DO NOTHING;

-- Batch 2: replies whose parents were created in an EARLIER batch — the other resolution
-- path, where the parent's community comes from comment_registry rather than the stage.
INSERT INTO hafd.operations (id, op_type_id, body_value)
VALUES
    (hafd.operation_id(37500020, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'bob', 'permlink', 'c4',
        'parent_author', 'alice', 'parent_permlink', 'p1')),
    (hafd.operation_id(37500021, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'dave', 'permlink', 'c5',
        'parent_author', 'bob', 'parent_permlink', 'p2')),
    -- erin: create -> delete -> re-create where the re-creation lands on the NEXT DAY,
    -- still inside this one batch. Each creation must be credited to its own day; a stage
    -- keyed per comment (rather than per comment+day) would move both onto 10-02, pushing
    -- that day's community count above account_content_daily and corrupting the
    -- endpoint's subtracted personal-blog bucket.
    (hafd.operation_id(37500025, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'erin', 'permlink', 'p5',
        'parent_author', '', 'parent_permlink', 'hive-100001')),
    (hafd.operation_id(37500026, 1), 17, JSONB_BUILD_OBJECT(
        'author', 'erin', 'permlink', 'p5')),
    (hafd.operation_id(37500031, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'erin', 'permlink', 'p5',
        'parent_author', '', 'parent_permlink', 'hive-100001')),

    -- frank: ROOT -> delete -> re-create as a REPLY, same key, same day, one batch.
    -- This shape exists on mainnet (testing001/'testing6', blocks 4010780/4011017/4011023,
    -- all 2016-08-12). Staging per (key, day) collapsed both creations onto the LAST one,
    -- crediting 2 comments and 0 posts while account_content_daily correctly recorded
    -- 1 post + 1 comment - the endpoint's buckets then stopped summing to
    -- get_account_content_stats, and the GREATEST() clamp hid it.
    (hafd.operation_id(37500032, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'frank', 'permlink', 'f1',
        'parent_author', '', 'parent_permlink', 'hive-100001')),
    (hafd.operation_id(37500033, 1), 17, JSONB_BUILD_OBJECT(
        'author', 'frank', 'permlink', 'f1')),
    (hafd.operation_id(37500034, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'frank', 'permlink', 'f1',
        'parent_author', 'alice', 'parent_permlink', 'p1')),

    -- grace: a community post, a reply beneath it, then the post is deleted and re-created
    -- OUTSIDE any community, then another reply. Three separate bugs meet here:
    --   * the stored community must be CLEARED on the re-creation, or every later reply
    --     inherits a community the post no longer belongs to;
    --   * heidi's FIRST reply was made while the post was still in the community, so it
    --     must keep that community rather than follow the parent's end-of-batch state;
    --   * grace's two creations must be credited to different buckets, not both to the
    --     community the key ended up in.
    (hafd.operation_id(37500035, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'grace', 'permlink', 'g1',
        'parent_author', '', 'parent_permlink', 'hive-100001')),
    (hafd.operation_id(37500036, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'heidi', 'permlink', 'h1',
        'parent_author', 'grace', 'parent_permlink', 'g1')),
    (hafd.operation_id(37500037, 1), 17, JSONB_BUILD_OBJECT(
        'author', 'grace', 'permlink', 'g1')),
    (hafd.operation_id(37500038, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'grace', 'permlink', 'g1',
        'parent_author', '', 'parent_permlink', 'photography')),
    (hafd.operation_id(37500039, 1), 1, JSONB_BUILD_OBJECT(
        'author', 'heidi', 'permlink', 'h2',
        'parent_author', 'grace', 'parent_permlink', 'g1'))
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Run the real processors, in the same order process_block_range does.
-- ---------------------------------------------------------------------------

-- Batch 2 deliberately spans the 10-01/10-02 day boundary.
SELECT haf_stats_app.process_community_registry(37500001, 37500019);
SELECT haf_stats_app.process_content_stats(37500001, 37500019);
SELECT haf_stats_app.process_community_registry(37500020, 37500045);
SELECT haf_stats_app.process_content_stats(37500020, 37500045);

-- ---------------------------------------------------------------------------
-- Assertions — live path
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    _title TEXT;
    _type SMALLINT;
    _roles INT;
    _n INT;
BEGIN
    SELECT title, type_id INTO _title, _type
    FROM haf_stats_backend.community_registry WHERE community = 'hive-100001';

    IF _title IS DISTINCT FROM 'Test Community' THEN
        RAISE EXCEPTION 'community title: expected "Test Community" (owner set it, mallory''s rename ignored, alice''s admin rename applied), got %', COALESCE(_title, '(null)');
    END IF;
    IF _type <> 1 THEN
        RAISE EXCEPTION 'community type_id: expected 1 (topic, from the leading digit), got %', _type;
    END IF;

    SELECT COUNT(*) INTO _n FROM haf_stats_backend.community_registry;
    IF _n <> 1 THEN
        RAISE EXCEPTION 'community_registry: expected exactly 1 registered community, got %', _n;
    END IF;

    -- owner (the community account) + alice as admin; mallory must have none.
    SELECT COUNT(*) INTO _roles FROM haf_stats_backend.community_role
    WHERE community = 'hive-100001';
    IF _roles <> 2 THEN
        RAISE EXCEPTION 'community_role: expected 2 rows (owner + alice admin), got %', _roles;
    END IF;

    -- Every comment in the thread inherits the ROOT's community, at any depth, whether
    -- its parent was created in the same batch (c1/c2/c3) or an earlier one (c4).
    SELECT COUNT(*) INTO _n
    FROM haf_stats_backend.comment_registry r
    JOIN hafd.accounts a ON a.id = r.author_id
    WHERE r.community = 'hive-100001'
      AND (a.name, r.permlink) IN
          (('alice', 'p1'), ('bob', 'c1'), ('carol', 'c2'), ('alice', 'c3'),
           ('alice', 'p4'), ('bob', 'c4'));
    IF _n <> 6 THEN
        RAISE EXCEPTION 'comment community inheritance: expected all 6 thread members mapped to hive-100001, got %', _n;
    END IF;

    -- The unregistered-community post, the legacy-tag post, and the reply below a
    -- non-community root must all stay NULL.
    SELECT COUNT(*) INTO _n
    FROM haf_stats_backend.comment_registry r
    JOIN hafd.accounts a ON a.id = r.author_id
    WHERE r.community IS NOT NULL
      AND (a.name, r.permlink) IN (('bob', 'p2'), ('carol', 'p3'), ('dave', 'c5'));
    IF _n <> 0 THEN
        RAISE EXCEPTION 'expected no community for the unregistered/legacy/non-community-reply content, got % mapped row(s)', _n;
    END IF;

    -- The 6 thread members above plus erin's re-created p5.
    -- alice/p1, bob/c1, carol/c2, alice/c3, alice/p4, bob/c4, erin/p5, frank/f1, heidi/h1.
    -- grace/g1 is deliberately NOT here: it was re-created outside any community.
    SELECT COUNT(*) INTO _n FROM haf_stats_backend.comment_registry WHERE community IS NOT NULL;
    IF _n <> 9 THEN
        RAISE EXCEPTION 'comment_registry: expected exactly 9 community-mapped comments, got %', _n;
    END IF;
END;
$$;

-- Rollup values, including the delete -> re-create double creation and the
-- reconciliation invariant the endpoint's personal-blog bucket depends on.
DO $$
DECLARE
    _r RECORD;
    _bad INT;
BEGIN
    FOR _r IN
        SELECT * FROM (VALUES
            -- alice: p1 + p4 twice = 3 posts, c3 = 1 comment
            ('alice', 3, 1),
            -- bob: no community posts (p2 is unregistered), c1 + c4 = 2 comments
            ('bob',   0, 2),
            -- carol: p3 is a legacy tag, c2 is in the community
            ('carol', 0, 1)
        ) AS t(account, posts, comments)
    LOOP
        SELECT COUNT(*) INTO _bad
        FROM haf_stats_backend.account_community_daily acd
        JOIN hafd.accounts a ON a.id = acd.account_id
        WHERE a.name = _r.account
          AND acd.community = 'hive-100001'
          AND acd.day = DATE '2019-10-01'
          AND acd.posts = _r.posts
          AND acd.comments = _r.comments;
        IF _bad <> 1 THEN
            RAISE EXCEPTION 'account_community_daily for %: expected posts=% comments=% on 2019-10-01, got %',
                _r.account, _r.posts, _r.comments,
                COALESCE((SELECT FORMAT('posts=%s comments=%s', acd.posts, acd.comments)
                          FROM haf_stats_backend.account_community_daily acd
                          JOIN hafd.accounts a ON a.id = acd.account_id
                          WHERE a.name = _r.account AND acd.community = 'hive-100001'
                            AND acd.day = DATE '2019-10-01'), '(no row)');
        END IF;
    END LOOP;

    -- dave only replied below a non-community post, so he must have no community row.
    SELECT COUNT(*) INTO _bad
    FROM haf_stats_backend.account_community_daily acd
    JOIN hafd.accounts a ON a.id = acd.account_id
    WHERE a.name = 'dave';
    IF _bad <> 0 THEN
        RAISE EXCEPTION 'dave should have no community activity, got % row(s)', _bad;
    END IF;

    -- erin's two creations of p5 straddle a day boundary inside ONE batch: exactly one
    -- post on each day, never two on the later one.
    SELECT COUNT(*) INTO _bad
    FROM haf_stats_backend.account_community_daily acd
    JOIN hafd.accounts a ON a.id = acd.account_id
    WHERE a.name = 'erin'
      AND acd.community = 'hive-100001'
      AND acd.posts = 1
      AND acd.comments = 0
      AND acd.day IN (DATE '2019-10-01', DATE '2019-10-02');
    IF _bad <> 2 THEN
        RAISE EXCEPTION 'erin''s delete/re-create across a day boundary: expected 1 post on EACH of 2019-10-01 and 2019-10-02, got % matching row(s) out of %',
            _bad,
            (SELECT COALESCE(STRING_AGG(FORMAT('%s:posts=%s', acd.day, acd.posts), ' '), '(none)')
             FROM haf_stats_backend.account_community_daily acd
             JOIN hafd.accounts a ON a.id = acd.account_id
             WHERE a.name = 'erin');
    END IF;

    -- frank's key was created once as a ROOT in the community and once as a REPLY under a
    -- community post: one post AND one comment, both in hive-100001.
    SELECT COUNT(*) INTO _bad
    FROM haf_stats_backend.account_community_daily acd
    JOIN hafd.accounts a ON a.id = acd.account_id
    WHERE a.name = 'frank' AND acd.community = 'hive-100001'
      AND acd.posts = 1 AND acd.comments = 1;
    IF _bad <> 1 THEN
        RAISE EXCEPTION 'frank root->reply flip: expected posts=1 comments=1 in hive-100001, got %',
            COALESCE((SELECT FORMAT('posts=%s comments=%s', acd.posts, acd.comments)
                      FROM haf_stats_backend.account_community_daily acd
                      JOIN hafd.accounts a ON a.id = acd.account_id
                      WHERE a.name = 'frank'), '(no row)');
    END IF;

    -- grace: one creation into the community, one outside it. Only the first counts here.
    SELECT COUNT(*) INTO _bad
    FROM haf_stats_backend.account_community_daily acd
    JOIN hafd.accounts a ON a.id = acd.account_id
    WHERE a.name = 'grace' AND acd.community = 'hive-100001' AND acd.posts = 1;
    IF _bad <> 1 THEN
        RAISE EXCEPTION 'grace community->personal re-creation: expected exactly 1 post credited to hive-100001, got %',
            COALESCE((SELECT FORMAT('posts=%s', acd.posts)
                      FROM haf_stats_backend.account_community_daily acd
                      JOIN hafd.accounts a ON a.id = acd.account_id
                      WHERE a.name = 'grace' AND acd.community = 'hive-100001'), '(no row)');
    END IF;

    -- The re-creation left the community, so the stored value must be CLEARED - otherwise
    -- every later reply inherits a community the post no longer belongs to.
    IF (SELECT r.community FROM haf_stats_backend.comment_registry r
        JOIN hafd.accounts a ON a.id = r.author_id
        WHERE a.name = 'grace' AND r.permlink = 'g1') IS NOT NULL THEN
        RAISE EXCEPTION 'grace/g1 was re-created outside any community, but comment_registry.community was not cleared';
    END IF;

    -- heidi replied twice to the same key: once while it was in the community (h1, must
    -- keep it) and once after it left (h2, must have none). Point-in-time inheritance.
    IF (SELECT r.community FROM haf_stats_backend.comment_registry r
        JOIN hafd.accounts a ON a.id = r.author_id
        WHERE a.name = 'heidi' AND r.permlink = 'h1') IS DISTINCT FROM 'hive-100001' THEN
        RAISE EXCEPTION 'heidi/h1 was posted while its parent was still in hive-100001 and must keep that community, got %',
            COALESCE((SELECT r.community FROM haf_stats_backend.comment_registry r
                      JOIN hafd.accounts a ON a.id = r.author_id
                      WHERE a.name = 'heidi' AND r.permlink = 'h1'), '(null)');
    END IF;

    IF (SELECT r.community FROM haf_stats_backend.comment_registry r
        JOIN hafd.accounts a ON a.id = r.author_id
        WHERE a.name = 'heidi' AND r.permlink = 'h2') IS NOT NULL THEN
        RAISE EXCEPTION 'heidi/h2 was posted after its parent left the community and must have none';
    END IF;

    -- The endpoint derives "Personal blog / No community" by subtraction, so the
    -- community counts must never exceed the per-account totals.
    SELECT COUNT(*) INTO _bad FROM (
        SELECT acd.account_id, acd.day
        FROM haf_stats_backend.account_community_daily acd
        GROUP BY acd.account_id, acd.day
        HAVING SUM(acd.posts) > COALESCE((
                   SELECT t.posts FROM haf_stats_backend.account_content_daily t
                   WHERE t.account_id = acd.account_id AND t.day = acd.day), -1)
            OR SUM(acd.comments) > COALESCE((
                   SELECT t.comments FROM haf_stats_backend.account_content_daily t
                   WHERE t.account_id = acd.account_id AND t.day = acd.day), -1)
    ) x;
    IF _bad <> 0 THEN
        RAISE EXCEPTION 'account_community_daily exceeds account_content_daily for % (account, day) pair(s)', _bad;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Assertions — rebuild path (process_content_volume)
--
-- tests/parity/content_volume_rebuild_consistency.sql covers this on real data, but the
-- real replay has no community rows to compare, so the twin's community output is only
-- ever exercised here. Replaying the whole fixture as ONE batch also deepens the
-- in-batch chain the resolver has to walk.
-- ---------------------------------------------------------------------------

-- Scoped to this fixture's accounts/day so it stays correct if ci_setup ever seeds these
-- tables for another test.
CREATE TEMP TABLE _live_community AS
    SELECT * FROM haf_stats_backend.account_community_daily
    WHERE account_id BETWEEN 47001 AND 47010;
CREATE TEMP TABLE _live_mapping AS
    SELECT author_id, permlink, community FROM haf_stats_backend.comment_registry
    WHERE author_id BETWEEN 47001 AND 47010;

DELETE FROM haf_stats_backend.account_community_daily WHERE account_id BETWEEN 47001 AND 47010;
DELETE FROM haf_stats_backend.comment_registry WHERE author_id BETWEEN 47001 AND 47010;
DELETE FROM haf_stats_backend.network_content_daily WHERE day IN (DATE '2019-10-01', DATE '2019-10-02');
DELETE FROM haf_stats_backend.network_author_daily WHERE day IN (DATE '2019-10-01', DATE '2019-10-02');
UPDATE haf_stats_backend.account_content_daily
   SET posts = 0, comments = 0, replies_received = 0
 WHERE day IN (DATE '2019-10-01', DATE '2019-10-02');

SELECT haf_stats_app.process_content_volume(37500001, 37500045);

DO $$
DECLARE
    _diff INT;
BEGIN
    SELECT COUNT(*) INTO _diff FROM (
        (SELECT account_id, day, community, posts, comments
           FROM haf_stats_backend.account_community_daily
          WHERE account_id BETWEEN 47001 AND 47010
         EXCEPT
         SELECT account_id, day, community, posts, comments FROM _live_community)
        UNION ALL
        (SELECT account_id, day, community, posts, comments FROM _live_community
         EXCEPT
         SELECT account_id, day, community, posts, comments
           FROM haf_stats_backend.account_community_daily
          WHERE account_id BETWEEN 47001 AND 47010)
    ) d;
    IF _diff <> 0 THEN
        RAISE EXCEPTION 'process_content_volume produced % account_community_daily row(s) differing from the live path', _diff;
    END IF;

    SELECT COUNT(*) INTO _diff FROM (
        (SELECT author_id, permlink, community FROM haf_stats_backend.comment_registry
          WHERE author_id BETWEEN 47001 AND 47010
         EXCEPT
         SELECT author_id, permlink, community FROM _live_mapping)
        UNION ALL
        (SELECT author_id, permlink, community FROM _live_mapping
         EXCEPT
         SELECT author_id, permlink, community FROM haf_stats_backend.comment_registry
          WHERE author_id BETWEEN 47001 AND 47010)
    ) d;
    IF _diff <> 0 THEN
        RAISE EXCEPTION 'process_content_volume produced % comment_registry row(s) differing from the live path (community resolution drifted between the two comment-scan paths)', _diff;
    END IF;

    RAISE NOTICE 'community fixture OK: registry/roles/titles, in-batch and cross-batch inheritance, edit + delete-re-create counting, and live-vs-rebuild agreement all verified';
END;
$$;

DROP TABLE _live_community;
DROP TABLE _live_mapping;
