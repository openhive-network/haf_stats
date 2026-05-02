-- Block range dispatcher.
-- Calls domain-specific processors in order. Add calls here as features are implemented.

CREATE OR REPLACE FUNCTION haf_stats_app.process_block_range(
    _first_block INT,
    _last_block  INT
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Processors will be added here as features are implemented.
    NULL;
END;
$$;
