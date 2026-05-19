DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_owner') THEN
    CREATE ROLE haf_stats_owner LOGIN NOINHERIT;
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

-- Join the HAF app group so haf_stats_owner can access hafd.* views
GRANT hive_applications_owner_group TO haf_stats_owner;

-- Direct schema access needed because haf_stats_owner/user are NOINHERIT
-- and cannot automatically inherit group privileges.
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
