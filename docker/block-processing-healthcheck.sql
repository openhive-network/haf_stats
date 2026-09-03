-- Block-processing liveness predicate for docker/block-processing-healthcheck.sh (#57).
-- Returns exactly one boolean; the shell compares it to 't'.
--
-- IN A FILE, not interpolated into a shell string, for two reasons carried over from
-- the sibling implementation in hive/haf_fyp (!50):
--
-- 1. It is the only way to test it. Built by shell interpolation, the tests can only
--    grep the assembled command for substrings -- and a substring search cannot tell
--    `a - b` from `b - a`. Swapping the operands of the subtraction below makes the
--    difference permanently negative, so the freshness test is always true and a wedged
--    main() reports healthy forever; every substring assertion still passes. As a file
--    the whole expression is compared against an expected one, which no operand swap,
--    prepended tautology or wrapped call survives.
-- 2. psql's :'var' substitution quotes and escapes, so nothing here is built by string
--    concatenation. The shell still validates :max_age, but as belt-and-braces rather
--    than as the only defence.
--
-- Parameters, all supplied with -v by the caller:
--   context       HAF context name (haf_stats)
--   max_age       whole seconds the loop may go without iterating
--   startup_time  when THIS container started processing, from the server's clock
--
-- NO `SET TIME ZONE`. last_active_at is `timestamp WITHOUT time zone`, written by HAF
-- as NOW() in the WRITER SESSION's zone. Upstream forces the reader to UTC, which does
-- not convert that value -- it only makes the reader assume it is UTC -- so on a server
-- ahead of UTC the difference goes negative and the freshness test passes forever.
-- Reading with now()::timestamp keeps both operands in one frame.
--
-- Be precise about WHICH frame: now()::timestamp renders in the SESSION's TimeZone, not
-- the server's. What makes it correct is that writer and reader resolve to the same
-- setting -- true here because both run against the same server default. A per-role
-- `ALTER ROLE ... SET TimeZone`, a per-database setting, or PGTZ in one context and not
-- the other reintroduces the identical fail-open; so does a server zone that observes
-- DST, across a fall-back transition. Measured on this deployment: the server runs
-- Etc/UTC, which has neither problem.
--
-- scripts/process_blocks.sh takes startup_time from the same server clock for the same
-- reason, so all three values are commensurable.

SELECT
    (
        -- The loop iterated recently...
        (now()::timestamp - (SELECT c.last_active_at FROM hafd.contexts AS c WHERE c.name = :'context'))
            < (:'max_age' || ' seconds')::interval
        -- ...and did so in THIS container, not before a restart.
        AND (SELECT c.last_active_at FROM hafd.contexts AS c WHERE c.name = :'context')
            > :'startup_time'::timestamp
    )
    -- Or there is simply nothing left to process. Upstream ships this arm and it is
    -- kept for parity, but be clear about its cost: it is OR-ed, so it can report
    -- healthy without the freshness test passing at all -- including right after a
    -- restart of an in-sync app, and when hived stops (consistent_block freezes, the app
    -- catches up within a block or two, and this stays true regardless of whether the
    -- loop is alive). This check cannot see chain staleness; only the HAProxy
    -- agent-check can, and that is deferred to the module-file work.
    OR hive.is_app_in_sync(:'context');
