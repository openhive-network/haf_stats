DO $$
BEGIN
  CREATE ROLE haf_stats_owner WITH LOGIN INHERIT IN ROLE hive_applications_owner_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

DO $$
BEGIN
  CREATE ROLE haf_stats_user WITH LOGIN INHERIT IN ROLE hive_applications_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

-- Allow haf_admin to act as haf_stats_owner (for installation scripts)
GRANT haf_stats_owner TO haf_admin;

-- Allow haf_stats_owner to act as haf_stats_user (for testing)
GRANT haf_stats_user TO haf_stats_owner;
