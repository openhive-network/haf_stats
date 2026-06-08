DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_owner') THEN
    -- INHERIT (like btracker_owner) so that, as a member of
    -- hive_applications_owner_group, the owner can INSERT/UPDATE hafd.contexts
    -- when creating the HAF context and advancing the block pointer in main().
    -- A NOINHERIT owner fails context creation with "permission denied for table contexts".
    CREATE ROLE haf_stats_owner LOGIN INHERIT;
  ELSE
    -- Repair an earlier install that created the role as NOINHERIT.
    ALTER ROLE haf_stats_owner INHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_user') THEN
    CREATE ROLE haf_stats_user LOGIN NOINHERIT;
  END IF;
END
$$;

-- haf_stats_user is readable by haf_stats_owner (owner inherits user perms)
GRANT haf_stats_user TO haf_stats_owner;

-- haf_admin (HAF superrole) owns haf_stats_owner
GRANT haf_stats_owner TO haf_admin;

-- Join the HAF app group so haf_stats_owner can access hafd.* views and write
-- hafd.contexts (same pattern as btracker_owner). A NOINHERIT owner here fails
-- context creation with "permission denied for table contexts".
-- REVOKE+GRANT (rather than a bare GRANT) refreshes the membership's inherit
-- flag from the now-INHERIT role: PG16+ freezes that flag at GRANT time, so a
-- membership first created while the role was NOINHERIT would otherwise stay
-- non-inheriting on re-install. On a fresh install the REVOKE is a harmless no-op.
REVOKE hive_applications_owner_group FROM haf_stats_owner;
GRANT hive_applications_owner_group TO haf_stats_owner;

-- Direct schema access: haf_stats_user is NOINHERIT (PostgREST connects as it
-- directly), so it cannot rely on group-inherited privileges. Granted to the
-- owner too for explicitness.
GRANT USAGE ON SCHEMA hafd TO haf_stats_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA hafd TO haf_stats_owner;
GRANT USAGE ON SCHEMA hive TO haf_stats_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA hive TO haf_stats_owner;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA hive TO haf_stats_owner;
GRANT USAGE ON SCHEMA hafd TO haf_stats_user;
GRANT SELECT ON ALL TABLES IN SCHEMA hafd TO haf_stats_user;
GRANT USAGE ON SCHEMA hive TO haf_stats_user;
GRANT SELECT ON ALL TABLES IN SCHEMA hive TO haf_stats_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA hive TO haf_stats_user;
