SET ROLE haf_stats_owner;

-- Block range dispatcher.
-- Calls domain-specific processors in groups (see "Processor groups" below). Add calls to a
-- group as features are implemented.

-- ---------------------------------------------------------------------------
-- Per-processor timings, off unless the session sets haf_stats.processor_timings = on
-- (e.g. options=-c haf_stats.processor_timings=on on the block processor's connection).
--
-- process_block_range reads the setting once per batch; when it is off that comparison is
-- all it adds. The processors that call a rollup/period/retention refresh read it again
-- at the refresh call site, only on a batch that crosses the refresh's block boundary.
-- When it is on, each step's wall time and the batch's operation counts are sent to the
-- client as INFO lines, one line each, which haf_app_driver.py writes to its log when
-- run with --server-messages=INFO:
--
--   haf_stats_processor_timing {"first_block":..,"last_block":..,"step":"process_financial",
--                               "within":null,"seconds":..,"reads":["transfer_operation",...]}
--   haf_stats_operation_counts {"first_block":..,"last_block":..,"seconds":..,"counts":[
--                               {"op_type":..,"virtual":..,"rows":..}]}
--
-- "within" is NULL for a step process_block_range calls, and names the processor for a
-- refresh timed inside one, whose seconds are therefore also in that processor's.
-- "reads" names the op types a step selects ("non_virtual" for every non-virtual type):
-- prepare_batch_ops from hafd.operations, every other step from what it staged. Its rows read
-- are the batch's counts of those types. The
-- counts query is instrumentation: its own time is its "seconds", not any step's. INFO,
-- not NOTICE, because INFO reaches the client whatever client_min_messages says.
-- scripts/processor_timings_report.py parses both lines. Nothing is stored.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.report_processor_timing;
CREATE OR REPLACE FUNCTION haf_stats_app.report_processor_timing(
    _step TEXT,
    _first_block INT,
    _last_block INT,
    _started TIMESTAMPTZ,
    _reads TEXT [],
    _within TEXT
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    RAISE INFO 'haf_stats_processor_timing %', json_build_object(
        'first_block', _first_block,
        'last_block', _last_block,
        'step', _step,
        'within', _within,
        'seconds', EXTRACT(EPOCH FROM clock_timestamp() - _started),
        'reads', _reads
    );
    RETURN clock_timestamp();
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.report_operation_counts;
CREATE OR REPLACE FUNCTION haf_stats_app.report_operation_counts(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    _started TIMESTAMPTZ := clock_timestamp();
    _counts JSONB;
BEGIN
    SELECT jsonb_agg(to_jsonb(c) ORDER BY c.op_type) INTO _counts
    FROM (
        SELECT
            replace(ot.name, 'hive::protocol::', '') AS op_type,
            ot.is_virtual AS virtual,
            COUNT(*) AS rows
        FROM hafd.operations AS o
        JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id
        WHERE o.id >= hafd.operation_id(_first_block, 0)
          AND o.id < hafd.operation_id(_last_block + 1, 0)
        GROUP BY ot.name, ot.is_virtual
    ) AS c;

    -- jsonb, not json: json_agg puts a newline between elements, and the driver logs
    -- each line of a message as a line of its own.
    RAISE INFO 'haf_stats_operation_counts %', jsonb_build_object(
        'first_block', _first_block,
        'last_block', _last_block,
        'seconds', EXTRACT(EPOCH FROM clock_timestamp() - _started),
        'counts', COALESCE(_counts, '[]'::JSONB)
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- The batch's operations, read from hafd.operations once per range.
--
-- Every processor reads its operations from this ON COMMIT DROP temp table rather than from
-- hafd.operations or hive.operations_view, so each op type is read and decoded once per batch
-- however many processors use it. process_block_range stages the full set first (_op_types
-- NULL); each processor also calls this lazily with the op types it reads, so direct calls
-- (the rebuild scripts, the install self-heals, the fixtures) still work and stage only what
-- they need. The range-key GUC, the staged-type GUC and the temp table's existence make a
-- call no-op when the range is already staged with every type it asks for; both GUCs are
-- transaction-local, so they end, and roll back, with the table. During parallel massive sync
-- the name is a view of the batch's shared staging instead ("Shared batch staging" below),
-- with the same GUCs set, so every call is a no-op there.
--
-- fill_batch_ops loads the rows into whatever haf_stats_batch_ops names and returns how many;
-- prepare_batch_ops makes the name a temp table to fill, and indexes and analyzes it, and
-- stage_shared_batch makes it a view of the shared table.
--
-- The full set is every non-virtual op (prepare_batch_authored_ops, process_network_ops and
-- exact_rc_for_range read them all), the hardcoded ids the processors filter on, and the
-- virtual types they resolve by name. hafd.operations, not operations_view: the haf_stats
-- context is non-forking, so every block it processes is irreversible.
--
-- op_bytes is the payload-size proxy the RC estimate is calibrated against (process_rc.sql),
-- serialized once here for the three rollups that sum it, and only for non-virtual ops.
-- custom_json_type_id is HAF's key for a custom_json op's id (hafd.custom_json_types), the key
-- both custom_json rollups store; NULL for every other op type.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.batch_op_types;
CREATE OR REPLACE FUNCTION haf_stats_app.batch_op_types(
    _op_types INT []
)
RETURNS INT []
LANGUAGE sql
STABLE
AS $$
    SELECT CASE WHEN _op_types IS NOT NULL THEN _op_types ELSE (
        SELECT ARRAY[0, 1, 2, 17, 18, 73] || ARRAY_AGG(ot.id ORDER BY ot.id)
        FROM hafd.operation_types AS ot
        WHERE NOT ot.is_virtual
           OR ot.name IN (
               'hive::protocol::author_reward_operation',
               'hive::protocol::comment_benefactor_reward_operation',
               'hive::protocol::curation_reward_operation',
               'hive::protocol::interest_operation',
               'hive::protocol::fill_transfer_from_savings_operation',
               'hive::protocol::fill_vesting_withdraw_operation',
               'hive::protocol::producer_reward_operation',
               'hive::protocol::liquidity_reward_operation',
               'hive::protocol::proposal_pay_operation',
               'hive::protocol::fill_order_operation',
               'hive::protocol::account_created_operation',
               'hive::protocol::producer_missed_operation'
           )
    ) END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.fill_batch_ops;
CREATE OR REPLACE FUNCTION haf_stats_app.fill_batch_ops(
    _first_block INT,
    _last_block INT,
    _types INT [],
    _full_set BOOLEAN
)
RETURNS BIGINT
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _rows BIGINT;
BEGIN
    IF _full_set THEN
        -- The full set is most of the range's operations, and the planner estimates the range
        -- at a few hundred of them whatever its size, so a join to hafd.blocks would be one
        -- index probe per operation. Driven from the range's blocks instead: one primary-key
        -- range scan of hafd.operations per block, a plan the estimate cannot change. OFFSET 0
        -- keeps the LATERAL subquery from being flattened back into an ordinary join.
        INSERT INTO haf_stats_batch_ops
            (op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value, op_bytes, custom_json_type_id)
        SELECT
            o.id,
            b.num,
            o.trx_in_block,
            o.op_type_id,
            b.created_at,
            b.created_at::DATE,
            o.body_value,
            CASE WHEN ot.is_virtual IS NOT TRUE THEN octet_length(o.body_value::TEXT) END,
            o.custom_json_type_id
        FROM hafd.blocks AS b
        CROSS JOIN LATERAL (
            SELECT op.id, op.trx_in_block, op.op_type_id, op.body_value, op.custom_json_type_id
            FROM hafd.operations AS op
            WHERE op.id >= hafd.operation_id(b.num, 0)
              AND op.id < hafd.operation_id(b.num + 1, 0)
              AND op.op_type_id = ANY(_types)
            OFFSET 0
        ) AS o
        LEFT JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id
        WHERE b.num BETWEEN _first_block AND _last_block;
    ELSE
        -- A few op types: few operations, however long the range (the install self-heals and
        -- the rebuild scripts stage one or two types over up to the whole chain), so each is
        -- joined to its block by an index probe.
        INSERT INTO haf_stats_batch_ops
            (op_id, block_num, trx_in_block, op_type_id, op_time, day, body_value, op_bytes, custom_json_type_id)
        SELECT
            o.id,
            b.num,
            o.trx_in_block,
            o.op_type_id,
            b.created_at,
            b.created_at::DATE,
            o.body_value,
            CASE WHEN ot.is_virtual IS NOT TRUE THEN octet_length(o.body_value::TEXT) END,
            o.custom_json_type_id
        FROM hafd.operations AS o
        JOIN hafd.blocks AS b ON b.num = hafd.operation_id_to_block_num(o.id)
        LEFT JOIN hafd.operation_types AS ot ON ot.id = o.op_type_id
        -- Both forms of the range: the id range is the operations primary key's; the derived
        -- block number is the Index Cond of hive_operations_op_type_id_block_num, which suits
        -- one or two types over a long range.
        WHERE o.id >= hafd.operation_id(_first_block, 0)
          AND o.id < hafd.operation_id(_last_block + 1, 0)
          AND hafd.operation_id_to_block_num(o.id) BETWEEN _first_block AND _last_block
          AND o.op_type_id = ANY(_types);
    END IF;
    GET DIAGNOSTICS _rows = ROW_COUNT;
    RETURN _rows;
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.prepare_batch_ops;
CREATE OR REPLACE FUNCTION haf_stats_app.prepare_batch_ops(
    _first_block INT,
    _last_block INT,
    _op_types INT [] DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _range_key TEXT := _first_block::TEXT || ':' || _last_block::TEXT;
    _types INT [] := haf_stats_app.batch_op_types(_op_types);
BEGIN
    IF current_setting('haf_stats.batch_ops_range', TRUE) = _range_key
       AND TO_REGCLASS('pg_temp.haf_stats_batch_ops') IS NOT NULL
       AND _types <@ NULLIF(current_setting('haf_stats.batch_ops_types', TRUE), '')::INT [] THEN
        RETURN;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_batch_ops (
        op_id BIGINT NOT NULL,
        block_num INT NOT NULL,
        trx_in_block SMALLINT,
        op_type_id SMALLINT NOT NULL,
        op_time TIMESTAMP NOT NULL,
        day DATE NOT NULL,
        body_value JSONB,
        op_bytes INT,
        custom_json_type_id SMALLINT
    ) ON COMMIT DROP;

    TRUNCATE haf_stats_batch_ops;
    -- The processors' op_type_id filters are what the index is for; it is built after the
    -- load, which is cheaper than maintaining it through the INSERT. Dropped first so a
    -- second staging in the same transaction loads without it too.
    DROP INDEX IF EXISTS pg_temp.haf_stats_batch_ops_type_idx;

    PERFORM haf_stats_app.fill_batch_ops(_first_block, _last_block, _types, _op_types IS NULL);

    CREATE INDEX haf_stats_batch_ops_type_idx ON haf_stats_batch_ops (op_type_id, op_id);
    -- Not body_value: no plan filters or joins on the JSONB, and sampling it is most of the cost.
    ANALYZE haf_stats_batch_ops (op_id, block_num, trx_in_block, op_type_id, op_time, day, op_bytes);
    PERFORM set_config('haf_stats.batch_ops_range', _range_key, TRUE);
    PERFORM set_config('haf_stats.batch_ops_types', _types::TEXT, TRUE);
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.fill_batch_authored_ops;
CREATE OR REPLACE FUNCTION haf_stats_app.fill_batch_authored_ops()
RETURNS BIGINT
LANGUAGE plpgsql
SET jit = OFF
SET from_collapse_limit = '16'
SET join_collapse_limit = '16'
SET enable_bitmapscan = 'off'
AS $$
DECLARE
    _safe BOOLEAN := FALSE;
    _rows BIGINT;
BEGIN
    -- Returns the number of rows loaded.
    --
    -- Plain hive.get_required_authorities first, for the types whose signers are not read from
    -- the body, in one subtransaction for the whole statement. Only if it fails is the
    -- statement run again through the per-row get_required_authorities_safe, whose
    -- subtransaction per op is what makes an op whose authorities cannot be computed
    -- contribute no rows. A batch with no such op therefore gets exactly the rows the safe
    -- wrapper would have given it, without its cost: the first run's rows roll back with its
    -- subtransaction. WHEN OTHERS because the safe wrapper treats any failure as authorless; a
    -- failure that is not the authority lookup's raises again from the second run.
    <<attempt>>
    LOOP
        BEGIN
            WITH authored AS MATERIALIZED (
                SELECT DISTINCT
                    s.op_id,
                    ra.account_name AS actor_name,
                    s.op_time,
                    s.day,
                    (CASE
                        WHEN s.op_type_id = 0 THEN 3::SMALLINT                 -- vote_operation
                        WHEN s.op_type_id = 1
                         AND COALESCE(s.body_value ->> 'parent_author', '') = ''
                                              THEN 1::SMALLINT                 -- comment_operation: post
                        WHEN s.op_type_id = 1 THEN 2::SMALLINT                 -- comment_operation: comment
                        WHEN s.op_type_id = 2 THEN 4::SMALLINT                 -- transfer_operation
                        WHEN s.op_type_id = 18 THEN 5::SMALLINT                -- custom_json_operation
                        ELSE NULL::SMALLINT                                    -- other authored op: ALL rollup only
                     END) AS op_class
                FROM haf_stats_batch_ops s
                JOIN hafd.operation_types ot ON ot.id = s.op_type_id AND NOT ot.is_virtual
                -- Every arm's filter reads only the op's type and _safe, so it is a one-time
                -- filter of the arm and only the arm for the op's type runs.
                --
                -- The four types that are most of the non-virtual stream sign with fields of
                -- their body, read here directly: the same accounts hive.get_required_authorities
                -- returns for them, without building the operation for it. A body that lacks the
                -- field gives NULL, or no array element, so no row; HAF gives '' or raises,
                -- which also leaves the op no account. A non-array auths field is skipped
                -- rather than raising.
                CROSS JOIN LATERAL (
                    SELECT s.body_value ->> 'voter' WHERE s.op_type_id = 0          -- vote_operation
                    UNION ALL
                    SELECT s.body_value ->> 'author' WHERE s.op_type_id = 1         -- comment_operation
                    UNION ALL
                    SELECT s.body_value ->> 'from' WHERE s.op_type_id = 2           -- transfer_operation
                    UNION ALL
                    SELECT auth.name                                                -- custom_json_operation
                    FROM jsonb_array_elements_text(
                        CASE WHEN jsonb_typeof(s.body_value -> 'required_auths') = 'array'
                             THEN s.body_value -> 'required_auths' END
                    ) AS auth (name)
                    WHERE s.op_type_id = 18
                    UNION ALL
                    SELECT auth.name
                    FROM jsonb_array_elements_text(
                        CASE WHEN jsonb_typeof(s.body_value -> 'required_posting_auths') = 'array'
                             THEN s.body_value -> 'required_posting_auths' END
                    ) AS auth (name)
                    WHERE s.op_type_id = 18
                    UNION ALL
                    -- Every other type through HAF, in the {type, value} form it takes, as
                    -- operations_view builds it. _safe is a constant of the statement, so only
                    -- one of the two functions is ever called.
                    SELECT r.account_name
                    FROM hive.get_required_authorities(jsonb_build_object(
                        'type', replace(ot.name, 'hive::protocol::', ''),
                        'value', s.body_value
                    )) r
                    WHERE s.op_type_id NOT IN (0, 1, 2, 18) AND NOT _safe
                    UNION ALL
                    SELECT r.account_name
                    FROM haf_stats_app.get_required_authorities_safe(jsonb_build_object(
                        'type', replace(ot.name, 'hive::protocol::', ''),
                        'value', s.body_value
                    )) r
                    WHERE s.op_type_id NOT IN (0, 1, 2, 18) AND _safe
                ) ra (account_name)
                WHERE ra.account_name IS NOT NULL
            ),
            name_ids AS MATERIALIZED (
                SELECT av.name, av.id
                FROM hive.accounts_view av
                WHERE av.name IN (
                    SELECT DISTINCT actor_name
                    FROM authored
                )
            )
            INSERT INTO haf_stats_batch_authored_ops (op_id, account_id, op_time, day, op_class)
            SELECT a.op_id, ni.id, a.op_time, a.day, a.op_class
            FROM authored a
            JOIN name_ids ni ON ni.name = a.actor_name;
            GET DIAGNOSTICS _rows = ROW_COUNT;

            EXIT attempt;
        EXCEPTION WHEN OTHERS THEN
            IF _safe THEN
                RAISE;
            END IF;
            _safe := TRUE;
        END;
    END LOOP;
    RETURN _rows;
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.prepare_batch_authored_ops;
CREATE OR REPLACE FUNCTION haf_stats_app.prepare_batch_authored_ops(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _range_key TEXT := _first_block::TEXT || ':' || _last_block::TEXT;
BEGIN
    -- Shared by process_account_cohorts and process_active_users so the authority
    -- lookup and name resolution over the batch's non-virtual ops (prepare_batch_ops)
    -- run once per batch instead of twice. process_block_range builds it before the
    -- two consumers; each consumer also calls this lazily so direct rebuild invocations
    -- still work. The range-key GUC plus the temp-table existence check make the repeat
    -- calls within a batch no-ops; the table is ON COMMIT DROP so each batch rebuilds.
    -- fill_batch_authored_ops loads the rows, into the shared staging too (stage_shared_batch).
    IF current_setting('haf_stats.batch_authored_ops_range', TRUE) = _range_key
       AND TO_REGCLASS('pg_temp.haf_stats_batch_authored_ops') IS NOT NULL THEN
        RETURN;
    END IF;

    PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block);

    CREATE TEMP TABLE IF NOT EXISTS haf_stats_batch_authored_ops (
        op_id BIGINT NOT NULL,
        account_id INT NOT NULL,
        op_time TIMESTAMP NOT NULL,
        day DATE NOT NULL,
        op_class SMALLINT
    ) ON COMMIT DROP;
    -- The primary key is added after the load: the rows arrive in name order, which is random
    -- op order, and building the key once is cheaper than inserting each row into it. Dropped
    -- first so a second staging in the same transaction loads without it too.
    ALTER TABLE haf_stats_batch_authored_ops DROP CONSTRAINT IF EXISTS haf_stats_batch_authored_ops_pkey;
    TRUNCATE haf_stats_batch_authored_ops;

    PERFORM haf_stats_app.fill_batch_authored_ops();

    -- The consumers count rows as operations (process_active_users) and join on op_id
    -- (account_custom_json_rows), so an (op, account) pair staged twice stops the batch.
    ALTER TABLE haf_stats_batch_authored_ops
        ADD CONSTRAINT haf_stats_batch_authored_ops_pkey PRIMARY KEY (op_id, account_id);
    ANALYZE haf_stats_batch_authored_ops;
    PERFORM set_config('haf_stats.batch_authored_ops_range', _range_key, FALSE);
END;
$$;

-- ---------------------------------------------------------------------------
-- Processor groups
--
-- The processors are called in groups: contiguous runs of the call order, each reading only
-- the batch's staged operations and what the processors before it in the same group wrote,
-- and writing tables no other group reads or writes within a batch. So the groups of one batch
-- can run in any order, or at once on separate connections, and write what the call order
-- writes:
--
--   financial    account_financial_*
--   users        account_cohort_*, active_user*: both read prepare_batch_authored_ops
--   content      community_registry before content_stats (a community registered in the batch
--                must be in community_registry when the comment scan classifies posts
--                addressed to it), content_stats before content_cohorts (which reads
--                network_author_daily)
--   custom_json  account_custom_json_*: reads prepare_batch_authored_ops, prepare_batch_exact_rc
--                and prepare_batch_custom_json_ops
--   network      network_op_daily, network_custom_json_daily, witness_blocks_daily
--
-- Each group writes its own deferred_rollup_refreshes rows (keyed by processor). Every group
-- starts by staging the batch's operations: in one session the first group stages them and the
-- rest find them staged; a group on a worker connection reads the batch's shared staging
-- ("Shared batch staging" below), which was staged once before the groups started, and stages
-- for itself, lazily as a direct processor call does, only what is not shared for its range.
-- process_daily_retention is not in a group: it reads and rewrites what
-- users and custom_json write, and can restage this session's temp tables for an older day
-- (db/daily_retention.sql), so it runs after every group, in the batch's own transaction.
--
-- process_block_range runs the groups one after another in its own session. During massive sync
-- scripts/haf_stats_parallel.py deals them out to worker connections that run at once instead
-- (a connection runs its groups one after another), each group in its own transaction
-- (process_processor_group), and commits each with a row in processor_group_progress recording
-- that the group has applied the batch. The batch's own
-- transaction -- the one that moves the HAF context -- runs only once every group has
-- committed (finish_parallel_range): it runs process_daily_retention, deletes the batch's
-- progress rows and records the batch in app_status. So the context never moves past a batch a
-- group has not applied, and when the batch's transaction does not commit (a group failed, the
-- process crashed) the batch is delivered again and every group that already applied it skips
-- it: the progress row commits with the group's writes, or not at all.
-- ---------------------------------------------------------------------------

-- At most one row per group, and only while a batch is in flight: a group's row is written in
-- the transaction that applies the batch to the group's tables, and deleted in the transaction
-- that moves the HAF context past the batch. A regular logged table, so it survives a crash
-- exactly as the group's writes do.
CREATE TABLE IF NOT EXISTS haf_stats_app.processor_group_progress (
    group_name TEXT PRIMARY KEY,
    first_block INT NOT NULL,
    last_block INT NOT NULL
);

-- The groups in call order: the order process_block_range runs them in.
DROP FUNCTION IF EXISTS haf_stats_app.processor_groups;
CREATE OR REPLACE FUNCTION haf_stats_app.processor_groups()
RETURNS TEXT []
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT ARRAY['financial', 'users', 'content', 'custom_json', 'network']::TEXT [];
$$;

-- The first block of _first_block.._last_block that _group has still to apply, or NULL when it
-- has applied all of them. A batch is delivered again from the block it started at, so a
-- progress row for any other start, or reaching past the range, means the HAF context was moved
-- under an in-flight batch: that raises rather than apply a block twice or skip one.
DROP FUNCTION IF EXISTS haf_stats_app.processor_group_from;
CREATE OR REPLACE FUNCTION haf_stats_app.processor_group_from(
    _group TEXT,
    _first_block INT,
    _last_block INT
)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    _done haf_stats_app.processor_group_progress;
BEGIN
    SELECT * INTO _done FROM haf_stats_app.processor_group_progress WHERE group_name = _group;
    IF NOT FOUND THEN
        RETURN _first_block;
    END IF;
    IF _done.first_block <> _first_block OR _done.last_block > _last_block THEN
        RAISE EXCEPTION 'haf_stats: processor group % has applied blocks %..% of a batch that was not committed, which blocks %..% do not continue', _group, _done.first_block, _done.last_block, _first_block, _last_block
            USING HINT = 'The HAF context was moved while a batch was in flight. Rebuild the group''s tables, or delete its haf_stats_app.processor_group_progress row once they hold exactly the blocks up to the context''s.';
    END IF;
    IF _done.last_block = _last_block THEN
        RETURN NULL;
    END IF;
    RETURN _done.last_block + 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Shared batch staging
--
-- During parallel massive sync the batch is staged once, before its groups start, into UNLOGGED
-- tables every connection reads: the four per-batch stages a group's processors read
-- (prepare_batch_ops, prepare_batch_authored_ops, prepare_batch_exact_rc,
-- prepare_batch_custom_json_ops), filled by the same fill_batch_* functions as the temp tables.
-- scripts/haf_stats_parallel.py runs the steps of shared_batch_stage_levels() in level order,
-- each in a transaction of its own (stage_shared_batch), on one worker connection in one round
-- trip, and dispatches the groups once every step has committed. A group then
-- attaches the stages (attach_shared_batch_stage): in its transaction, each stage's
-- haf_stats_batch_* name is a temp view of the shared table and the stage's range GUCs are set,
-- so every prepare_batch_* call of its processors is a no-op.
--
-- shared_batch_stage holds a row per stage that is complete, committed in the transaction that
-- loaded the stage's rows, and a stage is read only for the range in its row. It is UNLOGGED
-- like the rows, so the crash recovery that empties the rows empties it too: a batch delivered
-- again after a crash finds no stage and stages it again; one delivered again after a failed
-- group finds its stages complete and reads them as they were. A group whose share of the batch
-- starts past the batch's first block (processor_group_from) finds no stage of its range and
-- stages its own copy, as the single-session path does. finish_block_range deletes the batch's
-- marker rows with its progress rows. The stages are derived from irreversible blocks only, so
-- stage rows a crash leaves behind are never wrong for their range, and the rebuild scripts,
-- which stage in their own session, never read them.
--
-- Unlike the temp tables, the shared tables are created once, with their keys and index, and
-- a batch's rows replace the previous batch's by DELETE in the same transaction (the ops
-- step). TRUNCATE, or dropping and building an index, gives a table that is not temporary new
-- files, and committing that drops the old files' pages from shared_buffers and creates new
-- unlogged init forks, every batch. The tables are never empty between batches,
-- so an autovacuum ANALYZE never records an empty table for the planner; and they are not
-- analyzed every batch, only when a load is an order of magnitude off what the planner
-- assumes (analyze_shared_batch_stage). vacuum_truncate is off: autovacuum, which reclaims the
-- deleted rows for the next batch, would otherwise shorten the files under an ACCESS
-- EXCLUSIVE lock, which also drops their pages from shared_buffers.
-- ---------------------------------------------------------------------------

CREATE UNLOGGED TABLE IF NOT EXISTS haf_stats_app.shared_batch_stage (
    stage TEXT PRIMARY KEY CHECK (stage IN ('ops', 'authored_ops', 'exact_rc', 'custom_json_ops')),
    first_block INT NOT NULL,
    last_block INT NOT NULL,
    -- The ops stage's op types (batch_op_types); NULL for the others.
    op_types INT []
);

-- Each with the columns of the temp table it stands in for, in the same order, and its key or
-- index.
CREATE UNLOGGED TABLE IF NOT EXISTS haf_stats_app.shared_batch_ops (
    op_id BIGINT NOT NULL,
    block_num INT NOT NULL,
    trx_in_block SMALLINT,
    op_type_id SMALLINT NOT NULL,
    op_time TIMESTAMP NOT NULL,
    day DATE NOT NULL,
    body_value JSONB,
    op_bytes INT,
    custom_json_type_id SMALLINT
) WITH (vacuum_truncate = FALSE);
CREATE INDEX IF NOT EXISTS shared_batch_ops_type_idx ON haf_stats_app.shared_batch_ops (op_type_id, op_id);

CREATE UNLOGGED TABLE IF NOT EXISTS haf_stats_app.shared_batch_authored_ops (
    op_id BIGINT NOT NULL,
    account_id INT NOT NULL,
    op_time TIMESTAMP NOT NULL,
    day DATE NOT NULL,
    op_class SMALLINT,
    PRIMARY KEY (op_id, account_id)
) WITH (vacuum_truncate = FALSE);

CREATE UNLOGGED TABLE IF NOT EXISTS haf_stats_app.shared_batch_exact_rc (
    op_id BIGINT PRIMARY KEY,
    rc_exact BIGINT NOT NULL
) WITH (vacuum_truncate = FALSE);

CREATE UNLOGGED TABLE IF NOT EXISTS haf_stats_app.shared_batch_custom_json_ops (
    op_id BIGINT NOT NULL,
    day DATE NOT NULL,
    custom_json_type_id SMALLINT NOT NULL,
    op_bytes INT,
    rc_exact BIGINT
) WITH (vacuum_truncate = FALSE);

-- The staging steps in levels: every step reads only the stages of the levels before it, so the
-- steps of a level could run at once. scripts/haf_stats_parallel.py runs them one after another
-- in a single round trip instead: on a server where a round trip is slow, a level's own round
-- trip cost more than running its steps at once saved. The exact_rc step stages exact_rc, then
-- custom_json_ops, which joins the shares to the custom_json ops.
DROP FUNCTION IF EXISTS haf_stats_app.shared_batch_stage_levels;
CREATE OR REPLACE FUNCTION haf_stats_app.shared_batch_stage_levels()
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT '[["ops"], ["authored_ops", "exact_rc"]]'::JSONB;
$$;

-- In the calling transaction, makes each of _stages that is complete for exactly
-- _first_block.._last_block the batch's staging: haf_stats_batch_<stage> becomes a temp view of
-- haf_stats_app.shared_batch_<stage>, with the range GUCs its prepare_batch_* function checks.
-- Returns the stages it attached, for detach_shared_batch_stage. FOR SHARE: a step restaging a
-- stage deletes its row first, so a stage is never attached while it is being replaced.
DROP FUNCTION IF EXISTS haf_stats_app.attach_shared_batch_stage;
CREATE OR REPLACE FUNCTION haf_stats_app.attach_shared_batch_stage(
    _first_block INT,
    _last_block INT,
    _stages TEXT []
)
RETURNS TEXT []
LANGUAGE plpgsql
AS $$
DECLARE
    _range_key TEXT := _first_block::TEXT || ':' || _last_block::TEXT;
    _stage haf_stats_app.shared_batch_stage;
    _attached TEXT [] := '{}';
BEGIN
    FOR _stage IN
        SELECT st.*
        FROM haf_stats_app.shared_batch_stage AS st
        WHERE st.stage = ANY(_stages)
          AND st.first_block = _first_block
          AND st.last_block = _last_block
        ORDER BY st.stage
        FOR SHARE
    LOOP
        EXECUTE format('CREATE TEMP VIEW %I AS SELECT * FROM haf_stats_app.%I',
                       'haf_stats_batch_' || _stage.stage, 'shared_batch_' || _stage.stage);
        PERFORM set_config('haf_stats.batch_' || _stage.stage || '_range', _range_key, TRUE);
        IF _stage.stage = 'ops' THEN
            PERFORM set_config('haf_stats.batch_ops_types', _stage.op_types::TEXT, TRUE);
        END IF;
        _attached := _attached || _stage.stage;
    END LOOP;
    RETURN _attached;
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.detach_shared_batch_stage;
CREATE OR REPLACE FUNCTION haf_stats_app.detach_shared_batch_stage(
    _stages TEXT []
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _stage TEXT;
BEGIN
    FOREACH _stage IN ARRAY _stages LOOP
        EXECUTE format('DROP VIEW pg_temp.%I', 'haf_stats_batch_' || _stage);
        PERFORM set_config('haf_stats.batch_' || _stage || '_range', '', TRUE);
    END LOOP;
END;
$$;

-- ANALYZE _table (only _columns, when given) when _rows, the rows a stage just loaded into it, is
-- an order of magnitude off what the planner takes it to hold (pg_class.reltuples, -1 before the
-- table's first ANALYZE). One batch's statistics suit the next, and autovacuum analyzes the
-- tables as their rows are replaced. Counts below 1,000 rows are taken as 1,000: a stage that
-- small is cheap to read whatever the plan, and in the early chain such stages can swing by more
-- than ten times from one batch to the next.
DROP FUNCTION IF EXISTS haf_stats_app.analyze_shared_batch_stage;
CREATE OR REPLACE FUNCTION haf_stats_app.analyze_shared_batch_stage(
    _table REGCLASS,
    _rows BIGINT,
    _columns TEXT [] DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _planned REAL;
BEGIN
    SELECT c.reltuples INTO _planned FROM pg_class AS c WHERE c.oid = _table;
    IF _planned < 0
       OR GREATEST(_rows, 1000) > 10 * GREATEST(_planned, 1000)
       OR GREATEST(_planned, 1000) > 10 * GREATEST(_rows, 1000) THEN
        EXECUTE format('ANALYZE %s %s', _table,
                       CASE WHEN _columns IS NOT NULL THEN
                           '(' || (SELECT string_agg(quote_ident(c), ', ') FROM unnest(_columns) AS c) || ')'
                       ELSE '' END);
    END IF;
END;
$$;

-- One step of shared_batch_stage_levels() for _first_block.._last_block, in a transaction of its
-- own that the caller commits. A no-op when no group will apply the batch from its first block,
-- or when the step's stages are already complete for the range (a batch delivered again after a
-- failed group). The ops step deletes every stage's rows first: the others are built from it.
-- So the later steps find their tables holding no rows: a stage's rows commit only with its
-- marker row, and the step runs only while that marker is missing.
DROP FUNCTION IF EXISTS haf_stats_app.stage_shared_batch;
CREATE OR REPLACE FUNCTION haf_stats_app.stage_shared_batch(
    _step TEXT,
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, haf_stats_app, public
AS $$
DECLARE
    _timed BOOLEAN := current_setting('haf_stats.processor_timings', TRUE) = 'on';
    _t TIMESTAMPTZ;
    _stages TEXT [] := CASE _step
        WHEN 'ops' THEN ARRAY['ops']
        WHEN 'authored_ops' THEN ARRAY['authored_ops']
        WHEN 'exact_rc' THEN ARRAY['exact_rc', 'custom_json_ops']
    END;
    _stage TEXT;
    _types INT [];
    _attached TEXT [] := '{}';
BEGIN
    IF _stages IS NULL THEN
        RAISE EXCEPTION 'haf_stats: unknown batch staging step %', _step;
    END IF;
    IF NOT EXISTS (
        SELECT FROM unnest(haf_stats_app.processor_groups()) AS g (name)
        WHERE haf_stats_app.processor_group_from(g.name, _first_block, _last_block) = _first_block
    ) THEN
        RETURN;
    END IF;
    IF (SELECT COUNT(*) FROM haf_stats_app.shared_batch_stage AS st
        WHERE st.stage = ANY(_stages) AND st.first_block = _first_block AND st.last_block = _last_block
       ) = cardinality(_stages) THEN
        RETURN;
    END IF;

    PERFORM set_config('synchronous_commit', 'off', TRUE);
    IF _step = 'ops' THEN
        -- The marker rows first: deleting one waits for a group still reading its stage.
        DELETE FROM haf_stats_app.shared_batch_stage;
        DELETE FROM haf_stats_app.shared_batch_ops;
        DELETE FROM haf_stats_app.shared_batch_authored_ops;
        DELETE FROM haf_stats_app.shared_batch_exact_rc;
        DELETE FROM haf_stats_app.shared_batch_custom_json_ops;
    ELSE
        _attached := haf_stats_app.attach_shared_batch_stage(_first_block, _last_block, ARRAY['ops']);
        IF _attached <> ARRAY['ops'] THEN
            RAISE EXCEPTION 'haf_stats: blocks %..% have no shared ops stage for the % staging step', _first_block, _last_block, _step;
        END IF;
    END IF;

    -- Each stage's row first: it commits with the rows, and attaching the stage needs it.
    FOREACH _stage IN ARRAY _stages LOOP
        IF _timed THEN _t := clock_timestamp(); END IF;
        IF _stage = 'ops' THEN
            _types := haf_stats_app.batch_op_types(NULL);
        END IF;
        INSERT INTO haf_stats_app.shared_batch_stage (stage, first_block, last_block, op_types)
        VALUES (_stage, _first_block, _last_block, CASE WHEN _stage = 'ops' THEN _types END);
        _attached := _attached || haf_stats_app.attach_shared_batch_stage(_first_block, _last_block, ARRAY[_stage]);
        CASE _stage
        WHEN 'ops' THEN
            PERFORM haf_stats_app.analyze_shared_batch_stage(
                'haf_stats_app.shared_batch_ops',
                haf_stats_app.fill_batch_ops(_first_block, _last_block, _types, TRUE),
                -- Not body_value, as on the temp table.
                ARRAY['op_id', 'block_num', 'trx_in_block', 'op_type_id', 'op_time', 'day', 'op_bytes']);
            IF _timed THEN PERFORM haf_stats_app.report_processor_timing('prepare_batch_ops', _first_block, _last_block, _t, '{non_virtual,author_reward_operation,comment_benefactor_reward_operation,curation_reward_operation,interest_operation,fill_transfer_from_savings_operation,fill_vesting_withdraw_operation,producer_reward_operation,liquidity_reward_operation,proposal_pay_operation,fill_order_operation,account_created_operation,producer_missed_operation,ineffective_delete_comment_operation}', NULL); END IF;
        WHEN 'authored_ops' THEN
            PERFORM haf_stats_app.analyze_shared_batch_stage(
                'haf_stats_app.shared_batch_authored_ops', haf_stats_app.fill_batch_authored_ops());
            IF _timed THEN PERFORM haf_stats_app.report_processor_timing('prepare_batch_authored_ops', _first_block, _last_block, _t, '{non_virtual}', NULL); END IF;
        WHEN 'exact_rc' THEN
            PERFORM haf_stats_app.analyze_shared_batch_stage(
                'haf_stats_app.shared_batch_exact_rc', haf_stats_app.fill_batch_exact_rc(_first_block, _last_block));
            IF _timed THEN PERFORM haf_stats_app.report_processor_timing('prepare_batch_exact_rc', _first_block, _last_block, _t, '{non_virtual}', NULL); END IF;
        WHEN 'custom_json_ops' THEN
            PERFORM haf_stats_app.analyze_shared_batch_stage(
                'haf_stats_app.shared_batch_custom_json_ops', haf_stats_app.fill_batch_custom_json_ops());
            IF _timed THEN PERFORM haf_stats_app.report_processor_timing('prepare_batch_custom_json_ops', _first_block, _last_block, _t, '{custom_json_operation}', NULL); END IF;
        END CASE;
    END LOOP;
    PERFORM haf_stats_app.detach_shared_batch_stage(_attached);
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.run_processor_group;
CREATE OR REPLACE FUNCTION haf_stats_app.run_processor_group(
    _group TEXT,
    _first_block INT,
    _last_block INT,
    _shared TEXT [] DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _timed BOOLEAN := current_setting('haf_stats.processor_timings', TRUE) = 'on';
    _t TIMESTAMPTZ;
BEGIN
    -- Each IF _timed line reports the step above it and restarts the clock. The reads
    -- lists name the op types each step selects (see report_processor_timing). _shared names
    -- the stages attached from the shared batch staging (attach_shared_batch_stage): their
    -- prepare_batch_* calls are no-ops, and stage_shared_batch reported their time.
    IF _timed THEN _t := clock_timestamp(); END IF;
    -- Every processor below reads its operations from what this stages. It is reported once
    -- per batch, as the financial group's: in any other group it is either already done (one
    -- session), shared, or the group's own copy (a connection of its own), whose time is then
    -- in the group's first step.
    PERFORM haf_stats_app.prepare_batch_ops(_first_block, _last_block);
    CASE _group
    WHEN 'financial' THEN
        IF _timed AND NOT 'ops' = ANY(_shared) THEN _t := haf_stats_app.report_processor_timing('prepare_batch_ops', _first_block, _last_block, _t, '{non_virtual,author_reward_operation,comment_benefactor_reward_operation,curation_reward_operation,interest_operation,fill_transfer_from_savings_operation,fill_vesting_withdraw_operation,producer_reward_operation,liquidity_reward_operation,proposal_pay_operation,fill_order_operation,account_created_operation,producer_missed_operation,ineffective_delete_comment_operation}', NULL); END IF;
        PERFORM haf_stats_app.process_financial(_first_block, _last_block);
        IF _timed THEN PERFORM haf_stats_app.report_processor_timing('process_financial', _first_block, _last_block, _t, '{author_reward_operation,comment_benefactor_reward_operation,curation_reward_operation,claim_reward_balance_operation,interest_operation,transfer_operation,transfer_to_savings_operation,transfer_from_savings_operation,fill_transfer_from_savings_operation,transfer_to_vesting_operation,fill_vesting_withdraw_operation,producer_reward_operation,liquidity_reward_operation,proposal_pay_operation,fill_order_operation}', NULL); END IF;
    WHEN 'users' THEN
        PERFORM haf_stats_app.prepare_batch_authored_ops(_first_block, _last_block);
        IF _timed AND NOT 'authored_ops' = ANY(_shared) THEN _t := haf_stats_app.report_processor_timing('prepare_batch_authored_ops', _first_block, _last_block, _t, '{non_virtual}', NULL); END IF;
        PERFORM haf_stats_app.process_account_cohorts(_first_block, _last_block);
        IF _timed THEN _t := haf_stats_app.report_processor_timing('process_account_cohorts', _first_block, _last_block, _t, '{account_created_operation}', NULL); END IF;
        PERFORM haf_stats_app.process_active_users(_first_block, _last_block);
        IF _timed THEN PERFORM haf_stats_app.report_processor_timing('process_active_users', _first_block, _last_block, _t, '{}', NULL); END IF;
    WHEN 'content' THEN
        PERFORM haf_stats_app.process_community_registry(_first_block, _last_block);
        IF _timed THEN _t := haf_stats_app.report_processor_timing('process_community_registry', _first_block, _last_block, _t, '{account_created_operation,custom_json_operation}', NULL); END IF;
        PERFORM haf_stats_app.process_content_stats(_first_block, _last_block);
        IF _timed THEN _t := haf_stats_app.report_processor_timing('process_content_stats', _first_block, _last_block, _t, '{vote_operation,comment_operation,delete_comment_operation,ineffective_delete_comment_operation}', NULL); END IF;
        PERFORM haf_stats_app.process_content_cohorts(_first_block, _last_block);
        IF _timed THEN PERFORM haf_stats_app.report_processor_timing('process_content_cohorts', _first_block, _last_block, _t, '{comment_operation}', NULL); END IF;
    WHEN 'custom_json' THEN
        -- The three rollups that read exact RC each call the first of these, the two custom_json
        -- ones the second, and find them done; called here so their work is a step of its own
        -- rather than part of whichever rollup runs first. On a connection of its own the
        -- network group reads them from the shared batch staging, or, without it, stages them
        -- again inside process_network_ops and process_network_custom_json.
        PERFORM haf_stats_app.prepare_batch_exact_rc(_first_block, _last_block);
        IF _timed AND NOT 'exact_rc' = ANY(_shared) THEN _t := haf_stats_app.report_processor_timing('prepare_batch_exact_rc', _first_block, _last_block, _t, '{non_virtual}', NULL); END IF;
        PERFORM haf_stats_app.prepare_batch_custom_json_ops(_first_block, _last_block);
        IF _timed AND NOT 'custom_json_ops' = ANY(_shared) THEN _t := haf_stats_app.report_processor_timing('prepare_batch_custom_json_ops', _first_block, _last_block, _t, '{custom_json_operation}', NULL); END IF;
        PERFORM haf_stats_app.process_custom_json(_first_block, _last_block);
        IF _timed THEN PERFORM haf_stats_app.report_processor_timing('process_custom_json', _first_block, _last_block, _t, '{custom_json_operation}', NULL); END IF;
    WHEN 'network' THEN
        PERFORM haf_stats_app.process_network_ops(_first_block, _last_block);
        IF _timed THEN _t := haf_stats_app.report_processor_timing('process_network_ops', _first_block, _last_block, _t, '{non_virtual}', NULL); END IF;
        PERFORM haf_stats_app.process_network_custom_json(_first_block, _last_block);
        IF _timed THEN _t := haf_stats_app.report_processor_timing('process_network_custom_json', _first_block, _last_block, _t, '{custom_json_operation}', NULL); END IF;
        -- Reads hafd.blocks and the staged producer_missed ops, so it has no ordering dependency
        -- on any processor above it.
        PERFORM haf_stats_app.process_witness_blocks(_first_block, _last_block);
        IF _timed THEN PERFORM haf_stats_app.report_processor_timing('process_witness_blocks', _first_block, _last_block, _t, '{producer_missed_operation}', NULL); END IF;
    ELSE
        RAISE EXCEPTION 'haf_stats: unknown processor group %', _group;
    END CASE;
END;
$$;

-- One group's share of a massive-sync batch, on a worker connection, in a transaction of its own
-- that the caller commits: the group's processors and its progress row commit together.
-- A no-op when the group has already applied the batch. The batch's rollup refreshes are
-- deferred, as main() and process_blocks() defer them during massive sync.
DROP FUNCTION IF EXISTS haf_stats_app.process_processor_group;
CREATE OR REPLACE FUNCTION haf_stats_app.process_processor_group(
    _group TEXT,
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, haf_stats_app, public
AS $$
DECLARE
    _from INT;
    _shared TEXT [];
BEGIN
    IF NOT _group = ANY(haf_stats_app.processor_groups()) THEN
        RAISE EXCEPTION 'haf_stats: unknown processor group %', _group;
    END IF;
    -- Serialises two calls for the same group (a worker of a coordinator that died, still
    -- running when the batch is delivered again), so the second reads the first's progress row.
    PERFORM pg_advisory_xact_lock(hashtext('haf_stats_app.processor_group_progress'), hashtext(_group));
    _from := haf_stats_app.processor_group_from(_group, _first_block, _last_block);
    IF _from IS NULL THEN
        RETURN;
    END IF;

    -- The massive-sync durability trade main() makes. The batch's own transaction commits after
    -- this one, so its commit record follows this one's in the WAL: a crash cannot keep the
    -- context's move and lose this group's writes.
    PERFORM set_config('synchronous_commit', 'off', TRUE);
    PERFORM haf_stats_app.prepare_rollup_refreshes(TRUE);
    -- The stages are attached only for exactly the share this group applies: a share that
    -- starts past the batch's first block stages its own copy.
    _shared := haf_stats_app.attach_shared_batch_stage(_from, _last_block,
                                                       ARRAY['ops', 'authored_ops', 'exact_rc', 'custom_json_ops']);
    PERFORM haf_stats_app.run_processor_group(_group, _from, _last_block, _shared);
    PERFORM haf_stats_app.detach_shared_batch_stage(_shared);

    INSERT INTO haf_stats_app.processor_group_progress AS p (group_name, first_block, last_block)
    VALUES (_group, _first_block, _last_block)
    ON CONFLICT (group_name) DO UPDATE SET last_block = EXCLUDED.last_block;
END;
$$;

-- What follows the groups in every batch, in the batch's own transaction: process_daily_retention,
-- then the in-flight batch's progress rows, which the groups' writes now stand for, and the marker
-- rows of its shared staging. The staged rows stay until the next batch's ops step replaces them
-- ("Shared batch staging").
DROP FUNCTION IF EXISTS haf_stats_app.finish_block_range;
CREATE OR REPLACE FUNCTION haf_stats_app.finish_block_range(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _timed BOOLEAN := current_setting('haf_stats.processor_timings', TRUE) = 'on';
    _t TIMESTAMPTZ;
BEGIN
    IF _timed THEN _t := clock_timestamp(); END IF;
    PERFORM haf_stats_app.process_daily_retention(_first_block, _last_block);
    IF _timed THEN
        PERFORM haf_stats_app.report_processor_timing('process_daily_retention', _first_block, _last_block, _t, '{}', NULL);
        PERFORM haf_stats_app.report_operation_counts(_first_block, _last_block);
    END IF;
    DELETE FROM haf_stats_app.processor_group_progress;
    DELETE FROM haf_stats_app.shared_batch_stage;
END;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.process_block_range;
CREATE OR REPLACE FUNCTION haf_stats_app.process_block_range(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _group TEXT;
    _from INT;
BEGIN
    -- Every group in this session, skipping what a group already applied in a massive-sync
    -- batch that did not commit (processor_group_progress), e.g. when the parallel path is
    -- switched off after a crash.
    FOREACH _group IN ARRAY haf_stats_app.processor_groups() LOOP
        _from := haf_stats_app.processor_group_from(_group, _first_block, _last_block);
        IF _from IS NOT NULL THEN
            PERFORM haf_stats_app.run_processor_group(_group, _from, _last_block);
        END IF;
    END LOOP;
    PERFORM haf_stats_app.finish_block_range(_first_block, _last_block);
END;
$$;

RESET ROLE;
