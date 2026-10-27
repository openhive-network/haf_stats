-- Put the schema back to a PRE-UPGRADE state, so install-again runs every guarded upgrade. (#96)
--
-- Without this, CI ran one guarded statement out of 14: comment_registry.community's
-- ADD COLUMN, which every fresh install needs because its CREATE TABLE lacks the column. The other
-- 13 met tables that already had what they add, or lacked what they drop, so a typo in one -- or a
-- catalog test that is wrongly always-FALSE -- shipped green. This undoes all 14 (#44 added three); install-again
-- has to redo them, and tests/ci_install_verify.sql asserts that each one landed.
--
--  12 dropped columns   active_users_daily.ops, comment_registry.community,
--                       account_custom_json_daily.op_bytes,
--                       rc_exact on network_op_daily, network_custom_json_daily and
--                       account_custom_json_daily (#44),
--                       account_cohort_retention.eligible_at_7d/_30d/_90d,
--                       author_cohort_retention.eligible_at_30d/_90d/_180d
--   1 re-added column   account_custom_json_daily.rc_estimated, the pre-#32 column the upgrade drops
--   1 re-created table  account_financial_daily in its TEXT category/direction shape, as every
--                       release before the compact codes shipped it, holding one row: the upgrade
--                       must drop it and create the compact shape, empty. Created as
--                       haf_stats_owner, which owns it on a real node and runs the DROP.
--
-- Plus two ROLE edges (#88): haf_stats_user is put into hive_applications_group, which is how
-- testapi's role looked -- an unmerged revision of db/builtin_roles.sql (9a77508) created it
-- that way -- and into hive_applications_owner_group, so BOTH arms of the revoke have work.
-- install-again must remove both, and ci_install_verify.sql asserts it did: its MEMBER check
-- is transitive, and tests/ci_setup.sql makes owner_group a member of the group, so a revoke
-- that dropped either arm leaves haf_stats_user a member and fails there. On a fresh install
-- the revoke finds no edge to remove, because builtin_roles.sql's CREATE ROLE never grants
-- either group; without these edges the revoke would ship untested.
--
-- NOT covered here: the GRANTED BY path. This lane runs PostgreSQL 14, which parses that
-- clause and ignores it, and both grants below are made by the bootstrap superuser anyway.
-- The grantor-specific behaviour of PostgreSQL 16+ is exercised only on nodes.
--
-- No IF [NOT] EXISTS anywhere: if a column is renamed, this should fail rather than quietly break
-- less than it claims. The DO block at the end checks the result for the same reason.

GRANT hive_applications_group TO haf_stats_user;
GRANT hive_applications_owner_group TO haf_stats_user;

ALTER TABLE haf_stats_backend.active_users_daily DROP COLUMN ops;
ALTER TABLE haf_stats_backend.comment_registry DROP COLUMN community;
ALTER TABLE haf_stats_backend.account_custom_json_daily DROP COLUMN op_bytes;
ALTER TABLE haf_stats_backend.account_custom_json_daily DROP COLUMN rc_exact;
ALTER TABLE haf_stats_backend.network_op_daily DROP COLUMN rc_exact;
ALTER TABLE haf_stats_backend.network_custom_json_daily DROP COLUMN rc_exact;
ALTER TABLE haf_stats_backend.account_custom_json_daily
ADD COLUMN rc_estimated BIGINT NOT NULL DEFAULT 0;
ALTER TABLE haf_stats_backend.account_cohort_retention
DROP COLUMN eligible_at_7d,
DROP COLUMN eligible_at_30d,
DROP COLUMN eligible_at_90d;
ALTER TABLE haf_stats_backend.author_cohort_retention
DROP COLUMN eligible_at_30d,
DROP COLUMN eligible_at_90d,
DROP COLUMN eligible_at_180d;

SET ROLE haf_stats_owner;
DROP TABLE haf_stats_backend.account_financial_daily;
CREATE TABLE haf_stats_backend.account_financial_daily (
    account_id INT NOT NULL,
    day DATE NOT NULL,
    category TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('incoming', 'outgoing')),
    hive_nai BIGINT NOT NULL DEFAULT 0,
    hbd_nai BIGINT NOT NULL DEFAULT 0,
    vests_nai BIGINT NOT NULL DEFAULT 0,
    op_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, day, category, direction)
);
INSERT INTO haf_stats_backend.account_financial_daily (account_id, day, category, direction)
VALUES (900901, '2016-03-24', 'author_reward_operation', 'incoming');
RESET ROLE;

DO $check$
DECLARE
    _wrong TEXT;
BEGIN
    SELECT string_agg(format('%s.%s', t.rel, t.col), ', ') INTO _wrong
    FROM (
        VALUES
        ('haf_stats_backend.active_users_daily', 'ops', FALSE),
        ('haf_stats_backend.comment_registry', 'community', FALSE),
        ('haf_stats_backend.account_custom_json_daily', 'op_bytes', FALSE),
        ('haf_stats_backend.account_custom_json_daily', 'rc_estimated', TRUE),
        ('haf_stats_backend.account_custom_json_daily', 'rc_exact', FALSE),
        ('haf_stats_backend.network_op_daily', 'rc_exact', FALSE),
        ('haf_stats_backend.network_custom_json_daily', 'rc_exact', FALSE),
        ('haf_stats_backend.account_cohort_retention', 'eligible_at_7d', FALSE),
        ('haf_stats_backend.account_cohort_retention', 'eligible_at_30d', FALSE),
        ('haf_stats_backend.account_cohort_retention', 'eligible_at_90d', FALSE),
        ('haf_stats_backend.author_cohort_retention', 'eligible_at_30d', FALSE),
        ('haf_stats_backend.author_cohort_retention', 'eligible_at_90d', FALSE),
        ('haf_stats_backend.author_cohort_retention', 'eligible_at_180d', FALSE)
    ) AS t (rel, col, present)
    WHERE EXISTS (
        SELECT 1 FROM pg_attribute AS a
        WHERE a.attrelid = t.rel::REGCLASS AND a.attname = t.col AND NOT a.attisdropped
    ) <> t.present;
    IF _wrong IS NOT NULL THEN
        RAISE EXCEPTION 'break-schema: these columns are not in their pre-upgrade state: %', _wrong;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute AS a
        WHERE a.attrelid = 'haf_stats_backend.account_financial_daily'::REGCLASS
          AND a.attname = 'category' AND NOT a.attisdropped
    ) OR NOT EXISTS (SELECT 1 FROM haf_stats_backend.account_financial_daily WHERE account_id = 900901) THEN
        RAISE EXCEPTION 'break-schema: account_financial_daily is not back in its TEXT shape with the row install-again must drop';
    END IF;

    IF NOT pg_has_role('haf_stats_user', 'hive_applications_group', 'MEMBER') THEN
        RAISE EXCEPTION 'break-schema: haf_stats_user is not in hive_applications_group, so install-again has no membership to remove';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_auth_members AS a
        INNER JOIN pg_roles AS g ON a.roleid = g.oid
        WHERE a.member = 'haf_stats_user'::regrole AND g.rolname = 'hive_applications_owner_group'
    ) THEN
        RAISE EXCEPTION 'break-schema: haf_stats_user has no direct hive_applications_owner_group edge, so that arm of the revoke goes untested';
    END IF;

    RAISE NOTICE 'break-schema: all 14 guarded upgrades have work to do again (12 columns dropped, rc_estimated back, account_financial_daily in its TEXT shape with one row)';
END;
$check$;
