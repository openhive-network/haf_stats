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

SET ROLE haf_stats_owner;

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

GRANT SELECT ON haf_stats_app.app_status TO haf_stats_user;
GRANT SELECT ON haf_stats_app.app_version TO haf_stats_user;

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
DECLARE
    _stages hive.application_stages;
BEGIN
    IF NOT hive.app_context_exists('haf_stats') THEN
        _stages := ARRAY[
            hive.stage('MASSIVE_PROCESSING', 101, 10000, '20 seconds'),
            hive.live_stage()
        ]::hive.application_stages;
        PERFORM hive.app_create_context(
            _name   => 'haf_stats'::hafd.context_name,
            _schema => 'haf_stats_app',
            _stages => _stages
        );
        PERFORM hive.app_context_set_non_forking('haf_stats');
        PERFORM hive.app_context_detach('haf_stats');
        PERFORM hive.app_set_current_block_num('haf_stats', 0);
        RAISE NOTICE 'HAF context haf_stats created.';
    ELSE
        RAISE NOTICE 'HAF context haf_stats already exists, skipping.';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Main block-processing loop (PROCEDURE so CALL works and transactions commit).
-- Uses hive.app_next_iteration() which automatically advances the context block
-- pointer — unlike the older hive.app_next_block() function which does not.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE haf_stats_app.main(
    IN _context hafd.context_name DEFAULT 'haf_stats'
)
LANGUAGE plpgsql
AS $$
DECLARE
    _block_range hive.blocks_range;
BEGIN
    PERFORM haf_stats_app.allow_processing();
    RAISE NOTICE 'haf_stats starting. Last processed block: %', hive.app_get_current_block_num(_context);

    LOOP
        CALL hive.app_next_iteration(_context, _block_range, NULL, NULL);

        IF NOT haf_stats_app.continue_processing() THEN
            ROLLBACK;
            RAISE NOTICE 'haf_stats stopped at block %', hive.app_get_current_block_num(_context);
            RETURN;
        END IF;

        IF _block_range IS NULL THEN
            CONTINUE;
        END IF;

        PERFORM haf_stats_app.process_block_range(_block_range.first_block, _block_range.last_block);
        UPDATE haf_stats_app.app_status SET last_processed_block = _block_range.last_block;
    END LOOP;
END;
$$;

RESET ROLE;
