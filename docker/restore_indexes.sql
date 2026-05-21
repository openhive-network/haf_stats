-- Restore HAF indexes dropped during MASSIVE_SYNC with LOW memory footprint.
-- Calls hive.restore_indexes() directly (not enable_indexes_of_irreversible which uses 6GB).
-- Run as haf_admin while hived is NOT running (--skip-hived mode).

SET maintenance_work_mem = '256MB';

DO $$
DECLARE
    r RECORD;
    _start TIMESTAMP;
    _tables TEXT[] := ARRAY[
        'hafd.hive_state',
        'hafd.accounts',
        'hafd.blocks',
        'hafd.applied_hardforks',
        'hafd.transactions',
        'hafd.transactions_multisig',
        'hafd.operations',
        'hafd.account_operations'
    ];
    _t TEXT;
BEGIN
    -- Step 1: restore non-FK indexes table by table
    FOREACH _t IN ARRAY _tables LOOP
        RAISE NOTICE '--- Restoring indexes on % ---', _t;
        _start := clock_timestamp();
        PERFORM hive.restore_indexes(_t);
        RAISE NOTICE '--- Done % in % s ---', _t, EXTRACT(EPOCH FROM (clock_timestamp() - _start));
    END LOOP;

    -- Step 2: restore FK constraints
    RAISE NOTICE '--- Restoring FK constraints ---';
    FOR r IN
        SELECT index_constraint_name, command
        FROM hafd.indexes_constraints
        WHERE contexts @> ARRAY[0]
          AND is_foreign_key = TRUE
          AND status = 'missing'
        ORDER BY table_name
    LOOP
        RAISE NOTICE 'FK: %', r.index_constraint_name;
        UPDATE hafd.indexes_constraints
           SET status = 'creating'
         WHERE index_constraint_name = r.index_constraint_name;
        EXECUTE r.command;
        UPDATE hafd.indexes_constraints
           SET status = 'created'
         WHERE index_constraint_name = r.index_constraint_name;
    END LOOP;

    -- Step 3: final check
    RAISE NOTICE 'is_instance_ready: %', hive.is_instance_ready();
    RAISE NOTICE 'are_indexes_restored: %', hive.are_indexes_restored();
END;
$$;
