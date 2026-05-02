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
    PERFORM haf_stats_app.process_financial(_first_block, _last_block);
END;
$$;
