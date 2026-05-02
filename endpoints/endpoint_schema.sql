-- PostgREST-exposed API functions for haf_stats.
-- All functions live in haf_stats_endpoints and are callable by haf_stats_user.

CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_version()
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT git_hash FROM haf_stats_app.app_version LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_health()
RETURNS TABLE (
    status               TEXT,
    last_processed_block INT,
    version              TEXT
)
LANGUAGE sql STABLE
AS $$
    SELECT
        'ok'::TEXT                                               AS status,
        s.last_processed_block,
        (SELECT git_hash FROM haf_stats_app.app_version LIMIT 1) AS version
    FROM haf_stats_app.app_status s
    LIMIT 1;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;
