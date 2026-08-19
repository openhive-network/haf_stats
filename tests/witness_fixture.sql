-- Witness block-production fixtures for get_witness_missed_blocks (#54).
-- Loaded AFTER db/process_witness_blocks.sql so the REAL processor runs over them, the same
-- shape as cohort_fixture.sql / community_fixture.sql. This is what keeps the stub gate from
-- testing only the endpoint: unlike the operation-stream processors, this one reads just
-- hafd.blocks plus one virtual op type, so it is cheap to exercise for real on plain postgres.
--
-- Block nums are deliberately ABOVE every other fixture's (max 6000) and dated after
-- 2021-03-10, so the rc-footprint date->block windows are untouched. The vesting columns
-- mirror the other fixture blocks (1e9/1e9, ratio 1000) because get_network_hp_distribution
-- reads its VESTS/HP ratio from the HIGHEST-num block and asserts an exact value.
--
-- The processor is called over [7000, 7999] only. Every other fixture block carries the
-- producer_account_id DEFAULT 0 (see the hafd.blocks stub in ci_setup.sql), which is not a
-- real account, so scoping the call keeps those phantom rows out of the rollup.
--
-- Four witnesses, chosen so that missed / rate / last_missed each produce a DIFFERENT
-- ordering, and so both null-handling paths are covered:
--
--   wtnalice  produced+missed on both days -> 0 < rate < 1, extremes spanning two days
--   wtnbob    produced only, never missed  -> rate 0, first/last_missed_* NULL
--             (this is the order_by=last_missed NULLS-LAST regression case)
--   wtncarol  missed only, never produced  -> produced_count 0, rate exactly 1
--   wtndave   produced+missed, tying wtnalice's missed_count of 2 -> the tie-break case
--
-- Window totals over [7000, 7999]:
--   wtnalice  produced 7, missed 2, blocks 7001..7504, rate 2/9   = 0.222222
--   wtnbob    produced 4, missed 0, NULL..NULL,        rate 0/4   = 0.000000
--   wtncarol  produced 0, missed 3, blocks 7004..7502, rate 3/3   = 1.000000
--   wtndave   produced 5, missed 2, blocks 7505..7506, rate 2/7   = 0.285714
--
-- The extremes are set so the three orderings genuinely disagree - a test that cannot tell
-- order_by apart proves nothing:
--   order_by=missed       carol(3), [alice(2) TIE dave(2)], bob(0)
--   order_by=last_missed  dave(7506), alice(7504), carol(7502), bob(NULL, last)
--   order_by=rate         carol(1.0), dave(0.2857), alice(0.2222), bob(0.0)
--
-- alice and dave tie at missed_count 2 ON PURPOSE. Ordering by missed then falls entirely to the
-- `producer_account_id ASC` tie-break, and a leaderboard page of 2 cuts THROUGH that tie group -
-- so dropping the tie-break does not merely reshuffle the page, it changes which witness is on it.
-- That is the only shape in which the "the ordering is total, so the page is deterministic"
-- promise can actually fail a test.
--
-- The two days sit in different ISO weeks (2021-06-01 Tue, 2021-06-15 Tue) but the same month.
-- So month collapses them to 1 row while day and week both return 2 - the row COUNT does not
-- separate day from week; the LABEL does (day -> 2021-06-01 / 2021-06-15, week -> the Monday
-- starts 2021-05-31 / 2021-06-14). That is what pins DATE_TRUNC actually being applied rather
-- than the day rows being echoed under a different name.

-- Loaded as the connected superuser, not SET ROLE haf_stats_owner: that role holds only SELECT
-- on hafd, so seeding hafd.accounts under it fails with "permission denied for table accounts".
-- Same shape as cohort_fixture.sql / community_fixture.sql.
INSERT INTO hafd.accounts (id, name) VALUES
    (6001, 'wtnalice'),
    (6002, 'wtnbob'),
    (6003, 'wtncarol'),
    (6004, 'wtndave')
ON CONFLICT DO NOTHING;

-- Day 1 (2021-06-01): alice 4 produced, bob 2 produced.
-- Day 2 (2021-06-15): alice 3 produced, bob 2 produced.
INSERT INTO hafd.blocks
    (num, created_at, total_vesting_shares, total_vesting_fund_hive, producer_account_id)
VALUES
    (7000, '2021-06-01 00:00:00', 1000000000, 1000000000, 6001),
    (7001, '2021-06-01 00:00:03', 1000000000, 1000000000, 6001),
    (7002, '2021-06-01 00:00:06', 1000000000, 1000000000, 6002),
    (7003, '2021-06-01 00:00:09', 1000000000, 1000000000, 6001),
    (7004, '2021-06-01 00:00:12', 1000000000, 1000000000, 6002),
    (7005, '2021-06-01 00:00:15', 1000000000, 1000000000, 6001),
    (7500, '2021-06-15 12:00:00', 1000000000, 1000000000, 6001),
    (7501, '2021-06-15 12:00:03', 1000000000, 1000000000, 6002),
    (7502, '2021-06-15 12:00:06', 1000000000, 1000000000, 6001),
    (7503, '2021-06-15 12:00:09', 1000000000, 1000000000, 6002),
    (7504, '2021-06-15 12:00:12', 1000000000, 1000000000, 6001),
    -- wtndave exists to create a TIE with wtnalice on missed_count (both 2). Without a tie the
    -- documented "missed_count then producer_account_id make the ordering total" claim is
    -- untestable: every other fixture value is distinct, so dropping the tie-break would change
    -- nothing. dave's id (6004) is above alice's (6001), so the tie-break must put alice first.
    (7505, '2021-06-15 12:00:15', 1000000000, 1000000000, 6004),
    (7506, '2021-06-15 12:00:18', 1000000000, 1000000000, 6004),
    (7507, '2021-06-15 12:00:21', 1000000000, 1000000000, 6004),
    (7508, '2021-06-15 12:00:24', 1000000000, 1000000000, 6004),
    (7509, '2021-06-15 12:00:27', 1000000000, 1000000000, 6004)
ON CONFLICT (num) DO NOTHING;

-- producer_missed_operation (op type 86, virtual). body_value is the BARE value object on real
-- HAF - {"producer": "<name>"} - so the processor resolves the NAME to an account id.
-- A miss is recorded in the block that DID get produced, hence ids inside the block range above.
-- Two of wtncarol's misses share block 7502, which is what proves the count is a COUNT(*) of
-- miss events and not a count of distinct blocks - consecutive missed slots are the normal
-- shape of a real witness outage.
INSERT INTO hafd.operations (id, op_type_id, body_value) VALUES
    (7001000001, 86, '{"producer": "wtnalice"}'::JSONB),
    (7004000001, 86, '{"producer": "wtncarol"}'::JSONB),
    (7502000001, 86, '{"producer": "wtncarol"}'::JSONB),
    (7502000002, 86, '{"producer": "wtncarol"}'::JSONB),
    (7504000001, 86, '{"producer": "wtnalice"}'::JSONB),
    -- wtndave: 2 misses, tying wtnalice's count. Its extremes are LATER than alice's so
    -- order_by=last_missed still separates them - only order_by=missed hits the tie.
    (7505000001, 86, '{"producer": "wtndave"}'::JSONB),
    (7506000001, 86, '{"producer": "wtndave"}'::JSONB)
ON CONFLICT (id) DO NOTHING;

SELECT haf_stats_app.process_witness_blocks(7000, 7999);
