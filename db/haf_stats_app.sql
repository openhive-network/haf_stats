-- Core HAF Stats app: schemas, control tables, HAF context, lifecycle, and main loop.

-- ---------------------------------------------------------------------------
-- Schemas
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS haf_stats_app AUTHORIZATION haf_stats_owner;
CREATE SCHEMA IF NOT EXISTS haf_stats_backend AUTHORIZATION haf_stats_owner;
CREATE SCHEMA IF NOT EXISTS haf_stats_endpoints AUTHORIZATION haf_stats_owner;

GRANT USAGE ON SCHEMA haf_stats_app TO haf_stats_user;
GRANT USAGE ON SCHEMA haf_stats_backend TO haf_stats_user;
GRANT USAGE ON SCHEMA haf_stats_endpoints TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Control tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS haf_stats_app.app_status (
    continue_processing BOOL NOT NULL DEFAULT TRUE,
    last_processed_block INT NOT NULL DEFAULT 0
);

INSERT INTO haf_stats_app.app_status VALUES (TRUE, 0)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS haf_stats_app.app_version (
    git_hash TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- Lifecycle control functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.continue_processing()
RETURNS BOOL
LANGUAGE sql STABLE
AS $$
    SELECT continue_processing FROM haf_stats_app.app_status LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION haf_stats_app.allow_processing()
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE haf_stats_app.app_status SET continue_processing = TRUE;
$$;

CREATE OR REPLACE FUNCTION haf_stats_app.stop_processing()
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE haf_stats_app.app_status SET continue_processing = FALSE;
$$;

-- ---------------------------------------------------------------------------
-- HAF context registration (called once at install)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.create_context_if_not_exists()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT hive.app_context_exists('haf_stats') THEN
        PERFORM hive.app_create_context('haf_stats');
        RAISE NOTICE 'HAF context haf_stats created.';
    ELSE
        RAISE NOTICE 'HAF context haf_stats already exists, skipping.';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Main block-processing loop
-- hive.app_next_block(context_name) returns hive.blocks_range (first_block, last_block INT).
-- NULL return means no blocks yet — loop continues. Negative range means wait for live block.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_app.main()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _block_range hive.blocks_range;
BEGIN
    PERFORM haf_stats_app.allow_processing();

    LOOP
        _block_range := hive.app_next_block('haf_stats');

        IF _block_range IS NOT NULL AND _block_range.first_block > 0 THEN
            PERFORM haf_stats_app.process_block_range(_block_range.first_block, _block_range.last_block);
            UPDATE haf_stats_app.app_status SET last_processed_block = _block_range.last_block;
        END IF;

        EXIT WHEN NOT haf_stats_app.continue_processing();
    END LOOP;
END;
$$;
