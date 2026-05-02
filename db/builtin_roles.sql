DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_owner') THEN
    CREATE ROLE haf_stats_owner NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haf_stats_user') THEN
    CREATE ROLE haf_stats_user NOLOGIN NOINHERIT;
  END IF;
END
$$;

-- haf_stats_user is readable by haf_stats_owner (owner inherits user perms)
GRANT haf_stats_user TO haf_stats_owner;

-- haf_admin (HAF superrole) owns haf_stats_owner
GRANT haf_stats_owner TO haf_admin;
