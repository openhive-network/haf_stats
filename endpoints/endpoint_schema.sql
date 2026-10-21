SET ROLE haf_stats_owner;

-- ---------------------------------------------------------------------------
-- #23: from_date / to_date filter inputs accept EITHER a block number OR a
-- date/timestamp string. Co-located here (not db/) so it is present whenever the
-- endpoints are installed, including the stub endpoint-test stack that loads only
-- this file. Integer -> that block's date; anything else -> parsed date; NULL/'' ->
-- the caller default. NOTE: resolution reads hafd.blocks (irreversible blocks only)
-- and clamps via LEAST(_block, MAX(num)); a still-reversible (very recent) block
-- number therefore resolves to the head irreversible block's date. Harmless at the
-- day-bucket granularity of these endpoints.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS haf_stats_app.to_filter_date;
CREATE OR REPLACE FUNCTION haf_stats_app.to_filter_date(_input TEXT, _default DATE)
RETURNS DATE
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    _block BIGINT;
    _result DATE;
BEGIN
    _input := TRIM('"' FROM COALESCE(_input, ''));
    IF _input = '' THEN
        RETURN _default;
    END IF;

    BEGIN
        _block := _input::BIGINT;
    EXCEPTION WHEN OTHERS THEN
        _block := NULL;
    END;

    IF _block IS NOT NULL THEN
        IF _block <= 0 THEN
            RAISE SQLSTATE '22023' USING
                MESSAGE = 'block number must be positive, got: ' || _input;
        END IF;
        SELECT b.created_at::DATE INTO _result
        FROM hafd.blocks b
        WHERE b.num = LEAST(_block, (SELECT MAX(num) FROM hafd.blocks));
        RETURN _result;
    END IF;

    BEGIN
        RETURN _input::DATE;
    EXCEPTION WHEN OTHERS THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid from/to value (expected a block number or YYYY-MM-DD date): ' || _input;
    END;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.to_filter_date(TEXT, DATE) TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- #48: parse a free-form custom_json payload without aborting the query.
--
-- custom_json.json is an arbitrary caller-supplied STRING, so a malformed payload is a
-- normal on-chain occurrence and a bare ::JSONB cast would kill the whole request. The
-- exception trap is the idiom this repo already uses for exactly this hazard
-- (haf_stats_app.get_required_authorities_safe, and the per-row BEGIN/EXCEPTION in
-- process_community_registry's role replay).
--
-- Deliberately NOT `IS JSON`: that predicate is PostgreSQL 16+, and the stub endpoint-test
-- gate runs postgres:14-alpine (docker/docker-compose-ci.yml). Loading this file there under
-- ON_ERROR_STOP would fail at CREATE FUNCTION — plpgsql raw-parses embedded SQL when
-- check_function_bodies is on — taking down every stub-lane test, not just this endpoint's.
-- JSON_QUERY(... NULL ON ERROR) is PG17+ and is worse. Keep this PG14-safe.
--
-- Co-located here (not db/) for the same reason as to_filter_date above: the stub stack
-- loads only this file, so a helper in an unmounted db/*.sql would not exist there.
DROP FUNCTION IF EXISTS haf_stats_app.try_jsonb;
CREATE OR REPLACE FUNCTION haf_stats_app.try_jsonb(_txt TEXT)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
BEGIN
    RETURN _txt::JSONB;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.try_jsonb(TEXT) TO haf_stats_user;

-- #48: per-op-type ceiling on how many of an account's operations get_account_interactions
-- will resolve bodies for. The cost driver is a random heap fetch of each op's body, and those
-- bodies are scattered across the account's whole history; the index scan that selects them is
-- ~200x cheaper.
--
-- The number to reason about is ntypes x cap, NOT cap: a default (unfiltered) request budgets
-- op types 0/1/2/18 independently, so it can fetch FOUR pages. 4 x 4,000 = 16,000 bodies worst
-- case, ~10-14s cold at the rates below, comfortably inside the API statement_timeout. (An
-- earlier revision set 10,000 here and claimed a 5x cold improvement over the previous shared
-- 50,000 budget; per-type that is really 40,000 ops, i.e. ~1.25x, and it straddled the timeout.)
--
-- 4,000 is set from COLD-cache measurements on a full multi-TB node, not from a test box.
-- An earlier 50,000 was calibrated against a 16 GB database resident in a 32 GB buffer cache,
-- where it looked like ~0.5s — on a real node the same ceiling cost ~0.6-0.9 ms/op of random
-- I/O, putting a merely moderate account (~43k ops) at 28s cold and heavy accounts near 90s.
-- That is past any sane proxy read timeout and is exactly the random-read profile that starves
-- co-tenant apps on a shared node. Cold cost scales roughly linearly with ops fetched. A Sankey
-- renders a handful of partners, and covered_from discloses the shorter window, so the picture
-- barely changes for the vast majority of accounts.
--
-- A FUNCTION rather than a literal so tests can lower it and prove the guard fires: the
-- busiest account in the entire 5M-block CI replay corpus signs ~25,000 relevant ops, well
-- under any production-sane ceiling, so a hardcoded constant would be untestable in both CI
-- lanes — the vacuous-pass trap. Same inlinable-constant shape as
-- haf_stats_app.community_start_block().
DROP FUNCTION IF EXISTS haf_stats_app.max_interaction_ops;
CREATE OR REPLACE FUNCTION haf_stats_app.max_interaction_ops()
RETURNS INT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT 4000;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.max_interaction_ops() TO haf_stats_user;

-- Date range -> block range, for the on-demand account endpoints that then translate blocks
-- into an account_op_seq_no window.
--
-- Two single-row indexed probes, NOT MIN/MAX over a created_at filter: a combined aggregate
-- cannot use the created_at index and seq-scans hafd.blocks (~71s on a full node). num is
-- monotonic with created_at, so the earliest block at/after _from and the latest before
-- _to + 1 ARE the range bounds. (#33 perf)
--
-- Extracted because this pair was copy-pasted into three endpoints and the copies had already
-- drifted: only the newest carried the inverted-range guard, so an inverted range
-- short-circuited there while falling through to the seq binary search in the other two.
-- Returns NULLs when the range selects no blocks or comes out inverted, so every caller
-- short-circuits identically.
DROP FUNCTION IF EXISTS haf_stats_app.block_range_for_dates;
CREATE OR REPLACE FUNCTION haf_stats_app.block_range_for_dates(_from DATE, _to DATE)
RETURNS TABLE (from_block INT, to_block INT)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    _fb INT;
    _tb INT;
BEGIN
    SELECT b.num INTO _fb FROM hafd.blocks b
        WHERE b.created_at >= _from::timestamp ORDER BY b.created_at ASC LIMIT 1;
    SELECT b.num INTO _tb FROM hafd.blocks b
        WHERE b.created_at < (_to + 1)::timestamp ORDER BY b.created_at DESC LIMIT 1;

    IF _fb IS NULL OR _tb IS NULL OR _fb > _tb THEN
        RETURN;
    END IF;

    from_block := _fb;
    to_block := _tb;
    RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.block_range_for_dates(DATE, DATE) TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- custom_json id -> DApp name resolution (single source of truth).
-- Longest registered app_id_pattern that is a prefix of the id wins; a secondary
-- sort by pattern makes equal-length ties deterministic; unmatched ids fall back
-- to the raw id. Shared by every endpoint that labels a custom_json app
-- (get_account_rc_footprint group_by=app, get_account_rc_footprint_timeline), so
-- the resolved label is identical across them by construction. Co-located here (not
-- db/) so it installs with the endpoints, including the stub endpoint-test stack.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS haf_stats_app.resolve_dapp_name;
CREATE OR REPLACE FUNCTION haf_stats_app.resolve_dapp_name(_json_id TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (
            SELECT r.app_name
            FROM haf_stats_backend.custom_json_app_registry r
            WHERE starts_with(_json_id, r.app_id_pattern)
            ORDER BY LENGTH(r.app_id_pattern) DESC, r.app_id_pattern
            LIMIT 1
        ),
        _json_id
    )
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.resolve_dapp_name(TEXT) TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- custom_json id -> registry category resolution (single source of truth).
-- Same longest-prefix starts_with match as resolve_dapp_name, but returns the
-- app's category; an id matching no pattern falls back to 'Uncategorized' (the
-- same runtime fallback get_account_dapp_footprint uses). Shared by
-- get_account_rc_footprint group_by=category and get_account_rc_footprint_timeline
-- category_filter, so the category label is identical across them by construction.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS haf_stats_app.resolve_dapp_category;
CREATE OR REPLACE FUNCTION haf_stats_app.resolve_dapp_category(_json_id TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (
            SELECT r.category
            FROM haf_stats_backend.custom_json_app_registry r
            WHERE starts_with(_json_id, r.app_id_pattern)
            ORDER BY LENGTH(r.app_id_pattern) DESC, r.app_id_pattern
            LIMIT 1
        ),
        'Uncategorized'
    )
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.resolve_dapp_category(TEXT) TO haf_stats_user;

-- ---------------------------------------------------------------------------
-- Both labels of a custom_json id in ONE registry probe (issue #49).
--
-- resolve_dapp_name and resolve_dapp_category run the identical longest-prefix match and
-- differ only in the column they project and the fallback they apply, so an endpoint that
-- needs both - which is every endpoint that groups by app OR category - paid the probe twice.
-- Worse, neither scalar can be inlined: their bodies are COALESCE(<SubLink>, ...), and
-- inline_function rejects a body containing a SubLink, so each call is also a full function
-- invocation. This set-returning form has a FROM clause instead, which SQL SRF inlining DOES
-- accept, so CROSS JOIN LATERAL resolve_dapp(id) expands into a plain lateral join with no
-- call overhead at all.
--
-- Always returns exactly one row (the (SELECT 1) z(x) driver), so a CROSS JOIN LATERAL never
-- drops its driving row. Returns the same labels as the two scalars for every input, fallbacks
-- included; keep all three in step if the match rule ever changes.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS haf_stats_app.resolve_dapp;
CREATE OR REPLACE FUNCTION haf_stats_app.resolve_dapp(_json_id TEXT)
RETURNS TABLE (app_name TEXT, category TEXT)
LANGUAGE sql
STABLE
AS $$
    SELECT
        COALESCE(r.app_name, _json_id)        AS app_name,
        COALESCE(r.category, 'Uncategorized') AS category
    FROM (SELECT 1) z(x)
    LEFT JOIN LATERAL (
        SELECT reg.app_name, reg.category
        FROM haf_stats_backend.custom_json_app_registry reg
        WHERE starts_with(_json_id, reg.app_id_pattern)
        ORDER BY LENGTH(reg.app_id_pattern) DESC, reg.app_id_pattern
        LIMIT 1
    ) r ON TRUE
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.resolve_dapp(TEXT) TO haf_stats_user;

-- get_network_top_accounts window decomposition (issue #37). Splits [_from, _to]
-- into the full interior months served from the *_monthly rollups plus the partial
-- leading/trailing months served from the daily tables. Extracted from the endpoint
-- so the split — in particular the current-month seal guard — is unit-testable with an
-- injected _now (the endpoint passes NOW()::DATE; the parity suite passes literals,
-- since a replay-based HTTP test can never make "the trailing month == the current
-- month AND has data"). IMMUTABLE: a pure function of its three arguments.
--
-- Unused sub-ranges get an inverted [3000-01-01, 1900-01-01] bound so their index scan
-- returns nothing. Guarantee (verified in tests/parity): the leading days, trailing
-- days, and full months (expanded to days) partition [_from, _to] exactly — every day
-- covered once, nothing outside. The trailing month folds into the rollup only when it
-- is (a) fully elapsed (_to is its last day) AND (b) sealed (not the in-progress current
-- month) — the rollup lags daily by up to one refresh gate (~1h), so the current month
-- must come from daily to stay byte-exact even when queried on its final calendar day.
-- Interior/leading rollup months are always strictly before the trailing month (hence
-- sealed); a leading current month only arises in the same-month all-daily case.
DROP FUNCTION IF EXISTS haf_stats_app.top_accounts_window;
CREATE OR REPLACE FUNCTION haf_stats_app.top_accounts_window(
    _from DATE,
    _to DATE,
    _now DATE,
    OUT lead_from DATE,
    OUT lead_to DATE,
    OUT trail_from DATE,
    OUT trail_to DATE,
    OUT mm_from DATE,
    OUT mm_to DATE
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    _m_from DATE := DATE_TRUNC('month', _from)::DATE;  -- first day of _from's month
    _m_to   DATE := DATE_TRUNC('month', _to)::DATE;    -- first day of _to's month
    _empty_from CONSTANT DATE := DATE '3000-01-01';
    _empty_to   CONSTANT DATE := DATE '1900-01-01';
BEGIN
    IF _m_from = _m_to THEN
        -- Single calendar month: read it all from daily; no rollup, no trailing piece.
        lead_from  := _from;       lead_to  := _to;
        trail_from := _empty_from; trail_to := _empty_to;
        mm_from    := _empty_from;  mm_to   := _empty_to;
    ELSE
        -- Leading month: whole month -> rollup when _from is the 1st, else daily to month end.
        IF _from = _m_from THEN
            lead_from := _empty_from; lead_to := _empty_to;
            mm_from   := _m_from;
        ELSE
            lead_from := _from;
            lead_to   := (_m_from + INTERVAL '1 month' - INTERVAL '1 day')::DATE;
            mm_from   := (_m_from + INTERVAL '1 month')::DATE;
        END IF;
        -- Trailing month: fold into the rollup only when fully elapsed AND sealed.
        IF _to = (_m_to + INTERVAL '1 month' - INTERVAL '1 day')::DATE
           AND _m_to < DATE_TRUNC('month', _now)::DATE THEN
            trail_from := _empty_from; trail_to := _empty_to;
            mm_to      := _m_to;
        ELSE
            trail_from := _m_to;
            trail_to   := _to;
            mm_to      := (_m_to - INTERVAL '1 month')::DATE;
        END IF;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION haf_stats_app.top_accounts_window(DATE, DATE, DATE) TO haf_stats_user;

/** openapi
openapi: 3.1.0
info:
  title: HAF Stats - Blockchain Analytics
  description: >-
    Blockchain statistics and analytics API for the Hive network.
    Provides per-account financial summaries, RC usage breakdowns,
    and network-wide stake distribution.
  license:
    name: MIT License
    url: https://opensource.org/license/mit
  version: 1.0.0
externalDocs:
  description: HAF Stats GitLab repository
  url: https://gitlab.syncad.com/hive/haf_stats
tags:
  - name: Account
    description: Per-account analytics
  - name: Network
    description: Network-wide statistics
  - name: Witnesses
    description: Witness block production and reliability
  - name: Other
    description: Health and version endpoints
servers:
  - url: /haf-stats-api
components:
  schemas:
    # NULLABILITY CRITERION for this document (#68): a field is declared
    # `[type, "null"]` when the code that WRITES it can emit a null -- the SELECT
    # passes it through NULLIF, or a nullable column is populated by an expression
    # that can yield null. Not "the DDL permits null": haf_stats_backend
    # .governance_concentration_snapshot.total_hp_holders is a nullable column, but
    # its only writer sets it from COUNT(*) OVER () and emits no row at all when
    # there is nothing to count, so it cannot arrive null and is not marked. Its
    # five siblings on that same row CAN, because a zero total_vesting_fund_hive
    # nulls the ratio they derive from.
    #
    # Defensive NULLIFs are included even where a null looks unreachable today: if
    # it is genuinely unreachable the NULLIF should be removed, and until it is,
    # the document should not claim more than the query guarantees. Stated here
    # because an earlier pass marked some NULLIF-derived fields and not others with
    # nothing recording why.
    PostgrestError:
      # The body PostgREST returns for any request it rejects. Declared once and
      # referenced from every path: the shape is PostgREST's, not ours, and is identical
      # everywhere. Lifted from the negative tavern suites (under tests/tavern, in files
      # named .pat.json) rather than invented.
      #
      # Note for editors, kept here rather than in a response description because that
      # text is published to API consumers: never write a C-style comment open or close
      # sequence anywhere in these annotations. Either one ends or nests the enclosing
      # block, and psql then reports an unterminated comment hundreds of lines away from
      # the line that caused it. tests/unit/test_sql_comment_balance.py enforces this.
      type: object
      required: [code, message, details, hint]
      properties:
        code:
          type: string
          description: >-
            PostgreSQL SQLSTATE, or a PostgREST code for a request rejected before any
            function runs. Measured on this API: 22023 (an endpoint rejected an
            argument), 22P02 (a non-integer where an integer was expected), 42703 (an
            unknown column in a PostgREST filter), PGRST100 (an unparseable query
            string), and 53000 on /sync-status, which shares this schema for its 503.
            Do not switch on 22023 alone.
        message:
          type: string
          description: Human-readable explanation, usually naming the offending value.
        details:
          type:
            - string
            - "null"
        hint:
          type:
            - string
            - "null"
          description: >-
            Frequently populated for enum-valued parameters, e.g. "Must be one of: day,
            week, month".
  responses:
    BadRequest:
      description: >-
        The request was rejected. This covers both an endpoint rejecting an argument
        (SQLSTATE 22023, raised by the endpoint function or by
        haf_stats_app.to_filter_date) and PostgREST rejecting the request before any
        function runs -- an unparseable query string, an unknown column in a filter, or
        a value that will not cast to the parameter's type. The rewriter passes the
        query string through untouched, so the latter applies to every path including
        those that declare no parameters of their own.

        Declared for the same reason /sync-status declares its 503: prose in a 200
        description is not part of any machine-readable contract, so a client generated
        from a 200-only spec models the endpoint as infallible and throws on the body
        below.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/PostgrestError'
          # PGRST100 deliberately, not a 22023 parameter error: this response is
          # shared by all 24 paths, and six of them declare no parameters at all, so a
          # `invalid granularity` example would document an error those paths cannot
          # produce -- the same defect as omitting a reachable one. Measured reachable
          # on every path, including /version and /health, via `?order=;`.
          example:
            code: PGRST100
            message: '"failed to parse order ()" (line 1, column 1)'
            details: 'unexpected end of input expecting field name (* or [a..z0..9_])'
            hint: null
 */

-- ---------------------------------------------------------------------------
-- root() - serves the full OpenAPI spec at GET /
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS haf_stats_endpoints.root;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.root() RETURNS json
LANGUAGE plpgsql STABLE
AS $func$
DECLARE
    -- #70: the base URL the document advertises is deployment-specific, so it is
    -- patched in below rather than baked into the generated blob. Declared BEFORE the
    -- generated region -- scripts/openapi_rewrite.sh rewrites only what sits between
    -- the markers, so anything added here or after them survives regeneration.
    _base TEXT;

    -- The OpenAPI spec below is generated from the /** openapi ... */ annotations
    -- in this file by scripts/openapi_rewrite.sh (it fills the block after the
    -- "-- openapi-spec" marker). Edit the annotations, not the generated JSON.
-- openapi-spec
-- openapi-generated-code-begin
  openapi json = $$
{
  "openapi": "3.1.0",
  "info": {
    "title": "HAF Stats - Blockchain Analytics",
    "description": "Blockchain statistics and analytics API for the Hive network. Provides per-account financial summaries, RC usage breakdowns, and network-wide stake distribution.",
    "license": {
      "name": "MIT License",
      "url": "https://opensource.org/license/mit"
    },
    "version": "1.0.0"
  },
  "externalDocs": {
    "description": "HAF Stats GitLab repository",
    "url": "https://gitlab.syncad.com/hive/haf_stats"
  },
  "tags": [
    {
      "name": "Account",
      "description": "Per-account analytics"
    },
    {
      "name": "Network",
      "description": "Network-wide statistics"
    },
    {
      "name": "Witnesses",
      "description": "Witness block production and reliability"
    },
    {
      "name": "Other",
      "description": "Health and version endpoints"
    }
  ],
  "servers": [
    {
      "url": "/haf-stats-api"
    }
  ],
  "components": {
    "schemas": {
      "PostgrestError": {
        "type": "object",
        "required": [
          "code",
          "message",
          "details",
          "hint"
        ],
        "properties": {
          "code": {
            "type": "string",
            "description": "PostgreSQL SQLSTATE, or a PostgREST code for a request rejected before any function runs. Measured on this API: 22023 (an endpoint rejected an argument), 22P02 (a non-integer where an integer was expected), 42703 (an unknown column in a PostgREST filter), PGRST100 (an unparseable query string), and 53000 on /sync-status, which shares this schema for its 503. Do not switch on 22023 alone."
          },
          "message": {
            "type": "string",
            "description": "Human-readable explanation, usually naming the offending value."
          },
          "details": {
            "type": [
              "string",
              "null"
            ]
          },
          "hint": {
            "type": [
              "string",
              "null"
            ],
            "description": "Frequently populated for enum-valued parameters, e.g. \"Must be one of: day, week, month\"."
          }
        }
      }
    },
    "responses": {
      "BadRequest": {
        "description": "The request was rejected. This covers both an endpoint rejecting an argument (SQLSTATE 22023, raised by the endpoint function or by haf_stats_app.to_filter_date) and PostgREST rejecting the request before any function runs -- an unparseable query string, an unknown column in a filter, or a value that will not cast to the parameter's type. The rewriter passes the query string through untouched, so the latter applies to every path including those that declare no parameters of their own.\nDeclared for the same reason /sync-status declares its 503: prose in a 200 description is not part of any machine-readable contract, so a client generated from a 200-only spec models the endpoint as infallible and throws on the body below.",
        "content": {
          "application/json": {
            "schema": {
              "$ref": "#/components/schemas/PostgrestError"
            },
            "example": {
              "code": "PGRST100",
              "message": "\"failed to parse order ()\" (line 1, column 1)",
              "details": "unexpected end of input expecting field name (* or [a..z0..9_])",
              "hint": null
            }
          }
        }
      }
    }
  },
  "paths": {
    "/version": {
      "get": {
        "tags": [
          "Other"
        ],
        "summary": "Application version",
        "description": "Returns the git hash of the currently deployed version.",
        "operationId": "haf_stats_endpoints.get_version",
        "responses": {
          "200": {
            "description": "Git hash string",
            "content": {
              "application/json": {
                "schema": {
                  "type": "string"
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/health": {
      "get": {
        "tags": [
          "Other"
        ],
        "summary": "Health check",
        "description": "Returns service health, last processed block number, and whether the per-account community dimension has been backfilled.",
        "operationId": "haf_stats_endpoints.get_health",
        "responses": {
          "200": {
            "description": "Health status",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(status TEXT, last_processed_block INT, version TEXT, community_data_ready BOOLEAN)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "status": {
                        "type": "string",
                        "example": "ok"
                      },
                      "last_processed_block": {
                        "type": "integer"
                      },
                      "version": {
                        "type": "string"
                      },
                      "community_data_ready": {
                        "type": "boolean",
                        "description": "False when this node has processed past the community start block (37,500,000) but holds no per-account community rows \u2014 i.e. it synced before the community feature and scripts/rebuild_content_volume.sh has not been run yet. get_account_community_activity still answers on such a node, but reports everything under the personal-blog bucket."
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/sync-status": {
      "get": {
        "tags": [
          "Other"
        ],
        "summary": "Sync status",
        "description": "Returns the block this node has consumed as tracked by HAF itself (hafd.contexts.current_block_num for the haf_stats context), with that block's timestamp (UTC). This is the uniform HAF-app sync/health endpoint shape shared with the other HAF apps: the timestamp lets a consumer compute staleness with a single call (age = now() - last_block_time) without needing a separate head-block reference.\n\nNot the same number as /health, which reports haf_stats_app.app_status.last_processed_block - the app's own bookkeeping row. The two are one clock on a node the processor drives (main() writes both from the same variable in the same transaction), so they normally agree exactly; hafd.contexts is HAF's authoritative pointer and is what the rest of the ecosystem exposes under this name.",
        "operationId": "haf_stats_endpoints.get_sync_status",
        "responses": {
          "200": {
            "description": "Last block consumed by the haf_stats HAF context, and its timestamp. last_block_time is null when that block has no hafd.blocks row - i.e. nothing has been processed yet (there is no block 0), or the node is pruned and the context is behind the prune tail.\n\nTwo conditions answer 503 rather than 200: the HAF instance is still in massive sync (indexes not yet built), so the call fails fast instead of executing an unindexed lookup; or the HAF context is missing or not visible, which is reported rather than served as a healthy-looking body.",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "JSON",
                  "type": "object",
                  "required": [
                    "last_block_num",
                    "last_block_time"
                  ],
                  "properties": {
                    "last_block_num": {
                      "type": "integer",
                      "description": "last block consumed by the haf_stats HAF context"
                    },
                    "last_block_time": {
                      "type": [
                        "string",
                        "null"
                      ],
                      "format": "date-time",
                      "description": "UTC timestamp of that block; null if it has no hafd.blocks row"
                    }
                  }
                },
                "example": {
                  "last_block_num": 5000000,
                  "last_block_time": "2016-09-15T19:47:21"
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          },
          "503": {
            "description": "Temporarily unavailable, and the two cases are distinguished by message rather than by status. Either the HAF instance is still in massive sync (hafd.blocks' primary key is dropped for the duration, so the call fails fast instead of seq-scanning the largest table in the database), or the HAF context is missing or not visible to the reader. Both are raised as SQLSTATE 53000, which PostgREST maps to 503. Declared because prose in a 200 description is not part of any machine-readable contract: a client generated from a 200-only spec models this endpoint as infallible and throws on the error body below.",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/PostgrestError"
                },
                "example": {
                  "code": "53000",
                  "message": "HAF instance is not ready (massive sync in progress)",
                  "details": null,
                  "hint": null
                }
              }
            }
          }
        }
      }
    },
    "/account/{account}/financial-summary": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account financial summary",
        "description": "Aggregated HBD/HIVE/VESTS flows for an account over a time range, grouped by financial category and direction (incoming/outgoing).",
        "operationId": "haf_stats_endpoints.get_account_financial_summary",
        "parameters": [
          {
            "in": "path",
            "name": "account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive, defaults to 1 year ago"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "type": "string",
              "default": "month",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Aggregation granularity"
          }
        ],
        "responses": {
          "200": {
            "description": "Financial summary rows grouped by period and category",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, category TEXT, direction TEXT, hive_nai BIGINT, hbd_nai BIGINT, vests_nai BIGINT, op_count INT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": "string",
                        "description": "ISO-8601 date string for the aggregation bucket"
                      },
                      "category": {
                        "type": "string",
                        "description": "Canonical Hive operation type name, e.g. author_reward_operation"
                      },
                      "direction": {
                        "type": "string",
                        "enum": [
                          "incoming",
                          "outgoing"
                        ]
                      },
                      "hive_nai": {
                        "type": "integer"
                      },
                      "hbd_nai": {
                        "type": "integer"
                      },
                      "vests_nai": {
                        "type": "integer"
                      },
                      "op_count": {
                        "type": "integer"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/account/{account}/content-stats": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account content stats",
        "description": "Per-account posting and engagement summary \u2014 posts, comments, votes cast, votes received, replies received, and author rewards \u2014 aggregated by the chosen granularity. Author reward figures are sourced from the account's financial daily aggregates. Post and comment counts reflect content-creation events only (edits excluded): every creation is counted at creation time, including content later deleted or re-created under the same permlink, so figures can slightly exceed Hivemind, which counts only currently-live content. The difference is negligible in practice.",
        "operationId": "haf_stats_endpoints.get_account_content_stats",
        "parameters": [
          {
            "in": "path",
            "name": "account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "type": "string",
              "default": "month",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Aggregation granularity"
          }
        ],
        "responses": {
          "200": {
            "description": "Content and engagement rows grouped by period",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, posts BIGINT, comments BIGINT, votes_cast BIGINT, votes_received BIGINT, replies_received BIGINT, author_reward_hive_nai BIGINT, author_reward_hbd_nai BIGINT, author_reward_vests_nai BIGINT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": "string",
                        "description": "ISO-8601 date string for the aggregation bucket"
                      },
                      "posts": {
                        "type": "integer",
                        "description": "Root posts authored (parent_author = ''), counted at creation; edits excluded"
                      },
                      "comments": {
                        "type": "integer",
                        "description": "Replies authored (parent_author <> ''), counted at creation; edits excluded"
                      },
                      "votes_cast": {
                        "type": "integer"
                      },
                      "votes_received": {
                        "type": "integer"
                      },
                      "replies_received": {
                        "type": "integer"
                      },
                      "author_reward_hive_nai": {
                        "type": "integer"
                      },
                      "author_reward_hbd_nai": {
                        "type": "integer"
                      },
                      "author_reward_vests_nai": {
                        "type": "integer"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/account/{account}/community-activity": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account activity by community",
        "description": "Per-account created posts and comments grouped by Hive community, for the Community Activity treemap. A post belongs to the community named by its category; a reply belongs to its ROOT post's community, not its immediate parent's, matching how the chain propagates a thread's category to every descendant. Content outside any community \u2014 personal-blog posts and the legacy tag categories that predate communities \u2014 is returned as a single bucket with a null community, so the buckets always sum to get_account_content_stats' posts and comments for the same range. Counts are creations only (edits excluded), counted at creation time, exactly as get_account_content_stats counts them \u2014 so content later deleted is still counted, which is the main reason a figure here can exceed what Hivemind currently shows as live. Muting does NOT change community membership: Hivemind assigns community_id before any role check and only flags the post as muted, so muted and non-member posts belong to the community for both Hivemind and this endpoint. Communities are recognised from block 37,500,000 onward (Hivemind's community start block); nothing before it can belong to a community. Community titles follow Hivemind's rules for owner/admin updateProps; roles below admin are not modelled, so a title set through a role this app does not track is not reflected.",
        "operationId": "haf_stats_endpoints.get_account_community_activity",
        "parameters": [
          {
            "in": "path",
            "name": "account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          }
        ],
        "responses": {
          "200": {
            "description": "One row per community the account was active in, plus the no-community bucket",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(community TEXT, title TEXT, post_count BIGINT, comment_count BIGINT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "community": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "Community account name (e.g. hive-139531), or null for the personal-blog / no-community bucket"
                      },
                      "title": {
                        "type": "string",
                        "description": "Community title as set on-chain by an owner/admin updateProps; falls back to the community name when none was ever set"
                      },
                      "post_count": {
                        "type": "integer",
                        "description": "Root posts created in this community"
                      },
                      "comment_count": {
                        "type": "integer",
                        "description": "Replies created anywhere in a thread rooted in this community"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/account/{account}/interactions": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account interaction graph",
        "description": "Per-account OUTGOING interactions grouped by type and counterparty, for the Social Interaction Sankey (You -> type -> top partners). Five interaction types are counted: reply, vote, transfer, reblog and follow. The unit is always an interaction COUNT \u2014 transfer amounts and vote weights never affect it \u2014 so the bands are directly comparable. Each type returns its top_n partners by count plus a single \"Others\" band (partner null) aggregating the remaining partners, so the rows for a type always sum to that type's total regardless of top_n. Only operations the account itself SIGNED are counted, which is what makes the graph outgoing; interactions it merely received are not. Self-interactions (self-votes, transfers to yourself, replying to your own post) are excluded \u2014 they are a self-loop the sankey cannot render, and network_vote_daily.self_votes already reports them. Delegations are deliberately excluded: they belong to the Influence & Delegation Map, not to the interaction graph. Reply and reblog are DE-DUPLICATED, vote/transfer/follow are raw counts. A comment_operation that edits an existing reply reuses its permlink, so counting raw ops would report an edited reply as a second interaction (~11% inflation measured network-wide); reblog is idempotent state in Hivemind, so re-submitting it is not a new interaction. A vote and a follow, by contrast, are genuine repeatable events (vote -> unvote -> re-vote is two votes). The de-duplication is scoped to the requested window, so an edit of a reply created BEFORE the window is indistinguishable from an in-window creation; the effect is under 0.2% even at one-day windows and zero for the default full-history window. Follows are derived natively from the raw follow/reblog custom_json payloads rather than from Hivemind, and only a real follow counts \u2014 an unfollow (what:[]) or a mute (what:[\"ignore\"]) is a retraction, not an interaction. covered_from reports the window actually scanned. A request whose op count exceeds the server ceiling is answered from the most recent ops within budget rather than failing, and covered_from then reports the later start date. Each OP TYPE carries its own budget, so heavy DApp custom_json traffic can never displace the vote, reply or transfer bands. Note that reblog and follow BOTH ride custom_json, and share that budget with every DApp custom_json the account signs: an account whose recent custom_json is dominated by game or token traffic can therefore have its reblog and follow bands truncated away entirely. Whenever a band comes back empty AND its op type was truncated, it is reported as a single row with a null partner, interaction_count 0 and partners_merged 0, carrying the covered_from of the window that WAS scanned. Read it as \"no interactions of this type inside the covered window, and the window is shorter than you asked for\" \u2014 it does NOT assert that data was lost, because once the budget is exhausted the endpoint genuinely cannot tell an account with no follows from one whose follows fell outside it. A band that is empty over a FULLY covered window emits no row, so an unqualified absence still means a real zero.",
        "operationId": "haf_stats_endpoints.get_account_interactions",
        "parameters": [
          {
            "in": "path",
            "name": "account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "top_n",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 10,
              "minimum": 1,
              "maximum": 50
            },
            "description": "Number of named partners returned per interaction type (1-50); the rest are aggregated into the Others band"
          },
          {
            "in": "query",
            "name": "type_filter",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string",
              "enum": [
                "reply",
                "vote",
                "transfer",
                "reblog",
                "follow"
              ]
            },
            "description": "Restrict the response to a single interaction type; omit for all five"
          }
        ],
        "responses": {
          "200": {
            "description": "Top partners per interaction type, each type followed by its Others band",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(interaction_type TEXT, partner TEXT, interaction_count BIGINT, partner_rank INT, partners_merged INT, covered_from DATE)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "interaction_type": {
                        "type": "string",
                        "description": "One of reply, vote, transfer, reblog, follow"
                      },
                      "partner": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "Counterparty account name, or null for the Others band"
                      },
                      "interaction_count": {
                        "type": "integer",
                        "description": "Interactions with this partner (or absorbed into Others)"
                      },
                      "partner_rank": {
                        "type": "integer",
                        "description": "1..top_n for a named partner; top_n + 1 for the Others band"
                      },
                      "partners_merged": {
                        "type": "integer",
                        "description": "1 for a named partner; for Others, how many distinct partners it absorbs; 0 on a coverage-disclosure row (empty band over a truncated window)"
                      },
                      "covered_from": {
                        "type": "string",
                        "format": "date",
                        "description": "Start of the window actually scanned; equals from_date unless the server op ceiling truncated it"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/account/{account}/rc-footprint": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account RC footprint",
        "description": "Breakdown of Resource Credit consumption for an account over a time range, grouped by operation type or DApp. Counts the ops the account itself signed. Where the node records the RC each transaction cost (HAF 1.28.8 and later, from hardfork 20), an op is priced with its EXACT share of that cost: the whole cost for a single-op transaction, and for a multi-op transaction a share in proportion to the op-count estimate of each op. Otherwise an op is priced with that ESTIMATE (op_count * average rc_api cost from the calibrated rc_op_stats_daily rates). A window in which the account signed more than rc_exact_op_cap ops (15,000) is priced entirely with the estimate, to keep the call fast. For group_by=app and group_by=category the custom_json buckets come from the per-account daily rollup: each day's row is exact where the rollup recorded it and the byte-aware estimate otherwise, with no op limit; the non-custom_json bucket is exact under the op limit. Every row says which it got: rc_source (recorded, estimated or mixed), rc_exact_ops (how many of its ops were priced exactly), rc_exact_op_cap (the limit this node applies) and rc_over_cap (whether this window exceeded it), so a caller never has to infer it.",
        "operationId": "haf_stats_endpoints.get_account_rc_footprint",
        "parameters": [
          {
            "in": "path",
            "name": "account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "group_by",
            "required": false,
            "schema": {
              "type": "string",
              "default": "op_type",
              "enum": [
                "op_type",
                "app",
                "category"
              ]
            },
            "description": "Group results by operation type, DApp, or registry category (the custom_json_app_registry category each DApp belongs to, unmatched ids -> Uncategorized). app and category are byte-aware for custom_json (aggregations of the same daily buckets), so category totals reconcile with app rolled up by category - NOT with the timeline category_filter sum, which is priced per op as in op_type."
          }
        ],
        "responses": {
          "200": {
            "description": "RC consumption ranked by usage",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(label TEXT, rc_consumed BIGINT, op_count BIGINT, pct NUMERIC, rc_source TEXT, rc_exact_ops BIGINT, rc_exact_op_cap INT, rc_over_cap BOOLEAN)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "label": {
                        "type": "string",
                        "description": "Operation type name, custom_json DApp name, or registry category"
                      },
                      "rc_consumed": {
                        "type": "integer"
                      },
                      "op_count": {
                        "type": "integer"
                      },
                      "pct": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "Percentage of total RC consumed"
                      },
                      "rc_source": {
                        "type": "string",
                        "enum": [
                          "recorded",
                          "estimated",
                          "mixed"
                        ],
                        "description": "How rc_consumed was priced: recorded when every op in the row was priced with its exact share of the RC its transaction recorded, estimated when none was, mixed otherwise"
                      },
                      "rc_exact_ops": {
                        "type": "integer",
                        "description": "How many of the row's op_count ops were priced exactly"
                      },
                      "rc_exact_op_cap": {
                        "type": "integer",
                        "description": "The most signed ops one call prices exactly on this node. A window with more is priced with the estimate (the custom_json buckets of group_by=app and group_by=category excepted, which come from the daily rollup)"
                      },
                      "rc_over_cap": {
                        "type": "boolean",
                        "description": "Whether the account signed more than rc_exact_op_cap ops in the window, so the per-op pricing fell back to the estimate. The same for every row of a response"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/account/{account}/rc-footprint-timeline": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account RC footprint timeline",
        "description": "Per-event drill-down companion to rc-footprint: one row per RC-spending operation the account signed, most recent first, with the op type, resolved DApp name (+ raw custom_json id), block, timestamp and RC consumed. rc_consumed is the EXACT share of the RC its transaction cost where the node records it (HAF 1.28.8 and later, from hardfork 20), and otherwise the op-count ESTIMATE priced from the calibrated rc_op_stats_daily rates. Each event is priced the same way as in rc-footprint group_by=op_type, so summing rc_consumed over a window reconciles with that total when the account signed at most 15,000 ops in the window; above that rc-footprint is all estimate while each timeline event stays exact where recorded. Optional op_type_filter / app_filter narrow the timeline to the events of one op type or DApp (the same events as the matching rc-footprint bucket; each event is still priced per op, so an app_filter sum matches the op_type total, not the byte-aware group_by=app figure). rc_source says which pricing each event got. Pages via limit_count/offset_start, or O(1)-at-any-depth keyset paging by passing the previous page's last op_seq as before_seq.",
        "operationId": "haf_stats_endpoints.get_account_rc_footprint_timeline",
        "parameters": [
          {
            "in": "path",
            "name": "account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "op_type_filter",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Only return events of this operation type, e.g. vote_operation (matches the op_type label). Named *_filter because a query param cannot share a name with a response column."
          },
          {
            "in": "query",
            "name": "app_filter",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Only return custom_json events whose resolved DApp name equals this value, e.g. Splinterlands (matches the rc-footprint group_by=app label)."
          },
          {
            "in": "query",
            "name": "category_filter",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Only return custom_json events whose registry category equals this value, e.g. Gaming (matches the rc-footprint group_by=category label; see /custom-json-app-registry for the category set, or Uncategorized for ids matching no registered app). Combinable with app_filter (intersection). Each event is priced per op as in group_by=op_type, so a category_filter sum reconciles with the group_by=op_type custom_json total, NOT the byte-aware group_by=category figure."
          },
          {
            "in": "query",
            "name": "limit_count",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 100,
              "minimum": 1,
              "maximum": 1000
            },
            "description": "Maximum number of events to return (1-1000)"
          },
          {
            "in": "query",
            "name": "offset_start",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 0,
              "minimum": 0
            },
            "description": "Number of events to skip (offset pagination; O(depth), prefer before_seq)"
          },
          {
            "in": "query",
            "name": "before_seq",
            "required": false,
            "schema": {
              "x-sql-datatype": "BIGINT",
              "x-sql-default-value": "NULL",
              "type": "integer"
            },
            "description": "Keyset cursor: return only events with op_seq strictly less than this (i.e. older). Pass the previous page's last op_seq for O(1) deep paging that rides the seq index."
          }
        ],
        "responses": {
          "200": {
            "description": "RC-spending events, most recent first",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(\"timestamp\" TIMESTAMP, block_num INT, op_type TEXT, app TEXT, custom_json_id TEXT, rc_consumed BIGINT, op_seq BIGINT, rc_source TEXT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "timestamp": {
                        "type": "string",
                        "format": "date-time",
                        "description": "Block timestamp of the operation"
                      },
                      "block_num": {
                        "type": "integer"
                      },
                      "op_type": {
                        "type": "string",
                        "description": "Operation type name"
                      },
                      "app": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "Resolved DApp name for custom_json ops (custom_json_app_registry match, falling back to the raw id); null for non-custom_json ops"
                      },
                      "custom_json_id": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "Raw custom_json id (null for non-custom_json ops)"
                      },
                      "rc_consumed": {
                        "type": "integer",
                        "description": "RC consumed by this operation - its exact share of the transaction's recorded cost where there is one, else the estimate"
                      },
                      "op_seq": {
                        "type": "integer",
                        "description": "Per-account operation sequence number (dense, monotonic with time); pass the last row's value as before_seq to fetch the next page"
                      },
                      "rc_source": {
                        "type": "string",
                        "enum": [
                          "recorded",
                          "estimated"
                        ],
                        "description": "recorded when rc_consumed is the op's exact share of the RC its transaction recorded, estimated when the node has no recorded cost for it"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/account/{account}/dapp-footprint": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account DApp footprint",
        "description": "Per-account custom_json activity over a time range, grouped by DApp and the registry-defined category each app belongs to (custom_json_app_registry). Returns a single object with KPI fields (total ops, top category, top DApp), the per-category breakdown (for a donut chart), and the per-DApp breakdown tagged with its category (for a drill-down bar chart) - so the client renders the whole dashboard from one response. The primary metric is op COUNT (custom_json operations signed by the account). RC figures add up the per-account daily rollup: each daily row is the EXACT RC its operations' transactions recorded where the node has it (HAF 1.28.8 and later, from hardfork 20, for rows the processor built or the backfill filled from operations that all had one), and otherwise the calibrated ESTIMATE (rc_op_stats_daily rates sampled from rc_api). A multi-signer op counts its whole RC for each signer, as it counts once per signer in op_count. rc_source (recorded, estimated or mixed; null when there are no ops) and rc_exact_ops say which pricing the total and each category and DApp got. Defaults to the last 30 days.",
        "operationId": "haf_stats_endpoints.get_account_dapp_footprint",
        "parameters": [
          {
            "in": "path",
            "name": "account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          }
        ],
        "responses": {
          "200": {
            "description": "DApp footprint aggregate for the account",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "jsonb",
                  "type": "object",
                  "properties": {
                    "account": {
                      "type": "string"
                    },
                    "from_date": {
                      "type": "string"
                    },
                    "to_date": {
                      "type": "string"
                    },
                    "total_ops": {
                      "type": "integer"
                    },
                    "total_rc_estimated": {
                      "type": "integer",
                      "description": "Total RC consumed, summed per day - exact where the rollup recorded it, else the calibrated estimate (op_count*base_rc + op_bytes*byte_rc from rc_op_stats_daily). The name predates exact RC and is kept for compatibility"
                    },
                    "rc_source": {
                      "type": [
                        "string",
                        "null"
                      ],
                      "enum": [
                        "recorded",
                        "estimated",
                        "mixed",
                        null
                      ],
                      "description": "How total_rc_estimated was priced: recorded when every op came from a daily row holding the recorded RC, estimated when none did, mixed otherwise; null when there are no ops"
                    },
                    "rc_exact_ops": {
                      "type": "integer",
                      "description": "How many of total_ops were priced with the recorded RC"
                    },
                    "top_category": {
                      "type": [
                        "string",
                        "null"
                      ]
                    },
                    "top_dapp": {
                      "type": [
                        "string",
                        "null"
                      ]
                    },
                    "categories": {
                      "type": "array",
                      "description": "Per-category totals (donut chart)",
                      "items": {
                        "type": "object",
                        "properties": {
                          "category": {
                            "type": "string"
                          },
                          "op_count": {
                            "type": "integer"
                          },
                          "pct": {
                            "type": [
                              "number",
                              "null"
                            ]
                          },
                          "rc_estimated": {
                            "type": "integer"
                          },
                          "rc_pct": {
                            "type": [
                              "number",
                              "null"
                            ]
                          },
                          "rc_source": {
                            "type": "string",
                            "enum": [
                              "recorded",
                              "estimated",
                              "mixed"
                            ]
                          },
                          "rc_exact_ops": {
                            "type": "integer"
                          }
                        }
                      }
                    },
                    "dapps": {
                      "type": "array",
                      "description": "Per-app totals (registered app name), each tagged with its category (drill-down bars)",
                      "items": {
                        "type": "object",
                        "properties": {
                          "category": {
                            "type": "string"
                          },
                          "app_name": {
                            "type": "string"
                          },
                          "op_count": {
                            "type": "integer"
                          },
                          "pct": {
                            "type": [
                              "number",
                              "null"
                            ]
                          },
                          "rc_estimated": {
                            "type": "integer"
                          },
                          "rc_pct": {
                            "type": [
                              "number",
                              "null"
                            ]
                          },
                          "rc_source": {
                            "type": "string",
                            "enum": [
                              "recorded",
                              "estimated",
                              "mixed"
                            ]
                          },
                          "rc_exact_ops": {
                            "type": "integer"
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/custom-json-app-registry": {
      "get": {
        "tags": [
          "Other"
        ],
        "summary": "custom_json DApp registry",
        "description": "The custom_json DApp registry: every registered app_id_pattern mapped to its DApp name, registry category, and homepage. This is the single source of truth that get_account_rc_footprint (group_by=app / group_by=category), get_account_rc_footprint_timeline (app_filter / category_filter) and get_account_dapp_footprint use to attribute custom_json ids - a longest-prefix starts_with match against app_id_pattern, so a raw id like sm_market_rent resolves to the longest registered prefix (sm_); an id matching no pattern falls back to the Uncategorized category with its raw id as the app name. Exposed so a client can render category/DApp labels, colours and homepage links without hard-coding the mapping. Static between deploys and only ~dozens of rows, so it is safe to cache. Ordered by category, then app name.",
        "operationId": "haf_stats_endpoints.get_custom_json_app_registry",
        "responses": {
          "200": {
            "description": "Registered custom_json DApps, ordered by category then app name",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(app_id_pattern TEXT, app_name TEXT, category TEXT, homepage TEXT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "app_id_pattern": {
                        "type": "string",
                        "description": "custom_json id prefix; the longest one that prefixes an id wins"
                      },
                      "app_name": {
                        "type": "string",
                        "description": "Registered DApp name (the group_by=app label)"
                      },
                      "category": {
                        "type": "string",
                        "description": "Registry category (the group_by=category label)"
                      },
                      "homepage": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "DApp homepage URL, or null if unknown"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/rc-utilization": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Network RC utilization",
        "description": "Time-series of total RC consumption across the network, broken down by operation type, aggregated by the chosen granularity. Per (day, op type), each daily row is the EXACT RC its operations' transactions recorded where the node has it (HAF 1.28.8 and later, from hardfork 20, for rows the processor built or the backfill filled from operations that all had one), and otherwise the calibrated ESTIMATE (op_count*base_rc + op_bytes*byte_rc from rc_op_stats_daily, the rate effective on/before each day). rc_source says which a period got.",
        "operationId": "haf_stats_endpoints.get_network_rc_utilization",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "type": "string",
              "default": "day",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Aggregation granularity"
          }
        ],
        "responses": {
          "200": {
            "description": "RC utilization time-series",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, rc_total BIGINT, by_label JSONB, rc_source TEXT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": "string",
                        "description": "ISO-8601 date string for the aggregation bucket"
                      },
                      "rc_total": {
                        "type": "integer",
                        "description": "Total RC consumed in the period"
                      },
                      "by_label": {
                        "type": "object",
                        "additionalProperties": {
                          "type": "integer"
                        },
                        "description": "RC per operation type or DApp"
                      },
                      "rc_source": {
                        "type": "string",
                        "enum": [
                          "recorded",
                          "estimated",
                          "mixed"
                        ],
                        "description": "recorded when every (day, op type) row of the period holds the RC its operations recorded, estimated when none does, mixed otherwise"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/custom-json-usage": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "custom_json usage over time for one id",
        "description": "Time-series of network-wide custom_json (op_type 18) usage for a single id (e.g. `follow`, `sm_claim_daily`): op_count, summed payload bytes, and the RC cost per period. Per day, each daily row is the EXACT RC its operations' transactions recorded where the node has it (HAF 1.28.8 and later, from hardfork 20, for rows the processor built or the backfill filled from operations that all had one), and otherwise the calibrated ESTIMATE (op_count*base_rc + op_bytes*byte_rc from the op-18 rc_op_stats_daily rate effective on/before each day); the column keeps its old name rc_estimate. Reads the network_custom_json_daily rollup.",
        "operationId": "haf_stats_endpoints.get_network_custom_json_usage",
        "parameters": [
          {
            "in": "query",
            "name": "json_id",
            "required": true,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "The custom_json id to report (e.g. follow); required (400 if omitted)"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "type": "string",
              "default": "day",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Aggregation granularity"
          }
        ],
        "responses": {
          "200": {
            "description": "custom_json usage time-series for the id",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, op_count BIGINT, op_bytes BIGINT, rc_estimate NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": "string",
                        "description": "ISO-8601 date string for the aggregation bucket"
                      },
                      "op_count": {
                        "type": "integer",
                        "description": "Number of custom_json ops with this id in the period"
                      },
                      "op_bytes": {
                        "type": "integer",
                        "description": "Summed payload bytes of those ops"
                      },
                      "rc_estimate": {
                        "type": "number",
                        "description": "RC consumed by those ops, exact per day where recorded and estimated otherwise (may exceed 2^63)"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/top-custom-json": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Most-used custom_json ids / DApps",
        "description": "Leaderboard of the most-used network custom_json actions over [from_date, to_date], ranked by op_count (or op_bytes / rc_estimate), returning at most limit_count ranked rows. group_by=id ranks raw custom_json ids (each with its resolved DApp name + category); group_by=app collapses an app's ids to the registered DApp; group_by=category rolls up one level further (json_id is null for app, json_id and app_name are null for category). group_by=app and group_by=category PARTITION the window, so they append one extra Others row aggregating every group beyond limit_count, sorted last and emitted only when something is actually absorbed - the rows therefore always sum to the window total regardless of limit_count. Identify that row by its CATEGORY, which is null for group_by=app and Others for group_by=category: a real DApp id can itself resolve to the name Others, so app_name is not a reliable marker. group_by=id is a plain top-N and has no Others row. RC (the column rc_estimate, named before exact RC): per day, each daily row is the EXACT RC its operations' transactions recorded where the node has it (HAF 1.28.8 and later, from hardfork 20, for rows the processor built or the backfill filled from operations that all had one), and otherwise the calibrated ESTIMATE (op_count*base_rc + op_bytes*byte_rc at the op-18 rate effective on/before each day). Reads the network_custom_json_daily rollup; app/category resolved via custom_json_app_registry.",
        "operationId": "haf_stats_endpoints.get_network_top_custom_json",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "limit_count",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 25,
              "minimum": 1,
              "maximum": 100
            },
            "description": "Number of ranked rows to return (1-100); group_by=app/category may append one extra Others row"
          },
          {
            "in": "query",
            "name": "group_by",
            "required": false,
            "schema": {
              "type": "string",
              "default": "id",
              "enum": [
                "id",
                "app",
                "category"
              ]
            },
            "description": "Group by raw custom_json id, resolved DApp app, or category"
          },
          {
            "in": "query",
            "name": "order_by",
            "required": false,
            "schema": {
              "type": "string",
              "default": "op_count",
              "enum": [
                "op_count",
                "op_bytes",
                "rc_estimate"
              ]
            },
            "description": "Column to rank by, descending"
          }
        ],
        "responses": {
          "200": {
            "description": "custom_json usage leaderboard",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(json_id TEXT, app_name TEXT, category TEXT, op_count BIGINT, op_bytes BIGINT, rc_estimate NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "json_id": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "Raw custom_json id (null when group_by=app or category)"
                      },
                      "app_name": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "Resolved DApp name; Others on the aggregated tail row, which is identified by category rather than by this name (null when group_by=category)"
                      },
                      "category": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "DApp category (Uncategorized if unregistered). Marks the aggregated tail row - null when group_by=app, since that band spans categories, and Others when group_by=category"
                      },
                      "op_count": {
                        "type": "integer",
                        "description": "Number of custom_json ops in the window"
                      },
                      "op_bytes": {
                        "type": "integer",
                        "description": "Summed payload bytes of those ops"
                      },
                      "rc_estimate": {
                        "type": "number",
                        "description": "RC consumed by those ops, exact per day where recorded and estimated otherwise (may exceed 2^63)"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/hp-distribution": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "HP stake distribution",
        "description": "Bucketed distribution of Hive Power (HP) stake across all accounts, with both the account counts and the total HP held per bucket (enabling a \"% of accounts\" vs \"% of HP held\" view of wealth concentration). Reads current VESTS balances from balance_tracker; its schema is deployment-dependent so the function auto-detects the first readable relation (btracker_app / btracker_backend / hafbe_bal) - grant SELECT to haf_stats_user on whichever applies. total_hp is the sum of actual VESTS-converted balances in the bucket - for the unbounded 1M+ bucket this is the real total, not a midpoint estimate. Returns an empty array (HTTP 200, not an error) when the data source is unavailable - no readable balance relation, or hafd.blocks has no rows yet (fresh node, no VESTS/HP ratio). Consumers should treat an empty array as \"distribution not available yet\", not \"zero accounts\". (#20.5)",
        "operationId": "haf_stats_endpoints.get_network_hp_distribution",
        "responses": {
          "200": {
            "description": "HP distribution buckets ordered from smallest to largest",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(bucket TEXT, account_count BIGINT, pct_accounts NUMERIC, total_hp NUMERIC, pct_hp NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "bucket": {
                        "type": "string",
                        "example": "1-10 HP"
                      },
                      "account_count": {
                        "type": "integer"
                      },
                      "pct_accounts": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "Percentage of all accounts in this bucket"
                      },
                      "total_hp": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "Total HP held by all accounts in this bucket (sum of actual VESTS-converted balances)"
                      },
                      "pct_hp": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "This bucket's total_hp as a percentage of the sum of all buckets' total_hp"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/governance/influence-concentration": {
      "get": {
        "tags": [
          "Governance"
        ],
        "summary": "Stake influence concentration",
        "description": "Network-wide stake-concentration snapshot: Gini coefficient, the share of total Hive Power (HP) held by the richest 1% and 10% of accounts, the total number of HP holders, and the median and mean HP per holder. Computed from current VESTS balances (converted to HP via the live VESTS/HP ratio) and served from a precomputed snapshot, so the read is O(1). Returns an empty array (HTTP 200, not an error) when the snapshot has not been computed yet - no readable balance relation, or hafd.blocks has no rows yet (fresh node). Consumers should treat an empty array as \"not available yet\", not \"zero accounts\".",
        "operationId": "haf_stats_endpoints.get_governance_influence_concentration",
        "responses": {
          "200": {
            "description": "One row of network stake-concentration metrics",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(gini NUMERIC, top_1pct_hp_share NUMERIC, top_10pct_hp_share NUMERIC, total_hp_holders BIGINT, median_hp NUMERIC, mean_hp NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "gini": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "Gini coefficient of HP across all holders (0 = perfect equality, 1 = one account holds everything)",
                        "example": 0.94
                      },
                      "top_1pct_hp_share": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "Percentage of total HP held by the richest 1% of accounts",
                        "example": 71.2
                      },
                      "top_10pct_hp_share": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "Percentage of total HP held by the richest 10% of accounts",
                        "example": 93.4
                      },
                      "total_hp_holders": {
                        "type": "integer",
                        "description": "Number of accounts holding a positive VESTS balance",
                        "example": 164780
                      },
                      "median_hp": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "Median HP per holder",
                        "example": 12.4
                      },
                      "mean_hp": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "Mean HP per holder",
                        "example": 284.1
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/account-funnel": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "New account cohort retention",
        "description": "Day-7, day-30, and day-90 rolling retention for all newly created accounts, including accounts created through legacy pow/pow2 mining. An account is retained at day N when it signs at least one non-virtual operation on or after N days after creation, observed within a 180-day horizon [N, 180) days; the milestones nest and decline (day-90 subset of day-30 subset of day-7). Results are grouped by creation month. Disclosure is per-milestone: eligible_at_Nd counts only cohort members that have reached day N (created + N <= now), active_at_Nd counts the eligible members that were active, and pct_Nd = active_at_Nd / eligible_at_Nd (null when eligible_at_Nd is 0).",
        "operationId": "haf_stats_endpoints.get_network_account_funnel",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start cohort month (YYYY-MM-DD), inclusive, defaults to 1 year ago"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end cohort month (YYYY-MM-DD), inclusive, defaults to today"
          }
        ],
        "responses": {
          "200": {
            "description": "Cohort retention rows ordered by month",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(cohort_month TEXT, new_accounts INT, eligible_at_7d INT, active_at_7d INT, pct_7d NUMERIC, eligible_at_30d INT, active_at_30d INT, pct_30d NUMERIC, eligible_at_90d INT, active_at_90d INT, pct_90d NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "cohort_month": {
                        "type": "string",
                        "example": "2026-01"
                      },
                      "new_accounts": {
                        "type": "integer"
                      },
                      "eligible_at_7d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "active_at_7d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "pct_7d": {
                        "type": [
                          "number",
                          "null"
                        ]
                      },
                      "eligible_at_30d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "active_at_30d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "pct_30d": {
                        "type": [
                          "number",
                          "null"
                        ]
                      },
                      "eligible_at_90d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "active_at_90d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "pct_90d": {
                        "type": [
                          "number",
                          "null"
                        ]
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/author-retention": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Content creator cohort retention",
        "description": "Month cohorts of accounts whose first-ever root post falls in the cohort month, with the share that created content again in the 30-, 90-, and 180-day windows after that first post day. \"Created content again\" means a new post or comment create under chain comment_operation semantics; edits are excluded. Windows are contiguous and non-overlapping: (0,30], (30,90], and (90,180] days. Results are grouped by first-post month. Disclosure is per-milestone: eligible_at_Nd counts only cohort members that have reached day N (first_post + N <= now), active_at_Nd counts the eligible members that were active in that window, and pct_Nd = active_at_Nd / eligible_at_Nd (null when eligible_at_Nd is 0), so a recent cohort populates on a partial basis as its members mature. The usual retention decay ordering is empirical, not a mathematical guarantee.",
        "operationId": "haf_stats_endpoints.get_network_author_retention",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start cohort month (YYYY-MM-DD), inclusive, defaults to 1 year ago"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end cohort month (YYYY-MM-DD), inclusive, defaults to today"
          }
        ],
        "responses": {
          "200": {
            "description": "Author cohort retention rows ordered by month",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(cohort_month TEXT, first_post_accounts INT, eligible_at_30d INT, active_at_30d INT, pct_30d NUMERIC, eligible_at_90d INT, active_at_90d INT, pct_90d NUMERIC, eligible_at_180d INT, active_at_180d INT, pct_180d NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "cohort_month": {
                        "type": "string",
                        "example": "2026-01"
                      },
                      "first_post_accounts": {
                        "type": "integer"
                      },
                      "eligible_at_30d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "active_at_30d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "pct_30d": {
                        "type": [
                          "number",
                          "null"
                        ]
                      },
                      "eligible_at_90d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "active_at_90d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "pct_90d": {
                        "type": [
                          "number",
                          "null"
                        ]
                      },
                      "eligible_at_180d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "active_at_180d": {
                        "type": [
                          "integer",
                          "null"
                        ]
                      },
                      "pct_180d": {
                        "type": [
                          "number",
                          "null"
                        ]
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/daily-active-users": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Daily active users",
        "description": "Unique accounts that authored (signed) at least one operation per period, and the total volume of those operations, at the chosen granularity. An account is \"active\" when hive.get_required_authorities reports it as a required signer of an operation, so every authored op type counts and virtual (block/witness) activity is excluded. active_accounts is exact at the requested granularity (an account active on several days counts once per period); operations is a distinct-operation count (a multisig op counts once). operation_types selects which categories count: a comma-separated subset of post, comment, vote, transfer, custom_json, or \"all\" (the default), which counts every authored operation - not just the sum of the named categories.",
        "operationId": "haf_stats_endpoints.get_daily_active_users",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "type": "string",
              "default": "day",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Aggregation granularity"
          },
          {
            "in": "query",
            "name": "operation_types",
            "required": false,
            "schema": {
              "type": "string",
              "default": "all"
            },
            "description": "Comma-separated subset of post, comment, vote, transfer, custom_json, or \"all\" (every authored operation). Defaults to all."
          }
        ],
        "responses": {
          "200": {
            "description": "Daily-active-user time-series ordered by period",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, active_accounts BIGINT, operations BIGINT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": "string",
                        "description": "ISO-8601 date string for the aggregation bucket",
                        "example": "2016-04-01"
                      },
                      "active_accounts": {
                        "type": "integer",
                        "description": "Distinct accounts that authored an op in the period"
                      },
                      "operations": {
                        "type": "integer",
                        "description": "Distinct operations authored in the period"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/vote-stats": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Network voting activity",
        "description": "Network-wide voting activity over time - total votes, upvotes, downvotes, unvotes (weight 0), self-votes (voter = author), unique voters, and the downvote percentage per period. unique_voters is exact at the requested granularity (a voter active on several days counts once per period). downvote_pct is downvotes / (upvotes + downvotes) * 100, null when a period has no up- or down-votes.",
        "operationId": "haf_stats_endpoints.get_network_vote_stats",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "type": "string",
              "default": "day",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Aggregation period"
          }
        ],
        "responses": {
          "200": {
            "description": "Vote activity rows ordered by period",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, total_votes BIGINT, upvotes BIGINT, downvotes BIGINT, unvotes BIGINT, self_votes BIGINT, unique_voters BIGINT, downvote_pct NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": "string",
                        "example": "2026-04-01"
                      },
                      "total_votes": {
                        "type": "integer"
                      },
                      "upvotes": {
                        "type": "integer"
                      },
                      "downvotes": {
                        "type": "integer"
                      },
                      "unvotes": {
                        "type": "integer"
                      },
                      "self_votes": {
                        "type": "integer"
                      },
                      "unique_voters": {
                        "type": "integer"
                      },
                      "downvote_pct": {
                        "type": [
                          "number",
                          "null"
                        ]
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/content-volume": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Posts and comments created over time",
        "description": "Posts and comments created per period, with distinct authors. Counts follow chain semantics (comment_evaluator in hived): a comment_operation counts only when it actually creates the comment - edits of an existing (author, permlink) are not counted, while re-creating a previously deleted comment is. posts are root entries (parent_author = ''), comments everything else. unique_authors is exact at the requested granularity (an author active on several days counts once per period).",
        "operationId": "haf_stats_endpoints.get_network_content_volume",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "type": "string",
              "default": "day",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Aggregation period"
          }
        ],
        "responses": {
          "200": {
            "description": "Content volume rows ordered by period",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, posts BIGINT, comments BIGINT, unique_authors BIGINT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": "string",
                        "example": "2026-04-01"
                      },
                      "posts": {
                        "type": "integer"
                      },
                      "comments": {
                        "type": "integer"
                      },
                      "unique_authors": {
                        "type": "integer"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/engagement": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Content engagement quality metrics",
        "description": "Average votes and comments per post, and the share of posts with zero engagement, per period. Posts are grouped by their CREATION period and the counts are lifetime totals \u2014 a post created in period P contributes every vote and reply it has ever received to P, including ones that arrived in a later period. This is a cohort-by-creation view, not a count of activity that happened within the period. Because counts are lifetime, the most recent periods are right-censored: posts created near the end of the range have had little time to accrue votes/replies, so their zero_vote_post_pct / zero_comment_post_pct read artificially high \u2014 treat the latest buckets as provisional until they mature. zero_vote_post_pct and zero_comment_post_pct are ghost-posting health signals unique to Hive. vote_count includes upvotes and downvotes (weight != 0); unvotes (weight = 0) are excluded. reply_count counts only direct replies to root posts.",
        "operationId": "haf_stats_endpoints.get_network_engagement",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "default": "day",
              "type": "string",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Bucketing granularity (day, week, or month)"
          }
        ],
        "responses": {
          "200": {
            "description": "Engagement metrics per period",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, total_posts BIGINT, avg_votes_per_post NUMERIC, avg_comments_per_post NUMERIC, zero_vote_post_pct NUMERIC, zero_comment_post_pct NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": "string",
                        "format": "date"
                      },
                      "total_posts": {
                        "type": "integer"
                      },
                      "avg_votes_per_post": {
                        "type": [
                          "number",
                          "null"
                        ]
                      },
                      "avg_comments_per_post": {
                        "type": [
                          "number",
                          "null"
                        ]
                      },
                      "zero_vote_post_pct": {
                        "type": [
                          "number",
                          "null"
                        ]
                      },
                      "zero_comment_post_pct": {
                        "type": [
                          "number",
                          "null"
                        ]
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/network/top-accounts": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Top accounts per metric",
        "description": "Top N accounts ranked by the chosen metric. Reward and transfer metrics sum haf_stats financial data over [from_date, to_date]; transaction_count sums authored (signed) operations over the same range; hp_balance ranks the CURRENT own vesting balance from balance_tracker and ignores from_date/to_date (empty result if no balance_tracker schema is readable on the deployment). Default sort keys - author_rewards and curation_rewards: vests, then hbd, then hive sums; transfer_volume_in/out: hive, then hbd sums; transaction_count: op count; hp_balance: vesting balance. Ties broken by account id (creation order). Value fields not applicable to a metric are 0. Optional order_by/order_direction re-rank the FULL population before truncating (a true top/bottom-N by any displayed column, not a client-side re-sort of a biased top-N): order_by must be a column the metric populates (author/curation rewards: value_vests|value_hive|value_hbd|op_count|account; transfers: value_hive|value_hbd|op_count|account; transaction_count: op_count|account; hp_balance: value_vests|account) - other combos return 400. order_direction asc yields a true bottom-N. Omitting both reproduces the default ranking exactly.",
        "operationId": "haf_stats_endpoints.get_network_top_accounts",
        "parameters": [
          {
            "in": "query",
            "name": "metric",
            "required": false,
            "schema": {
              "type": "string",
              "default": "author_rewards",
              "enum": [
                "author_rewards",
                "curation_rewards",
                "transfer_volume_in",
                "transfer_volume_out",
                "hp_balance",
                "transaction_count"
              ]
            },
            "description": "Metric to rank accounts by"
          },
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis); ignored for hp_balance"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today; ignored for hp_balance"
          },
          {
            "in": "query",
            "name": "limit_count",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 25,
              "minimum": 1,
              "maximum": 100
            },
            "description": "Number of rows to return (1-100)"
          },
          {
            "in": "query",
            "name": "order_by",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string",
              "enum": [
                "value_vests",
                "value_hive",
                "value_hbd",
                "op_count",
                "account"
              ]
            },
            "description": "Column to rank by before truncating; omit to use the metric's default sort. Must be a column the metric populates (else 400): author/curation rewards allow all five; transfers exclude value_vests; transaction_count allows op_count/account; hp_balance allows value_vests/account. 'account' sorts alphabetically by name. Requesting the metric's own default column with order_direction=desc reproduces the default ranking exactly, i.e. its full multi-key tiebreak (e.g. author_rewards: vests, then hbd, then hive, then account id); any other column ranks by that single column, then account id."
          },
          {
            "in": "query",
            "name": "order_direction",
            "required": false,
            "schema": {
              "type": "string",
              "default": "desc",
              "enum": [
                "desc",
                "asc"
              ]
            },
            "description": "Sort direction applied to order_by (or the metric's default column when order_by is omitted). asc yields a true bottom-N."
          }
        ],
        "responses": {
          "200": {
            "description": "Ranked accounts, rank 1 is the top account",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(rank INT, account TEXT, value_hive_nai BIGINT, value_hbd_nai BIGINT, value_vests_nai BIGINT, op_count BIGINT)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "rank": {
                        "type": "integer",
                        "example": 1
                      },
                      "account": {
                        "type": "string",
                        "example": "blocktrades"
                      },
                      "value_hive_nai": {
                        "type": "integer"
                      },
                      "value_hbd_nai": {
                        "type": "integer"
                      },
                      "value_vests_nai": {
                        "type": "integer"
                      },
                      "op_count": {
                        "type": "integer"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    },
    "/witnesses/missed-blocks": {
      "get": {
        "tags": [
          "Witnesses"
        ],
        "summary": "Witness missed blocks and reliability",
        "description": "Missed versus produced blocks per witness over [from_date, to_date]. Omit granularity for a LEADERBOARD (one row per producer, period null); set it for a TIME SERIES (one row per period, producer null unless witness is given). Every producer with any activity in the window is included, INCLUDING those that missed nothing, so rate is a meaningful reliability figure and a witness= query returns a row whenever that witness was scheduled; the active set is NOT filtered server-side, since backup witnesses are exactly the ones that miss. rate is missed_count / (produced_count + missed_count), a fraction in [0,1] rounded to 6 decimals - not a percentage, because at 2 decimals a witness that missed 1 of 28,800 slots would print 0.00. A witness whose only activity in the window was a miss has produced_count 0 and rate 1. Reads the witness_blocks_daily rollup only, so numerator and denominator always share one clock (the app's last processed block) and counts never include blocks the app has not processed yet; /sync-status discloses that lag. from_date/to_date select whole UTC days, so the newest day holds only the blocks processed so far - \"today so far\". In series mode every period OVERLAPPING the window is returned at its full-period value, so a from_date or to_date landing mid-week or mid-month yields that whole period rather than a partial slice labelled as a full one (same rule as the other network time series). Hourly buckets are not supported: every rollup here is day-grained, and serving hours from raw operations would reintroduce the two-clock split this endpoint exists to avoid; time-of-day miss patterns are a follow-up that should add an hourly rollup. Witness rank and top-21 membership are deliberately NOT returned - those are hafbe-api /witnesses; join them on the producer name. NOTE: produced + missed is close to but not exactly 28,800 slots per day. A chain halt loses slots entirely (no block is produced AND no miss is recorded), and a halt straddling midnight can hand one back the next day - the replay corpus shows 28,711 on 2016-04-10 and 28,801 on 2016-04-11. Do not derive produced as 28800 - missed.",
        "operationId": "haf_stats_endpoints.get_witness_missed_blocks",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Block number or end date (YYYY-MM-DD), inclusive, defaults to today"
          },
          {
            "in": "query",
            "name": "witness",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string"
            },
            "description": "Restrict to a single witness account name; omit for all producers. Unknown names, and names with no scheduled slots in the window, return an empty array. Note this is NOT an active/top-21 filter - a demoted or backup witness returns its real figures, which is the population the endpoint exists to expose. (Issue #54's sketch and block_explorer_ui#774 call this parameter `producer`; it had to be renamed because `producer` is also a response column, and RETURNS TABLE columns are OUT parameters.)"
          },
          {
            "in": "query",
            "name": "granularity",
            "required": false,
            "schema": {
              "x-sql-datatype": "TEXT",
              "x-sql-default-value": "NULL",
              "type": "string",
              "enum": [
                "day",
                "week",
                "month"
              ]
            },
            "description": "Omit for the per-witness leaderboard; set to bucket the window into a time series"
          },
          {
            "in": "query",
            "name": "order_by",
            "required": false,
            "schema": {
              "type": "string",
              "default": "missed",
              "enum": [
                "missed",
                "rate",
                "last_missed"
              ]
            },
            "description": "Leaderboard ranking column, descending. Validated but not applied when granularity is set (a series is always ordered by period)"
          },
          {
            "in": "query",
            "name": "limit_count",
            "required": false,
            "schema": {
              "type": "integer",
              "default": 1000,
              "minimum": 1,
              "maximum": 1000
            },
            "description": "Number of leaderboard rows to return (1-1000), defaulting to the MAXIMUM rather than to a small page. Both the ceiling and that default differ from the sibling leaderboards on purpose: those rank an unbounded space (21k+ custom_json ids) where a top-N is the whole point, whereas the group set here is the WITNESS set - bounded by how many accounts were scheduled in the window, ~120-200 on modern Hive. Truncation is uniquely dangerous for the witness-table consumer, which merges by producer and renders an absent witness as \"0 missed\", so a dropped row becomes a WRONG figure rather than a missing one; the response carries no truncation indicator, so a low default would be a trap rather than a safeguard. The window aggregation is independent of the limit, so the wide default is nearly free (47.8 ms at 100 vs 62.4 ms at 1000 over full history). Validated but not applied when granularity is set."
          }
        ],
        "responses": {
          "200": {
            "description": "Witness missed-block leaderboard or time series",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(period TEXT, producer TEXT, missed_count BIGINT, produced_count BIGINT, rate NUMERIC, first_missed_block INT, last_missed_block INT, first_missed_at TIMESTAMP, last_missed_at TIMESTAMP)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "period": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "ISO-8601 date string for the aggregation bucket (null in leaderboard mode)"
                      },
                      "producer": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "description": "Witness account name (null in a network-wide series, i.e. granularity set without witness)"
                      },
                      "missed_count": {
                        "type": "integer",
                        "description": "Scheduled slots the witness missed in the window"
                      },
                      "produced_count": {
                        "type": "integer",
                        "description": "Blocks the witness produced in the window"
                      },
                      "rate": {
                        "type": [
                          "number",
                          "null"
                        ],
                        "description": "missed/(produced+missed), a fraction in [0,1] to 6 decimals; null only when the window holds no slots"
                      },
                      "first_missed_block": {
                        "type": [
                          "integer",
                          "null"
                        ],
                        "description": "Block at which the first miss in the window was recorded (null if nothing was missed)"
                      },
                      "last_missed_block": {
                        "type": [
                          "integer",
                          "null"
                        ],
                        "description": "Block at which the last miss in the window was recorded (null if nothing was missed)"
                      },
                      "first_missed_at": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "format": "date-time",
                        "description": "Timestamp of first_missed_block; with last_missed_at this separates a single outage from sustained flakiness"
                      },
                      "last_missed_at": {
                        "type": [
                          "string",
                          "null"
                        ],
                        "format": "date-time",
                        "description": "Timestamp of last_missed_block"
                      }
                    }
                  }
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/BadRequest"
          }
        }
      }
    }
  }
}
$$;
-- openapi-generated-code-end
BEGIN
    -- Read the operator's base URL, if this deployment set one. Wrapped because
    -- haf_stats_app.app_config does not exist on every database that loads this file:
    -- the CI stub lane hand-creates only the tables it needs, and a half-installed
    -- database should still serve a document rather than 500 on GET /.
    BEGIN
        SELECT c.swagger_base_url INTO _base FROM haf_stats_app.app_config AS c LIMIT 1;
    EXCEPTION
        WHEN undefined_table OR insufficient_privilege THEN _base := NULL;
    END;

    -- Accept only something that can actually BE a base URL: an absolute path, or an
    -- http(s) origin. This is not defensive padding -- haf_api_node passes
    -- `--swagger-url=${PUBLIC_HOSTNAME}`, and PUBLIC_HOSTNAME is a BARE HOSTNAME
    -- ("your.hostname.com" in its .env.example). Taking that literally would publish
    -- `servers: [{url: "your.hostname.com"}]`, which is not a URL and is worse than the
    -- hardcoded value it replaced. So a hostname-shaped value is ignored and the
    -- default stands, which is correct on a node; a caller that wants to override
    -- passes a path or an origin.
    -- Two rejections that are not padding:
    --
    --   //evil.com   -- protocol-relative. It matches a naive `^/`, and Swagger UI
    --                   resolves it as <current-scheme>//evil.com, so "Try it out" and
    --                   any credentials typed into it go to ANOTHER ORIGIN. The path arm
    --                   therefore refuses a second leading slash.
    --   https://host -- an origin with NO PATH. haf_api_node routes this app only under
    --                   /haf-stats-api/*, so publishing a bare origin would send every
    --                   generated client to https://host/network/engagement -> 404. A
    --                   scheme-prefixed PUBLIC_HOSTNAME is exactly how that would arrive,
    --                   and falling back is strictly better than publishing it. Callers
    --                   that mean it pass the path: https://host/haf-stats-api.
    IF _base IS NULL OR _base !~ '^(/($|[^/])|https?://[^/]+/)' THEN
        _base := '/haf-stats-api';
    END IF;

    -- jsonb, not text surgery: the generated blob is machine-written and its exact
    -- spacing is not a contract, so matching on `"url": "/haf-stats-api"` would break
    -- silently the first time the generator reformatted. jsonb_pretty keeps GET /
    -- readable in a browser; it does reorder keys, which OpenAPI does not care about.
    RETURN jsonb_pretty(
        jsonb_set(
            openapi::jsonb,
            '{servers}',
            jsonb_build_array(jsonb_build_object('url', _base))
        )
    )::json;
END
$func$;

-- ---------------------------------------------------------------------------
-- Health / version
-- ---------------------------------------------------------------------------

/** openapi:paths
/version:
  get:
    tags:
      - Other
    summary: Application version
    description: Returns the git hash of the currently deployed version.
    operationId: haf_stats_endpoints.get_version
    responses:
      '200':
        description: Git hash string
        content:
          application/json:
            schema:
              type: string
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_version;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_version()
RETURNS TEXT
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT git_hash FROM haf_stats_app.app_version LIMIT 1;
$$;

/** openapi:paths
/health:
  get:
    tags:
      - Other
    summary: Health check
    description: >-
      Returns service health, last processed block number, and whether the per-account
      community dimension has been backfilled.
    operationId: haf_stats_endpoints.get_health
    responses:
      '200':
        description: Health status
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(status TEXT, last_processed_block INT, version TEXT, community_data_ready BOOLEAN)"
              # ARRAY, not object. The function is RETURNS TABLE(...), so PostgREST
              # serialises it as a list -- live: [{"status":"ok",...}]. Declared as an
              # object, a generated client reads .status off a list and breaks. Every
              # other TABLE-returning endpoint here is already declared as an array;
              # this one was the exception.
              type: array
              items:
                type: object
                properties:
                  status:
                    type: string
                    example: ok
                  last_processed_block:
                    type: integer
                  version:
                    type: string
                  community_data_ready:
                    type: boolean
                    description: >-
                      False when this node has processed past the community start block
                      (37,500,000) but holds no per-account community rows — i.e. it
                      synced before the community feature and
                      scripts/rebuild_content_volume.sh has not been run yet.
                      get_account_community_activity still answers on such a node, but
                      reports everything under the personal-blog bucket.
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_health;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_health()
RETURNS TABLE(status TEXT, last_processed_block INT, version TEXT, community_data_ready BOOLEAN)
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        'ok'::TEXT                                               AS status,
        s.last_processed_block,
        (SELECT git_hash FROM haf_stats_app.app_version LIMIT 1) AS version,
        -- The community dimension is the one thing install cannot self-heal (it rides on
        -- comment_registry's genesis create-vs-edit replay), so a node upgraded from an
        -- older version answers get_account_community_activity with everything in the
        -- personal-blog bucket until the rebuild runs — indistinguishable, to a caller,
        -- from an account that genuinely never posted in a community. Surface it here so
        -- that state is detectable rather than silently plausible.
        (
            s.last_processed_block < haf_stats_app.community_start_block()
            OR EXISTS (SELECT 1 FROM haf_stats_backend.account_community_daily)
        ) AS community_data_ready
    FROM haf_stats_app.app_status s
    -- Belt-and-braces against the duplicate rows that installs predating the guarded
    -- seed left behind: db/haf_stats_app.sql now de-dups and enforces a singleton index,
    -- but this endpoint must not report a synced node as being at block 0 (which would
    -- also flip community_data_ready true for the wrong reason) if one ever reappears.
    ORDER BY s.last_processed_block DESC
    LIMIT 1;
$$;

/** openapi:paths
/sync-status:
  get:
    tags:
      - Other
    summary: Sync status
    description: >-
      Returns the block this node has consumed as tracked by HAF itself
      (hafd.contexts.current_block_num for the haf_stats context), with that
      block's timestamp (UTC). This is the uniform HAF-app sync/health endpoint
      shape shared with the other HAF apps: the timestamp lets a consumer
      compute staleness with a single call (age = now() - last_block_time)
      without needing a separate head-block reference.


      Not the same number as /health, which reports
      haf_stats_app.app_status.last_processed_block - the app's own bookkeeping
      row. The two are one clock on a node the processor drives (main() writes
      both from the same variable in the same transaction), so they normally
      agree exactly; hafd.contexts is HAF's authoritative pointer and is what
      the rest of the ecosystem exposes under this name.
    operationId: haf_stats_endpoints.get_sync_status
    responses:
      '200':
        description: >-
          Last block consumed by the haf_stats HAF context, and its timestamp.
          last_block_time is null when that block has no hafd.blocks row - i.e.
          nothing has been processed yet (there is no block 0), or the node is
          pruned and the context is behind the prune tail.


          Two conditions answer 503 rather than 200: the HAF instance is still
          in massive sync (indexes not yet built), so the call fails fast
          instead of executing an unindexed lookup; or the HAF context is
          missing or not visible, which is reported rather than served as a
          healthy-looking body.
        content:
          application/json:
            schema:
              x-sql-datatype: JSON
              type: object
              required: [last_block_num, last_block_time]
              properties:
                last_block_num:
                  type: integer
                  description: last block consumed by the haf_stats HAF context
                last_block_time:
                  # ["string", "null"], not `nullable: true`: this document declares
                  # openapi 3.1.0, where `nullable` was removed and is inert - a validator
                  # would reject the null response this very description documents.
                  # scripts/process_openapi.py handles this form explicitly.
                  type:
                    - string
                    - "null"
                  format: date-time
                  description: >-
                    UTC timestamp of that block; null if it has no hafd.blocks
                    row
            example:
              last_block_num: 5000000
              last_block_time: '2016-09-15T19:47:21'
      '400':
        $ref: '#/components/responses/BadRequest'
      '503':
        description: >-
          Temporarily unavailable, and the two cases are distinguished by message
          rather than by status. Either the HAF instance is still in massive sync
          (hafd.blocks' primary key is dropped for the duration, so the call fails
          fast instead of seq-scanning the largest table in the database), or the
          HAF context is missing or not visible to the reader. Both are raised as
          SQLSTATE 53000, which PostgREST maps to 503. Declared because prose in a
          200 description is not part of any machine-readable contract: a client
          generated from a 200-only spec models this endpoint as infallible and
          throws on the error body below.
        content:
          application/json:
            schema:
              # The same wire shape as every other error on this API. Two independent
              # definitions of one shape would make a generator emit two model classes,
              # so a consumer could not catch one error type across the endpoints.
              $ref: '#/components/schemas/PostgrestError'
            example:
              code: '53000'
              message: HAF instance is not ready (massive sync in progress)
              details: null
              hint: null
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_sync_status;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_sync_status()
RETURNS JSON
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _s RECORD;
BEGIN
    -- No cache - sync status needs real-time accuracy
    PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=0"}]', true);

    -- haf_stats_app.sync_status() is SECURITY DEFINER (db/sync_status.sql): hafd.contexts
    -- has RLS whose only application SELECT policy is granted TO hive_applications_group,
    -- and haf_stats_user is kept out of that group (db/builtin_roles.sql removes it where
    -- an earlier install left it, #88) because it also carries TRUNCATE on hafd.contexts
    -- and CREATE on hafd - to a role PostgREST connects as unauthenticated. The definer also owns the massive-sync guard and
    -- the context name; this function owns only the wire format.
    SELECT * INTO _s FROM haf_stats_app.sync_status();

    -- Zero rows means one of: the HAF context has not been registered yet, it was
    -- removed, or haf_stats_owner (the definer) lost hive_applications_group so RLS hides
    -- every row - which fails SILENTLY, with no error. Answering 200 with a body of
    -- `null` (what a bare scalar subquery would do here) merges all three with "healthy"
    -- and hides a privilege misconfiguration behind a healthy-looking response. 53000
    -- maps to HTTP 503 on PostgREST; a bare RAISE (P0001) would map to 400 and tell a
    -- probe its own request was malformed. Both measured on PostgREST 12.2.3.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HAF context ''haf_stats'' is not visible: the app is not installed on this node, its context was removed, or haf_stats_owner lost its hive_applications_group membership (see db/builtin_roles.sql)'
            USING ERRCODE = '53000';
    END IF;

    -- Two keys only, byte-compatible with hafbe's and haf_fyp's /sync-status: literal
    -- 'T', 19 characters, no fractional seconds, no timezone suffix. Consumers parse it
    -- with a fixed format, so any drift here is a silent breaking change. The definer's
    -- extra diagnostic columns stay off the wire on purpose - uniformity is the point of
    -- this endpoint, and they are available from psql and to tests/parity.
    RETURN json_build_object(
        'last_block_num', _s.context_block_num,
        'last_block_time', to_char(_s.last_block_time, 'YYYY-MM-DD"T"HH24:MI:SS')
    );
END
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-account financial summary
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{account}/financial-summary:
  get:
    tags:
      - Account
    summary: Account financial summary
    description: >-
      Aggregated HBD/HIVE/VESTS flows for an account over a time range,
      grouped by financial category and direction (incoming/outgoing).
    operationId: haf_stats_endpoints.get_account_financial_summary
    parameters:
      - in: path
        name: account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive, defaults to 1 year ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: granularity
        required: false
        schema:
          type: string
          default: month
          enum: [day, week, month]
        description: Aggregation granularity
    responses:
      '200':
        description: Financial summary rows grouped by period and category
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, category TEXT, direction TEXT, hive_nai BIGINT, hbd_nai BIGINT, vests_nai BIGINT, op_count INT)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type: string
                    description: ISO-8601 date string for the aggregation bucket
                  category:
                    type: string
                    description: Canonical Hive operation type name, e.g. author_reward_operation
                  direction:
                    type: string
                    enum: [incoming, outgoing]
                  hive_nai:
                    type: integer
                  hbd_nai:
                    type: integer
                  vests_nai:
                    type: integer
                  op_count:
                    type: integer
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_financial_summary;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_financial_summary(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'month'
)
RETURNS TABLE(period TEXT, category TEXT, direction TEXT, hive_nai BIGINT, hbd_nai BIGINT, vests_nai BIGINT, op_count INT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
BEGIN
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '1 year')::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Wax's extendRest JSON-encodes string query params for custom namespaces,
    -- sending e.g. "month" (%22month%22) instead of month. Strip a surrounding
    -- pair of double quotes so the value passes the enum check below regardless of
    -- whether the client sent a raw or JSON-encoded string. See haf_stats issue #22.
    "granularity" := TRIM('"' FROM "granularity");
    -- IS NULL is required: "NULL NOT IN (...)" evaluates to NULL (not TRUE), so
    -- a NULL granularity would otherwise slip past and reach DATE_TRUNC.
    IF "granularity" IS NULL OR "granularity" NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE("granularity", '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;
    RETURN QUERY
    SELECT
        TO_CHAR(DATE_TRUNC("granularity", afd.day), 'YYYY-MM-DD') AS period,
        afd.category,
        afd.direction,
        SUM(afd.hive_nai)::BIGINT,
        SUM(afd.hbd_nai)::BIGINT,
        SUM(afd.vests_nai)::BIGINT,
        SUM(afd.op_count)::INT
    FROM haf_stats_backend.account_financial_daily afd
    JOIN hafd.accounts ha ON ha.id = afd.account_id
    WHERE ha.name  = "account"
      AND afd.day BETWEEN _from AND _to
    GROUP BY 1, 2, 3
    ORDER BY 1, 2, 3;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-account content & engagement stats
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{account}/content-stats:
  get:
    tags:
      - Account
    summary: Account content stats
    description: >-
      Per-account posting and engagement summary — posts, comments, votes cast,
      votes received, replies received, and author rewards — aggregated by the
      chosen granularity. Author reward figures are sourced from the account's
      financial daily aggregates. Post and comment counts reflect content-creation
      events only (edits excluded): every creation is counted at creation time,
      including content later deleted or re-created under the same permlink, so
      figures can slightly exceed Hivemind, which counts only currently-live content.
      The difference is negligible in practice.
    operationId: haf_stats_endpoints.get_account_content_stats
    parameters:
      - in: path
        name: account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: granularity
        required: false
        schema:
          type: string
          default: month
          enum: [day, week, month]
        description: Aggregation granularity
    responses:
      '200':
        description: Content and engagement rows grouped by period
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, posts BIGINT, comments BIGINT, votes_cast BIGINT, votes_received BIGINT, replies_received BIGINT, author_reward_hive_nai BIGINT, author_reward_hbd_nai BIGINT, author_reward_vests_nai BIGINT)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type: string
                    description: ISO-8601 date string for the aggregation bucket
                  posts:
                    type: integer
                    description: Root posts authored (parent_author = ''), counted at creation; edits excluded
                  comments:
                    type: integer
                    description: Replies authored (parent_author <> ''), counted at creation; edits excluded
                  votes_cast:
                    type: integer
                  votes_received:
                    type: integer
                  replies_received:
                    type: integer
                  author_reward_hive_nai:
                    type: integer
                  author_reward_hbd_nai:
                    type: integer
                  author_reward_vests_nai:
                    type: integer
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_content_stats;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_content_stats(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'month'
)
RETURNS TABLE(period TEXT, posts BIGINT, comments BIGINT, votes_cast BIGINT, votes_received BIGINT, replies_received BIGINT, author_reward_hive_nai BIGINT, author_reward_hbd_nai BIGINT, author_reward_vests_nai BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _account_id INT;
BEGIN
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '30 days')::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "month"); see issue #22.
    "granularity" := TRIM('"' FROM "granularity");
    -- IS NULL is required: "NULL NOT IN (...)" evaluates to NULL (not TRUE), so
    -- a NULL granularity would otherwise slip past and reach DATE_TRUNC.
    IF "granularity" IS NULL OR "granularity" NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE("granularity", '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;

    -- Resolve the account name to its id once, then filter the daily tables on
    -- account_id (their leading index column). Unknown account -> empty result.
    SELECT id INTO _account_id FROM hafd.accounts WHERE name = "account";
    IF _account_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    -- FULL OUTER JOIN so a period with rewards but no tracked content (or vice
    -- versa) still appears. Each side is pre-aggregated to the period so the join
    -- is 1:1 on period and cannot fan out rows.
    WITH content AS (
        SELECT
            DATE_TRUNC("granularity", acd.day) AS period,
            SUM(acd.posts)            AS posts,
            SUM(acd.comments)         AS comments,
            SUM(acd.votes_cast)       AS votes_cast,
            SUM(acd.votes_received)   AS votes_received,
            SUM(acd.replies_received) AS replies_received
        FROM haf_stats_backend.account_content_daily acd
        WHERE acd.account_id = _account_id
          AND acd.day BETWEEN _from AND _to
        GROUP BY 1
    ),
    rewards AS (
        SELECT
            DATE_TRUNC("granularity", afd.day) AS period,
            SUM(afd.hive_nai)  AS hive_nai,
            SUM(afd.hbd_nai)   AS hbd_nai,
            SUM(afd.vests_nai) AS vests_nai
        FROM haf_stats_backend.account_financial_daily afd
        WHERE afd.account_id = _account_id
          AND afd.day BETWEEN _from AND _to
          AND afd.category = 'author_reward_operation'
          AND afd.direction = 'incoming'
        GROUP BY 1
    )
    SELECT
        TO_CHAR(COALESCE(c.period, r.period), 'YYYY-MM-DD'),
        COALESCE(c.posts, 0)::BIGINT,
        COALESCE(c.comments, 0)::BIGINT,
        COALESCE(c.votes_cast, 0)::BIGINT,
        COALESCE(c.votes_received, 0)::BIGINT,
        COALESCE(c.replies_received, 0)::BIGINT,
        COALESCE(r.hive_nai, 0)::BIGINT,
        COALESCE(r.hbd_nai, 0)::BIGINT,
        COALESCE(r.vests_nai, 0)::BIGINT
    FROM content c
    FULL OUTER JOIN rewards r ON c.period = r.period
    ORDER BY 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-account activity by community (issue #47)
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{account}/community-activity:
  get:
    tags:
      - Account
    summary: Account activity by community
    description: >-
      Per-account created posts and comments grouped by Hive community, for the
      Community Activity treemap. A post belongs to the community named by its category;
      a reply belongs to its ROOT post's community, not its immediate parent's, matching
      how the chain propagates a thread's category to every descendant. Content outside
      any community — personal-blog posts and the legacy tag categories that predate
      communities — is returned as a single bucket with a null community, so the buckets
      always sum to get_account_content_stats' posts and comments for the same range.
      Counts are creations only (edits excluded), counted at creation time, exactly as
      get_account_content_stats counts them — so content later deleted is still counted,
      which is the main reason a figure here can exceed what Hivemind currently shows as
      live. Muting does NOT change community membership: Hivemind assigns community_id
      before any role check and only flags the post as muted, so muted and non-member
      posts belong to the community for both Hivemind and this endpoint.
      Communities are recognised from block 37,500,000 onward (Hivemind's community start
      block); nothing before it can belong to a community. Community titles follow
      Hivemind's rules for owner/admin updateProps; roles below admin are not modelled, so
      a title set through a role this app does not track is not reflected.
    operationId: haf_stats_endpoints.get_account_community_activity
    parameters:
      - in: path
        name: account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
    responses:
      '200':
        description: One row per community the account was active in, plus the no-community bucket
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(community TEXT, title TEXT, post_count BIGINT, comment_count BIGINT)"
              type: array
              items:
                type: object
                properties:
                  community:
                    type:
                      - string
                      - "null"
                    description: Community account name (e.g. hive-139531), or null for the personal-blog / no-community bucket
                  title:
                    type: string
                    description: Community title as set on-chain by an owner/admin updateProps; falls back to the community name when none was ever set
                  post_count:
                    type: integer
                    description: Root posts created in this community
                  comment_count:
                    type: integer
                    description: Replies created anywhere in a thread rooted in this community
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_community_activity;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_community_activity(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL
)
RETURNS TABLE(community TEXT, title TEXT, post_count BIGINT, comment_count BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _account_id INT;
BEGIN
    -- Genesis default (the #35 convention), not last-30-days: a treemap is an all-time
    -- view, and a silent 30-day window is exactly what #35 had to undo elsewhere.
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    SELECT id INTO _account_id FROM hafd.accounts WHERE name = "account";
    IF _account_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH per_community AS (
        SELECT
            acd.community            AS community,
            SUM(acd.posts)::BIGINT   AS posts,
            SUM(acd.comments)::BIGINT AS comments
        FROM haf_stats_backend.account_community_daily acd
        WHERE acd.account_id = _account_id
          AND acd.day BETWEEN _from AND _to
        GROUP BY acd.community
    ),
    -- The account's totals over the same range, from the table get_account_content_stats
    -- reads. Both sides count the same creation events, so subtracting the community
    -- buckets from these yields the no-community bucket without storing it.
    totals AS (
        SELECT
            COALESCE(SUM(t.posts), 0)::BIGINT    AS posts,
            COALESCE(SUM(t.comments), 0)::BIGINT AS comments
        FROM haf_stats_backend.account_content_daily t
        WHERE t.account_id = _account_id
          AND t.day BETWEEN _from AND _to
    ),
    -- GREATEST guards the arithmetic rather than trusting it: a partially-rebuilt
    -- deployment must under-report the personal bucket, never emit a negative count.
    -- The ::BIGINT casts are required, not cosmetic: SUM() over BIGINT returns NUMERIC,
    -- which would propagate through the UNION ALL and fail the declared RETURNS TABLE.
    no_community AS (
        SELECT
            GREATEST(t.posts - s.posts, 0)::BIGINT       AS posts,
            GREATEST(t.comments - s.comments, 0)::BIGINT AS comments
        FROM totals t
        CROSS JOIN (
            SELECT
                COALESCE(SUM(pc.posts), 0)    AS posts,
                COALESCE(SUM(pc.comments), 0) AS comments
            FROM per_community pc
        ) s
    ),
    buckets AS (
        SELECT pc.community, pc.posts, pc.comments
        FROM per_community pc
        UNION ALL
        SELECT NULL::TEXT, nc.posts, nc.comments
        FROM no_community nc
        WHERE nc.posts > 0 OR nc.comments > 0
    )
    SELECT
        b.community,
        CASE
            WHEN b.community IS NULL THEN 'Personal blog / No community'
            ELSE COALESCE(cr.title, b.community)
        END,
        b.posts,
        b.comments
    FROM buckets b
    LEFT JOIN haf_stats_backend.community_registry cr ON cr.community = b.community
    -- Largest first for the treemap; the no-community bucket always sorts last, and the
    -- name breaks ties so paging/diffing a response is stable.
    ORDER BY (b.community IS NULL), (b.posts + b.comments) DESC, b.community;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-account interaction graph (#48, backend for block_explorer_ui#762)
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{account}/interactions:
  get:
    tags:
      - Account
    summary: Account interaction graph
    description: >-
      Per-account OUTGOING interactions grouped by type and counterparty, for the Social
      Interaction Sankey (You -> type -> top partners). Five interaction types are counted:
      reply, vote, transfer, reblog and follow. The unit is always an interaction COUNT —
      transfer amounts and vote weights never affect it — so the bands are directly
      comparable. Each type returns its top_n partners by count plus a single "Others" band
      (partner null) aggregating the remaining partners, so the rows for a type always sum
      to that type's total regardless of top_n.
      Only operations the account itself SIGNED are counted, which is what makes the graph
      outgoing; interactions it merely received are not. Self-interactions (self-votes,
      transfers to yourself, replying to your own post) are excluded — they are a
      self-loop the sankey cannot render, and network_vote_daily.self_votes already
      reports them.
      Delegations are deliberately excluded: they belong to the Influence & Delegation Map,
      not to the interaction graph.
      Reply and reblog are DE-DUPLICATED, vote/transfer/follow are raw counts. A
      comment_operation that edits an existing reply reuses its permlink, so counting raw
      ops would report an edited reply as a second interaction (~11% inflation measured
      network-wide); reblog is idempotent state in Hivemind, so re-submitting it is not a
      new interaction. A vote and a follow, by contrast, are genuine repeatable events
      (vote -> unvote -> re-vote is two votes). The de-duplication is scoped to the
      requested window, so an edit of a reply created BEFORE the window is indistinguishable
      from an in-window creation; the effect is under 0.2% even at one-day windows and zero
      for the default full-history window.
      Follows are derived natively from the raw follow/reblog custom_json payloads rather
      than from Hivemind, and only a real follow counts — an unfollow (what:[]) or a mute
      (what:["ignore"]) is a retraction, not an interaction.
      covered_from reports the window actually scanned. A request whose op count exceeds the
      server ceiling is answered from the most recent ops within budget rather than failing,
      and covered_from then reports the later start date. Each OP TYPE carries its own budget,
      so heavy DApp custom_json traffic can never displace the vote, reply or transfer bands.
      Note that reblog and follow BOTH ride custom_json, and share that budget with every DApp
      custom_json the account signs: an account whose recent custom_json is dominated by game
      or token traffic can therefore have its reblog and follow bands truncated away entirely.
      Whenever a band comes back empty AND its op type was truncated, it is reported as a single
      row with a null partner, interaction_count 0 and partners_merged 0, carrying the
      covered_from of the window that WAS scanned. Read it as "no interactions of this type
      inside the covered window, and the window is shorter than you asked for" — it does NOT
      assert that data was lost, because once the budget is exhausted the endpoint genuinely
      cannot tell an account with no follows from one whose follows fell outside it. A band that
      is empty over a FULLY covered window emits no row, so an unqualified absence still means
      a real zero.
    operationId: haf_stats_endpoints.get_account_interactions
    parameters:
      - in: path
        name: account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: top_n
        required: false
        schema:
          type: integer
          default: 10
          minimum: 1
          maximum: 50
        description: Number of named partners returned per interaction type (1-50); the rest are aggregated into the Others band
      - in: query
        name: type_filter
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
          enum: [reply, vote, transfer, reblog, follow]
        description: Restrict the response to a single interaction type; omit for all five
    responses:
      '200':
        description: Top partners per interaction type, each type followed by its Others band
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(interaction_type TEXT, partner TEXT, interaction_count BIGINT, partner_rank INT, partners_merged INT, covered_from DATE)"
              type: array
              items:
                type: object
                properties:
                  interaction_type:
                    type: string
                    description: One of reply, vote, transfer, reblog, follow
                  partner:
                    type:
                      - string
                      - "null"
                    description: Counterparty account name, or null for the Others band
                  interaction_count:
                    type: integer
                    description: Interactions with this partner (or absorbed into Others)
                  partner_rank:
                    type: integer
                    description: 1..top_n for a named partner; top_n + 1 for the Others band
                  partners_merged:
                    type: integer
                    description: >-
                      1 for a named partner; for Others, how many distinct partners it absorbs;
                      0 on a coverage-disclosure row (empty band over a truncated window)
                  covered_from:
                    type: string
                    format: date
                    description: Start of the window actually scanned; equals from_date unless the server op ceiling truncated it
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_interactions;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_interactions(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "top_n" INT = 10,
    "type_filter" TEXT = NULL
)
RETURNS TABLE(interaction_type TEXT, partner TEXT, interaction_count BIGINT, partner_rank INT, partners_merged INT, covered_from DATE)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _account_id INT;
    _from_block INT;
    _to_block INT;
    _lo_seq BIGINT;
    _hi_seq BIGINT;
    _type TEXT;
    _cap INT;
    -- Op types worth scanning at all, given type_filter. Each gets its OWN budget below.
    _types INT[];
BEGIN
    -- Genesis default, not last-30-days: an interaction graph is an all-time view of who an
    -- account deals with, and #35 is the standing ruling against silent 30-day windows.
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- `top_n IS NULL OR` is load-bearing, not defensive noise. Without it the guard is
    -- `NULL < 1 OR NULL > 50` = NULL, `IF NULL THEN` does not fire, and the ranking filters
    -- below (rn <= top_n / rn > top_n) then yield NULL for every row — returning HTTP 200
    -- with an EMPTY body for a perfectly valid account. Wax sends JSON-encoded and empty
    -- params (#22), so a null top_n is reachable from the real client.
    IF "top_n" IS NULL OR "top_n" < 1 OR "top_n" > 50 THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid top_n: ' || COALESCE("top_n"::TEXT, '(null)'),
            HINT = 'Must be between 1 and 50';
    END IF;

    -- NULL means "all five types"; '' is treated as absent too. Tolerate Wax's JSON-encoded
    -- quoting (#22). Compared below as (_type IS NULL OR kind = _type) — never a bare
    -- kind = _type, which would return nothing at all for the default request.
    _type := NULLIF(TRIM('"' FROM COALESCE("type_filter", '')), '');
    IF _type IS NOT NULL AND _type NOT IN ('reply', 'vote', 'transfer', 'reblog', 'follow') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid type_filter: ' || _type,
            HINT = 'Must be one of: reply, vote, transfer, reblog, follow';
    END IF;

    SELECT a.id INTO _account_id FROM hafd.accounts a WHERE a.name = "account";
    IF _account_id IS NULL THEN
        RETURN;   -- unknown account -> empty result, same contract as the sibling endpoints
    END IF;

    -- COALESCE because LIMIT NULL means NO LIMIT in PostgreSQL: if the ceiling function is
    -- ever replaced with one returning NULL (the cap test does replace it, to prove the guard
    -- fires), an unguarded LIMIT would silently become the unbounded whale scan this cap
    -- exists to prevent.
    _cap := COALESCE(haf_stats_app.max_interaction_ops(), 4000);

    SELECT r.from_block, r.to_block INTO _from_block, _to_block
    FROM haf_stats_app.block_range_for_dates(_from, _to) r;
    IF _from_block IS NULL OR _to_block IS NULL THEN
        RETURN;
    END IF;

    -- Block range -> this account's account_op_seq_no range. account_operations.block_num is
    -- computed and unindexed, so only the seq bound can actually restrict the scan; the
    -- helper binary-searches the (account_id, account_op_seq_no) index. (#33/#40)
    SELECT r.lo_seq, r.hi_seq INTO _lo_seq, _hi_seq
    FROM haf_stats_app.account_op_seq_range(_account_id, _from_block, _to_block) r;
    IF _lo_seq IS NULL OR _hi_seq IS NULL OR _lo_seq > _hi_seq THEN
        RETURN;   -- no ops in the window
    END IF;

    -- One budget PER OP TYPE, not per band group. A shared budget made the answer depend on
    -- type_filter: an account whose votes+replies+transfers shared one 50,000-op page
    -- reported fewer votes than the same account queried with type_filter=vote, where votes
    -- had the page to themselves — a band and its own drill-down disagreeing for identical
    -- inputs. Per-type budgets also keep DApp custom_json traffic (which yields no
    -- counterparty at all) from ever displacing the vote, reply or transfer bands.
    _types := CASE _type
        WHEN 'vote'     THEN ARRAY[0]
        WHEN 'reply'    THEN ARRAY[1]
        WHEN 'transfer' THEN ARRAY[2]
        WHEN 'reblog'   THEN ARRAY[18]
        WHEN 'follow'   THEN ARRAY[18]
        ELSE ARRAY[0, 1, 2, 18]
    END;

    RETURN QUERY
    WITH wanted AS (
        SELECT UNNEST(_types) AS op_type_id
    ),
    -- _cap + 1 rows per type: the extra row is how truncation is DETECTED without a second
    -- scan. Counting rows is exact, where the previous block-number comparison was not — when
    -- the cap boundary fell inside the earliest matching block, "oldest kept" equalled
    -- "oldest available" and the guard wrongly concluded nothing had been dropped, reporting
    -- full coverage for a truncated answer.
    page_raw AS MATERIALIZED (
        SELECT w.op_type_id AS t, p.operation_id, p.account_op_seq_no, p.block_num
        FROM wanted w
        CROSS JOIN LATERAL (
            SELECT ao.operation_id, ao.account_op_seq_no, ao.block_num
            FROM hive.account_operations_view ao
            WHERE ao.account_id = _account_id
              AND ao.transacting_account_id = ao.account_id   -- signed it => outgoing
              AND ao.op_type_id = w.op_type_id
              AND ao.account_op_seq_no BETWEEN _lo_seq AND _hi_seq
            ORDER BY ao.account_op_seq_no DESC
            LIMIT _cap + 1
        ) p
    ),
    -- Ranking happens over the already-bounded _cap + 1 rows, so it costs nothing; putting the
    -- window function inside the LATERAL above would have forced a scan of every matching
    -- index entry instead of stopping at the limit.
    ranked_page AS MATERIALIZED (
        SELECT
            pr.t,
            pr.operation_id,
            bl.created_at::DATE AS day,
            ROW_NUMBER() OVER (PARTITION BY pr.t ORDER BY pr.account_op_seq_no DESC) AS rn,
            COUNT(*) OVER (PARTITION BY pr.t) AS fetched
        FROM page_raw pr
        JOIN hafd.blocks bl ON bl.num = pr.block_num
    ),
    -- Per-type coverage AND the boundary day, computed together because the two must agree.
    coverage AS (
        SELECT
            b.t,
            b.truncated,
            b.boundary_day,
            CASE WHEN NOT b.truncated THEN _from ELSE b.boundary_day + 1 END AS covered_from
        FROM (
            SELECT
                rp.t,
                MAX(rp.fetched) > _cap AS truncated,
                MIN(rp.day) FILTER (WHERE rp.rn <= _cap) AS boundary_day
            FROM ranked_page rp
            GROUP BY rp.t
        ) b
    ),
    -- The served set. When the cap bit, the oldest day inside it was only PARTIALLY scanned, so
    -- its ops are dropped rather than counted: otherwise the response would report interactions
    -- from a day that covered_from excludes, and a client re-deriving totals over
    -- [covered_from, to_date] would get a smaller number than the endpoint just gave it. Paying
    -- for rows we then discard is deliberate — it is what makes the counts and the disclosed
    -- window describe exactly the same period.
    page AS MATERIALIZED (
        SELECT rp.t, rp.operation_id
        FROM ranked_page rp
        JOIN coverage c ON c.t = rp.t
        WHERE rp.rn <= _cap
          AND (NOT c.truncated OR rp.day > c.boundary_day)
    ),
    -- MATERIALIZED is load-bearing on the three CTEs below, not a hint. Each is referenced
    -- once, so PostgreSQL would inline them — and inlining duplicates the try_jsonb() call
    -- into every downstream expression that touches the parsed payload. EXPLAIN VERBOSE showed
    -- ~200 copies of it in the projection, turning one plpgsql exception-trapped parse per row
    -- into hundreds (1.86s vs 187ms on a 13,277-op account). Materialising forces exactly one
    -- parse per row, which is what the payload-restricted parse below was written to achieve.
    -- MATERIALIZED is load-bearing on the CTEs below, not a hint. Each is referenced once, so
    -- PostgreSQL would inline them — and inlining duplicates the try_jsonb() call into every
    -- downstream expression that touches the parsed payload. EXPLAIN VERBOSE showed ~200 copies
    -- of it in the projection, turning one plpgsql exception-trapped parse per row into hundreds
    -- (1.86s vs 187ms on a 13,277-op account). Materialising forces exactly one parse per row.
    --
    -- Only the five scalars actually read are projected — never body_value itself. A
    -- comment_operation body carries the whole post markdown plus json_metadata (~2-3 KB), so
    -- carrying it through two materialised tuplestores would put tens of MB per request into
    -- work_mem (4 MB by default) and spill to temp files, adding disk I/O to the exact path the
    -- op ceiling exists to keep cheap — and multiplying that across PostgREST's 20 pool slots.
    ops AS MATERIALIZED (
        SELECT
            p.t,
            ov.body_value ->> 'author'        AS body_author,
            ov.body_value ->> 'permlink'      AS body_permlink,
            ov.body_value ->> 'parent_author' AS body_parent_author,
            ov.body_value ->> 'to'            AS body_to,
            ov.body_value ->> 'weight'        AS body_weight,
            -- Parse the payload only for the two ids that can carry an edge. This keeps the
            -- exception-trapping parse (a subtransaction per call) off the vote/comment/
            -- transfer stream entirely, and off DApp custom_json.
            --
            -- This IS a scope limit, and a deliberate one: the id is not trusted to say WHICH
            -- operation a payload holds (a reblog really does arrive under id='follow', which is
            -- why the operation is identified from the payload KEYS below), but it is used to
            -- decide WHETHER to parse at all. A follow or reblog published under some third id
            -- is therefore out of scope — parsing every custom_json to find them would reinstate
            -- the per-op cost this gate removes.
            CASE
                WHEN p.t = 18 AND ov.body_value ->> 'id' IN ('follow', 'reblog')
                    THEN haf_stats_app.try_jsonb(ov.body_value ->> 'json')
            END AS payload
        FROM page p
        -- Bodies come from hive.operations_view, NOT hafd.operations: account_operations_view
        -- UNION ALLs a reversible branch whose bodies live in hafd.operations_reversible, so
        -- joining the irreversible table alone would silently drop every op at the chain head.
        JOIN hive.operations_view ov ON ov.id = p.operation_id
    ),
    -- Both real-world payload shapes occur and neither is an edge case: measured over the
    -- first 5,000,000 blocks, 67% are the bare object {"follower":...} and 33% are the
    -- array-wrapped ["follow", {...}]. Unwrap to the inner object either way, then classify
    -- ONCE — kind is derived here and every later expression switches on it, rather than each
    -- re-testing the payload keys and drifting apart.
    unwrapped AS MATERIALIZED (
        SELECT
            o.t,
            o.body_author,
            o.body_permlink,
            o.body_parent_author,
            o.body_to,
            o.body_weight,
            cj.cj,
            CASE o.t
                WHEN 0 THEN 'vote'
                WHEN 1 THEN 'reply'
                WHEN 2 THEN 'transfer'
                ELSE CASE
                    -- hivemind's follow/reblog handlers BOTH require the payload's self-declared
                    -- actor to be the signing account and return early otherwise, so an op that
                    -- names someone else creates nothing on chain. Without this check the graph
                    -- was inflatable by the very account being graphed: signing
                    -- {"follower":"someone-else","following":"C"} would have drawn A -> C.
                    -- (Zero such ops exist below block 5,000,000 — this is forward defence.)
                    WHEN cj.cj ? 'following' AND cj.cj ->> 'follower' = "account" THEN 'follow'
                    -- A reblog DELETE ("un-reblog") carries the same author/permlink plus a
                    -- `delete` key. It removes content, so it is a retraction exactly like an
                    -- unfollow, and must not draw an edge.
                    WHEN cj.cj ? 'author' AND cj.cj ? 'permlink' AND NOT (cj.cj ? 'delete')
                         AND cj.cj ->> 'account' = "account" THEN 'reblog'
                END
            END AS kind
        FROM ops o
        CROSS JOIN LATERAL (
            SELECT CASE
                WHEN JSONB_TYPEOF(o.payload) = 'array'  THEN o.payload -> 1
                WHEN JSONB_TYPEOF(o.payload) = 'object' THEN o.payload
            END AS cj
        ) cj
    ),
    -- One row per candidate interaction: its type, its counterparty, and the key that
    -- de-duplicates it. dedup_key MUST be paired with the partner, never used alone:
    -- @calva's permlink 'bitcoin-the-end-of-money-as-we-know-it' was created under parent
    -- @sebhaj, deleted, then re-created under @socialleadninja — two real interactions with
    -- two different partners that a permlink-only dedup would collapse into one, keeping a
    -- nondeterministic winner.
    events AS MATERIALIZED (
        SELECT
            u.t,
            u.kind,
            CASE u.kind
                -- weight = 0 is an UNVOTE: the vote is withdrawn, so it is a retraction, not
                -- an interaction. Excluded for the same reason as an unfollow, and matching
                -- post_engagement, which already refuses to count weight-0 votes as engagement.
                WHEN 'vote' THEN CASE WHEN COALESCE(u.body_weight::INT, 0) <> 0
                                      THEN u.body_author END
                WHEN 'reply' THEN NULLIF(u.body_parent_author, '')   -- '' => a root post
                WHEN 'transfer' THEN u.body_to
                -- hivemind reads what[0] and lowercases it, so it acts on the FIRST element
                -- only. Containment (@>) instead treated ["posts","blog"] as a follow where
                -- hivemind sees "posts" and does nothing — 254 such ops in the first 5,000,000
                -- blocks. An unfollow (what: []) and a mute (what: ["ignore"]) fall out here.
                WHEN 'follow' THEN CASE WHEN LOWER(u.cj -> 'what' ->> 0) = 'blog'
                                        THEN u.cj ->> 'following' END
                WHEN 'reblog' THEN u.cj ->> 'author'
            END AS partner,
            CASE u.kind
                -- An edit reuses the reply's permlink, so the permlink identifies the reply.
                WHEN 'reply' THEN u.body_permlink
                -- A reblog IS idempotent state in hivemind: the same (author, permlink)
                -- reblogged twice is one interaction.
                WHEN 'reblog' THEN (u.cj ->> 'author') || '/' || (u.cj ->> 'permlink')
                -- vote / transfer / FOLLOW: every op is its own event. A re-vote and a
                -- follow -> unfollow -> re-follow are genuinely repeated acts, so these fall
                -- through to the per-op key in `filtered`.
                ELSE NULL
            END AS dedup_key
        FROM unwrapped u
    ),
    -- Drop non-edges: root posts (no parent), DApp custom_json, unfollows/mutes/un-reblogs,
    -- unvotes, malformed payloads (try_jsonb returned NULL so cj is NULL and every ? test is
    -- false), and self-interactions. Partner names come straight from the op body and are
    -- never joined to hafd.accounts, so a counterparty that exists only in
    -- hafd.accounts_reversible is still counted.
    filtered AS (
        SELECT
            e.t,
            e.kind,
            e.partner,
            -- Give the "count every op" types a unique key so ONE aggregation path serves all
            -- five types. ROW_NUMBER() OVER () is already unique across this set; the '#'
            -- prefix keeps a synthetic key from ever colliding with a real permlink or
            -- author/permlink pair, neither of which can contain '#'.
            COALESCE(e.dedup_key, '#' || ROW_NUMBER() OVER ()) AS dedup_key
        FROM events e
        WHERE e.kind IS NOT NULL
          AND e.partner IS NOT NULL
          AND e.partner <> ''
          AND e.partner <> "account"
          AND (_type IS NULL OR e.kind = _type)
    ),
    per_partner AS (
        SELECT f.t, f.kind, f.partner, COUNT(DISTINCT f.dedup_key)::BIGINT AS cnt
        FROM filtered f
        GROUP BY f.t, f.kind, f.partner
    ),
    ranked AS (
        SELECT
            pp.t,
            pp.kind,
            pp.partner,
            pp.cnt,
            -- Partner name breaks count ties so paging and response diffing are stable.
            ROW_NUMBER() OVER (PARTITION BY pp.kind ORDER BY pp.cnt DESC, pp.partner) AS rn
        FROM per_partner pp
    ),
    named AS (
        SELECT r.t, r.kind, r.partner, r.cnt, r.rn::INT AS rn, 1 AS merged
        FROM ranked r
        WHERE r.rn <= "top_n"
    ),
    -- The five bands this request asked for, with the op type each is budgeted under. reblog
    -- and follow BOTH ride op 18, which is what makes the eviction below possible.
    requested_kinds AS (
        SELECT v.kind, v.t
        FROM (VALUES ('reply', 1), ('vote', 0), ('transfer', 2), ('reblog', 18), ('follow', 18))
             AS v(kind, t)
        WHERE _type IS NULL OR v.kind = _type
    ),
    -- A band can be scanned and still come back empty because the budget for its op type was
    -- consumed by ops of a DIFFERENT band. reblog and follow share op 18 with ALL DApp
    -- custom_json, so an account whose most recent op-18 ops are entirely sm_*/dcity traffic
    -- loses both bands — and with no rows to carry covered_from, that was invisible.
    --
    -- The row means "empty band, over a window we could not fully cover". It deliberately does
    -- NOT claim data was lost: once the budget is exhausted the endpoint cannot distinguish an
    -- account with no follows from one whose follows fell outside the window, and pretending
    -- otherwise would be the same over-claim the covered_from arithmetic exists to avoid. What
    -- it does guarantee is the converse — an empty band over a FULLY covered window emits
    -- nothing, so an unqualified absence is a real zero.
    evicted AS (
        SELECT
            rk.t,
            rk.kind,
            NULL::TEXT AS partner,
            0::BIGINT AS cnt,
            ("top_n" + 1) AS rn,
            0 AS merged
        FROM requested_kinds rk
        JOIN coverage c ON c.t = rk.t
        WHERE c.truncated
          AND NOT EXISTS (SELECT 1 FROM ranked r WHERE r.kind = rk.kind)
    ),
    -- One Others band per type, emitted only when something is actually absorbed, so a type
    -- with fewer partners than top_n returns no zero row.
    others AS (
        SELECT
            MIN(r.t) AS t,
            r.kind,
            NULL::TEXT AS partner,
            SUM(r.cnt)::BIGINT AS cnt,
            ("top_n" + 1) AS rn,
            COUNT(*)::INT AS merged
        FROM ranked r
        WHERE r.rn > "top_n"
        GROUP BY r.kind
    )
    SELECT
        b.kind,
        b.partner,
        b.cnt,
        b.rn::INT,
        b.merged,
        -- Coverage is per OP TYPE, because the budget is: reblog and follow share op 18, while
        -- reply, vote and transfer each have their own.
        c.covered_from
    FROM (
        SELECT named.t, named.kind, named.partner, named.cnt, named.rn, named.merged FROM named
        UNION ALL
        SELECT others.t, others.kind, others.partner, others.cnt, others.rn, others.merged FROM others
        UNION ALL
        SELECT evicted.t, evicted.kind, evicted.partner, evicted.cnt, evicted.rn, evicted.merged FROM evicted
    ) b
    LEFT JOIN coverage c ON c.t = b.t
    -- Types in a stable order so the sankey's bands do not reshuffle between calls, then
    -- rank within a type (Others always last, since its rank is top_n + 1).
    ORDER BY
        CASE b.kind
            WHEN 'reply' THEN 1 WHEN 'vote' THEN 2 WHEN 'transfer' THEN 3
            WHEN 'reblog' THEN 4 ELSE 5
        END,
        b.rn;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-account RC footprint
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{account}/rc-footprint:
  get:
    tags:
      - Account
    summary: Account RC footprint
    description: >-
      Breakdown of Resource Credit consumption for an account over a time range, grouped by
      operation type or DApp. Counts the ops the account itself signed. Where the
      node records the RC each transaction cost (HAF 1.28.8 and later, from hardfork 20), an op
      is priced with its EXACT share of that cost: the whole cost for a single-op transaction,
      and for a multi-op transaction a share in proportion to the op-count estimate of each op.
      Otherwise an op is priced with that ESTIMATE (op_count * average rc_api cost from the
      calibrated rc_op_stats_daily rates). A window in which the account signed more than
      rc_exact_op_cap ops (15,000) is priced entirely with the estimate, to keep the call fast.
      For group_by=app and
      group_by=category the custom_json buckets come from the per-account daily rollup:
      each day's row is exact where the rollup recorded it and the byte-aware estimate
      otherwise, with no op limit; the non-custom_json bucket is exact under the op limit.
      Every row says which it got: rc_source (recorded, estimated or mixed), rc_exact_ops (how
      many of its ops were priced exactly), rc_exact_op_cap (the limit this node applies) and
      rc_over_cap (whether this window exceeded it), so a caller never has to infer it.
    operationId: haf_stats_endpoints.get_account_rc_footprint
    parameters:
      - in: path
        name: account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: group_by
        required: false
        schema:
          type: string
          default: op_type
          enum: [op_type, app, category]
        description: >-
          Group results by operation type, DApp, or registry category (the
          custom_json_app_registry category each DApp belongs to, unmatched ids ->
          Uncategorized). app and category are byte-aware for custom_json (aggregations of
          the same daily buckets), so category totals reconcile with app rolled up by
          category - NOT with the timeline category_filter sum, which is priced per op as in op_type.
    responses:
      '200':
        description: RC consumption ranked by usage
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(label TEXT, rc_consumed BIGINT, op_count BIGINT, pct NUMERIC, rc_source TEXT, rc_exact_ops BIGINT, rc_exact_op_cap INT, rc_over_cap BOOLEAN)"
              type: array
              items:
                type: object
                properties:
                  label:
                    type: string
                    description: Operation type name, custom_json DApp name, or registry category
                  rc_consumed:
                    type: integer
                  op_count:
                    type: integer
                  pct:
                    type:
                      - number
                      - "null"
                    description: Percentage of total RC consumed
                  rc_source:
                    type: string
                    enum: [recorded, estimated, mixed]
                    description: >-
                      How rc_consumed was priced: recorded when every op in the row was priced with its exact share of the RC its
                      transaction recorded, estimated when none was, mixed otherwise
                  rc_exact_ops:
                    type: integer
                    description: How many of the row's op_count ops were priced exactly
                  rc_exact_op_cap:
                    type: integer
                    description: >-
                      The most signed ops one call prices exactly on this node. A window with
                      more is priced with the estimate (the custom_json buckets of group_by=app
                      and group_by=category excepted, which come from the daily rollup)
                  rc_over_cap:
                    type: boolean
                    description: >-
                      Whether the account signed more than rc_exact_op_cap ops in the window, so
                      the per-op pricing fell back to the estimate. The same for every row of a response
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_rc_footprint;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_rc_footprint(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "group_by" TEXT = 'op_type'
)
RETURNS TABLE(label TEXT, rc_consumed BIGINT, op_count BIGINT, pct NUMERIC, rc_source TEXT, rc_exact_ops BIGINT, rc_exact_op_cap INT, rc_over_cap BOOLEAN)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _account_id INT;
    _from_block INT;
    _to_block INT;
    _lo_seq BIGINT;
    _hi_seq BIGINT;
BEGIN
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '30 days')::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "op_type"); see issue #22.
    group_by := TRIM('"' FROM group_by);
    IF group_by IS NULL OR group_by NOT IN ('op_type', 'app', 'category') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid group_by: ' || COALESCE(group_by, '(null)'),
            HINT = 'Must be one of: op_type, app, category';
    END IF;

    SELECT id INTO _account_id FROM hafd.accounts WHERE name = account;
    IF _account_id IS NULL THEN
        RETURN;   -- unknown account -> empty result
    END IF;

    -- Estimated RC footprint, computed ON-DEMAND from account_operations (issue #33): the
    -- account's own signed ops are those with account_id = transacting_account_id (the tx
    -- signer), which correctly excludes ops it only received. Virtual ops are
    -- excluded (they consume no RC).
    --
    -- The date range is translated to a block range and then to this account's
    -- account_op_seq_no range (binary search), because account_operations.block_num is computed
    -- and unindexed - only account_op_seq_no bounds the indexed (account_id, seq) scan, so a
    -- narrow window actually reads only its slice instead of the account's whole history.
    -- ORDER BY ... LIMIT 1, NOT MIN/MAX(num): a combined aggregate with a created_at filter
    -- cannot use the created_at index and seq-scans hafd.blocks (~71s on a full node). The
    -- earliest block at/after _from (and latest before _to+1) is a single indexed lookup; num
    -- is monotonic with created_at, so that row's num is the range bound. (#33 perf)
    SELECT r.from_block, r.to_block INTO _from_block, _to_block
    FROM haf_stats_app.block_range_for_dates(_from, _to) r;
    IF _from_block IS NULL OR _to_block IS NULL THEN
        RETURN;
    END IF;

    SELECT lo_seq, hi_seq INTO _lo_seq, _hi_seq
    FROM haf_stats_app.account_op_seq_range(_account_id, _from_block, _to_block);
    IF _lo_seq IS NULL OR _hi_seq IS NULL OR _lo_seq > _hi_seq THEN
        RETURN;   -- no ops in the window
    END IF;

    IF group_by = 'op_type' THEN
        -- RC per op is EXACT where the node records the transaction's RC cost
        -- (haf_stats_app.exact_rc_for_ops, issue #44: the op's share of hafd.transactions.rc_cost)
        -- and otherwise the op-count estimate avg_cost_rc, the rc_api average for the type at the
        -- rate effective on/before the op's day. The estimate still needs no per-op body join;
        -- the exact path reads only the ops' transactions. A window with more signed ops than
        -- haf_stats_app.exact_rc_op_cap() (15,000) is priced entirely with the estimate, which keeps
        -- the call inside the API role's statement_timeout.
        RETURN QUERY
        WITH signed AS MATERIALIZED (
            SELECT ao.operation_id, ao.op_type_id, bv.created_at::DATE AS day
            FROM hive.account_operations_view ao
            JOIN hafd.blocks bv ON bv.num = ao.block_num
            JOIN hafd.operation_types ot ON ot.id = ao.op_type_id AND ot.is_virtual = FALSE
            WHERE ao.account_id = _account_id
              AND ao.transacting_account_id = ao.account_id
              AND ao.account_op_seq_no BETWEEN _lo_seq AND _hi_seq
              AND ao.block_num BETWEEN _from_block AND _to_block
        ),
        ex AS MATERIALIZED (
            -- Over exact_rc_op_cap() the function would discard the array anyway; skip building it.
            SELECT e.operation_id, e.rc_exact
            FROM haf_stats_app.exact_rc_for_ops(
                CASE WHEN (SELECT count(s.operation_id) FROM signed s) > haf_stats_app.exact_rc_op_cap()
                     THEN '{}'::BIGINT []
                     ELSE ARRAY(SELECT s.operation_id FROM signed s WHERE s.operation_id IS NOT NULL)
                END) e
        ),
        cap_info AS MATERIALIZED (
            -- The same count ex decides on, reported to the caller (#101).
            SELECT haf_stats_app.exact_rc_op_cap() AS cap,
                   (SELECT count(s.operation_id) FROM signed s) AS n
        ),
        acct_ops AS (
            -- Per (op type, day): how many ops, how many of them were priced exactly, and the
            -- exact RC of those. The rest are priced with the estimate below.
            SELECT s.op_type_id, s.day,
                   COUNT(*)::BIGINT                    AS op_count,
                   COUNT(ex.rc_exact)::BIGINT          AS exact_count,
                   COALESCE(SUM(ex.rc_exact), 0)::NUMERIC AS exact_rc
            FROM signed s
            LEFT JOIN ex ON ex.operation_id = s.operation_id
            GROUP BY s.op_type_id, s.day
        ),
        priced AS (
            SELECT
                COALESCE(replace(ot.name, 'hive::protocol::', ''),
                         'op_type_' || ao.op_type_id)                          AS label,
                ao.op_count,
                ao.exact_count,
                (ao.exact_rc
                 + (ao.op_count - ao.exact_count)
                   * haf_stats_app.rc_avg_cost(ao.op_type_id, ao.day))::BIGINT AS rc
            FROM acct_ops ao
            LEFT JOIN hafd.operation_types ot ON ot.id = ao.op_type_id
        ),
        agg AS (
            SELECT priced.label,
                   SUM(priced.rc)::BIGINT          AS rc_consumed,
                   SUM(priced.op_count)::BIGINT    AS op_count,
                   SUM(priced.exact_count)::BIGINT AS exact_ops
            FROM priced GROUP BY priced.label
        ),
        tot AS (SELECT SUM(agg.rc_consumed) AS gt FROM agg)
        SELECT agg.label, agg.rc_consumed, agg.op_count,
               ROUND(agg.rc_consumed * 100.0 / NULLIF(t.gt, 0), 2),
               haf_stats_app.rc_source_label(agg.exact_ops, agg.op_count),
               agg.exact_ops,
               ci.cap,
               ci.n > ci.cap
        FROM agg, tot t, cap_info ci
        ORDER BY agg.rc_consumed DESC, agg.label;
    ELSE
        -- group_by = 'app' or 'category': size-aware custom_json from the pre-aggregated
        -- account_custom_json_daily (op_count + op_bytes per json_id, base+byte op-18 rate),
        -- rolled up to the registered DApp name (resolve_dapp_name) or, for group_by='category',
        -- one registry level further to the DApp's category (resolve_dapp_category, unmatched
        -- ids -> 'Uncategorized'). Distinct json_ids sharing a label merge (e.g. 'sm_' and
        -- 'splinterlands' -> Splinterlands; Splinterlands + Rising Star -> Gaming). Plus one
        -- 'non-custom_json' bucket for all other signed ops (op_count * avg_cost), so totals
        -- still cover 100% of the account's RC. The two modes differ ONLY in the label resolver,
        -- so a category total reconciles exactly with the app totals summed by category (and with
        -- get_account_dapp_footprint's categories[].rc_estimated).
        RETURN QUERY
        WITH cj AS (
            SELECT CASE WHEN group_by = 'category'
                        THEN haf_stats_app.resolve_dapp_category(acj.json_id)
                        ELSE haf_stats_app.resolve_dapp_name(acj.json_id) END AS label,
                   SUM(acj.op_count)::BIGINT     AS op_count,
                   SUM(COALESCE(acj.rc_exact, acj.op_count * dr.base_rc + acj.op_bytes * dr.byte_rc))::BIGINT AS rc_consumed,
                   -- A day's row carries rc_exact only when all its ops had a recorded cost.
                   COALESCE(SUM(acj.op_count) FILTER (WHERE acj.rc_exact IS NOT NULL), 0)::BIGINT AS exact_ops
            FROM haf_stats_backend.account_custom_json_daily acj
            CROSS JOIN LATERAL haf_stats_app.rc_rate(18::SMALLINT, acj.day) dr
            WHERE acj.account_id = _account_id
              AND acj.day BETWEEN _from AND _to
            GROUP BY CASE WHEN group_by = 'category'
                          THEN haf_stats_app.resolve_dapp_category(acj.json_id)
                          ELSE haf_stats_app.resolve_dapp_name(acj.json_id) END
        ),
        noncj_signed AS MATERIALIZED (
            SELECT ao.operation_id, ao.op_type_id, bv.created_at::DATE AS day
            FROM hive.account_operations_view ao
            JOIN hafd.blocks bv ON bv.num = ao.block_num
            JOIN hafd.operation_types ot ON ot.id = ao.op_type_id AND ot.is_virtual = FALSE
            WHERE ao.account_id = _account_id
              AND ao.transacting_account_id = ao.account_id
              AND ao.account_op_seq_no BETWEEN _lo_seq AND _hi_seq
              AND ao.block_num BETWEEN _from_block AND _to_block
              AND ao.op_type_id <> 18
        ),
        all_signed_count AS MATERIALIZED (
            -- The cap is decided on ALL the window's signed ops, custom_json included: the ops
            -- group_by=op_type hands over, so both groupings of one window make the same
            -- exact-or-estimate decision. Counted without the hafd.blocks join (only the priced ops
            -- need their day); _to_block is an irreversible block, so the join removes nothing here.
            SELECT count(ao.operation_id) AS n
            FROM hive.account_operations_view ao
            JOIN hafd.operation_types ot ON ot.id = ao.op_type_id AND ot.is_virtual = FALSE
            WHERE ao.account_id = _account_id
              AND ao.transacting_account_id = ao.account_id
              AND ao.account_op_seq_no BETWEEN _lo_seq AND _hi_seq
              AND ao.block_num BETWEEN _from_block AND _to_block
        ),
        noncj_ex AS MATERIALIZED (
            -- Only the non-custom_json ops are priced: the custom_json buckets come from the rollup.
            SELECT e.operation_id, e.rc_exact
            FROM haf_stats_app.exact_rc_for_ops(
                CASE WHEN (SELECT c.n FROM all_signed_count c) > haf_stats_app.exact_rc_op_cap()
                     THEN '{}'::BIGINT []
                     ELSE ARRAY(SELECT s.operation_id FROM noncj_signed s WHERE s.operation_id IS NOT NULL)
                END) e
        ),
        noncj AS (
            -- Exact where the node records the transaction's RC cost, the op-count estimate
            -- otherwise (same rule as group_by=op_type, issue #44).
            SELECT 'non-custom_json'::TEXT       AS label,
                   SUM(t.op_count)::BIGINT        AS op_count,
                   SUM(t.exact_rc
                       + (t.op_count - t.exact_count)
                         * haf_stats_app.rc_avg_cost(t.op_type_id, t.day))::BIGINT AS rc_consumed,
                   SUM(t.exact_count)::BIGINT     AS exact_ops
            FROM (
                SELECT s.op_type_id, s.day,
                       COUNT(*)::BIGINT                       AS op_count,
                       COUNT(x.rc_exact)::BIGINT              AS exact_count,
                       COALESCE(SUM(x.rc_exact), 0)::NUMERIC  AS exact_rc
                FROM noncj_signed s
                LEFT JOIN noncj_ex x ON x.operation_id = s.operation_id
                GROUP BY s.op_type_id, s.day
            ) t
        ),
        combined AS (
            SELECT cj.label, cj.rc_consumed, cj.op_count, cj.exact_ops FROM cj
            UNION ALL
            SELECT noncj.label, noncj.rc_consumed, noncj.op_count, noncj.exact_ops FROM noncj WHERE noncj.op_count > 0
        ),
        tot AS (SELECT SUM(combined.rc_consumed) AS gt FROM combined)
        SELECT combined.label, combined.rc_consumed, combined.op_count,
               ROUND(combined.rc_consumed * 100.0 / NULLIF(t.gt, 0), 2),
               haf_stats_app.rc_source_label(combined.exact_ops, combined.op_count),
               combined.exact_ops,
               haf_stats_app.exact_rc_op_cap(),
               -- The same count noncj_ex decides on, so rc_over_cap says why that bucket is estimated.
               (SELECT c.n FROM all_signed_count c) > haf_stats_app.exact_rc_op_cap()
        FROM combined, tot t
        ORDER BY combined.rc_consumed DESC, combined.label;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: account RC footprint timeline (per-event drill-down, issue #10)
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{account}/rc-footprint-timeline:
  get:
    tags:
      - Account
    summary: Account RC footprint timeline
    description: >-
      Per-event drill-down companion to rc-footprint: one row per RC-spending operation the
      account signed, most recent first, with the op type, resolved DApp name (+ raw custom_json
      id), block, timestamp and RC consumed. rc_consumed is the EXACT share of the RC its
      transaction cost where the node records it (HAF 1.28.8 and later, from hardfork 20), and
      otherwise the op-count ESTIMATE priced from the calibrated rc_op_stats_daily rates. Each
      event is priced the same way as in rc-footprint group_by=op_type, so summing rc_consumed
      over a window reconciles with that total when the account signed at most 15,000 ops in
      the window; above that rc-footprint is all estimate while each timeline event stays exact
      where recorded. Optional op_type_filter / app_filter narrow the
      timeline to the events of one op type or DApp (the same events as the matching rc-footprint
      bucket; each event is still priced per op, so an app_filter sum matches the op_type total,
      not the byte-aware group_by=app figure). rc_source says which pricing each event got.
      Pages via limit_count/offset_start,
      or O(1)-at-any-depth keyset paging by passing the previous page's last op_seq as before_seq.
    operationId: haf_stats_endpoints.get_account_rc_footprint_timeline
    parameters:
      - in: path
        name: account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: op_type_filter
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: >-
          Only return events of this operation type, e.g. vote_operation (matches the op_type
          label). Named *_filter because a query param cannot share a name with a response column.
      - in: query
        name: app_filter
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: >-
          Only return custom_json events whose resolved DApp name equals this value, e.g.
          Splinterlands (matches the rc-footprint group_by=app label).
      - in: query
        name: category_filter
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: >-
          Only return custom_json events whose registry category equals this value, e.g. Gaming
          (matches the rc-footprint group_by=category label; see /custom-json-app-registry for the
          category set, or Uncategorized for ids matching no registered app). Combinable with
          app_filter (intersection). Each event is priced per op as in group_by=op_type, so a
          category_filter sum reconciles with the group_by=op_type custom_json total, NOT the
          byte-aware group_by=category figure.
      - in: query
        name: limit_count
        required: false
        schema:
          type: integer
          default: 100
          minimum: 1
          maximum: 1000
        description: Maximum number of events to return (1-1000)
      - in: query
        name: offset_start
        required: false
        schema:
          type: integer
          default: 0
          minimum: 0
        description: Number of events to skip (offset pagination; O(depth), prefer before_seq)
      - in: query
        name: before_seq
        required: false
        schema:
          x-sql-datatype: BIGINT
          x-sql-default-value: "NULL"
          type: integer
        description: >-
          Keyset cursor: return only events with op_seq strictly less than this (i.e. older).
          Pass the previous page's last op_seq for O(1) deep paging that rides the seq index.
    responses:
      '200':
        description: RC-spending events, most recent first
        content:
          application/json:
            schema:
              x-sql-datatype: 'TABLE("timestamp" TIMESTAMP, block_num INT, op_type TEXT, app TEXT, custom_json_id TEXT, rc_consumed BIGINT, op_seq BIGINT, rc_source TEXT)'
              type: array
              items:
                type: object
                properties:
                  timestamp:
                    type: string
                    format: date-time
                    description: Block timestamp of the operation
                  block_num:
                    type: integer
                  op_type:
                    type: string
                    description: Operation type name
                  app:
                    type:
                      - string
                      - "null"
                    description: >-
                      Resolved DApp name for custom_json ops (custom_json_app_registry match,
                      falling back to the raw id); null for non-custom_json ops
                  custom_json_id:
                    type:
                      - string
                      - "null"
                    description: Raw custom_json id (null for non-custom_json ops)
                  rc_consumed:
                    type: integer
                    description: RC consumed by this operation - its exact share of the transaction's recorded cost where there is one, else the estimate
                  op_seq:
                    type: integer
                    description: >-
                      Per-account operation sequence number (dense, monotonic with time); pass the
                      last row's value as before_seq to fetch the next page
                  rc_source:
                    type: string
                    enum: [recorded, estimated]
                    description: >-
                      recorded when rc_consumed is the op's exact share of the RC its transaction
                      recorded, estimated when the node has no recorded cost for it
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_rc_footprint_timeline;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_rc_footprint_timeline(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "op_type_filter" TEXT = NULL,
    "app_filter" TEXT = NULL,
    "category_filter" TEXT = NULL,
    "limit_count" INT = 100,
    "offset_start" INT = 0,
    "before_seq" BIGINT = NULL
)
RETURNS TABLE("timestamp" TIMESTAMP, block_num INT, op_type TEXT, app TEXT, custom_json_id TEXT, rc_consumed BIGINT, op_seq BIGINT, rc_source TEXT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _account_id INT;
    _from_block INT;
    _to_block INT;
    _lo_seq BIGINT;
    _hi_seq BIGINT;
    _op_type_filter TEXT;
    _app_filter TEXT;
    _category_filter TEXT;
    _filter_op_type_id INT;
    _virtual_ids SMALLINT[];
    _matching_ids TEXT[];
BEGIN
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '30 days')::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    IF "limit_count" IS NULL OR "limit_count" < 1 OR "limit_count" > 1000 THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid limit_count: ' || COALESCE("limit_count"::TEXT, '(null)'),
            HINT = 'Must be between 1 and 1000';
    END IF;
    IF "offset_start" IS NULL OR "offset_start" < 0 THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid offset_start: ' || COALESCE("offset_start"::TEXT, '(null)'),
            HINT = 'Must be >= 0';
    END IF;

    -- Normalize the optional drill-down filters: tolerate Wax's JSON-encoded quoting (issue #22)
    -- and treat '' as absent. op_type_filter matches the op_type label (e.g. vote_operation);
    -- app_filter matches the RESOLVED DApp name (e.g. Splinterlands) and category_filter the
    -- RESOLVED registry category (e.g. Gaming), so the caller can drill into the exact
    -- get_account_rc_footprint group_by=op_type / group_by=app / group_by=category bucket it clicked.
    _op_type_filter := NULLIF(TRIM('"' FROM COALESCE("op_type_filter", '')), '');
    _app_filter := NULLIF(TRIM('"' FROM COALESCE("app_filter", '')), '');
    _category_filter := NULLIF(TRIM('"' FROM COALESCE("category_filter", '')), '');

    SELECT id INTO _account_id FROM hafd.accounts WHERE name = account;
    IF _account_id IS NULL THEN
        RETURN;   -- unknown account -> empty result
    END IF;

    -- Resolve op_type_filter to a non-virtual op_type_id; an unknown or virtual type matches no
    -- RC-spending event, so short-circuit to empty.
    IF _op_type_filter IS NOT NULL THEN
        SELECT ot.id INTO _filter_op_type_id
        FROM hafd.operation_types ot
        WHERE replace(ot.name, 'hive::protocol::', '') = _op_type_filter
          AND ot.is_virtual = FALSE;
        IF _filter_op_type_id IS NULL THEN
            RETURN;
        END IF;
    END IF;

    -- app_filter and category_filter both select only custom_json (op 18) events; pairing either
    -- with an op_type_filter for a different type is contradictory -> empty.
    IF (_app_filter IS NOT NULL OR _category_filter IS NOT NULL)
       AND _filter_op_type_id IS NOT NULL AND _filter_op_type_id <> 18 THEN
        RETURN;
    END IF;

    -- Window bounding (same as get_account_rc_footprint): date range -> block range -> this
    -- account's account_op_seq_no range (binary search), so a narrow window rides the indexed
    -- (account_id, seq) scan instead of the whole history.
    SELECT r.from_block, r.to_block INTO _from_block, _to_block
    FROM haf_stats_app.block_range_for_dates(_from, _to) r;
    IF _from_block IS NULL OR _to_block IS NULL THEN
        RETURN;
    END IF;

    SELECT lo_seq, hi_seq INTO _lo_seq, _hi_seq
    FROM haf_stats_app.account_op_seq_range(_account_id, _from_block, _to_block);
    IF _lo_seq IS NULL OR _hi_seq IS NULL OR _lo_seq > _hi_seq THEN
        RETURN;   -- no ops in the window
    END IF;

    -- One row per signed op (account_id = transacting_account_id, the signer). rc_consumed is
    -- the op's EXACT share of its transaction's recorded RC cost where there is one
    -- (haf_stats_app.exact_rc_for_ops, issue #44), else the read-time ESTIMATE
    -- rc_avg_cost(op_type, day) - the same per-op rule as the aggregate's group_by=op_type, so
    -- SUM(rc_consumed) over a window reconciles with that total, as long as the window holds at
    -- most exact_rc_op_cap() signed ops (a page never exceeds it; the aggregate above it is all
    -- estimate). Order by account_op_seq_no DESC alone: within an account it is dense and
    -- MONOTONIC with block_num (the invariant account_op_seq_range relies on), so it equals
    -- timestamp DESC while being served by the (account_id, seq) index - an Index Scan Backward
    -- that stops at OFFSET+LIMIT. Adding the computed block_num to the ORDER BY would instead force
    -- a full-window Sort. app is the resolved DApp name via haf_stats_app.resolve_dapp_name (the
    -- SAME resolver group_by=app uses, so the labels match by construction); custom_json_id keeps
    -- the raw id.
    -- NOTE on app_filter/category_filter reconciliation: each selects the SET of events in a
    -- group_by=app / group_by=category bucket, but each event is priced per op (exact or the
    -- op-count estimate), so SUM over such a drill-down reconciles with the group_by=op_type custom_json
    -- total, NOT the byte-aware group_by=app / group_by=category bucket figure (the aggregate
    -- prices custom_json two ways - flat for op_type, size-aware for app/category; the timeline
    -- follows the op_type model end to end).
    -- before_seq is the keyset cursor: ORDER BY account_op_seq_no DESC means "seq < before_seq" is
    -- served by the same (account_id, seq) index with no offset walk, so deep paging stays O(1).
    IF _app_filter IS NULL AND _category_filter IS NULL THEN
        -- No app filter: page first, then resolve the app for the returned page only (custom_json),
        -- avoiding a whole-history body scan. Virtual ops are dropped INSIDE the index-scan filter
        -- (op_type_id <> ALL(_virtual_ids)) rather than via an operation_types join above the LIMIT
        -- driver, so reward-heavy accounts (e.g. witnesses) don't pay a per-row join for rows the
        -- scan discards. (_virtual_ids is only needed here, so it is materialized inside this branch.)
        _virtual_ids := ARRAY(SELECT id FROM hafd.operation_types WHERE is_virtual);
        RETURN QUERY
        WITH page AS (
            SELECT ao.operation_id, ao.op_type_id, ao.block_num, ao.account_op_seq_no
            FROM hive.account_operations_view ao
            WHERE ao.account_id = _account_id
              AND ao.transacting_account_id = ao.account_id
              AND ao.account_op_seq_no BETWEEN _lo_seq AND _hi_seq
              AND ao.block_num BETWEEN _from_block AND _to_block
              AND ao.op_type_id <> ALL(_virtual_ids)
              AND (_filter_op_type_id IS NULL OR ao.op_type_id = _filter_op_type_id)
              AND ("before_seq" IS NULL OR ao.account_op_seq_no < "before_seq")
            ORDER BY ao.account_op_seq_no DESC
            LIMIT "limit_count" OFFSET "offset_start"
        ),
        ex AS MATERIALIZED (
            -- Exact RC for the returned page only (issue #44); an event without one is priced
            -- with the estimate, as before.
            SELECT e.operation_id, e.rc_exact
            FROM haf_stats_app.exact_rc_for_ops(
                ARRAY(SELECT p.operation_id FROM page p WHERE p.operation_id IS NOT NULL)) e
        )
        SELECT
            bv.created_at::TIMESTAMP,
            page.block_num,
            replace(ot.name, 'hive::protocol::', ''),
            CASE WHEN page.op_type_id = 18
                 THEN haf_stats_app.resolve_dapp_name(ov.body -> 'value' ->> 'id') END,
            CASE WHEN page.op_type_id = 18 THEN ov.body -> 'value' ->> 'id' END,
            COALESCE(ex.rc_exact,
                     haf_stats_app.rc_avg_cost(page.op_type_id, bv.created_at::DATE)::BIGINT),
            page.account_op_seq_no::BIGINT,
            haf_stats_app.rc_source_label((ex.rc_exact IS NOT NULL)::INT, 1)
        FROM page
        JOIN hafd.blocks bv ON bv.num = page.block_num
        JOIN hafd.operation_types ot ON ot.id = page.op_type_id
        LEFT JOIN hive.operations_view ov ON page.op_type_id = 18 AND ov.id = page.operation_id
        LEFT JOIN ex ON ex.operation_id = page.operation_id
        ORDER BY page.account_op_seq_no DESC;
    ELSE
        -- app_filter and/or category_filter set. The resolved DApp name/category is a body-derived
        -- value, so filtering on it via a raw op-18 body scan is O(op-18 count in the window) and
        -- can't early-terminate for a rare or absent app/category (a heavy game account -> tens of
        -- seconds). Instead resolve the candidate json_ids from the per-account custom_json rollup
        -- (account_custom_json_daily, the same table + signer attribution get_account_rc_footprint
        -- group_by=app trusts): the resolver runs once per DISTINCT id the account used (~dozens),
        -- not per event. If none resolve to the filter(s), the account never signed that DApp /
        -- category in the window -> return empty WITHOUT touching the raw op stream (the
        -- op-volume-independent fast path). Otherwise scan the raw op-18 rows filtered by the exact
        -- json_id set (a plain = ANY match, so the scan predicate needs no per-row resolver - the
        -- app label is resolved only on the returned page), which the (account_id, seq) index
        -- still serves backward and early-terminates at OFFSET+LIMIT / before_seq. Passing both
        -- filters intersects them (an app must also be in the category). NOTE: this ties the
        -- filters to the rollup's freshness the same way group_by=app already is; each event is
        -- priced per op, exact or the op-count estimate, as in the branch above.
        SELECT ARRAY(
            SELECT acj.json_id
            FROM haf_stats_backend.account_custom_json_daily acj
            WHERE acj.account_id = _account_id
              AND acj.day BETWEEN _from AND _to
            GROUP BY acj.json_id
            HAVING (_app_filter IS NULL OR haf_stats_app.resolve_dapp_name(acj.json_id) = _app_filter)
               AND (_category_filter IS NULL OR haf_stats_app.resolve_dapp_category(acj.json_id) = _category_filter)
        ) INTO _matching_ids;
        IF _matching_ids IS NULL OR cardinality(_matching_ids) = 0 THEN
            RETURN;
        END IF;

        RETURN QUERY
        WITH page AS (
            SELECT ao.block_num,
                   ao.account_op_seq_no,
                   ao.operation_id,
                   ov.body -> 'value' ->> 'id' AS json_id
            FROM hive.account_operations_view ao
            JOIN hive.operations_view ov ON ov.id = ao.operation_id
            WHERE ao.account_id = _account_id
              AND ao.transacting_account_id = ao.account_id
              AND ao.account_op_seq_no BETWEEN _lo_seq AND _hi_seq
              AND ao.block_num BETWEEN _from_block AND _to_block
              AND ao.op_type_id = 18
              AND (ov.body -> 'value' ->> 'id') = ANY(_matching_ids)
              AND ("before_seq" IS NULL OR ao.account_op_seq_no < "before_seq")
            ORDER BY ao.account_op_seq_no DESC
            LIMIT "limit_count" OFFSET "offset_start"
        ),
        ex AS MATERIALIZED (
            SELECT e.operation_id, e.rc_exact
            FROM haf_stats_app.exact_rc_for_ops(
                ARRAY(SELECT p.operation_id FROM page p WHERE p.operation_id IS NOT NULL)) e
        )
        SELECT
            bv.created_at::TIMESTAMP,
            page.block_num,
            'custom_json_operation'::TEXT,
            haf_stats_app.resolve_dapp_name(page.json_id),
            page.json_id,
            COALESCE(ex.rc_exact,
                     haf_stats_app.rc_avg_cost(18::SMALLINT, bv.created_at::DATE)::BIGINT),
            page.account_op_seq_no::BIGINT,
            haf_stats_app.rc_source_label((ex.rc_exact IS NOT NULL)::INT, 1)
        FROM page
        JOIN hafd.blocks bv ON bv.num = page.block_num
        LEFT JOIN ex ON ex.operation_id = page.operation_id
        ORDER BY page.account_op_seq_no DESC;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: account DApp footprint (per-account custom_json activity by category)
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{account}/dapp-footprint:
  get:
    tags:
      - Account
    summary: Account DApp footprint
    description: >-
      Per-account custom_json activity over a time range, grouped by DApp and the
      registry-defined category each app belongs to (custom_json_app_registry).
      Returns a single object with KPI fields (total ops, top category,
      top DApp), the per-category breakdown (for a donut chart), and the per-DApp
      breakdown tagged with its category (for a drill-down bar chart) - so the client
      renders the whole dashboard from one response. The primary metric is op COUNT
      (custom_json operations signed by the account). RC figures add up the per-account daily
      rollup: each daily row is the EXACT RC its operations' transactions recorded where the node has it (HAF 1.28.8 and later, from hardfork 20, for rows the processor built or the backfill filled from operations that all had one), and otherwise the calibrated ESTIMATE (rc_op_stats_daily rates sampled from rc_api). A
      multi-signer op counts its whole RC for each signer, as it counts once per signer in
      op_count. rc_source (recorded, estimated or mixed; null when there are no ops) and
      rc_exact_ops say which pricing the total and each category and DApp got. Defaults to the
      last 30 days.
    operationId: haf_stats_endpoints.get_account_dapp_footprint
    parameters:
      - in: path
        name: account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
    responses:
      '200':
        description: DApp footprint aggregate for the account
        content:
          application/json:
            schema:
              x-sql-datatype: jsonb
              type: object
              properties:
                account:
                  type: string
                from_date:
                  type: string
                to_date:
                  type: string
                total_ops:
                  type: integer
                total_rc_estimated:
                  type: integer
                  description: Total RC consumed, summed per day - exact where the rollup recorded it, else the calibrated estimate (op_count*base_rc + op_bytes*byte_rc from rc_op_stats_daily). The name predates exact RC and is kept for compatibility
                rc_source:
                  type:
                    - string
                    - "null"
                  enum: [recorded, estimated, mixed, null]
                  description: >-
                    How total_rc_estimated was priced: recorded when every op came from a daily row
                    holding the recorded RC, estimated when none did, mixed otherwise; null when
                    there are no ops
                rc_exact_ops:
                  type: integer
                  description: How many of total_ops were priced with the recorded RC
                top_category:
                  type:
                    - string
                    - "null"
                top_dapp:
                  type:
                    - string
                    - "null"
                categories:
                  type: array
                  description: Per-category totals (donut chart)
                  items:
                    type: object
                    properties:
                      category:
                        type: string
                      op_count:
                        type: integer
                      pct:
                        type:
                          - number
                          - "null"
                      rc_estimated:
                        type: integer
                      rc_pct:
                        type:
                          - number
                          - "null"
                      rc_source:
                        type: string
                        enum: [recorded, estimated, mixed]
                      rc_exact_ops:
                        type: integer
                dapps:
                  type: array
                  description: Per-app totals (registered app name), each tagged with its category (drill-down bars)
                  items:
                    type: object
                    properties:
                      category:
                        type: string
                      app_name:
                        type: string
                      op_count:
                        type: integer
                      pct:
                        type:
                          - number
                          - "null"
                      rc_estimated:
                        type: integer
                      rc_pct:
                        type:
                          - number
                          - "null"
                      rc_source:
                        type: string
                        enum: [recorded, estimated, mixed]
                      rc_exact_ops:
                        type: integer
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_dapp_footprint;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_dapp_footprint(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL
)
RETURNS jsonb
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _account_id INT;
    _result jsonb;
BEGIN
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '30 days')::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    SELECT id INTO _account_id FROM hafd.accounts WHERE name = "account";

    -- Unknown account (or no activity) returns a well-formed empty footprint, not an
    -- error - the client always gets the same object shape.
    IF _account_id IS NULL THEN
        RETURN jsonb_build_object(
            'account', "account", 'from_date', _from, 'to_date', _to,
            'total_ops', 0, 'total_rc_estimated', 0, 'rc_source', NULL, 'rc_exact_ops', 0,
            'top_category', NULL, 'top_dapp', NULL,
            'categories', '[]'::jsonb, 'dapps', '[]'::jsonb);
    END IF;

    -- Per-day estimated RC (issue #33): each activity day is priced at the custom_json
    -- (op_type 18) rate effective on/before that day, so historical activity keeps its era's
    -- rate as the rc_op_stats_daily series grows. Activity predating every sampled rate falls
    -- back to the earliest sample, and an empty rate table to the seeded constants, so the
    -- estimate is never zeroed. The rate is resolved ONCE per distinct activity day (not per
    -- (json_id, day) row) so cost stays bounded as the rate history grows.
    --
    -- AS MATERIALIZED is what makes that last sentence true rather than merely likely: a
    -- single-reference CTE is inlined, and the planner may then pull the lateral back above the
    -- day join and resolve per (json_id, day) row after all. It collapsed anyway on the data
    -- tested here, but only by the planner's choice (issue #49).
    WITH day_rate AS MATERIALIZED (
        SELECT
            d.day,
            dr.base_rc,
            dr.byte_rc
        FROM (
            SELECT DISTINCT acj.day
            FROM haf_stats_backend.account_custom_json_daily acj
            WHERE acj.account_id = _account_id
              AND acj.day BETWEEN _from AND _to
        ) d
        -- Was a hand-inlined copy of the as-of rule (with the same fallback constants); folded
        -- back onto the shared accessor so there is one definition to fix, and so this endpoint
        -- inherits its index-seekable form (issue #49). rc_rate applies the same COALESCE
        -- defaults the copy did, hence none here.
        CROSS JOIN LATERAL haf_stats_app.rc_rate(18::SMALLINT, d.day) dr
    ),
    -- Price each (json_id, day) row at its day's rate and roll up to json_id, then resolve
    -- each to its registered app + category via a longest-prefix starts_with match against
    -- custom_json_app_registry (an unmatched id falls to 'Uncategorized' with the raw id as
    -- the app name). Rolled up to apps (drill-down bars) and categories (donut); all in one object.
    per_json AS (
        SELECT
            acj.json_id,
            SUM(acj.op_count)::BIGINT AS op_count,
            SUM(COALESCE(acj.rc_exact, acj.op_count * dr.base_rc + acj.op_bytes * dr.byte_rc))::BIGINT AS rc_consumed,
            -- A day's row carries rc_exact only when all its ops had a recorded cost (#101).
            COALESCE(SUM(acj.op_count) FILTER (WHERE acj.rc_exact IS NOT NULL), 0)::BIGINT AS exact_ops
        FROM haf_stats_backend.account_custom_json_daily acj
        JOIN day_rate dr ON dr.day = acj.day
        WHERE acj.account_id = _account_id
          AND acj.day BETWEEN _from AND _to
        GROUP BY acj.json_id
    ),
    resolved AS (
        SELECT
            COALESCE(r.category, 'Uncategorized') AS category,
            COALESCE(r.app_name, pj.json_id)      AS app_name,
            pj.op_count,
            pj.rc_consumed,
            pj.exact_ops
        FROM per_json pj
        LEFT JOIN LATERAL (
            SELECT reg.category, reg.app_name
            FROM haf_stats_backend.custom_json_app_registry reg
            WHERE starts_with(pj.json_id, reg.app_id_pattern)
            -- Secondary sort by pattern makes equal-length-prefix ties deterministic.
            ORDER BY LENGTH(reg.app_id_pattern) DESC, reg.app_id_pattern
            LIMIT 1
        ) r ON TRUE
    ),
    per_app AS (
        SELECT category, app_name, SUM(op_count) AS op_count, SUM(rc_consumed) AS rc_consumed,
               SUM(exact_ops)::BIGINT AS exact_ops
        FROM resolved GROUP BY category, app_name
    ),
    per_cat AS (
        SELECT category, SUM(op_count) AS op_count, SUM(rc_consumed) AS rc_consumed,
               SUM(exact_ops)::BIGINT AS exact_ops
        FROM resolved GROUP BY category
    ),
    tot AS (SELECT COALESCE(SUM(op_count), 0) AS total, COALESCE(SUM(rc_consumed), 0) AS total_rc,
                   COALESCE(SUM(exact_ops), 0)::BIGINT AS total_exact FROM resolved)
    SELECT jsonb_build_object(
        'account', "account",
        'from_date', _from,
        'to_date', _to,
        'total_ops', (SELECT total FROM tot),
        -- total_rc: exact per day where the rollup recorded it (#44), else the calibrated estimate.
        'total_rc_estimated', (SELECT total_rc FROM tot),
        'rc_source', (SELECT CASE WHEN total = 0 THEN NULL
                                  ELSE haf_stats_app.rc_source_label(total_exact, total::BIGINT) END FROM tot),
        'rc_exact_ops', (SELECT total_exact FROM tot),
        'top_category', (SELECT category FROM per_cat ORDER BY op_count DESC, category LIMIT 1),
        'top_dapp', (SELECT app_name FROM per_app ORDER BY op_count DESC, app_name LIMIT 1),
        'categories', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'category', category,
                       'op_count', op_count,
                       'pct', ROUND(op_count * 100.0 / NULLIF((SELECT total FROM tot), 0), 2),
                       'rc_estimated', rc_consumed,
                       'rc_pct', ROUND(rc_consumed * 100.0 / NULLIF((SELECT total_rc FROM tot), 0), 2),
                       'rc_source', haf_stats_app.rc_source_label(exact_ops, op_count::BIGINT),
                       'rc_exact_ops', exact_ops)
                       ORDER BY op_count DESC, category)
            FROM per_cat), '[]'::jsonb),
        'dapps', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'category', category,
                       'app_name', app_name,
                       'op_count', op_count,
                       'pct', ROUND(op_count * 100.0 / NULLIF((SELECT total FROM tot), 0), 2),
                       'rc_estimated', rc_consumed,
                       'rc_pct', ROUND(rc_consumed * 100.0 / NULLIF((SELECT total_rc FROM tot), 0), 2),
                       'rc_source', haf_stats_app.rc_source_label(exact_ops, op_count::BIGINT),
                       'rc_exact_ops', exact_ops)
                       ORDER BY op_count DESC, app_name)
            FROM per_app), '[]'::jsonb)
    ) INTO _result;

    RETURN _result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: custom_json DApp registry (the id -> app/category/homepage lookup)
-- ---------------------------------------------------------------------------

/** openapi:paths
/custom-json-app-registry:
  get:
    tags:
      - Other
    summary: custom_json DApp registry
    description: >-
      The custom_json DApp registry: every registered app_id_pattern mapped to its DApp name,
      registry category, and homepage. This is the single source of truth that
      get_account_rc_footprint (group_by=app / group_by=category),
      get_account_rc_footprint_timeline (app_filter / category_filter) and
      get_account_dapp_footprint use to attribute custom_json ids - a longest-prefix starts_with
      match against app_id_pattern, so a raw id like sm_market_rent resolves to the longest
      registered prefix (sm_); an id matching no pattern falls back to the Uncategorized category
      with its raw id as the app name. Exposed so a client can render category/DApp labels,
      colours and homepage links without hard-coding the mapping. Static between deploys and only
      ~dozens of rows, so it is safe to cache. Ordered by category, then app name.
    operationId: haf_stats_endpoints.get_custom_json_app_registry
    responses:
      '200':
        description: Registered custom_json DApps, ordered by category then app name
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(app_id_pattern TEXT, app_name TEXT, category TEXT, homepage TEXT)"
              type: array
              items:
                type: object
                properties:
                  app_id_pattern:
                    type: string
                    description: custom_json id prefix; the longest one that prefixes an id wins
                  app_name:
                    type: string
                    description: Registered DApp name (the group_by=app label)
                  category:
                    type: string
                    description: Registry category (the group_by=category label)
                  homepage:
                    type:
                      - string
                      - "null"
                    description: DApp homepage URL, or null if unknown
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_custom_json_app_registry;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_custom_json_app_registry()
RETURNS TABLE(app_id_pattern TEXT, app_name TEXT, category TEXT, homepage TEXT)
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    -- Straight read of the seeded reference table (haf_stats_backend.custom_json_app_registry,
    -- created in db/process_rc.sql, populated by db/seed_data.sql). No parameters: the whole
    -- registry is small and static between deploys. Ordered so the client gets a stable,
    -- category-grouped list for rendering the #654 dashboard legend/colours.
    SELECT r.app_id_pattern, r.app_name, r.category, r.homepage
    FROM haf_stats_backend.custom_json_app_registry r
    ORDER BY r.category, r.app_name, r.app_id_pattern;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network-wide RC utilization by op type / DApp
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/rc-utilization:
  get:
    tags:
      - Network
    summary: Network RC utilization
    description: >-
      Time-series of total RC consumption across the network, broken down by operation type,
      aggregated by the chosen granularity. Per (day, op type), each daily row is the EXACT RC its operations' transactions recorded where the node has it (HAF 1.28.8 and later, from hardfork 20, for rows the processor built or the backfill filled from operations that all had one), and otherwise the calibrated ESTIMATE
      (op_count*base_rc + op_bytes*byte_rc from rc_op_stats_daily, the rate effective on/before
      each day). rc_source says which a period got.
    operationId: haf_stats_endpoints.get_network_rc_utilization
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: granularity
        required: false
        schema:
          type: string
          default: day
          enum: [day, week, month]
        description: Aggregation granularity
    responses:
      '200':
        description: RC utilization time-series
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, rc_total BIGINT, by_label JSONB, rc_source TEXT)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type: string
                    description: ISO-8601 date string for the aggregation bucket
                  rc_total:
                    type: integer
                    description: Total RC consumed in the period
                  by_label:
                    type: object
                    additionalProperties:
                      type: integer
                    description: RC per operation type or DApp
                  rc_source:
                    type: string
                    enum: [recorded, estimated, mixed]
                    description: >-
                      recorded when every (day, op type) row of the period holds the RC its
                      operations recorded, estimated when none does, mixed otherwise
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_rc_utilization;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_rc_utilization(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, rc_total BIGINT, by_label JSONB, rc_source TEXT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
BEGIN
    -- No date filter ⇒ full history, for consistency with get_network_vote_stats and
    -- get_daily_active_users (issue #35). Omitting from_date previously defaulted to the
    -- last 30 days, so the block_explorer_ui "No Filter / all history" option silently
    -- returned only a month; default to the chain genesis day (2016-03-24, block 1) instead.
    -- network_op_daily holds no rows before first data, so a genesis floor is exact. The rate
    -- resolution below is an as-of range join (not a per-row LATERAL), which keeps compute cheap
    -- (~0.3s month / ~0.5s day server-side on testapi). NOTE: a full-history read at DAY grain is
    -- a ~3.7k-row / ~5MB response (~3s end-to-end, payload-bound, not compute), so all-history
    -- callers should request granularity=month (~0.3s end-to-end); block_explorer_ui's
    -- "No Filter" option does so. The default grain stays 'day' for narrow explicit ranges.
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "day"); see issue #22.
    granularity := TRIM('"' FROM granularity);
    -- Validate granularity before it reaches DATE_TRUNC below: an unsupported
    -- unit there raises 'unit "..." not recognized' (an HTTP 500). Mirrors the
    -- guard in get_account_financial_summary.
    IF granularity IS NULL OR granularity NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE(granularity, '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;
    RETURN QUERY
    -- Price each network_op_daily row at its op type's rate effective on/before its day.
    -- RC = op_count*base_rc + op_bytes*byte_rc. Days before the earliest sample use that earliest
    -- sample; days with no rate row at all fall back to generic constants via COALESCE.
    --
    -- The as-of row is picked by the same two btree-seekable probes as haf_stats_app.rc_rate
    -- (see db/process_rc.sql), NOT by calling it: this endpoint's no-sample fallback is
    -- 120000000, not rc_rate's custom_json-calibrated 23428456, and that fallback is the live
    -- path for every op type the sampler has not reached yet.
    --
    -- Issue #35 replaced a per-(op_type, day) LATERAL with a window-function interval join
    -- because the LATERAL re-scanned the whole rate table per pair. That reasoning expired with
    -- idx_rc_op_stats_op_type_day: the interval join is O(rows x samples-per-op-type) - it grew
    -- with the rate history exactly like the defect issue #49 is about - while the probes are
    -- now O(log n) index scans and flat forever. The driving relation is already one row per
    -- (op_type, day), so there is nothing to hoist here; only the per-call cost changes.
    WITH priced AS (
        SELECT
            DATE_TRUNC(granularity, nod.day)                                AS period,
            COALESCE(replace(ot.name, 'hive::protocol::', ''),
                     'op_type_' || nod.op_type_id)                          AS label,
            -- The day's exact RC where the rollup recorded it (#44), else the estimate.
            COALESCE(nod.rc_exact,
                     (nod.op_count  * COALESCE(ri.base_rc, 120000000)
                      + nod.op_bytes * COALESCE(ri.byte_rc, 475000))::BIGINT) AS rc,
            (nod.rc_exact IS NOT NULL)                                      AS is_exact
        FROM haf_stats_backend.network_op_daily nod
        LEFT JOIN LATERAL (
            SELECT pick.base_rc, pick.byte_rc
            FROM (
                (
                    SELECT 0 AS pri, r.base_rc, r.byte_rc
                    FROM haf_stats_backend.rc_op_stats_daily r
                    WHERE r.op_type_id = nod.op_type_id AND r.day <= nod.day
                    ORDER BY r.day DESC
                    LIMIT 1
                )
                UNION ALL
                (
                    SELECT 1 AS pri, r.base_rc, r.byte_rc
                    FROM haf_stats_backend.rc_op_stats_daily r
                    WHERE r.op_type_id = nod.op_type_id
                    ORDER BY r.day ASC
                    LIMIT 1
                )
            ) pick
            ORDER BY pick.pri
            LIMIT 1
        ) ri ON TRUE
        LEFT JOIN hafd.operation_types ot ON ot.id = nod.op_type_id
        WHERE nod.day BETWEEN _from AND _to
    ),
    per_label AS (
        -- Qualify period/label: bare "period" collides with the RETURNS TABLE OUT variable.
        SELECT priced.period, priced.label, SUM(priced.rc)::BIGINT AS rc_label_total,
               COUNT(*) FILTER (WHERE priced.is_exact) AS exact_rows,
               COUNT(*)                                AS all_rows
        FROM priced
        GROUP BY priced.period, priced.label
    )
    SELECT
        TO_CHAR(per_label.period, 'YYYY-MM-DD')                     AS period,
        SUM(per_label.rc_label_total)::BIGINT                       AS rc_total,
        jsonb_object_agg(per_label.label, per_label.rc_label_total) AS by_label,
        -- Counted in daily ROWS, not ops: a rollup row is exact or estimated as a whole.
        haf_stats_app.rc_source_label(SUM(per_label.exact_rows)::BIGINT,
                                      SUM(per_label.all_rows)::BIGINT) AS rc_source
    FROM per_label
    GROUP BY per_label.period
    ORDER BY 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network-wide custom_json usage by id (issue #41)
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/custom-json-usage:
  get:
    tags:
      - Network
    summary: custom_json usage over time for one id
    description: >-
      Time-series of network-wide custom_json (op_type 18) usage for a single id (e.g. `follow`,
      `sm_claim_daily`): op_count, summed payload bytes, and the RC cost per period. Per day,
      each daily row is the EXACT RC its operations' transactions recorded where the node has it (HAF 1.28.8 and later, from hardfork 20, for rows the processor built or the backfill filled from operations that all had one), and otherwise the calibrated ESTIMATE (op_count*base_rc + op_bytes*byte_rc from the op-18
      rc_op_stats_daily rate effective on/before each day); the column keeps its old name
      rc_estimate. Reads the network_custom_json_daily rollup.
    operationId: haf_stats_endpoints.get_network_custom_json_usage
    parameters:
      - in: query
        name: json_id
        # The description below has always said "required (400 if omitted)", and live
        # confirms it: omitting it returns 400 22023 "json_id is required". Declared
        # optional, Swagger UI's "Try it" and any generated client emit a call that
        # cannot succeed.
        required: true
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: The custom_json id to report (e.g. follow); required (400 if omitted)
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: granularity
        required: false
        schema:
          type: string
          default: day
          enum: [day, week, month]
        description: Aggregation granularity
    responses:
      '200':
        description: custom_json usage time-series for the id
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, op_count BIGINT, op_bytes BIGINT, rc_estimate NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type: string
                    description: ISO-8601 date string for the aggregation bucket
                  op_count:
                    type: integer
                    description: Number of custom_json ops with this id in the period
                  op_bytes:
                    type: integer
                    description: Summed payload bytes of those ops
                  rc_estimate:
                    type: number
                    description: RC consumed by those ops, exact per day where recorded and estimated otherwise (may exceed 2^63)
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_custom_json_usage;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_custom_json_usage(
    "json_id" TEXT = NULL,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, op_count BIGINT, op_bytes BIGINT, rc_estimate NUMERIC)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _json_id TEXT;
BEGIN
    -- Tolerate Wax's JSON-encoded string params (e.g. "follow"); see issue #22. json_id is
    -- required, but declared with a NULL default so an omitted param yields a clean 400 here
    -- rather than a PostgREST "function not found" 404.
    _json_id := TRIM('"' FROM COALESCE("json_id", ''));
    IF _json_id = '' THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'json_id is required',
            HINT = 'Provide a custom_json id (e.g. follow)';
    END IF;

    -- No date filter ⇒ full history (chain genesis 2016-03-24), consistent with the sibling
    -- network endpoints (issue #35).
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "day"); see issue #22.
    granularity := TRIM('"' FROM granularity);
    IF granularity IS NULL OR granularity NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE(granularity, '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;

    RETURN QUERY
    -- Price each activity day at the op-18 rate effective on/before it (rc_rate always returns
    -- one row via seeded defaults), then roll up to the requested granularity. byte_rc is NUMERIC,
    -- so the RC sum is already NUMERIC and is returned as-is (not cast to BIGINT, which could
    -- overflow on a wide window). GROUP BY the DATE_TRUNC expression (not the `period` alias, which
    -- collides with the RETURNS TABLE OUT column).
    SELECT
        TO_CHAR(DATE_TRUNC(granularity, ncj.day), 'YYYY-MM-DD')             AS period,
        SUM(ncj.op_count)::BIGINT                                           AS op_count,
        SUM(ncj.op_bytes)::BIGINT                                           AS op_bytes,
        SUM(COALESCE(ncj.rc_exact, ncj.op_count * dr.base_rc + ncj.op_bytes * dr.byte_rc))::NUMERIC AS rc_estimate
    FROM haf_stats_backend.network_custom_json_daily ncj
    CROSS JOIN LATERAL haf_stats_app.rc_rate(18::SMALLINT, ncj.day) dr
    WHERE ncj.json_id = _json_id
      AND ncj.day BETWEEN _from AND _to
    GROUP BY DATE_TRUNC(granularity, ncj.day)
    ORDER BY 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: most-used network custom_json ids / DApps (issue #41)
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/top-custom-json:
  get:
    tags:
      - Network
    summary: Most-used custom_json ids / DApps
    description: >-
      Leaderboard of the most-used network custom_json actions over [from_date, to_date], ranked
      by op_count (or op_bytes / rc_estimate), returning at most limit_count ranked rows. group_by=id
      ranks raw custom_json ids (each with its resolved DApp name + category); group_by=app
      collapses an app's ids to the registered DApp; group_by=category rolls up one level further
      (json_id is null for app, json_id and app_name are null for category). group_by=app and
      group_by=category PARTITION the window, so they append one extra Others row aggregating
      every group beyond limit_count, sorted last and emitted only when something is actually
      absorbed - the rows therefore always sum to the window total regardless of limit_count.
      Identify that row by its CATEGORY, which is null for group_by=app and Others for
      group_by=category: a real DApp id can itself resolve to the name Others, so app_name is
      not a reliable marker. group_by=id is a plain top-N and has no Others row. RC (the column
      rc_estimate, named before exact RC): per day, each daily row is the EXACT RC its operations' transactions recorded where the node has it (HAF 1.28.8 and later, from hardfork 20, for rows the processor built or the backfill filled from operations that all had one), and otherwise the calibrated ESTIMATE (op_count*base_rc +
      op_bytes*byte_rc at the op-18 rate effective on/before each day).
      Reads the network_custom_json_daily rollup; app/category resolved via custom_json_app_registry.
    operationId: haf_stats_endpoints.get_network_top_custom_json
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: limit_count
        required: false
        schema:
          type: integer
          default: 25
          minimum: 1
          maximum: 100
        description: Number of ranked rows to return (1-100); group_by=app/category may append one extra Others row
      - in: query
        name: group_by
        required: false
        schema:
          type: string
          default: id
          enum: [id, app, category]
        description: Group by raw custom_json id, resolved DApp app, or category
      - in: query
        name: order_by
        required: false
        schema:
          type: string
          default: op_count
          enum: [op_count, op_bytes, rc_estimate]
        description: Column to rank by, descending
    responses:
      '200':
        description: custom_json usage leaderboard
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(json_id TEXT, app_name TEXT, category TEXT, op_count BIGINT, op_bytes BIGINT, rc_estimate NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  json_id:
                    type:
                      - string
                      - "null"
                    description: Raw custom_json id (null when group_by=app or category)
                  app_name:
                    type:
                      - string
                      - "null"
                    description: Resolved DApp name; Others on the aggregated tail row, which is identified by category rather than by this name (null when group_by=category)
                  category:
                    type:
                      - string
                      - "null"
                    description: DApp category (Uncategorized if unregistered). Marks the aggregated tail row - null when group_by=app, since that band spans categories, and Others when group_by=category
                  op_count:
                    type: integer
                    description: Number of custom_json ops in the window
                  op_bytes:
                    type: integer
                    description: Summed payload bytes of those ops
                  rc_estimate:
                    type: number
                    description: RC consumed by those ops, exact per day where recorded and estimated otherwise (may exceed 2^63)
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_top_custom_json;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_top_custom_json(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "limit_count" INT = 25,
    "group_by" TEXT = 'id',
    "order_by" TEXT = 'op_count'
)
RETURNS TABLE(json_id TEXT, app_name TEXT, category TEXT, op_count BIGINT, op_bytes BIGINT, rc_estimate NUMERIC)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
BEGIN
    -- No date filter ⇒ full history (chain genesis 2016-03-24), consistent with the sibling
    -- network endpoints (issue #35).
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    IF "limit_count" IS NULL OR "limit_count" < 1 OR "limit_count" > 100 THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid limit_count: ' || COALESCE("limit_count"::TEXT, '(null)'),
            HINT = 'Must be between 1 and 100';
    END IF;

    -- Tolerate Wax's JSON-encoded string params (e.g. "id"); see issue #22.
    group_by := TRIM('"' FROM group_by);
    IF group_by IS NULL OR group_by NOT IN ('id', 'app', 'category') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid group_by: ' || COALESCE(group_by, '(null)'),
            HINT = 'Must be one of: id, app, category';
    END IF;

    order_by := TRIM('"' FROM order_by);
    IF order_by IS NULL OR order_by NOT IN ('op_count', 'op_bytes', 'rc_estimate') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid order_by: ' || COALESCE(order_by, '(null)'),
            HINT = 'Must be one of: op_count, op_bytes, rc_estimate';
    END IF;

    -- rc_estimate is returned as NUMERIC (not cast to BIGINT): a no-date, network-wide sum can
    -- approach the BIGINT ceiling (~9.2e18) as custom_json volume grows, and this is a coarse
    -- estimate, so precision beyond that is irrelevant. per_id prices each (json_id, day) at the
    -- op-18 rate effective on/before it (byte_rc is NUMERIC, so the sum is already NUMERIC).
    --
    -- Both branches resolve that rate ONCE PER DISTINCT DAY in day_rate rather than once per
    -- (json_id, day) row. A wide window holds ~120 ids/day, so the old per-row LATERAL called
    -- rc_rate ~300k times over full history and WAS this endpoint's entire latency - and it grew
    -- with the length of the rate history, not with the data, so it got slower every day the
    -- sampler ran (issue #49). Same day_rate shape get_account_dapp_footprint already uses.
    --
    -- AS MATERIALIZED is load-bearing: inlined, the planner is free to pull the lateral back
    -- above the day join and silently restore per-row evaluation. The INNER JOIN loses nothing -
    -- rc_rate always yields exactly one row, and day_rate is built from the same table under the
    -- same day predicate in the same snapshot, so it is 1:1 with the days actually scanned.
    --
    -- Do not "simplify" the SUM into SUM(op_count) * base_rc + SUM(op_bytes) * byte_rc: it is
    -- per-DAY pricing, and PostgREST prints NUMERIC verbatim, so re-associating the arithmetic
    -- would change the printed scale even where the value is unchanged.
    IF group_by = 'id' THEN
        -- Fast path: rank the raw ids, then resolve the DApp name/category for ONLY the returned
        -- page. resolve_dapp probes the registry, so resolving every distinct id in a wide window
        -- before the LIMIT would be wasted work. json_id is unique, so it is a complete tiebreak
        -- on its own.
        RETURN QUERY
        WITH day_rate AS MATERIALIZED (
            SELECT d.day, dr.base_rc, dr.byte_rc
            FROM (
                SELECT DISTINCT ncj.day
                FROM haf_stats_backend.network_custom_json_daily ncj
                WHERE ncj.day BETWEEN _from AND _to
            ) d
            CROSS JOIN LATERAL haf_stats_app.rc_rate(18::SMALLINT, d.day) dr
        ),
        per_id AS (
            SELECT
                ncj.json_id,
                SUM(ncj.op_count)::BIGINT                                  AS op_count,
                SUM(ncj.op_bytes)::BIGINT                                  AS op_bytes,
                SUM(COALESCE(ncj.rc_exact, ncj.op_count * dr.base_rc + ncj.op_bytes * dr.byte_rc)) AS rc_estimate
            FROM haf_stats_backend.network_custom_json_daily ncj
            JOIN day_rate dr ON dr.day = ncj.day
            WHERE ncj.day BETWEEN _from AND _to
            GROUP BY ncj.json_id
        ),
        top AS (
            SELECT p.json_id, p.op_count, p.op_bytes, p.rc_estimate
            FROM per_id p
            ORDER BY
                CASE WHEN order_by = 'op_bytes'    THEN p.op_bytes
                     WHEN order_by = 'rc_estimate' THEN p.rc_estimate
                     ELSE p.op_count END DESC,
                p.json_id
            LIMIT "limit_count"
        )
        SELECT
            t.json_id,
            res.app_name,
            res.category,
            t.op_count,
            t.op_bytes,
            t.rc_estimate
        FROM top t
        CROSS JOIN LATERAL haf_stats_app.resolve_dapp(t.json_id) res
        ORDER BY
            CASE WHEN order_by = 'op_bytes'    THEN t.op_bytes
                 WHEN order_by = 'rc_estimate' THEN t.rc_estimate
                 ELSE t.op_count END DESC,
            t.json_id;
    ELSE
        -- group_by = 'app' or 'category': the DApp / category IS the group key, so resolution must
        -- happen before grouping (resolved once per distinct id, since per_id already collapsed the
        -- days). json_id is null for both dimensions; app_name is null for category. resolve_dapp
        -- returns both labels from ONE registry probe, where the two scalar resolvers ran the same
        -- longest-prefix match twice per id - and neither of them can be inlined (issue #49).
        RETURN QUERY
        WITH day_rate AS MATERIALIZED (
            -- See the group_by = 'id' branch above: one rc_rate call per DISTINCT activity day.
            SELECT d.day, dr.base_rc, dr.byte_rc
            FROM (
                SELECT DISTINCT ncj.day
                FROM haf_stats_backend.network_custom_json_daily ncj
                WHERE ncj.day BETWEEN _from AND _to
            ) d
            CROSS JOIN LATERAL haf_stats_app.rc_rate(18::SMALLINT, d.day) dr
        ),
        per_id AS (
            SELECT
                ncj.json_id,
                SUM(ncj.op_count)::BIGINT                                  AS op_count,
                SUM(ncj.op_bytes)::BIGINT                                  AS op_bytes,
                SUM(COALESCE(ncj.rc_exact, ncj.op_count * dr.base_rc + ncj.op_bytes * dr.byte_rc)) AS rc_estimate
            FROM haf_stats_backend.network_custom_json_daily ncj
            JOIN day_rate dr ON dr.day = ncj.day
            WHERE ncj.day BETWEEN _from AND _to
            GROUP BY ncj.json_id
        ),
        keyed AS (
            SELECT
                res.app_name,
                res.category,
                pid.op_count,
                pid.op_bytes,
                pid.rc_estimate
            FROM per_id pid
            CROSS JOIN LATERAL haf_stats_app.resolve_dapp(pid.json_id) res
        ),
        grouped AS (
            SELECT
                CASE WHEN group_by = 'app' THEN k.app_name END AS app_name,
                k.category                                     AS category,
                SUM(k.op_count)::BIGINT                         AS op_count,
                SUM(k.op_bytes)::BIGINT                         AS op_bytes,
                SUM(k.rc_estimate)                             AS rc_estimate
            FROM keyed k
            GROUP BY
                CASE WHEN group_by = 'app' THEN k.app_name END,
                k.category
        ),
        -- These two dimensions PARTITION the window - every op is counted in exactly one group -
        -- so a bare LIMIT would have turned a complete breakdown into a truncated leaderboard,
        -- and any share-of-total a client computed from the response would silently be wrong.
        -- Instead the tail is aggregated into one Others band, as get_account_interactions does
        -- for its per-type partners, so the rows still sum to the window total at any
        -- limit_count. Until issue #49 this branch ignored limit_count altogether and returned
        -- every group (21,939 rows / 3.2 MB over full history).
        ranked AS (
            SELECT
                g.app_name, g.category, g.op_count, g.op_bytes, g.rc_estimate,
                ROW_NUMBER() OVER (
                    ORDER BY
                        CASE WHEN order_by = 'op_bytes'    THEN g.op_bytes
                             WHEN order_by = 'rc_estimate' THEN g.rc_estimate
                             ELSE g.op_count END DESC,
                        g.category, g.app_name
                ) AS rn
            FROM grouped g
        ),
        named AS (
            SELECT 0 AS is_others, r.app_name, r.category, r.op_count, r.op_bytes, r.rc_estimate
            FROM ranked r
            WHERE r.rn <= "limit_count"
        ),
        -- HAVING on an ungrouped aggregate: exactly one row when the tail is non-empty, none
        -- when every group already fit, so a window with few apps returns no zero-filled band.
        -- The band spans categories, so category is null for group_by=app - it is the one row
        -- whose label is not a registry value.
        others AS (
            SELECT
                1 AS is_others,
                CASE WHEN group_by = 'app' THEN 'Others' END::TEXT AS app_name,
                CASE WHEN group_by = 'app' THEN NULL ELSE 'Others' END::TEXT AS category,
                SUM(r.op_count)::BIGINT  AS op_count,
                SUM(r.op_bytes)::BIGINT  AS op_bytes,
                SUM(r.rc_estimate)       AS rc_estimate
            FROM ranked r
            WHERE r.rn > "limit_count"
            HAVING COUNT(*) > 0
        ),
        -- (category, app_name) is grouped's group key, so it is unique across the named rows and
        -- the ordering is total - the page is deterministic. is_others leads it because the tail
        -- aggregate routinely outweighs the largest single group and would otherwise sort into
        -- the middle of the leaderboard.
        banded AS (
            SELECT * FROM named
            UNION ALL
            SELECT * FROM others
        )
        SELECT
            NULL::TEXT,
            b.app_name,
            b.category,
            b.op_count,
            b.op_bytes,
            b.rc_estimate
        FROM banded b
        ORDER BY
            b.is_others,
            CASE WHEN order_by = 'op_bytes'    THEN b.op_bytes
                 WHEN order_by = 'rc_estimate' THEN b.rc_estimate
                 ELSE b.op_count END DESC,
            b.category, b.app_name;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network HP stake distribution (bucketed)
-- Reads cross-schema from btracker_app (Balance Tracker).
-- Requires: GRANT SELECT ON btracker_app.current_account_balances TO haf_stats_user
-- VESTS/HP ratio is read dynamically from hafd.blocks at query time.
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/hp-distribution:
  get:
    tags:
      - Network
    summary: HP stake distribution
    description: >-
      Bucketed distribution of Hive Power (HP) stake across all accounts, with
      both the account counts and the total HP held per bucket (enabling a
      "% of accounts" vs "% of HP held" view of wealth concentration).
      Reads current VESTS balances from balance_tracker; its schema is
      deployment-dependent so the function auto-detects the first readable
      relation (btracker_app / btracker_backend / hafbe_bal) - grant SELECT to
      haf_stats_user on whichever applies.
      total_hp is the sum of actual VESTS-converted balances in the bucket - for
      the unbounded 1M+ bucket this is the real total, not a midpoint estimate.
      Returns an empty array (HTTP 200, not an error) when the data source is
      unavailable - no readable balance relation, or hafd.blocks has no
      rows yet (fresh node, no VESTS/HP ratio). Consumers should treat an empty
      array as "distribution not available yet", not "zero accounts". (#20.5)
    operationId: haf_stats_endpoints.get_network_hp_distribution
    responses:
      '200':
        description: HP distribution buckets ordered from smallest to largest
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(bucket TEXT, account_count BIGINT, pct_accounts NUMERIC, total_hp NUMERIC, pct_hp NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  bucket:
                    type: string
                    example: "1-10 HP"
                  account_count:
                    type: integer
                  pct_accounts:
                    type:
                      - number
                      - "null"
                    description: Percentage of all accounts in this bucket
                  total_hp:
                    type:
                      - number
                      - "null"
                    description: Total HP held by all accounts in this bucket (sum of actual VESTS-converted balances)
                  pct_hp:
                    type:
                      - number
                      - "null"
                    description: This bucket's total_hp as a percentage of the sum of all buckets' total_hp
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_hp_distribution;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_hp_distribution()
RETURNS TABLE(bucket TEXT, account_count BIGINT, pct_accounts NUMERIC, total_hp NUMERIC, pct_hp NUMERIC)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    -- Served from the precomputed haf_stats_backend.hp_distribution_snapshot (refreshed by
    -- haf_stats_app.refresh_hp_distribution_snapshot, scheduled via pg_cron; see
    -- db/process_hp_distribution.sql). The expensive whole-table scan of ~1.8M current VESTS
    -- balances lives in that refresh, off the request path, so this read is O(8 rows) instead
    -- of aggregating every account's balance into buckets on every request.
    -- #20.5: the snapshot is empty until first computed (no readable balance relation, or a
    -- fresh node with no VESTS/HP ratio), so this returns [] (HTTP 200) - the documented
    -- "distribution not available yet" contract, unchanged from the previous inline version.
    -- The refresh's bucket order is preserved via sort_order.
    RETURN QUERY
    SELECT s.bucket, s.account_count, s.pct_accounts, s.total_hp, s.pct_hp
    FROM haf_stats_backend.hp_distribution_snapshot s
    ORDER BY s.sort_order;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: governance influence concentration (stake concentration snapshot, #11)
-- Reads the precomputed haf_stats_backend.governance_concentration_snapshot,
-- refreshed by haf_stats_app.refresh_governance_concentration() (scheduled via
-- pg_cron; see db/process_governance_concentration.sql). The expensive balance
-- scan+sort lives in the refresh, so this read is O(1).
-- ---------------------------------------------------------------------------

/** openapi:paths
/governance/influence-concentration:
  get:
    tags:
      - Governance
    summary: Stake influence concentration
    description: >-
      Network-wide stake-concentration snapshot: Gini coefficient, the share of
      total Hive Power (HP) held by the richest 1% and 10% of accounts, the total
      number of HP holders, and the median and mean HP per holder. Computed from
      current VESTS balances (converted to HP via the live VESTS/HP ratio) and
      served from a precomputed snapshot, so the read is O(1).
      Returns an empty array (HTTP 200, not an error) when the snapshot has not
      been computed yet - no readable balance relation, or hafd.blocks has no rows
      yet (fresh node). Consumers should treat an empty array as "not available
      yet", not "zero accounts".
    operationId: haf_stats_endpoints.get_governance_influence_concentration
    responses:
      '200':
        description: One row of network stake-concentration metrics
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(gini NUMERIC, top_1pct_hp_share NUMERIC, top_10pct_hp_share NUMERIC, total_hp_holders BIGINT, median_hp NUMERIC, mean_hp NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  gini:
                    type:
                      - number
                      - "null"
                    description: Gini coefficient of HP across all holders (0 = perfect equality, 1 = one account holds everything)
                    example: 0.94
                  top_1pct_hp_share:
                    type:
                      - number
                      - "null"
                    description: Percentage of total HP held by the richest 1% of accounts
                    example: 71.2
                  top_10pct_hp_share:
                    type:
                      - number
                      - "null"
                    description: Percentage of total HP held by the richest 10% of accounts
                    example: 93.4
                  total_hp_holders:
                    type: integer
                    description: Number of accounts holding a positive VESTS balance
                    example: 164780
                  median_hp:
                    type:
                      - number
                      - "null"
                    description: Median HP per holder
                    example: 12.4
                  mean_hp:
                    type:
                      - number
                      - "null"
                    description: Mean HP per holder
                    example: 284.1
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_governance_influence_concentration;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_governance_influence_concentration()
RETURNS TABLE(gini NUMERIC, top_1pct_hp_share NUMERIC, top_10pct_hp_share NUMERIC, total_hp_holders BIGINT, median_hp NUMERIC, mean_hp NUMERIC)
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        s.gini,
        s.top_1pct_hp_share,
        s.top_10pct_hp_share,
        s.total_hp_holders,
        s.median_hp,
        s.mean_hp
    FROM haf_stats_backend.governance_concentration_snapshot s
    LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Feature: new account cohort retention
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/account-funnel:
  get:
    tags:
      - Network
    summary: New account cohort retention
    description: >-
      Day-7, day-30, and day-90 rolling retention for all newly created
      accounts, including accounts created through legacy pow/pow2 mining. An
      account is retained at day N when it signs at least one non-virtual
      operation on or after N days after creation, observed within a 180-day
      horizon [N, 180) days; the milestones nest and decline (day-90 subset of
      day-30 subset of day-7). Results are grouped by creation month. Disclosure
      is per-milestone: eligible_at_Nd counts only cohort members that have
      reached day N (created + N <= now), active_at_Nd counts the eligible
      members that were active, and pct_Nd = active_at_Nd / eligible_at_Nd
      (null when eligible_at_Nd is 0).
    operationId: haf_stats_endpoints.get_network_account_funnel
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start cohort month (YYYY-MM-DD), inclusive, defaults to 1 year ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end cohort month (YYYY-MM-DD), inclusive, defaults to today
    responses:
      '200':
        description: Cohort retention rows ordered by month
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(cohort_month TEXT, new_accounts INT, eligible_at_7d INT, active_at_7d INT, pct_7d NUMERIC, eligible_at_30d INT, active_at_30d INT, pct_30d NUMERIC, eligible_at_90d INT, active_at_90d INT, pct_90d NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  cohort_month:
                    type: string
                    example: "2026-01"
                  new_accounts:
                    type: integer
                  eligible_at_7d:
                    type:
                      - integer
                      - "null"
                  active_at_7d:
                    type:
                      - integer
                      - "null"
                  pct_7d:
                    type:
                      - number
                      - "null"
                  eligible_at_30d:
                    type:
                      - integer
                      - "null"
                  active_at_30d:
                    type:
                      - integer
                      - "null"
                  pct_30d:
                    type:
                      - number
                      - "null"
                  eligible_at_90d:
                    type:
                      - integer
                      - "null"
                  active_at_90d:
                    type:
                      - integer
                      - "null"
                  pct_90d:
                    type:
                      - number
                      - "null"
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_account_funnel;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_account_funnel(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL
)
RETURNS TABLE(cohort_month TEXT, new_accounts INT, eligible_at_7d INT, active_at_7d INT, pct_7d NUMERIC, eligible_at_30d INT, active_at_30d INT, pct_30d NUMERIC, eligible_at_90d INT, active_at_90d INT, pct_90d NUMERIC)
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        TO_CHAR(acr.cohort_month, 'YYYY-MM')                                    AS cohort_month,
        acr.new_accounts,
        acr.eligible_at_7d,
        acr.active_at_7d,
        ROUND(acr.active_at_7d  * 100.0 / NULLIF(acr.eligible_at_7d, 0), 1)     AS pct_7d,
        acr.eligible_at_30d,
        acr.active_at_30d,
        ROUND(acr.active_at_30d * 100.0 / NULLIF(acr.eligible_at_30d, 0), 1)    AS pct_30d,
        acr.eligible_at_90d,
        acr.active_at_90d,
        ROUND(acr.active_at_90d * 100.0 / NULLIF(acr.eligible_at_90d, 0), 1)    AS pct_90d
    FROM haf_stats_backend.account_cohort_retention acr
    WHERE acr.cohort_month
        BETWEEN DATE_TRUNC('month', haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '1 year')::DATE))::DATE
        AND DATE_TRUNC('month', haf_stats_app.to_filter_date("to_date", NOW()::DATE))::DATE
    ORDER BY acr.cohort_month;
$$;

-- ---------------------------------------------------------------------------
-- Feature: content-creator cohort retention
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/author-retention:
  get:
    tags:
      - Network
    summary: Content creator cohort retention
    description: >-
      Month cohorts of accounts whose first-ever root post falls in the cohort
      month, with the share that created content again in the 30-, 90-, and
      180-day windows after that first post day. "Created content again" means a
      new post or comment create under chain comment_operation semantics; edits
      are excluded. Windows are contiguous and non-overlapping: (0,30],
      (30,90], and (90,180] days. Results are grouped by first-post month.
      Disclosure is per-milestone: eligible_at_Nd counts only cohort members that
      have reached day N (first_post + N <= now), active_at_Nd counts the eligible
      members that were active in that window, and pct_Nd = active_at_Nd /
      eligible_at_Nd (null when eligible_at_Nd is 0), so a recent cohort populates
      on a partial basis as its members mature. The usual retention decay ordering
      is empirical, not a mathematical guarantee.
    operationId: haf_stats_endpoints.get_network_author_retention
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start cohort month (YYYY-MM-DD), inclusive, defaults to 1 year ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end cohort month (YYYY-MM-DD), inclusive, defaults to today
    responses:
      '200':
        description: Author cohort retention rows ordered by month
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(cohort_month TEXT, first_post_accounts INT, eligible_at_30d INT, active_at_30d INT, pct_30d NUMERIC, eligible_at_90d INT, active_at_90d INT, pct_90d NUMERIC, eligible_at_180d INT, active_at_180d INT, pct_180d NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  cohort_month:
                    type: string
                    example: "2026-01"
                  first_post_accounts:
                    type: integer
                  eligible_at_30d:
                    type:
                      - integer
                      - "null"
                  active_at_30d:
                    type:
                      - integer
                      - "null"
                  pct_30d:
                    type:
                      - number
                      - "null"
                  eligible_at_90d:
                    type:
                      - integer
                      - "null"
                  active_at_90d:
                    type:
                      - integer
                      - "null"
                  pct_90d:
                    type:
                      - number
                      - "null"
                  eligible_at_180d:
                    type:
                      - integer
                      - "null"
                  active_at_180d:
                    type:
                      - integer
                      - "null"
                  pct_180d:
                    type:
                      - number
                      - "null"
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_author_retention;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_author_retention(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL
)
RETURNS TABLE(cohort_month TEXT, first_post_accounts INT, eligible_at_30d INT, active_at_30d INT, pct_30d NUMERIC, eligible_at_90d INT, active_at_90d INT, pct_90d NUMERIC, eligible_at_180d INT, active_at_180d INT, pct_180d NUMERIC)
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        TO_CHAR(acr.cohort_month, 'YYYY-MM')                                    AS cohort_month,
        acr.first_post_accounts,
        acr.eligible_at_30d,
        acr.active_at_30d,
        ROUND(acr.active_at_30d  * 100.0 / NULLIF(acr.eligible_at_30d, 0), 1)    AS pct_30d,
        acr.eligible_at_90d,
        acr.active_at_90d,
        ROUND(acr.active_at_90d  * 100.0 / NULLIF(acr.eligible_at_90d, 0), 1)    AS pct_90d,
        acr.eligible_at_180d,
        acr.active_at_180d,
        ROUND(acr.active_at_180d * 100.0 / NULLIF(acr.eligible_at_180d, 0), 1)   AS pct_180d
    FROM haf_stats_backend.author_cohort_retention acr
    WHERE acr.cohort_month
        BETWEEN DATE_TRUNC('month', haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '1 year')::DATE))::DATE
        AND DATE_TRUNC('month', haf_stats_app.to_filter_date("to_date", NOW()::DATE))::DATE
    ORDER BY acr.cohort_month;
$$;

-- ---------------------------------------------------------------------------
-- Feature: daily active users
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/daily-active-users:
  get:
    tags:
      - Network
    summary: Daily active users
    description: >-
      Unique accounts that authored (signed) at least one operation per period,
      and the total volume of those operations, at the chosen granularity. An
      account is "active" when hive.get_required_authorities reports it as a
      required signer of an operation, so every authored op type counts and
      virtual (block/witness) activity is excluded. active_accounts is exact at
      the requested granularity (an account active on several days counts once
      per period); operations is a distinct-operation count (a multisig op counts
      once). operation_types selects which categories count: a comma-separated
      subset of post, comment, vote, transfer, custom_json, or "all" (the
      default), which counts every authored operation - not just the sum of the
      named categories.
    operationId: haf_stats_endpoints.get_daily_active_users
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: granularity
        required: false
        schema:
          type: string
          default: day
          enum: [day, week, month]
        description: Aggregation granularity
      - in: query
        name: operation_types
        required: false
        schema:
          type: string
          default: all
        description: >-
          Comma-separated subset of post, comment, vote, transfer, custom_json,
          or "all" (every authored operation). Defaults to all.
    responses:
      '200':
        description: Daily-active-user time-series ordered by period
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, active_accounts BIGINT, operations BIGINT)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type: string
                    description: ISO-8601 date string for the aggregation bucket
                    example: "2016-04-01"
                  active_accounts:
                    type: integer
                    description: Distinct accounts that authored an op in the period
                  operations:
                    type: integer
                    description: Distinct operations authored in the period
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_daily_active_users;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_daily_active_users(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'day',
    "operation_types" TEXT = 'all'
)
RETURNS TABLE(period TEXT, active_accounts BIGINT, operations BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    -- op_class codes resolved from operation_types. -1 is the reserved ALL rollup
    -- (every authored op); 1 post, 2 comment, 3 vote, 4 transfer, 5 custom_json.
    _classes SMALLINT[];
    _bad     TEXT;
BEGIN
    -- No date filter ⇒ full history, for consistency with get_network_vote_stats and
    -- balance-api transfer-statistics (issue #34). Omitting from_date previously defaulted
    -- to the last 30 days, so a client's "No Filter / all history" option silently returned
    -- only a month; default to the chain genesis day (2016-03-24, block 1) instead so an
    -- unfiltered request returns every available period. The rollup holds no rows before the
    -- first data, so a genesis floor is exact regardless of how much history the node replayed.
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Wax's extendRest JSON-encodes string query params for custom namespaces,
    -- sending e.g. "all"/"day" (%22all%22) instead of all/day, which makes the
    -- strict operation_types enum check below reject the value. Strip a surrounding
    -- pair of double quotes from each text param so both raw and JSON-encoded strings
    -- are accepted. See haf_stats issue #22.
    granularity     := TRIM('"' FROM granularity);
    operation_types := TRIM('"' FROM operation_types);
    -- Validate granularity before it reaches DATE_TRUNC below: an unsupported unit
    -- there raises 'unit "..." not recognized' (an HTTP 500). Mirrors the guard in
    -- get_network_rc_utilization.
    IF granularity IS NULL OR granularity NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE(granularity, '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;

    -- Resolve operation_types to op_class codes. 'all' (the default, also matched
    -- when the list is empty or contains the token 'all') reads the reserved
    -- op_class = -1 rollup, NOT the sum of the named classes (which omit op types
    -- like account_update, witness ops, etc.).
    IF operation_types IS NULL
       OR btrim(operation_types) = ''
       OR EXISTS (
            SELECT 1 FROM unnest(string_to_array(lower(operation_types), ',')) AS t
            WHERE btrim(t) = 'all')
    THEN
        _classes := ARRAY[-1]::SMALLINT[];
    ELSE
        SELECT array_agg(m.code), MAX(m.bad) INTO _classes, _bad
        FROM (
            SELECT
                (CASE btrim(lower(t))
                    WHEN 'post'        THEN 1
                    WHEN 'comment'     THEN 2
                    WHEN 'vote'        THEN 3
                    WHEN 'transfer'    THEN 4
                    WHEN 'custom_json' THEN 5
                 END)::SMALLINT AS code,
                (CASE WHEN btrim(lower(t)) IN
                        ('post', 'comment', 'vote', 'transfer', 'custom_json')
                      THEN NULL ELSE btrim(t) END) AS bad
            FROM unnest(string_to_array(operation_types, ',')) AS t
            WHERE btrim(t) <> ''
        ) m;
        IF _bad IS NOT NULL THEN
            RAISE SQLSTATE '22023' USING
                MESSAGE = 'invalid operation_type: ' || _bad,
                HINT = 'Must be a comma-separated subset of: post, comment, vote, transfer, custom_json (or all)';
        END IF;
    END IF;

    -- A list with no usable tokens (e.g. ",,," or whitespace) is an empty selection;
    -- array_agg over zero rows leaves _classes NULL, and "op_class = ANY(NULL)" matches
    -- nothing. Treat it as 'all', consistent with an empty string above.
    IF _classes IS NULL THEN
        _classes := ARRAY[-1]::SMALLINT[];
    END IF;

    -- Fast path: ALL (-1) or a single named class is pre-aggregated per period in
    -- active_users_period_counts (maintained by process_active_users), so read it
    -- directly instead of COUNT(DISTINCT)-scanning the membership table. Every period
    -- overlapping [_from, _to] is returned at its FULL-period value: a from/to landing
    -- mid-period yields that period's full count, not a partial slice - consistent with
    -- account_cohort_retention and what a time-series chart expects.
    IF array_length(_classes, 1) = 1 THEN
        RETURN QUERY
        SELECT
            TO_CHAR(pc.period, 'YYYY-MM-DD'),
            pc.active_accounts,
            pc.operations
        FROM haf_stats_backend.active_users_period_counts pc
        WHERE pc.period_type = granularity
          AND pc.op_class = _classes[1]
          AND pc.period >= DATE_TRUNC(granularity, _from)::DATE
          AND pc.period <= _to
        ORDER BY 1;
        RETURN;
    END IF;

    -- Multi-class subset (>=2 named classes): active_accounts is the DISTINCT union
    -- across the selected classes (an account active in two of them counts once), which
    -- the per-class rollup cannot pre-sum, so re-aggregate the membership for these
    -- uncommon requests. operations is additive per class. Same full-period bucketing.
    RETURN QUERY
    WITH accounts AS (
        SELECT
            DATE_TRUNC(granularity, aud.day)::DATE AS period,
            COUNT(DISTINCT aud.account_id) AS active_accounts
        FROM haf_stats_backend.active_users_daily aud
        WHERE aud.op_class = ANY(_classes)
          AND aud.day >= DATE_TRUNC(granularity, _from)::DATE
          AND aud.day < (DATE_TRUNC(granularity, _to) + ('1 ' || granularity)::INTERVAL)::DATE
        GROUP BY 1
    ),
    ops AS (
        SELECT
            DATE_TRUNC(granularity, auo.day)::DATE AS period,
            SUM(auo.operations) AS operations
        FROM haf_stats_backend.active_user_ops_daily auo
        WHERE auo.op_class = ANY(_classes)
          AND auo.day >= DATE_TRUNC(granularity, _from)::DATE
          AND auo.day < (DATE_TRUNC(granularity, _to) + ('1 ' || granularity)::INTERVAL)::DATE
        GROUP BY 1
    )
    SELECT
        TO_CHAR(a.period, 'YYYY-MM-DD'),
        a.active_accounts::BIGINT,
        COALESCE(o.operations, 0)::BIGINT
    FROM accounts a
    LEFT JOIN ops o ON o.period = a.period
    ORDER BY 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network-wide voting activity
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/vote-stats:
  get:
    tags:
      - Network
    summary: Network voting activity
    description: >-
      Network-wide voting activity over time - total votes, upvotes, downvotes,
      unvotes (weight 0), self-votes (voter = author), unique voters, and the
      downvote percentage per period. unique_voters is exact at the requested
      granularity (a voter active on several days counts once per period).
      downvote_pct is downvotes / (upvotes + downvotes) * 100, null when a period
      has no up- or down-votes.
    operationId: haf_stats_endpoints.get_network_vote_stats
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: granularity
        required: false
        schema:
          type: string
          default: day
          enum:
            - day
            - week
            - month
        description: Aggregation period
    responses:
      '200':
        description: Vote activity rows ordered by period
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, total_votes BIGINT, upvotes BIGINT, downvotes BIGINT, unvotes BIGINT, self_votes BIGINT, unique_voters BIGINT, downvote_pct NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type: string
                    example: "2026-04-01"
                  total_votes:
                    type: integer
                  upvotes:
                    type: integer
                  downvotes:
                    type: integer
                  unvotes:
                    type: integer
                  self_votes:
                    type: integer
                  unique_voters:
                    type: integer
                  downvote_pct:
                    type:
                      - number
                      - "null"
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_vote_stats;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_vote_stats(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, total_votes BIGINT, upvotes BIGINT, downvotes BIGINT, unvotes BIGINT, self_votes BIGINT, unique_voters BIGINT, downvote_pct NUMERIC)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
BEGIN
    -- No date filter ⇒ full history. Omitting from_date previously defaulted to the
    -- last 30 days, so the client's "No Filter" silently returned only a month; default
    -- to the chain genesis day (2016-03-24, block 1) instead so an unfiltered request
    -- returns every available period. The rollup holds no rows before the first data, so
    -- a genesis floor is exact regardless of how much history the node has replayed.
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "day"); see issue #22.
    "granularity" := TRIM('"' FROM "granularity");
    -- IS NULL is required: "NULL NOT IN (...)" evaluates to NULL (not TRUE), so
    -- a NULL granularity would otherwise slip past and reach DATE_TRUNC.
    IF "granularity" IS NULL OR "granularity" NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE("granularity", '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;

    -- Read the per-period rollup (network_vote_period_counts, maintained by
    -- process_content_stats) directly. Previously this SUM-ed network_vote_daily and
    -- COUNT(DISTINCT voter_id)-scanned the whole network_voter_daily membership on every
    -- request - fine at the 90-day daily grain but several seconds for 52-week / all-time
    -- ranges, past the Wax 2s client timeout. unique_voters is non-additive across days,
    -- so it is materialised per period in the rollup; a wide range is now a single indexed
    -- range scan. Every period overlapping [_from, _to] is returned at its FULL-period
    -- value (a from/to landing mid-period yields that period's full count), matching
    -- get_daily_active_users and what a time-series chart expects. downvote_pct is derived
    -- here (not stored): downvotes / (upvotes + downvotes) * 100, null when a period has no
    -- up- or down-votes.
    RETURN QUERY
    SELECT
        TO_CHAR(pc.period, 'YYYY-MM-DD'),
        (pc.upvotes + pc.downvotes + pc.unvotes)::BIGINT,
        pc.upvotes::BIGINT,
        pc.downvotes::BIGINT,
        pc.unvotes::BIGINT,
        pc.self_votes::BIGINT,
        pc.unique_voters::BIGINT,
        ROUND(pc.downvotes * 100.0 / NULLIF(pc.upvotes + pc.downvotes, 0), 2)
    FROM haf_stats_backend.network_vote_period_counts pc
    WHERE pc.period_type = "granularity"
      AND pc.period >= DATE_TRUNC("granularity", _from)::DATE
      AND pc.period <= _to
    ORDER BY 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network-wide content volume
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/content-volume:
  get:
    tags:
      - Network
    summary: Posts and comments created over time
    description: >-
      Posts and comments created per period, with distinct authors. Counts follow
      chain semantics (comment_evaluator in hived): a comment_operation counts
      only when it actually creates the comment - edits of an existing
      (author, permlink) are not counted, while re-creating a previously deleted
      comment is. posts are root entries (parent_author = ''), comments
      everything else. unique_authors is exact at the requested granularity (an
      author active on several days counts once per period).
    operationId: haf_stats_endpoints.get_network_content_volume
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: granularity
        required: false
        schema:
          type: string
          default: day
          enum:
            - day
            - week
            - month
        description: Aggregation period
    responses:
      '200':
        description: Content volume rows ordered by period
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, posts BIGINT, comments BIGINT, unique_authors BIGINT)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type: string
                    example: "2026-04-01"
                  posts:
                    type: integer
                  comments:
                    type: integer
                  unique_authors:
                    type: integer
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_content_volume;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_content_volume(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, posts BIGINT, comments BIGINT, unique_authors BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
BEGIN
    -- No date filter ⇒ full history, consistent with get_network_vote_stats /
    -- get_daily_active_users / get_network_rc_utilization (issue #35). Omitting from_date
    -- previously defaulted to the last 30 days, so block_explorer_ui's "No Filter / all
    -- history" option silently returned only a month. This endpoint now reads the
    -- pre-aggregated network_content_period_counts rollup (a single indexed range scan, ~0.1s
    -- server-side at genesis for both day and month grain), so full history is cheap;
    -- default to chain genesis (2016-03-24, block 1).
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "month"); see issue #22.
    "granularity" := TRIM('"' FROM "granularity");
    -- IS NULL is required: "NULL NOT IN (...)" evaluates to NULL (not TRUE), so
    -- a NULL granularity would otherwise slip past and reach DATE_TRUNC.
    IF "granularity" IS NULL OR "granularity" NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE("granularity", '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;

    RETURN QUERY
    -- Read the per-period rollup (network_content_period_counts, maintained by
    -- process_content_stats) directly. Previously this SUM-ed network_content_daily and
    -- COUNT(DISTINCT author_id)-scanned the whole network_author_daily membership on every
    -- request - fine at the 30-day daily default but several seconds on wide week/month
    -- ranges, past the Wax 2s client timeout. unique_authors is non-additive across days, so
    -- it is materialised per period in the rollup; a wide range is now a single indexed range
    -- scan. Every period overlapping [_from, _to] is returned at its FULL-period value (a
    -- from/to landing mid-period yields that period's full count), matching
    -- get_network_vote_stats and get_daily_active_users and what a time-series chart expects.
    SELECT
        TO_CHAR(pc.period, 'YYYY-MM-DD'),
        pc.posts::BIGINT,
        pc.comments::BIGINT,
        pc.unique_authors::BIGINT
    FROM haf_stats_backend.network_content_period_counts pc
    WHERE pc.period_type = "granularity"
      AND pc.period >= DATE_TRUNC("granularity", _from)::DATE
      AND pc.period <= _to
    ORDER BY 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network-wide content engagement quality
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/engagement:
  get:
    tags:
      - Network
    summary: Content engagement quality metrics
    description: >-
      Average votes and comments per post, and the share of posts with zero
      engagement, per period. Posts are grouped by their CREATION period and the
      counts are lifetime totals — a post created in period P contributes every
      vote and reply it has ever received to P, including ones that arrived in a
      later period. This is a cohort-by-creation view, not a count of activity
      that happened within the period. Because counts are lifetime, the most
      recent periods are right-censored: posts created near the end of the range
      have had little time to accrue votes/replies, so their
      zero_vote_post_pct / zero_comment_post_pct read artificially high — treat
      the latest buckets as provisional until they mature. zero_vote_post_pct and
      zero_comment_post_pct are ghost-posting health signals unique to Hive.
      vote_count includes upvotes and downvotes (weight != 0); unvotes
      (weight = 0) are excluded. reply_count counts only direct replies to root
      posts.
    operationId: haf_stats_endpoints.get_network_engagement
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: granularity
        required: false
        schema:
          x-sql-datatype: TEXT
          # `default`, not x-sql-default-value. The generator checks `default` FIRST and
          # only falls back to x-sql-default-value, so carrying both would leave the
          # latter driving nothing while looking authoritative -- an editor changing it
          # would see no effect on the SQL signature and no CI failure. `default` also
          # reaches the published document, which x-sql-default-value does not: with
          # only the latter this endpoint advertised a plain optional string while its
          # siblings advertised `day` (#71). All 13 other defaulted parameters in this
          # document carry `default` alone; this now matches them.
          default: day
          type: string
          enum: [day, week, month]
        description: Bucketing granularity (day, week, or month)
    responses:
      '200':
        description: Engagement metrics per period
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, total_posts BIGINT, avg_votes_per_post NUMERIC, avg_comments_per_post NUMERIC, zero_vote_post_pct NUMERIC, zero_comment_post_pct NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type: string
                    format: date
                  total_posts:
                    type: integer
                  avg_votes_per_post:
                    type:
                      - number
                      - "null"
                  avg_comments_per_post:
                    type:
                      - number
                      - "null"
                  zero_vote_post_pct:
                    type:
                      - number
                      - "null"
                  zero_comment_post_pct:
                    type:
                      - number
                      - "null"
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_engagement;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_engagement(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, total_posts BIGINT, avg_votes_per_post NUMERIC, avg_comments_per_post NUMERIC, zero_vote_post_pct NUMERIC, zero_comment_post_pct NUMERIC)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
BEGIN
    -- No date filter ⇒ full history, consistent with get_network_vote_stats /
    -- get_daily_active_users / get_network_rc_utilization (issue #35). Omitting from_date
    -- previously defaulted to the last 30 days, so block_explorer_ui's "No Filter / all
    -- history" option silently returned only a month. This endpoint now reads the
    -- pre-aggregated engagement_period_counts rollup (a single indexed range scan, ~0.1s
    -- server-side at genesis for both day and month grain), so full history is cheap;
    -- default to chain genesis (2016-03-24, block 1).
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "day"); see issue #22.
    "granularity" := TRIM('"' FROM "granularity");
    IF "granularity" IS NULL OR "granularity" NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE("granularity", '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;

    RETURN QUERY
    -- Read the per-period rollup (engagement_period_counts, maintained by process_content_stats)
    -- directly. Previously this COUNT/AVG/FILTER-ed haf_stats_backend.post_engagement (one row
    -- per root post, tens of millions of rows) on every request - fine at the 30-day daily
    -- default but multiple seconds on wide week/month ranges, past the Wax 2s client timeout. The
    -- five additive metrics are materialised per period in the rollup; averages and zero-
    -- engagement percentages are reconstructed here (byte-identical to the old AVG/FILTER output:
    -- AVG(x) = SUM(x)/COUNT(*) and the FILTER counts are pre-summed), so a wide range is a single
    -- indexed range scan. Every period overlapping [_from, _to] is returned at its FULL-period
    -- value, matching get_network_content_volume / get_network_vote_stats. The lifetime-count /
    -- right-censored-recent-periods semantics are unchanged: the rollup stores the same lifetime
    -- sums the per-request query computed.
    SELECT
        TO_CHAR(pc.period, 'YYYY-MM-DD'),
        pc.total_posts::BIGINT,
        ROUND(pc.sum_votes::NUMERIC   / NULLIF(pc.total_posts, 0), 2),
        ROUND(pc.sum_replies::NUMERIC / NULLIF(pc.total_posts, 0), 2),
        ROUND(pc.zero_vote_posts    * 100.0 / NULLIF(pc.total_posts, 0), 2),
        ROUND(pc.zero_comment_posts * 100.0 / NULLIF(pc.total_posts, 0), 2)
    FROM haf_stats_backend.engagement_period_counts pc
    WHERE pc.period_type = "granularity"
      AND pc.period >= DATE_TRUNC("granularity", _from)::DATE
      AND pc.period <= _to
    ORDER BY 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-metric account leaderboard
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/top-accounts:
  get:
    tags:
      - Network
    summary: Top accounts per metric
    description: >-
      Top N accounts ranked by the chosen metric. Reward and transfer metrics sum
      haf_stats financial data over [from_date, to_date]; transaction_count sums authored
      (signed) operations over the same range; hp_balance ranks the CURRENT own
      vesting balance from balance_tracker and ignores from_date/to_date (empty result if
      no balance_tracker schema is readable on the deployment). Default sort keys -
      author_rewards and curation_rewards: vests, then hbd, then hive sums;
      transfer_volume_in/out: hive, then hbd sums; transaction_count: op count;
      hp_balance: vesting balance. Ties broken by account id (creation order).
      Value fields not applicable to a metric are 0. Optional order_by/order_direction
      re-rank the FULL population before truncating (a true top/bottom-N by any displayed
      column, not a client-side re-sort of a biased top-N): order_by must be a column the
      metric populates (author/curation rewards: value_vests|value_hive|value_hbd|op_count|account;
      transfers: value_hive|value_hbd|op_count|account; transaction_count: op_count|account;
      hp_balance: value_vests|account) - other combos return 400. order_direction asc yields
      a true bottom-N. Omitting both reproduces the default ranking exactly.
    operationId: haf_stats_endpoints.get_network_top_accounts
    parameters:
      - in: query
        name: metric
        required: false
        schema:
          type: string
          default: author_rewards
          enum:
            - author_rewards
            - curation_rewards
            - transfer_volume_in
            - transfer_volume_out
            - hp_balance
            - transaction_count
        description: Metric to rank accounts by
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis); ignored for hp_balance
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today; ignored for hp_balance
      - in: query
        name: limit_count
        required: false
        schema:
          type: integer
          default: 25
          minimum: 1
          maximum: 100
        description: Number of rows to return (1-100)
      - in: query
        name: order_by
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
          enum:
            - value_vests
            - value_hive
            - value_hbd
            - op_count
            - account
        description: >-
          Column to rank by before truncating; omit to use the metric's default sort. Must be a
          column the metric populates (else 400): author/curation rewards allow all five; transfers
          exclude value_vests; transaction_count allows op_count/account; hp_balance allows
          value_vests/account. 'account' sorts alphabetically by name. Requesting the metric's own
          default column with order_direction=desc reproduces the default ranking exactly, i.e. its
          full multi-key tiebreak (e.g. author_rewards: vests, then hbd, then hive, then account id);
          any other column ranks by that single column, then account id.
      - in: query
        name: order_direction
        required: false
        schema:
          type: string
          default: desc
          enum:
            - desc
            - asc
        description: >-
          Sort direction applied to order_by (or the metric's default column when order_by is
          omitted). asc yields a true bottom-N.
    responses:
      '200':
        description: Ranked accounts, rank 1 is the top account
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(rank INT, account TEXT, value_hive_nai BIGINT, value_hbd_nai BIGINT, value_vests_nai BIGINT, op_count BIGINT)"
              type: array
              items:
                type: object
                properties:
                  rank:
                    type: integer
                    example: 1
                  account:
                    type: string
                    example: "blocktrades"
                  value_hive_nai:
                    type: integer
                  value_hbd_nai:
                    type: integer
                  value_vests_nai:
                    type: integer
                  op_count:
                    type: integer
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_top_accounts;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_top_accounts(
    "metric" TEXT = 'author_rewards',
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "limit_count" INT = 25,
    "order_by" TEXT = NULL,
    "order_direction" TEXT = 'desc'
)
RETURNS TABLE(rank INT, account TEXT, value_hive_nai BIGINT, value_hbd_nai BIGINT, value_vests_nai BIGINT, op_count BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _category TEXT;
    _direction TEXT;
    _balance_rel TEXT;
    -- Window decomposition for the daily/monthly hybrid (issue #37): full interior
    -- months are read from the *_monthly rollups; the partial leading/trailing months
    -- (including the always-in-progress current month) are read from the daily tables,
    -- so results stay byte-exact and the current month is never stale. The split lives
    -- in haf_stats_app.top_accounts_window (unit-tested there with an injected _now); an
    -- unused sub-range comes back as an inverted [3000-01-01, 1900-01-01] bound so its
    -- index scan returns nothing. See the reward branch for how the pieces are UNIONed.
    _lead_from DATE;        -- daily leading partial range
    _lead_to DATE;
    _trail_from DATE;       -- daily trailing partial range
    _trail_to DATE;
    _mm_from DATE;          -- monthly full-month range (month-start keys)
    _mm_to DATE;
    -- TRUE when the request is the whole history up to now (the no-filter default): from omitted
    -- (⇒ genesis) and to omitted (⇒ today). Then the leaderboard is served from the pre-aggregated
    -- all-time per-account tables (account_txn_alltime / account_financial_alltime) instead of a
    -- genesis→now re-sum of the monthly rollups (#38). Any bounded range keeps the exact hybrid.
    _alltime BOOLEAN;
    -- Ordering (issue #39). order_by/order_direction let the UI rank the FULL population
    -- by any displayed column before truncating, instead of only the metric's default
    -- sort. _natural is the metric's default primary column; when the request resolves to
    -- (natural column, desc) we keep the existing index-ordered fast paths byte-for-byte.
    _natural TEXT;         -- metric's default primary order_by token
    _ob TEXT;              -- resolved order_by = COALESCE(order_by, _natural)
    _asc BOOLEAN;          -- order_direction = 'asc'
    _use_fast BOOLEAN;     -- (natural col, desc) ⇒ existing fast paths, byte-identical
    _col TEXT;             -- physical sort column for the ordered path (from a fixed map)
    _order_clause TEXT;    -- built ORDER BY tail for the ordered path
    _pop_select TEXT;      -- per-metric full-population SELECT for the ordered path
    _sql TEXT;
BEGIN
    -- No date filter ⇒ full history, consistent with the sibling network endpoints (#35). Omitting
    -- from_date previously defaulted to the last 30 days; default to chain genesis (2016-03-24,
    -- block 1) so block_explorer_ui's "No Filter" returns the all-time leaderboard, served cheaply
    -- from the all-time aggregates below.
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- All-time fast path only when the window spans genesis..today; the all-time tables are
    -- refreshed daily, so the result is as-of the last refresh (≤1 day stale, acceptable for an
    -- all-time ranking — same contract as hp_balance). Bounded ranges stay exact via the hybrid.
    _alltime := (_from <= '2016-03-24'::DATE AND _to >= NOW()::DATE);

    SELECT w.lead_from, w.lead_to, w.trail_from, w.trail_to, w.mm_from, w.mm_to
      INTO _lead_from, _lead_to, _trail_from, _trail_to, _mm_from, _mm_to
      FROM haf_stats_app.top_accounts_window(_from, _to, NOW()::DATE) w;

    -- Tolerate Wax's JSON-encoded string params (e.g. "author_rewards"); see issue #22.
    "metric" := TRIM('"' FROM "metric");
    IF "metric" IS NULL OR "metric" NOT IN ('author_rewards', 'curation_rewards',
        'transfer_volume_in', 'transfer_volume_out', 'hp_balance', 'transaction_count') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid metric: ' || COALESCE("metric", '(null)'),
            HINT = 'Must be one of: author_rewards, curation_rewards, transfer_volume_in, '
                || 'transfer_volume_out, hp_balance, transaction_count';
    END IF;

    IF "limit_count" IS NULL OR "limit_count" < 1 OR "limit_count" > 100 THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid limit_count: ' || COALESCE("limit_count"::TEXT, '(null)'),
            HINT = 'Must be between 1 and 100';
    END IF;

    -- Ordering params (issue #39). order_direction defaults to 'desc'; tolerate Wax's
    -- JSON-encoded strings like "asc" (issue #22), same as metric above.
    "order_direction" := LOWER(TRIM('"' FROM COALESCE("order_direction", 'desc')));
    IF "order_direction" NOT IN ('asc', 'desc') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid order_direction: ' || COALESCE("order_direction", '(null)'),
            HINT = 'Must be one of: asc, desc';
    END IF;
    _asc := ("order_direction" = 'asc');

    -- order_by must name a column the metric actually populates: a metric only fills its
    -- own value columns (transaction_count only op_count; hp_balance only vesting balance;
    -- transfers never carry VESTS), so ordering by a structurally-zero column is a client
    -- bug, not a valid request — reject it clearly rather than return a meaningless order.
    IF "order_by" IS NOT NULL THEN
        "order_by" := LOWER(TRIM('"' FROM "order_by"));
        IF NOT (
               ("metric" IN ('author_rewards', 'curation_rewards')
                    AND "order_by" IN ('value_vests', 'value_hbd', 'value_hive', 'op_count', 'account'))
            OR ("metric" IN ('transfer_volume_in', 'transfer_volume_out')
                    AND "order_by" IN ('value_hive', 'value_hbd', 'op_count', 'account'))
            OR ("metric" = 'transaction_count'
                    AND "order_by" IN ('op_count', 'account'))
            OR ("metric" = 'hp_balance'
                    AND "order_by" IN ('value_vests', 'account'))
        ) THEN
            RAISE SQLSTATE '22023' USING
                MESSAGE = format('invalid order_by %L for metric %L', "order_by", "metric"),
                HINT = 'order_by must be a column this metric populates (value_vests, '
                    || 'value_hive, value_hbd, op_count, or account); e.g. transaction_count '
                    || 'supports only op_count/account, hp_balance only value_vests/account.';
        END IF;
    END IF;

    -- Metric's default primary sort column. When the request resolves to (natural, desc)
    -- we fall through to the existing index-ordered fast paths below (byte-identical to
    -- the pre-#39 response); any other column or asc uses the ordered path after them.
    _natural := CASE
        WHEN "metric" IN ('author_rewards', 'curation_rewards')       THEN 'value_vests'
        WHEN "metric" IN ('transfer_volume_in', 'transfer_volume_out') THEN 'value_hive'
        WHEN "metric" = 'transaction_count'                            THEN 'op_count'
        ELSE 'value_vests'  -- hp_balance
    END;
    _ob := COALESCE("order_by", _natural);
    _use_fast := (NOT _asc) AND (_ob = _natural);

    IF _use_fast THEN
    -- ===================== fast paths (unchanged, pre-#39) =====================
    -- Reward + transfer metrics share account_financial_daily; the
    -- (category, direction, day) index makes each branch a targeted range scan.
    -- Accounts are resolved AFTER aggregation + LIMIT (top N names only).
    IF "metric" IN ('author_rewards', 'curation_rewards') THEN
        _category := CASE "metric"
            WHEN 'author_rewards' THEN 'author_reward_operation'
            ELSE 'curation_reward_operation'
        END;

        RETURN QUERY
        -- Rewards are HBD/VESTS mixes; VESTS (the HP part) is the dominant and
        -- always-present component, so it leads the sort key. src UNIONs the full
        -- interior months (rollup) with the partial leading/trailing days (daily);
        -- unused pieces match nothing via their inverted bounds (issue #37).
        WITH top AS (
            -- all-time fast path (no-filter default): a DIRECT index-ordered read of the
            -- pre-summed per-account rollup — no re-aggregation, so top-N is an Index Scan on
            -- idx_afa_reward_rank (this arm alone, LIMIT 25, warm: 0.35 ms on testapi, 2026-09-17)
            -- rather than the pre-#38 GroupAggregate over ~2M rows. Not index-only: op_count is not
            -- in that index, so the heap is read for every index entry visited (each returned row,
            -- plus any dead versions a refresh left behind). _alltime has no Vars, so only one of
            -- these two arms scans (#38) -- but the tables of BOTH are ACCESS SHARE-locked for the
            -- whole request, so an ACCESS EXCLUSIVE lock on any of them (the pre-#95 TRUNCATE
            -- refresh, an ALTER TABLE) blocks this metric for every date range. Same for the
            -- transfer and transaction_count branches below.
            (
                SELECT a.account_id,
                       a.hive_nai AS hive, a.hbd_nai AS hbd, a.vests_nai AS vests, a.op_count AS ops
                FROM haf_stats_backend.account_financial_alltime a
                WHERE _alltime AND a.category = _category AND a.direction = 'incoming'
                ORDER BY a.vests_nai DESC, a.hbd_nai DESC, a.hive_nai DESC, a.account_id ASC
                LIMIT "limit_count"
            )
            UNION ALL
            -- bounded-range hybrid: full interior months (rollup) + partial leading/trailing days
            -- (daily), aggregated per account (issue #37). VESTS (the HP part) leads the sort.
            (
                SELECT
                    s.account_id,
                    SUM(s.hive_nai)  AS hive,
                    SUM(s.hbd_nai)   AS hbd,
                    SUM(s.vests_nai) AS vests,
                    SUM(s.op_count)  AS ops
                FROM (
                    SELECT m.account_id, m.hive_nai, m.hbd_nai, m.vests_nai, m.op_count
                    FROM haf_stats_backend.account_financial_monthly m
                    WHERE NOT _alltime AND m.category = _category AND m.direction = 'incoming'
                      AND m.month BETWEEN _mm_from AND _mm_to
                    UNION ALL
                    SELECT f.account_id, f.hive_nai, f.hbd_nai, f.vests_nai, f.op_count
                    FROM haf_stats_backend.account_financial_daily f
                    WHERE NOT _alltime AND f.category = _category AND f.direction = 'incoming'
                      AND f.day BETWEEN _lead_from AND _lead_to
                    UNION ALL
                    SELECT f.account_id, f.hive_nai, f.hbd_nai, f.vests_nai, f.op_count
                    FROM haf_stats_backend.account_financial_daily f
                    WHERE NOT _alltime AND f.category = _category AND f.direction = 'incoming'
                      AND f.day BETWEEN _trail_from AND _trail_to
                ) s
                GROUP BY s.account_id
                ORDER BY SUM(s.vests_nai) DESC, SUM(s.hbd_nai) DESC,
                    SUM(s.hive_nai) DESC, s.account_id ASC
                LIMIT "limit_count"
            )
        )
        SELECT
            (ROW_NUMBER() OVER (ORDER BY t.vests DESC, t.hbd DESC, t.hive DESC,
                t.account_id ASC))::INT,
            a.name::TEXT,
            t.hive::BIGINT,
            t.hbd::BIGINT,
            t.vests::BIGINT,
            t.ops::BIGINT
        FROM top t
        JOIN hafd.accounts a ON a.id = t.account_id
        ORDER BY 1;

    ELSIF "metric" IN ('transfer_volume_in', 'transfer_volume_out') THEN
        _direction := CASE "metric"
            WHEN 'transfer_volume_in' THEN 'incoming'
            ELSE 'outgoing'
        END;

        RETURN QUERY
        -- Transfers carry HIVE or HBD (never VESTS); HIVE is the native unit and
        -- leads the sort key. Same daily/monthly hybrid as the reward branch (#37).
        WITH top AS (
            -- all-time fast path: DIRECT index-ordered read (Index Scan on idx_afa_transfer_rank,
            -- this arm alone, LIMIT 25, warm: 0.44 ms on testapi; not index-only, op_count is not in
            -- the index, so rows are read from the heap), no re-aggregation (#38). Only one arm
            -- scans, but both arms' tables are locked (see the reward branch).
            (
                SELECT a.account_id, a.hive_nai AS hive, a.hbd_nai AS hbd, a.op_count AS ops
                FROM haf_stats_backend.account_financial_alltime a
                WHERE _alltime AND a.category = 'transfer_operation' AND a.direction = _direction
                ORDER BY a.hive_nai DESC, a.hbd_nai DESC, a.account_id ASC
                LIMIT "limit_count"
            )
            UNION ALL
            -- bounded-range hybrid (issue #37). Transfers carry HIVE or HBD (never VESTS); HIVE
            -- is the native unit and leads the sort key.
            (
                SELECT
                    s.account_id,
                    SUM(s.hive_nai) AS hive,
                    SUM(s.hbd_nai)  AS hbd,
                    SUM(s.op_count) AS ops
                FROM (
                    SELECT m.account_id, m.hive_nai, m.hbd_nai, m.op_count
                    FROM haf_stats_backend.account_financial_monthly m
                    WHERE NOT _alltime AND m.category = 'transfer_operation' AND m.direction = _direction
                      AND m.month BETWEEN _mm_from AND _mm_to
                    UNION ALL
                    SELECT f.account_id, f.hive_nai, f.hbd_nai, f.op_count
                    FROM haf_stats_backend.account_financial_daily f
                    WHERE NOT _alltime AND f.category = 'transfer_operation' AND f.direction = _direction
                      AND f.day BETWEEN _lead_from AND _lead_to
                    UNION ALL
                    SELECT f.account_id, f.hive_nai, f.hbd_nai, f.op_count
                    FROM haf_stats_backend.account_financial_daily f
                    WHERE NOT _alltime AND f.category = 'transfer_operation' AND f.direction = _direction
                      AND f.day BETWEEN _trail_from AND _trail_to
                ) s
                GROUP BY s.account_id
                ORDER BY SUM(s.hive_nai) DESC, SUM(s.hbd_nai) DESC, s.account_id ASC
                LIMIT "limit_count"
            )
        )
        SELECT
            (ROW_NUMBER() OVER (ORDER BY t.hive DESC, t.hbd DESC,
                t.account_id ASC))::INT,
            a.name::TEXT,
            t.hive::BIGINT,
            t.hbd::BIGINT,
            0::BIGINT,
            t.ops::BIGINT
        FROM top t
        JOIN hafd.accounts a ON a.id = t.account_id
        ORDER BY 1;

    ELSIF "metric" = 'transaction_count' THEN
        RETURN QUERY
        -- op_class -1 is the ALL rollup: every authored op, counted once per
        -- distinct signer (see process_active_users.sql). Same daily/monthly hybrid
        -- as the reward branch, over the per-account monthly ops rollup (#37).
        WITH top AS (
            -- all-time fast path: DIRECT index-ordered read (Index-Only Scan on
            -- idx_account_txn_alltime_ops), no re-aggregation (#38). One-time filter picks one arm.
            (
                SELECT a.account_id, a.ops
                FROM haf_stats_backend.account_txn_alltime a
                WHERE _alltime
                ORDER BY a.ops DESC, a.account_id ASC
                LIMIT "limit_count"
            )
            UNION ALL
            -- bounded-range hybrid over the per-account monthly ops rollup (issue #37).
            (
                SELECT s.account_id, SUM(s.ops) AS ops
                FROM (
                    SELECT m.account_id, m.ops
                    FROM haf_stats_backend.active_users_account_monthly m
                    WHERE NOT _alltime AND m.op_class = -1
                      AND m.month BETWEEN _mm_from AND _mm_to
                    UNION ALL
                    SELECT au.account_id, au.ops
                    FROM haf_stats_backend.active_users_daily au
                    WHERE NOT _alltime AND au.op_class = -1
                      AND au.day BETWEEN _lead_from AND _lead_to
                    UNION ALL
                    SELECT au.account_id, au.ops
                    FROM haf_stats_backend.active_users_daily au
                    WHERE NOT _alltime AND au.op_class = -1
                      AND au.day BETWEEN _trail_from AND _trail_to
                ) s
                GROUP BY s.account_id
                ORDER BY SUM(s.ops) DESC, s.account_id ASC
                LIMIT "limit_count"
            )
        )
        SELECT
            (ROW_NUMBER() OVER (ORDER BY t.ops DESC, t.account_id ASC))::INT,
            a.name::TEXT,
            0::BIGINT,
            0::BIGINT,
            0::BIGINT,
            t.ops::BIGINT
        FROM top t
        JOIN hafd.accounts a ON a.id = t.account_id
        ORDER BY 1;

    ELSE  -- hp_balance
        -- Same balance-relation resolution as get_network_hp_distribution:
        -- balance_tracker installs under different schemas per deployment, and
        -- information_schema.tables only lists relations this role can read, so
        -- the pick is guaranteed readable; [] when none exists (documented).
        SELECT format('%I.%I', t.table_schema, t.table_name)
          INTO _balance_rel
          FROM (VALUES
                    ('btracker_app',     'current_account_balances',      1),
                    ('btracker_backend', 'current_account_balances_view', 2),
                    ('hafbe_bal',        'current_account_balances',      3)
               ) AS cand (sch, rel, prio)
          JOIN information_schema.tables t
            ON t.table_schema = cand.sch AND t.table_name = cand.rel
         ORDER BY cand.prio
         LIMIT 1;

        IF _balance_rel IS NULL THEN
            RETURN;  -- no readable balance relation on this deployment
        END IF;

        -- _balance_rel comes from format('%I.%I', ...) over a fixed allowlist,
        -- so interpolating it (%s) into the dynamic query is injection-safe.
        RETURN QUERY EXECUTE format($q$
            WITH top AS (
                SELECT b.account AS account_id, b.balance AS vests
                FROM %s b
                WHERE b.nai = 37   -- VESTS (btracker nai smallint code)
                  AND b.balance > 0
                ORDER BY b.balance DESC, b.account ASC
                LIMIT $1
            )
            SELECT
                (ROW_NUMBER() OVER (ORDER BY t.vests DESC, t.account_id ASC))::INT,
                a.name::TEXT,
                0::BIGINT,
                0::BIGINT,
                t.vests::BIGINT,
                0::BIGINT
            FROM top t
            JOIN hafd.accounts a ON a.id = t.account_id
            ORDER BY 1
        $q$, _balance_rel) USING "limit_count";
    END IF;
    RETURN;
    END IF;  -- _use_fast

    -- ======================= ordered path (issue #39) =========================
    -- Reached only when order_by names a non-default column or order_direction = asc.
    -- The requested ordering has no covering index, so — unlike the fast paths — this
    -- ranks the metric's FULL per-account population before truncating. That is the
    -- whole point of the feature: re-sorting a truncated top-N client-side reorders a
    -- biased sample, so the true top/bottom-N by another column is a different set and
    -- must be selected server-side. Cost is a scan + top-N sort over the population (up
    -- to ~2M accounts, tens–hundreds of ms; order_by=account also joins names pre-LIMIT).

    -- Physical sort column, resolved from a fixed map — never raw user text, so the
    -- string is injection-safe. order_by was validated against the metric above.
    _col := CASE _ob
        WHEN 'value_vests' THEN 'vests'
        WHEN 'value_hive'  THEN 'hive'
        WHEN 'value_hbd'   THEN 'hbd'
        WHEN 'op_count'    THEN 'ops'
        WHEN 'account'     THEN 'name'
    END;
    -- account_id is the deterministic final tiebreak (creation order), matching the
    -- fast paths. NULLS LAST is defensive; population values are always non-null.
    _order_clause := format('%s %s NULLS LAST, account_id ASC',
        _col, CASE WHEN _asc THEN 'ASC' ELSE 'DESC' END);

    -- Per-metric full population (account_id, hive, hbd, vests, ops), NO per-arm LIMIT.
    -- _alltime is injected as a literal so exactly one arm scans (constant-folded, #38):
    -- the all-time table for the no-filter default, else the daily/monthly hybrid (#37).
    -- Metrics zero-fill the value columns they do not carry (same contract as the output).
    IF "metric" IN ('author_rewards', 'curation_rewards') THEN
        _category := CASE "metric"
            WHEN 'author_rewards' THEN 'author_reward_operation'
            ELSE 'curation_reward_operation'
        END;
        _pop_select := format($pop$
            SELECT a.account_id, a.hive_nai AS hive, a.hbd_nai AS hbd, a.vests_nai AS vests, a.op_count AS ops
              FROM haf_stats_backend.account_financial_alltime a
             WHERE %1$L::boolean AND a.category = %2$L AND a.direction = 'incoming'
            UNION ALL
            SELECT s.account_id, SUM(s.hive_nai) AS hive, SUM(s.hbd_nai) AS hbd,
                   SUM(s.vests_nai) AS vests, SUM(s.op_count) AS ops
              FROM (
                SELECT m.account_id, m.hive_nai, m.hbd_nai, m.vests_nai, m.op_count
                  FROM haf_stats_backend.account_financial_monthly m
                 WHERE NOT %1$L::boolean AND m.category = %2$L AND m.direction = 'incoming'
                   AND m.month BETWEEN %3$L AND %4$L
                UNION ALL
                SELECT f.account_id, f.hive_nai, f.hbd_nai, f.vests_nai, f.op_count
                  FROM haf_stats_backend.account_financial_daily f
                 WHERE NOT %1$L::boolean AND f.category = %2$L AND f.direction = 'incoming'
                   AND f.day BETWEEN %5$L AND %6$L
                UNION ALL
                SELECT f.account_id, f.hive_nai, f.hbd_nai, f.vests_nai, f.op_count
                  FROM haf_stats_backend.account_financial_daily f
                 WHERE NOT %1$L::boolean AND f.category = %2$L AND f.direction = 'incoming'
                   AND f.day BETWEEN %7$L AND %8$L
              ) s GROUP BY s.account_id
        $pop$, _alltime, _category, _mm_from, _mm_to, _lead_from, _lead_to, _trail_from, _trail_to);

    ELSIF "metric" IN ('transfer_volume_in', 'transfer_volume_out') THEN
        _direction := CASE "metric"
            WHEN 'transfer_volume_in' THEN 'incoming'
            ELSE 'outgoing'
        END;
        _pop_select := format($pop$
            SELECT a.account_id, a.hive_nai AS hive, a.hbd_nai AS hbd, 0::bigint AS vests, a.op_count AS ops
              FROM haf_stats_backend.account_financial_alltime a
             WHERE %1$L::boolean AND a.category = 'transfer_operation' AND a.direction = %2$L
            UNION ALL
            SELECT s.account_id, SUM(s.hive_nai) AS hive, SUM(s.hbd_nai) AS hbd,
                   0::bigint AS vests, SUM(s.op_count) AS ops
              FROM (
                SELECT m.account_id, m.hive_nai, m.hbd_nai, m.op_count
                  FROM haf_stats_backend.account_financial_monthly m
                 WHERE NOT %1$L::boolean AND m.category = 'transfer_operation' AND m.direction = %2$L
                   AND m.month BETWEEN %3$L AND %4$L
                UNION ALL
                SELECT f.account_id, f.hive_nai, f.hbd_nai, f.op_count
                  FROM haf_stats_backend.account_financial_daily f
                 WHERE NOT %1$L::boolean AND f.category = 'transfer_operation' AND f.direction = %2$L
                   AND f.day BETWEEN %5$L AND %6$L
                UNION ALL
                SELECT f.account_id, f.hive_nai, f.hbd_nai, f.op_count
                  FROM haf_stats_backend.account_financial_daily f
                 WHERE NOT %1$L::boolean AND f.category = 'transfer_operation' AND f.direction = %2$L
                   AND f.day BETWEEN %7$L AND %8$L
              ) s GROUP BY s.account_id
        $pop$, _alltime, _direction, _mm_from, _mm_to, _lead_from, _lead_to, _trail_from, _trail_to);

    ELSIF "metric" = 'transaction_count' THEN
        _pop_select := format($pop$
            SELECT a.account_id, 0::bigint AS hive, 0::bigint AS hbd, 0::bigint AS vests, a.ops AS ops
              FROM haf_stats_backend.account_txn_alltime a
             WHERE %1$L::boolean
            UNION ALL
            SELECT s.account_id, 0::bigint AS hive, 0::bigint AS hbd, 0::bigint AS vests, SUM(s.ops) AS ops
              FROM (
                SELECT m.account_id, m.ops
                  FROM haf_stats_backend.active_users_account_monthly m
                 WHERE NOT %1$L::boolean AND m.op_class = -1 AND m.month BETWEEN %2$L AND %3$L
                UNION ALL
                SELECT au.account_id, au.ops
                  FROM haf_stats_backend.active_users_daily au
                 WHERE NOT %1$L::boolean AND au.op_class = -1 AND au.day BETWEEN %4$L AND %5$L
                UNION ALL
                SELECT au.account_id, au.ops
                  FROM haf_stats_backend.active_users_daily au
                 WHERE NOT %1$L::boolean AND au.op_class = -1 AND au.day BETWEEN %6$L AND %7$L
              ) s GROUP BY s.account_id
        $pop$, _alltime, _mm_from, _mm_to, _lead_from, _lead_to, _trail_from, _trail_to);

    ELSE  -- hp_balance (ordered only by value_vests asc or account; same balance-rel pick as above)
        SELECT format('%I.%I', t.table_schema, t.table_name)
          INTO _balance_rel
          FROM (VALUES
                    ('btracker_app',     'current_account_balances',      1),
                    ('btracker_backend', 'current_account_balances_view', 2),
                    ('hafbe_bal',        'current_account_balances',      3)
               ) AS cand (sch, rel, prio)
          JOIN information_schema.tables t
            ON t.table_schema = cand.sch AND t.table_name = cand.rel
         ORDER BY cand.prio
         LIMIT 1;
        IF _balance_rel IS NULL THEN
            RETURN;  -- no readable balance relation on this deployment
        END IF;
        _pop_select := format($pop$
            SELECT b.account AS account_id, 0::bigint AS hive, 0::bigint AS hbd,
                   b.balance AS vests, 0::bigint AS ops
              FROM %s b
             WHERE b.nai = 37 AND b.balance > 0
        $pop$, _balance_rel);
    END IF;

    -- Rank the full population by the requested order, truncate, then resolve names.
    -- ROW_NUMBER re-applies the same ORDER BY so rank matches row order without relying on
    -- CTE row-order preservation; %2$s is the fixed validated ORDER BY tail and %3$s the
    -- range-checked integer limit — both safe.
    --
    -- Two shapes by whether the sort needs the account name. For value/op orderings the
    -- name is only needed for the final N rows, so we sort+LIMIT the population first and
    -- join hafd.accounts to just those N (mirrors the fast paths, which also resolve names
    -- after LIMIT). Only order_by=account sorts BY the name, so there the join must precede
    -- LIMIT — its cost is inherent to alphabetical ordering over the whole population.
    IF _ob = 'account' THEN
        _sql := format($ob$
            WITH pop AS ( %1$s ),
            j AS (
                SELECT p.account_id, a.name, p.hive, p.hbd, p.vests, p.ops
                  FROM pop p
                  JOIN hafd.accounts a ON a.id = p.account_id
            ),
            ranked AS (
                SELECT * FROM j ORDER BY %2$s LIMIT %3$s
            )
            SELECT (ROW_NUMBER() OVER (ORDER BY %2$s))::INT,
                   name::TEXT, hive::BIGINT, hbd::BIGINT, vests::BIGINT, ops::BIGINT
              FROM ranked
             ORDER BY 1
        $ob$, _pop_select, _order_clause, "limit_count");
    ELSE
        _sql := format($ob$
            WITH pop AS ( %1$s ),
            ranked AS (
                SELECT * FROM pop ORDER BY %2$s LIMIT %3$s
            )
            SELECT (ROW_NUMBER() OVER (ORDER BY %2$s))::INT,
                   a.name::TEXT, ranked.hive::BIGINT, ranked.hbd::BIGINT,
                   ranked.vests::BIGINT, ranked.ops::BIGINT
              FROM ranked
              JOIN hafd.accounts a ON a.id = ranked.account_id
             ORDER BY 1
        $ob$, _pop_select, _order_clause, "limit_count");
    END IF;

    RETURN QUERY EXECUTE _sql;
END;
$$;

-- ---------------------------------------------------------------------------
-- Feature: witness missed blocks and reliability (issue #54)
-- ---------------------------------------------------------------------------

/** openapi:paths
/witnesses/missed-blocks:
  get:
    tags:
      - Witnesses
    summary: Witness missed blocks and reliability
    description: >-
      Missed versus produced blocks per witness over [from_date, to_date]. Omit granularity for a
      LEADERBOARD (one row per producer, period null); set it for a TIME SERIES (one row per period,
      producer null unless witness is given). Every producer with any activity in the window is
      included, INCLUDING those that missed nothing, so rate is a meaningful reliability figure and
      a witness= query returns a row whenever that witness was scheduled; the active set is NOT
      filtered server-side, since backup witnesses are exactly the ones that miss. rate is
      missed_count / (produced_count + missed_count), a fraction in [0,1] rounded to 6 decimals -
      not a percentage, because at 2 decimals a witness that missed 1 of 28,800 slots would print
      0.00. A witness whose only activity in the window was a miss has produced_count 0 and rate 1.
      Reads the witness_blocks_daily rollup only, so numerator and denominator always share one
      clock (the app's last processed block) and counts never include blocks the app has not
      processed yet; /sync-status discloses that lag. from_date/to_date select whole UTC days, so
      the newest day holds only the blocks processed so far - "today so far". In series mode every
      period OVERLAPPING the window is returned at its full-period value, so a from_date or to_date
      landing mid-week or mid-month yields that whole period rather than a partial slice labelled as
      a full one (same rule as the other network time series). Hourly buckets are
      not supported: every rollup here is day-grained, and serving hours from raw operations would
      reintroduce the two-clock split this endpoint exists to avoid; time-of-day miss patterns are
      a follow-up that should add an hourly rollup. Witness rank and top-21 membership are
      deliberately NOT returned - those are hafbe-api /witnesses; join them on the producer name.
      NOTE: produced + missed is close to but not exactly 28,800 slots per day. A chain halt loses
      slots entirely (no block is produced AND no miss is recorded), and a halt straddling midnight
      can hand one back the next day - the replay corpus shows 28,711 on 2016-04-10 and 28,801 on
      2016-04-11. Do not derive produced as 28800 - missed.
    operationId: haf_stats_endpoints.get_witness_missed_blocks
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or start date (YYYY-MM-DD), inclusive; omit for full history (defaults to chain genesis)
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: Block number or end date (YYYY-MM-DD), inclusive, defaults to today
      - in: query
        name: witness
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
        description: >-
          Restrict to a single witness account name; omit for all producers. Unknown names, and
          names with no scheduled slots in the window, return an empty array. Note this is NOT an
          active/top-21 filter - a demoted or backup witness returns its real figures, which is the
          population the endpoint exists to expose. (Issue #54's sketch and block_explorer_ui#774
          call this parameter `producer`; it had to be renamed because `producer` is also a response
          column, and RETURNS TABLE columns are OUT parameters.)
      - in: query
        name: granularity
        required: false
        schema:
          x-sql-datatype: TEXT
          x-sql-default-value: "NULL"
          type: string
          enum: [day, week, month]
        description: Omit for the per-witness leaderboard; set to bucket the window into a time series
      - in: query
        name: order_by
        required: false
        schema:
          type: string
          default: missed
          enum: [missed, rate, last_missed]
        description: Leaderboard ranking column, descending. Validated but not applied when granularity is set (a series is always ordered by period)
      - in: query
        name: limit_count
        required: false
        schema:
          type: integer
          default: 1000
          minimum: 1
          maximum: 1000
        description: >-
          Number of leaderboard rows to return (1-1000), defaulting to the MAXIMUM rather than to a
          small page. Both the ceiling and that default differ from the sibling leaderboards on
          purpose: those rank an unbounded space (21k+ custom_json ids) where a top-N is the whole
          point, whereas the group set here is the WITNESS set - bounded by how many accounts were
          scheduled in the window, ~120-200 on modern Hive. Truncation is uniquely dangerous for the
          witness-table consumer, which merges by producer and renders an absent witness as
          "0 missed", so a dropped row becomes a WRONG figure rather than a missing one; the
          response carries no truncation indicator, so a low default would be a trap rather than a
          safeguard. The window aggregation is independent of the limit, so the wide default is
          nearly free (47.8 ms at 100 vs 62.4 ms at 1000 over full history). Validated but not
          applied when granularity is set.
    responses:
      '200':
        description: Witness missed-block leaderboard or time series
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(period TEXT, producer TEXT, missed_count BIGINT, produced_count BIGINT, rate NUMERIC, first_missed_block INT, last_missed_block INT, first_missed_at TIMESTAMP, last_missed_at TIMESTAMP)"
              type: array
              items:
                type: object
                properties:
                  period:
                    type:
                      - string
                      - "null"
                    description: ISO-8601 date string for the aggregation bucket (null in leaderboard mode)
                  producer:
                    type:
                      - string
                      - "null"
                    description: Witness account name (null in a network-wide series, i.e. granularity set without witness)
                  missed_count:
                    type: integer
                    description: Scheduled slots the witness missed in the window
                  produced_count:
                    type: integer
                    description: Blocks the witness produced in the window
                  rate:
                    type:
                      - number
                      - "null"
                    description: missed/(produced+missed), a fraction in [0,1] to 6 decimals; null only when the window holds no slots
                  first_missed_block:
                    type:
                      - integer
                      - "null"
                    description: Block at which the first miss in the window was recorded (null if nothing was missed)
                  last_missed_block:
                    type:
                      - integer
                      - "null"
                    description: Block at which the last miss in the window was recorded (null if nothing was missed)
                  first_missed_at:
                    type:
                      - string
                      - "null"
                    format: date-time
                    description: Timestamp of first_missed_block; with last_missed_at this separates a single outage from sustained flakiness
                  last_missed_at:
                    type:
                      - string
                      - "null"
                    format: date-time
                    description: Timestamp of last_missed_block
      '400':
        $ref: '#/components/responses/BadRequest'
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_witness_missed_blocks;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_witness_missed_blocks(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "witness" TEXT = NULL,
    "granularity" TEXT = NULL,
    "order_by" TEXT = 'missed',
    "limit_count" INT = 1000
)
RETURNS TABLE(period TEXT, producer TEXT, missed_count BIGINT, produced_count BIGINT, rate NUMERIC, first_missed_block INT, last_missed_block INT, first_missed_at TIMESTAMP, last_missed_at TIMESTAMP)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _from DATE;
    _to DATE;
    _witness TEXT;
    _witness_id INT;
    _gran TEXT;
    _ob TEXT;
BEGIN
    -- The query parameter is `witness`, not `producer`, because RETURNS TABLE columns ARE OUT
    -- parameters: an IN parameter named `producer` is rejected outright with
    -- 'parameter name "producer" used more than once'. The response field keeps the on-chain
    -- name (hafd.blocks.producer_account_id, producer_missed_operation.producer).

    -- No date filter ⇒ full history (chain genesis 2016-03-24), consistent with the sibling
    -- network endpoints (issue #35). Reliability comparisons should pass an explicit window;
    -- an all-time leaderboard is dominated by whoever was scheduled longest.
    _from := haf_stats_app.to_filter_date("from_date", '2016-03-24'::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "gtg"); see issue #22. '' means absent.
    _witness := NULLIF(TRIM('"' FROM COALESCE("witness", '')), '');
    _gran := NULLIF(TRIM('"' FROM COALESCE("granularity", '')), '');
    _ob := TRIM('"' FROM "order_by");

    -- Deliberately INVERTED relative to every sibling endpoint's "IS NULL OR x NOT IN (...)":
    -- here a NULL/absent granularity is a MEANINGFUL value (it selects the leaderboard), so the
    -- usual guard would reject the default. _gran is non-null inside this branch, so NOT IN is a
    -- plain boolean and can never evaluate to NULL.
    IF _gran IS NOT NULL AND _gran NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || _gran,
            HINT = 'Must be one of: day, week, month (omit for the per-witness leaderboard)';
    END IF;

    -- IS NULL is required: "NULL NOT IN (...)" evaluates to NULL (not TRUE), so a NULL order_by
    -- would slip past and reach the CASE.
    IF _ob IS NULL OR _ob NOT IN ('missed', 'rate', 'last_missed') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid order_by: ' || COALESCE(_ob, '(null)'),
            HINT = 'Must be one of: missed, rate, last_missed';
    END IF;

    -- IS NULL is required for a second reason here: LIMIT NULL means NO LIMIT, so a null
    -- limit_count would dump the entire leaderboard instead of one page.
    IF "limit_count" IS NULL OR "limit_count" < 1 OR "limit_count" > 1000 THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid limit_count: ' || COALESCE("limit_count"::TEXT, '(null)'),
            HINT = 'Must be between 1 and 1000';
    END IF;

    IF _witness IS NOT NULL THEN
        SELECT a.id INTO _witness_id FROM hafd.accounts a WHERE a.name = _witness;
        -- Unknown account ⇒ empty result, not an error (the idiom every account endpoint uses).
        -- A known witness with no activity in the window returns empty by the same route.
        IF _witness_id IS NULL THEN
            RETURN;
        END IF;
    END IF;

    IF _gran IS NULL THEN
        -- ------------------------------------------------------------------
        -- Leaderboard: one row per producer over the whole window.
        -- ------------------------------------------------------------------
        RETURN QUERY
        WITH agg AS (
            SELECT
                wb.producer_account_id AS producer_account_id,
                SUM(wb.produced_count)::BIGINT AS produced_count,
                SUM(wb.missed_count)::BIGINT AS missed_count,
                MIN(wb.first_missed_block)::INT AS first_missed_block,
                MAX(wb.last_missed_block)::INT AS last_missed_block
            FROM haf_stats_backend.witness_blocks_daily wb
            WHERE wb.day BETWEEN _from AND _to
              AND (_witness_id IS NULL OR wb.producer_account_id = _witness_id)
            GROUP BY wb.producer_account_id
        ),
        -- ::NUMERIC on the numerator is load-bearing: BIGINT / BIGINT is INTEGER division and
        -- would round every real miss rate to 0. NULLIF guards the (unreachable, since a row
        -- exists only when one of the counters is positive) zero-slot case.
        rated AS (
            SELECT
                g.producer_account_id, g.produced_count, g.missed_count,
                g.first_missed_block, g.last_missed_block,
                ROUND(g.missed_count::NUMERIC
                      / NULLIF(g.produced_count + g.missed_count, 0), 6) AS rate
            FROM agg g
        ),
        -- NULLS LAST is mandatory, not defensive: last_missed_block is NULL for every witness
        -- that never missed, and PostgreSQL's DESC sorts NULLs FIRST - without it,
        -- order_by=last_missed would return a page of witnesses that have never missed a block.
        -- missed_count then producer_account_id make the ordering total, so the page is
        -- deterministic.
        top AS (
            SELECT r.*
            FROM rated r
            ORDER BY
                (CASE WHEN _ob = 'rate' THEN r.rate
                      WHEN _ob = 'last_missed' THEN r.last_missed_block::NUMERIC
                      ELSE r.missed_count::NUMERIC END) DESC NULLS LAST,
                r.missed_count DESC,
                r.producer_account_id ASC
            LIMIT "limit_count"
        )
        -- Names and block timestamps resolve AFTER the limit - at most limit_count rows, each a
        -- PK lookup (the get_network_top_custom_json fast-path idiom). LEFT JOIN so a witness
        -- with no misses is not dropped by its NULL extremes.
        SELECT
            NULL::TEXT,
            a.name::TEXT,
            t.missed_count,
            t.produced_count,
            t.rate,
            t.first_missed_block,
            t.last_missed_block,
            fb.created_at,
            lb.created_at
        FROM top t
        JOIN hafd.accounts a ON a.id = t.producer_account_id
        LEFT JOIN hafd.blocks fb ON fb.num = t.first_missed_block
        LEFT JOIN hafd.blocks lb ON lb.num = t.last_missed_block
        ORDER BY
            (CASE WHEN _ob = 'rate' THEN t.rate
                  WHEN _ob = 'last_missed' THEN t.last_missed_block::NUMERIC
                  ELSE t.missed_count::NUMERIC END) DESC NULLS LAST,
            t.missed_count DESC,
            t.producer_account_id ASC;
    ELSE
        -- ------------------------------------------------------------------
        -- Time series: one row per period. With witness= it is that witness's series; without
        -- it, network-wide totals (producer null). Sparse - periods with no data are omitted,
        -- matching every other time series here. GROUP BY the DATE_TRUNC expression, not the
        -- `period` alias, which collides with the RETURNS TABLE OUT column.
        -- ------------------------------------------------------------------
        RETURN QUERY
        WITH agg AS (
            SELECT
                DATE_TRUNC(_gran, wb.day) AS bucket,
                SUM(wb.produced_count)::BIGINT AS produced_count,
                SUM(wb.missed_count)::BIGINT AS missed_count,
                MIN(wb.first_missed_block)::INT AS first_missed_block,
                MAX(wb.last_missed_block)::INT AS last_missed_block
            FROM haf_stats_backend.witness_blocks_daily wb
            -- Expand to whole BUCKET boundaries, not the raw day window. `day BETWEEN _from AND
            -- _to` would emit a partial edge period LABELLED as a full one: a window of
            -- 2016-04-15..04-20 at granularity=month returned period '2016-04-01' holding six
            -- days of blocks, which renders as a ~70% collapse in block production that never
            -- happened. Same both-ends form as get_daily_active_users, which aggregates a
            -- *_daily table into buckets exactly like this; the house rule is stated at
            -- get_daily_active_users' "every period overlapping [_from, _to] is returned at its
            -- FULL-period value" comment. Interpolating _gran is safe - it is validated against
            -- ('day','week','month') above. No effect at granularity=day.
            WHERE wb.day >= DATE_TRUNC(_gran, _from)::DATE
              AND wb.day < (DATE_TRUNC(_gran, _to) + ('1 ' || _gran)::INTERVAL)::DATE
              AND (_witness_id IS NULL OR wb.producer_account_id = _witness_id)
            GROUP BY DATE_TRUNC(_gran, wb.day)
        )
        -- Cost note: unlike the leaderboard, whose two hafd.blocks probes per row are capped by
        -- limit_count, this branch does two PK probes per BUCKET with no client-settable bound -
        -- a full-history granularity=day call is ~3,500 buckets, so ~7,000 random probes into a
        -- table that is ~30 GB on mainnet. Measured at ~85 ms warm here; the exposure is a cold
        -- cache, where the probe keys are spread one per day across all of chain history and
        -- cannot be assumed resident. Left unbounded deliberately: truncating a chart is worse
        -- than a slow one, and the rollup scan that feeds it is already the dominant cost for
        -- every window a frontend actually requests.
        SELECT
            TO_CHAR(g.bucket, 'YYYY-MM-DD'),
            _witness,
            g.missed_count,
            g.produced_count,
            ROUND(g.missed_count::NUMERIC
                  / NULLIF(g.produced_count + g.missed_count, 0), 6),
            g.first_missed_block,
            g.last_missed_block,
            fb.created_at,
            lb.created_at
        FROM agg g
        LEFT JOIN hafd.blocks fb ON fb.num = g.first_missed_block
        LEFT JOIN hafd.blocks lb ON lb.num = g.last_missed_block
        ORDER BY 1;
    END IF;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;

RESET ROLE;
