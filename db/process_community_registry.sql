SET ROLE haf_stats_owner;

-- Feature: Hive community registry (names, types, titles) — the label side of
-- get_account_community_activity (issue #47, backend for block_explorer_ui#761).
--
-- A community is an ordinary chain account whose name matches ^hive-[1-3][0-9]{4,6}$;
-- the leading digit is its type (1 topic / 2 journal / 3 council). Hivemind only
-- registers such an account as a community when it is created at or after block
-- 37,500,000 (hive/indexer/community.py, start_block) — an identically-named account
-- created earlier is NEVER a community, so no post before that block can belong to one.
-- That single constant is why this processor and the community half of
-- process_content_stats.sql are no-ops over pre-2019 history.
--
-- Human-readable titles exist only in custom_json ops (id = 'community'), never in the
-- post ops:
--     {required_posting_auths: [<signer>], id: "community",
--      json: "[\"updateProps\", {\"community\": \"hive-139531\",
--                                \"props\": {\"title\": \"HiveDevs\", ...}}]"}
-- Anyone can broadcast that op, so an unauthorized one must be ignored or any account
-- could rename any community. Hivemind gates it on the signer holding admin/owner, so we
-- track exactly that much of its role state machine (community_role) and nothing more:
-- mod/member/muted roles are not modelled, since only title authorization needs roles.
--
-- What this does NOT model (documented in the endpoint description too). Note muting is
-- NOT on this list: hivemind's process_community_post resolves community_id from the
-- category (root) or the parent (reply) BEFORE any role check, and a muted or
-- non-member author only sets hive_posts.is_muted — community_id is never cleared. So a
-- muted author's post still belongs to the community, for hivemind and for us alike.
-- The divergences that DO exist:
--   * setRole: we model only owner/admin, since nothing but title authorization needs
--     roles. mod/member/muted grants are ignored, so a community whose title was set by
--     a role we do not track is not reproduced.
--   * type_id is derived from the community NAME at registration. Hivemind seeds it the
--     same way but lets updateProps change it later; we do not follow that.
--   * Registration is gated on the account_created block being >= the start block.

-- ---------------------------------------------------------------------------
-- Shared constants
--
-- SQL-language + IMMUTABLE so the planner inlines them; is_community_name is applied
-- per-row in the content processor's hot path and must not become a function call.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.community_start_block;
CREATE OR REPLACE FUNCTION haf_stats_app.community_start_block()
RETURNS INT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT 37500000;
$$;

DROP FUNCTION IF EXISTS haf_stats_app.is_community_name;
CREATE OR REPLACE FUNCTION haf_stats_app.is_community_name(_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT _name ~ '^hive-[1-3][0-9]{4,6}$';
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.community_start_block() TO haf_stats_user;
GRANT EXECUTE ON FUNCTION haf_stats_app.is_community_name(TEXT) TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- One row per registered community. created_block is what lets the content processor
-- reject a post addressed to a community that did not exist yet (a category can look
-- like a community name years before the account is created).
CREATE TABLE IF NOT EXISTS haf_stats_backend.community_registry (
    community TEXT NOT NULL,
    -- Leading digit of the name: 1 topic, 2 journal, 3 council.
    type_id SMALLINT NOT NULL,
    created_block INT NOT NULL,
    -- Latest title set by an authorized updateProps; NULL until one is seen. The
    -- endpoint falls back to the community name.
    title TEXT,
    PRIMARY KEY (community)
);

GRANT SELECT ON haf_stats_backend.community_registry TO haf_stats_user;

-- Owner/admin role holders per community — the minimum needed to authorize a title
-- change. Seeded at registration with the community account itself as owner (the account
-- that holds the keys is the initial owner), then maintained from setRole ops. A
-- demotion below admin DELETEs the row: this table means "may edit this community's
-- props", so it must not retain revoked authority.
CREATE TABLE IF NOT EXISTS haf_stats_backend.community_role (
    community TEXT NOT NULL,
    account_id INT NOT NULL,
    -- Hivemind Role scale, restricted to what we act on: 8 owner, 6 admin.
    role SMALLINT NOT NULL,
    PRIMARY KEY (community, account_id)
);

GRANT SELECT ON haf_stats_backend.community_role TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Processor
--
-- Two passes per batch:
--   1. Registration — set-based, from the virtual account_created_operation. That vop
--      fires exactly once per account for EVERY creation mechanism (account_create /
--      _with_delegation / create_claimed_account / pow mining), which is why
--      Step 1 of haf_stats_app.process_account_cohorts() (process_account_cohorts.sql)
--      drives off it too rather than the explicit *_create ops.
--   2. Roles + titles — row-at-a-time in op order. A setRole granting admin must be
--      visible to a later updateProps in the SAME batch, so this one cannot be
--      set-based. It is affordable because the loop only ever visits custom_json ops
--      with id = 'community', a tiny slice of the op stream.
--
-- Idempotent, unlike the additive counters elsewhere in this app: registration is
-- ON CONFLICT DO NOTHING and roles/titles are last-writer-wins over an ordered replay.
-- Reprocessing a range therefore cannot corrupt it (it just redoes the same work), which
-- is what lets install_app.sh self-heal it with a plain backfill call.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_app.process_community_registry;
CREATE OR REPLACE FUNCTION haf_stats_app.process_community_registry(
    _first_block INT,
    _last_block INT
)
RETURNS VOID
LANGUAGE plpgsql
SET jit = OFF
AS $$
DECLARE
    _from_block INT;
    _rec RECORD;
    _json JSONB;
    _action TEXT;
    _payload JSONB;
    _community TEXT;
    _signer TEXT;
    _signer_role SMALLINT;
    _target_role SMALLINT;
    _current_target_role SMALLINT;
    _title TEXT;
BEGIN

-- No community can exist before the hivemind start block, so skip the scan entirely for
-- historical ranges. This makes the whole processor free on a pre-2019 replay.
IF _last_block < haf_stats_app.community_start_block() THEN
    RETURN;
END IF;

_from_block := GREATEST(_first_block, haf_stats_app.community_start_block());

-- Pass 1: register communities created in this range, and seed the community account
-- itself as owner so it can immediately set roles and props.
WITH registered AS (
    INSERT INTO haf_stats_backend.community_registry (community, type_id, created_block)
    SELECT
        ov.body_value ->> 'new_account_name',
        SUBSTRING(ov.body_value ->> 'new_account_name' FROM 6 FOR 1)::SMALLINT,
        ov.block_num
    FROM hive.operations_view ov
    WHERE ov.block_num BETWEEN _from_block AND _last_block
      AND ov.op_type_id = (
          SELECT id FROM hafd.operation_types
          WHERE name = 'hive::protocol::account_created_operation'
      )
      AND haf_stats_app.is_community_name(ov.body_value ->> 'new_account_name')
    ON CONFLICT (community) DO NOTHING
    RETURNING community
)
INSERT INTO haf_stats_backend.community_role (community, account_id, role)
SELECT r.community, a.id, 8   -- owner
FROM registered r
JOIN hafd.accounts a ON a.name = r.community
ON CONFLICT (community, account_id) DO UPDATE SET role = EXCLUDED.role;

-- Pass 2: apply community custom_json ops in op order.
FOR _rec IN
    SELECT ov.id, ov.body_value
    FROM hive.operations_view ov
    WHERE ov.block_num BETWEEN _from_block AND _last_block
      AND ov.op_type_id = 18   -- hive::protocol::custom_json_operation
      AND ov.body_value ->> 'id' = 'community'
    ORDER BY ov.id
LOOP
    -- custom_json.json is a free-form STRING: a malformed payload is a normal
    -- occurrence on-chain and must not abort the batch.
    BEGIN
        _json := (_rec.body_value ->> 'json')::JSONB;
    EXCEPTION WHEN OTHERS THEN
        _json := NULL;
    END;

    IF _json IS NULL OR JSONB_TYPEOF(_json) <> 'array' THEN
        CONTINUE;
    END IF;

    _action := _json ->> 0;
    _payload := _json -> 1;

    -- IS NULL is required, not decorative: `->> 0` yields SQL NULL for a JSON null, and
    -- "NULL NOT IN (...)" evaluates to NULL, not TRUE — so a payload like [null, {...}]
    -- would slip past this gate and fall through to the setRole branch below.
    IF _action IS NULL
       OR _action NOT IN ('setRole', 'updateProps')
       OR _payload IS NULL OR JSONB_TYPEOF(_payload) <> 'object' THEN
        CONTINUE;
    END IF;

    _community := _payload ->> 'community';
    _signer := _rec.body_value -> 'required_posting_auths' ->> 0;

    IF _community IS NULL OR _signer IS NULL THEN
        CONTINUE;
    END IF;

    -- Only act on communities we have actually registered: an op naming an unregistered
    -- (or pre-start-block) account is not a community op.
    IF NOT EXISTS (
        SELECT 1 FROM haf_stats_backend.community_registry cr
        WHERE cr.community = _community
    ) THEN
        CONTINUE;
    END IF;

    SELECT COALESCE(MAX(role), 0)::SMALLINT INTO _signer_role
    FROM haf_stats_backend.community_role r
    JOIN hafd.accounts a ON a.id = r.account_id
    WHERE r.community = _community AND a.name = _signer;

    -- Everything below needs admin (6) or owner (8); a guest broadcasting these ops is
    -- exactly the spoofing case this gate exists for.
    IF _signer_role < 6 THEN
        CONTINUE;
    END IF;

    IF _action = 'updateProps' THEN
        -- updateProps carries the whole props object; a call that omits title leaves the
        -- stored one alone.
        --
        -- Hivemind REJECTS a bad title rather than repairing it: CommunityOp._read_props
        -- calls read_key_str(props, 'title', 20), which asserts the value is a string, is
        -- already stripped, is at most 20 characters, and does not start with '@' or '#';
        -- any AssertionError aborts validate() and the WHOLE op is discarded. Truncating
        -- to fit (as an earlier revision did) would store titles no Hive frontend shows,
        -- and would make the hivemind oracle's title check fire and blame the role gate.
        _title := _payload -> 'props' ->> 'title';
        IF _title IS NOT NULL
           AND _title = BTRIM(_title)
           AND LENGTH(_title) BETWEEN 1 AND 20
           AND LEFT(_title, 1) NOT IN ('@', '#') THEN
            UPDATE haf_stats_backend.community_registry
            SET title = _title
            WHERE community = _community;
        END IF;
        CONTINUE;
    END IF;

    -- setRole: {community, account, role}. We persist only owner/admin; anything lower
    -- REVOKES, so a demoted admin stops being able to rename the community.
    _target_role := CASE _payload ->> 'role'
        WHEN 'owner' THEN 8
        WHEN 'admin' THEN 6
        WHEN 'mod' THEN 4
        WHEN 'member' THEN 2
        WHEN 'guest' THEN 0
        WHEN 'muted' THEN -2
    END;

    -- Hivemind forbids granting a role at or above your own.
    IF _target_role IS NULL OR _target_role >= _signer_role THEN
        CONTINUE;
    END IF;

    -- ...and it also protects the TARGET: community_set_role refuses when the target
    -- already outranks (or matches) the signer, and the owner can never be demoted.
    -- Without this an admin could strip the owner's role and then, with the owner gone,
    -- the community's title becomes editable by whoever remains.
    SELECT COALESCE(MAX(r.role), 0)::SMALLINT INTO _current_target_role
    FROM haf_stats_backend.community_role r
    JOIN hafd.accounts a ON a.id = r.account_id
    WHERE r.community = _community AND a.name = _payload ->> 'account';

    IF _current_target_role = 8
       OR (_current_target_role >= _signer_role AND (_payload ->> 'account') IS DISTINCT FROM _signer) THEN
        CONTINUE;
    END IF;

    IF _target_role >= 6 THEN
        INSERT INTO haf_stats_backend.community_role (community, account_id, role)
        SELECT _community, a.id, _target_role
        FROM hafd.accounts a
        WHERE a.name = _payload ->> 'account'
        ON CONFLICT (community, account_id) DO UPDATE SET role = EXCLUDED.role;
    ELSE
        DELETE FROM haf_stats_backend.community_role r
        USING hafd.accounts a
        WHERE r.community = _community
          AND r.account_id = a.id
          AND a.name = _payload ->> 'account';
    END IF;
END LOOP;

END;
$$;

RESET ROLE;
