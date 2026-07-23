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
-- content: one row per currently-LIVE post/comment, with hivemind's own community_id and
-- depth. That difference is the point — hivemind shows live content while haf_stats counts
-- creations, so alice (p4 created twice) and erin (p5 created twice) must come out as an
-- expected EXCESS on our side rather than a mismatch.

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

CREATE TABLE IF NOT EXISTS hivemind_app.hive_posts (
    id INTEGER PRIMARY KEY,
    author_id INTEGER NOT NULL,
    community_id INTEGER,
    depth SMALLINT NOT NULL,
    counter_deleted INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL
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
    (47007, 'erin')
ON CONFLICT (id) DO NOTHING;

-- Live content only. p4 and p5 each appear ONCE despite being created twice (delete ->
-- re-create), which is precisely the creations-vs-live gap the oracle tolerates in our
-- favour but not against us.
INSERT INTO hivemind_app.hive_posts (id, author_id, community_id, depth, counter_deleted, created_at)
VALUES
    (1, 47002, 1,    0, 0, '2019-10-01 12:00:00'),   -- alice/p1
    (2, 47003, 1,    1, 0, '2019-10-01 12:00:00'),   -- bob/c1
    (3, 47004, 1,    2, 0, '2019-10-01 12:00:00'),   -- carol/c2
    (4, 47002, 1,    3, 0, '2019-10-01 12:00:00'),   -- alice/c3
    (5, 47002, 1,    0, 0, '2019-10-01 12:00:00'),   -- alice/p4 (live copy)
    (6, 47003, 1,    1, 0, '2019-10-01 12:00:00'),   -- bob/c4
    (7, 47007, 1,    0, 0, '2019-10-02 12:00:00'),   -- erin/p5 (live copy)
    -- Outside any community: hivemind leaves community_id NULL, and so do we.
    (8, 47003, NULL, 0, 0, '2019-10-01 12:00:00'),   -- bob/p2  (unregistered hive-200002)
    (9, 47004, NULL, 0, 0, '2019-10-01 12:00:00'),   -- carol/p3 (legacy tag)
    (10, 47005, NULL, 1, 0, '2019-10-01 12:00:00')   -- dave/c5 (reply below a non-community root)
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
