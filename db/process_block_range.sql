SET ROLE haf_stats_owner;

-- Block range dispatcher.
-- Calls domain-specific processors in order. Add calls here as features are implemented.

CREATE OR REPLACE FUNCTION haf_stats_app.process_block_range(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM haf_stats_app.process_financial(_first_block, _last_block);
    PERFORM haf_stats_app.process_rc(_first_block, _last_block);
    PERFORM haf_stats_app.process_account_cohorts(_first_block, _last_block);
    PERFORM haf_stats_app.process_active_users(_first_block, _last_block);
    PERFORM haf_stats_app.process_content_stats(_first_block, _last_block);
    PERFORM haf_stats_app.process_custom_json(_first_block, _last_block);
END;
$$;

RESET ROLE;
