-- Minimal hivemind_app test double, so tests/parity/community_vs_hivemind.sql's ACTIVE
-- path is exercised in CI (issue #47).
--
-- Without this the oracle is dead code until it first runs on a production node: every
-- hivemind query in it is dynamic SQL (EXECUTE), which is only parsed when a hivemind_app
-- schema actually exists, so a typo or a wrong column name would hide until then.
-- Stubbing an external schema for exactly this reason is the same posture ci_setup.sql
-- takes for btracker_app.current_account_balances.
--
-- The rows mirror what hivemind WOULD hold for tests/community_fixture.sql's synthetic
-- content: one row per CREATION, as hive_posts keeps it -- a deleted post stays, with
-- counter_deleted > 0, and its re-creation is a new row -- with hivemind's own community_id,
-- depth, parent, permlink and block_num_created, ids in creation order. The oracle reads only
-- the live rows (counter_deleted = 0), and that difference is its point: hivemind shows live
-- content while haf_stats counts creations, so alice (p4 created twice) and erin (p5 created
-- twice) must come out as an expected EXCESS on our side rather than a mismatch.
--
-- The full creation set is what tests/ci_hivemind_source.sql runs the hivemind content source
-- over (db/process_content_stats.sql, "Content source"), asserting it produces what the
-- internal source produces from the raw ops. frank, grace and heidi -- the root -> reply flip
-- and the community -> personal re-creation -- are here for that; their live rows the oracle
-- sees match ours, so its expected excess stays two.

CREATE SCHEMA IF NOT EXISTS hivemind_app;

CREATE TABLE IF NOT EXISTS hivemind_app.hive_communities (
    id INTEGER PRIMARY KEY,
    type_id SMALLINT NOT NULL,
    name VARCHAR(16) NOT NULL,
    title VARCHAR(32) NOT NULL DEFAULT '',
    -- The oracle bounds hivemind's side by our processed head, so it needs to know when
    -- each community was registered; default keeps the generated mainnet fixture's
    -- column-less INSERT working.
    created_at TIMESTAMP NOT NULL DEFAULT '2019-01-01 00:00:00'
);

ALTER TABLE hivemind_app.hive_communities
ADD COLUMN IF NOT EXISTS created_at TIMESTAMP NOT NULL DEFAULT '2019-01-01 00:00:00';

CREATE TABLE IF NOT EXISTS hivemind_app.hive_accounts (
    id INTEGER PRIMARY KEY,
    name VARCHAR(16) NOT NULL
);

-- permlink_id/parent_id/root_id/block_num_created are nullable here only because
-- tests/mainnet_community_fixture.sql mirrors its nodes without them; those rows carry no
-- block_num_created, so the hivemind content source never reads them.
CREATE TABLE IF NOT EXISTS hivemind_app.hive_posts (
    id INTEGER PRIMARY KEY,
    author_id INTEGER NOT NULL,
    community_id INTEGER,
    depth SMALLINT NOT NULL,
    counter_deleted INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL,
    permlink_id INTEGER,
    parent_id INTEGER,
    root_id INTEGER,
    block_num_created INTEGER
);

CREATE TABLE IF NOT EXISTS hivemind_app.hive_permlink_data (
    id INTEGER PRIMARY KEY,
    permlink VARCHAR(255) NOT NULL UNIQUE
);

INSERT INTO hivemind_app.hive_communities (id, type_id, name, title)
VALUES (1, 1, 'hive-100001', 'Test Community')
ON CONFLICT (id) DO NOTHING;

INSERT INTO hivemind_app.hive_accounts (id, name)
VALUES
    (47001, 'hive-100001'),
    (47002, 'alice'),
    (47003, 'bob'),
    (47004, 'carol'),
    (47005, 'dave'),
    (47007, 'erin'),
    (47008, 'frank'),
    (47009, 'grace'),
    (47010, 'heidi')
ON CONFLICT (id) DO NOTHING;

INSERT INTO hivemind_app.hive_permlink_data (id, permlink)
VALUES
    (1, 'p1'), (2, 'c1'), (3, 'c2'), (4, 'c3'), (5, 'p2'), (6, 'p3'), (7, 'p4'),
    (8, 'c4'), (9, 'c5'), (10, 'p5'), (11, 'f1'), (12, 'g1'), (13, 'h1'), (14, 'h2')
ON CONFLICT (id) DO NOTHING;

-- Every creation of tests/community_fixture.sql, in op order. hivemind sets a reply's
-- community_id from its parent, so a thread carries its root's community; created_at is 3 s
-- before the block, as hivemind records it. The comment op at 37500014 is an edit of p1, so
-- it has no row.
INSERT INTO hivemind_app.hive_posts
    (id, author_id, community_id, depth, counter_deleted, created_at,
     permlink_id, parent_id, root_id, block_num_created)
VALUES
    (1,  47002, 1,    0, 0, '2019-10-01 11:59:57', 1,  0,  1,  37500010),   -- alice/p1
    (2,  47003, 1,    1, 0, '2019-10-01 11:59:57', 2,  1,  1,  37500011),   -- bob/c1
    (3,  47004, 1,    2, 0, '2019-10-01 11:59:57', 3,  2,  1,  37500012),   -- carol/c2
    (4,  47002, 1,    3, 0, '2019-10-01 11:59:57', 4,  3,  1,  37500013),   -- alice/c3
    -- Outside any community: hivemind leaves community_id NULL, and so do we.
    (5,  47003, NULL, 0, 0, '2019-10-01 11:59:57', 5,  0,  5,  37500015),   -- bob/p2 (unregistered hive-200002)
    (6,  47004, NULL, 0, 0, '2019-10-01 11:59:57', 6,  0,  6,  37500016),   -- carol/p3 (legacy tag)
    (7,  47002, 1,    0, 1, '2019-10-01 11:59:57', 7,  0,  7,  37500017),   -- alice/p4, deleted at 37500018
    (8,  47002, 1,    0, 0, '2019-10-01 11:59:57', 7,  0,  8,  37500019),   -- alice/p4 (live copy)
    (9,  47003, 1,    1, 0, '2019-10-01 11:59:57', 8,  1,  1,  37500020),   -- bob/c4
    (10, 47005, NULL, 1, 0, '2019-10-01 11:59:57', 9,  5,  5,  37500021),   -- dave/c5 (reply below a non-community root)
    (11, 47007, 1,    0, 1, '2019-10-01 11:59:57', 10, 0,  11, 37500025),   -- erin/p5, deleted at 37500026
    (12, 47007, 1,    0, 0, '2019-10-02 11:59:57', 10, 0,  12, 37500031),   -- erin/p5 (live copy, the next day)
    (13, 47008, 1,    0, 1, '2019-10-02 11:59:57', 11, 0,  13, 37500032),   -- frank/f1 as a root, deleted at 37500033
    (14, 47008, 1,    1, 0, '2019-10-02 11:59:57', 11, 1,  1,  37500034),   -- frank/f1 re-created as a reply to alice/p1
    (15, 47009, 1,    0, 1, '2019-10-02 11:59:57', 12, 0,  15, 37500035),   -- grace/g1 in the community, deleted at 37500037
    (16, 47010, 1,    1, 0, '2019-10-02 11:59:57', 13, 15, 15, 37500036),   -- heidi/h1, under the first g1
    (17, 47009, NULL, 0, 0, '2019-10-02 11:59:57', 12, 0,  17, 37500038),   -- grace/g1 re-created as a legacy-tag post
    (18, 47010, NULL, 1, 0, '2019-10-02 11:59:57', 14, 17, 17, 37500039)    -- heidi/h2, under the second g1
ON CONFLICT (id) DO NOTHING;

GRANT USAGE ON SCHEMA hivemind_app TO haf_stats_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA hivemind_app TO haf_stats_owner;

-- Assert the oracle's own arithmetic on this fixture, so a future change to it cannot
-- silently start passing for the wrong reason. Ours minus hivemind must be exactly the two
-- re-creations (alice/p4 and erin/p5) and nothing else.
--
-- SCOPED to this fixture's accounts (47001-47007): tests/mainnet_community_fixture.sql
-- adds real mainnet nodes to BOTH sides, so a global count here would drift every time
-- that sample is regenerated. The oracle itself still compares everything.
DO $$
DECLARE
    _excess BIGINT;
BEGIN
    SELECT
        (SELECT COALESCE(SUM(acd.posts) + SUM(acd.comments), 0)
           FROM haf_stats_backend.account_community_daily acd
          WHERE acd.account_id BETWEEN 47001 AND 47007)
      - (SELECT COUNT(*)
           FROM hivemind_app.hive_posts hp
          WHERE hp.community_id IS NOT NULL
            AND hp.counter_deleted = 0
            AND hp.author_id BETWEEN 47001 AND 47007)
    INTO _excess;

    IF _excess <> 2 THEN
        RAISE EXCEPTION 'hivemind oracle fixture: expected our creations to exceed hivemind''s live rows by exactly 2 (alice/p4 + erin/p5 re-creations), got %', _excess;
    END IF;
END;
$$;
