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
-- custom_json id -> DApp name resolution (single source of truth).
-- Longest registered app_id_pattern that is a prefix of the id wins; a secondary
-- sort by pattern makes equal-length ties deterministic; unmatched ids fall back
-- to the raw id. Shared by every endpoint that labels a custom_json app
-- (get_account_rc_footprint group_by=app, get_account_rc_footprint_timeline), so
-- the resolved label is identical across them by construction. Co-located here (not
-- db/) so it installs with the endpoints, including the stub endpoint-test stack.
-- ---------------------------------------------------------------------------
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
  - name: Other
    description: Health and version endpoints
servers:
  - url: /haf-stats-api
 */

-- ---------------------------------------------------------------------------
-- root() - serves the full OpenAPI spec at GET /
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION haf_stats_endpoints.root() RETURNS json
LANGUAGE plpgsql STABLE
AS $func$
DECLARE
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
      "name": "Other",
      "description": "Health and version endpoints"
    }
  ],
  "servers": [
    {
      "url": "/haf-stats-api"
    }
  ],
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
                        "type": "string",
                        "nullable": true,
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
        "description": "Breakdown of estimated Resource Credit consumption for an account over a time range, grouped by operation type or DApp. Counts the ops the account itself signed (the RC payer) and prices them from the calibrated rc_op_stats_daily rates; RC is an ESTIMATE (op_type uses op_count * average rc_api cost), as real per-op RC cost is unavailable on this node.",
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
                "app"
              ]
            },
            "description": "Group results by operation type or DApp"
          }
        ],
        "responses": {
          "200": {
            "description": "RC consumption ranked by usage",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(label TEXT, rc_consumed BIGINT, op_count BIGINT, pct NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "label": {
                        "type": "string",
                        "description": "Operation type name or custom_json app ID"
                      },
                      "rc_consumed": {
                        "type": "integer"
                      },
                      "op_count": {
                        "type": "integer"
                      },
                      "pct": {
                        "type": "number",
                        "description": "Percentage of total RC consumed"
                      }
                    }
                  }
                }
              }
            }
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
        "description": "Per-event drill-down companion to rc-footprint: one row per RC-spending operation the account signed, most recent first, with the op type, resolved DApp name (+ raw custom_json id), block, timestamp and estimated RC consumed. rc_consumed is an ESTIMATE (op_count model priced from the calibrated rc_op_stats_daily rates), as real per-op RC cost is unavailable on this node; summing rc_consumed over a window reconciles with the rc-footprint group_by=op_type total (the op-count model). Optional op_type_filter / app_filter narrow the timeline to the events of one op type or DApp (the same events as the matching rc-footprint bucket; per-event rc_consumed stays the op-count estimate, so an app_filter sum matches the op_type total, not the byte-aware group_by=app figure). Pages via limit_count/offset_start, or O(1)-at-any-depth keyset paging by passing the previous page's last op_seq as before_seq.",
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
                  "x-sql-datatype": "TABLE(\"timestamp\" TIMESTAMP, block_num INT, op_type TEXT, app TEXT, custom_json_id TEXT, rc_consumed BIGINT, op_seq BIGINT)",
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
                        "type": "string",
                        "nullable": true,
                        "description": "Resolved DApp name for custom_json ops (custom_json_app_registry match, falling back to the raw id); null for non-custom_json ops"
                      },
                      "custom_json_id": {
                        "type": "string",
                        "nullable": true,
                        "description": "Raw custom_json id (null for non-custom_json ops)"
                      },
                      "rc_consumed": {
                        "type": "integer",
                        "description": "Estimated RC consumed by this operation"
                      },
                      "op_seq": {
                        "type": "integer",
                        "description": "Per-account operation sequence number (dense, monotonic with time); pass the last row's value as before_seq to fetch the next page"
                      }
                    }
                  }
                }
              }
            }
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
        "description": "Per-account custom_json activity over a time range, grouped by DApp and the registry-defined category each app belongs to (custom_json_app_registry). Returns a single object with KPI fields (total ops, top category, top DApp), the per-category breakdown (for a donut chart), and the per-DApp breakdown tagged with its category (for a drill-down bar chart) - so the client renders the whole dashboard from one response. The primary metric is op COUNT (custom_json operations signed by the account); RC figures are a calibrated ESTIMATE (rc_op_stats_daily rates sampled from rc_api), as real per-op RC cost is unavailable on this node. Defaults to the last 30 days.",
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
                      "description": "Estimated total RC consumed (op_count*base_rc + op_bytes*byte_rc from rc_op_stats_daily; a calibrated estimate, not real RC spend)"
                    },
                    "top_category": {
                      "type": "string",
                      "nullable": true
                    },
                    "top_dapp": {
                      "type": "string",
                      "nullable": true
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
                            "type": "number"
                          },
                          "rc_estimated": {
                            "type": "integer"
                          },
                          "rc_pct": {
                            "type": "number"
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
                            "type": "number"
                          },
                          "rc_estimated": {
                            "type": "integer"
                          },
                          "rc_pct": {
                            "type": "number"
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
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
        "description": "Time-series of estimated total RC consumption across the network, broken down by operation type, aggregated by the chosen granularity. RC is a calibrated ESTIMATE (op_count*base_rc + op_bytes*byte_rc from rc_op_stats_daily, the rate effective on/before each day), as real per-op RC cost is unavailable on this node.",
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
                  "x-sql-datatype": "TABLE(period TEXT, rc_total BIGINT, by_label JSONB)",
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
                      }
                    }
                  }
                }
              }
            }
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
                        "type": "number",
                        "description": "Percentage of all accounts in this bucket"
                      },
                      "total_hp": {
                        "type": "number",
                        "description": "Total HP held by all accounts in this bucket (sum of actual VESTS-converted balances)"
                      },
                      "pct_hp": {
                        "type": "number",
                        "description": "This bucket's total_hp as a percentage of the sum of all buckets' total_hp"
                      }
                    }
                  }
                }
              }
            }
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
                        "type": "number",
                        "description": "Gini coefficient of HP across all holders (0 = perfect equality, 1 = one account holds everything)",
                        "example": 0.94
                      },
                      "top_1pct_hp_share": {
                        "type": "number",
                        "description": "Percentage of total HP held by the richest 1% of accounts",
                        "example": 71.2
                      },
                      "top_10pct_hp_share": {
                        "type": "number",
                        "description": "Percentage of total HP held by the richest 10% of accounts",
                        "example": 93.4
                      },
                      "total_hp_holders": {
                        "type": "integer",
                        "description": "Number of accounts holding a positive VESTS balance",
                        "example": 164780
                      },
                      "median_hp": {
                        "type": "number",
                        "description": "Median HP per holder",
                        "example": 12.4
                      },
                      "mean_hp": {
                        "type": "number",
                        "description": "Mean HP per holder",
                        "example": 284.1
                      }
                    }
                  }
                }
              }
            }
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
                        "type": "integer",
                        "nullable": true
                      },
                      "active_at_7d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "pct_7d": {
                        "type": "number",
                        "nullable": true
                      },
                      "eligible_at_30d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "active_at_30d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "pct_30d": {
                        "type": "number",
                        "nullable": true
                      },
                      "eligible_at_90d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "active_at_90d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "pct_90d": {
                        "type": "number",
                        "nullable": true
                      }
                    }
                  }
                }
              }
            }
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
                        "type": "integer",
                        "nullable": true
                      },
                      "active_at_30d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "pct_30d": {
                        "type": "number",
                        "nullable": true
                      },
                      "eligible_at_90d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "active_at_90d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "pct_90d": {
                        "type": "number",
                        "nullable": true
                      },
                      "eligible_at_180d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "active_at_180d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "pct_180d": {
                        "type": "number",
                        "nullable": true
                      }
                    }
                  }
                }
              }
            }
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
                        "type": "number",
                        "nullable": true
                      }
                    }
                  }
                }
              }
            }
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
              "x-sql-default-value": "'day'",
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
                        "type": "number"
                      },
                      "avg_comments_per_post": {
                        "type": "number"
                      },
                      "zero_vote_post_pct": {
                        "type": "number"
                      },
                      "zero_comment_post_pct": {
                        "type": "number"
                      }
                    }
                  }
                }
              }
            }
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
          }
        }
      }
    }
  }
}
$$;
-- openapi-generated-code-end
BEGIN
    RETURN openapi;
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
                    (37,500,000) but holds no per-account community rows — i.e. it synced
                    before the community feature and scripts/rebuild_content_volume.sh has
                    not been run yet. get_account_community_activity still answers on such
                    a node, but reports everything under the personal-blog bucket.
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
        --
        -- The install watermark is the primary signal, NOT the presence of rows: a node
        -- replaying from genesis with this feature installed crosses block 37,500,000 long
        -- before the first hive-1NNNNN account exists, so account_community_daily is
        -- legitimately empty for that whole stretch while the dimension is nonetheless
        -- complete by construction. Reporting false there sent operators to a multi-hour
        -- rebuild that repairs nothing. The EXISTS arm is kept as the "the rebuild has run"
        -- signal for genuinely upgraded nodes (and for nodes that rebuilt before the
        -- watermark existed).
        (
            s.last_processed_block < haf_stats_app.community_start_block()
            -- COALESCE is load-bearing: an empty status table makes the subquery NULL, and
            -- `FALSE OR NULL OR FALSE` is NULL, not FALSE — the flag would come back null
            -- instead of reporting "not ready".
            OR COALESCE((
                SELECT cfs.installed_at_block < haf_stats_app.community_start_block()
                FROM haf_stats_app.community_feature_status cfs
                LIMIT 1
            ), FALSE)
            OR EXISTS (SELECT 1 FROM haf_stats_backend.account_community_daily)
        ) AS community_data_ready
    FROM haf_stats_app.app_status s
    LIMIT 1;
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
                    type: string
                    nullable: true
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
-- Feature: per-account RC footprint
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{account}/rc-footprint:
  get:
    tags:
      - Account
    summary: Account RC footprint
    description: >-
      Breakdown of estimated Resource Credit consumption for an account over a time range,
      grouped by operation type or DApp. Counts the ops the account itself signed (the RC
      payer) and prices them from the calibrated rc_op_stats_daily rates; RC is an ESTIMATE
      (op_type uses op_count * average rc_api cost), as real per-op RC cost is unavailable on
      this node.
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
          enum: [op_type, app]
        description: Group results by operation type or DApp
    responses:
      '200':
        description: RC consumption ranked by usage
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(label TEXT, rc_consumed BIGINT, op_count BIGINT, pct NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  label:
                    type: string
                    description: Operation type name or custom_json app ID
                  rc_consumed:
                    type: integer
                  op_count:
                    type: integer
                  pct:
                    type: number
                    description: Percentage of total RC consumed
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_rc_footprint;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_rc_footprint(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "group_by" TEXT = 'op_type'
)
RETURNS TABLE(label TEXT, rc_consumed BIGINT, op_count BIGINT, pct NUMERIC)
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
    IF group_by IS NULL OR group_by NOT IN ('op_type', 'app') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid group_by: ' || COALESCE(group_by, '(null)'),
            HINT = 'Must be one of: op_type, app';
    END IF;

    SELECT id INTO _account_id FROM hafd.accounts WHERE name = account;
    IF _account_id IS NULL THEN
        RETURN;   -- unknown account -> empty result
    END IF;

    -- Estimated RC footprint, computed ON-DEMAND from account_operations (issue #33): the
    -- account's own signed ops are those with account_id = transacting_account_id (the tx
    -- signer = the RC payer), which correctly excludes ops it only received. Virtual ops are
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
    SELECT num INTO _from_block FROM hafd.blocks
        WHERE created_at >= _from::timestamp ORDER BY created_at ASC LIMIT 1;
    SELECT num INTO _to_block FROM hafd.blocks
        WHERE created_at < (_to + 1)::timestamp ORDER BY created_at DESC LIMIT 1;
    IF _from_block IS NULL OR _to_block IS NULL THEN
        RETURN;
    END IF;

    SELECT lo_seq, hi_seq INTO _lo_seq, _hi_seq
    FROM haf_stats_app.account_op_seq_range(_account_id, _from_block, _to_block);
    IF _lo_seq IS NULL OR _hi_seq IS NULL OR _lo_seq > _hi_seq THEN
        RETURN;   -- no ops in the window
    END IF;

    IF group_by = 'op_type' THEN
        -- RC = op_count * avg_cost_rc per op type (op-count model). avg_cost_rc is the rc_api
        -- average for the type, applied at the rate effective on/before each op's day - this
        -- avoids a per-op hafd.operations body join (the on-demand cost driver).
        RETURN QUERY
        WITH acct_ops AS (
            SELECT ao.op_type_id, bv.created_at::DATE AS day, COUNT(*)::BIGINT AS op_count
            FROM hive.account_operations_view ao
            JOIN hafd.blocks bv ON bv.num = ao.block_num
            JOIN hafd.operation_types ot ON ot.id = ao.op_type_id AND ot.is_virtual = FALSE
            WHERE ao.account_id = _account_id
              AND ao.transacting_account_id = ao.account_id
              AND ao.account_op_seq_no BETWEEN _lo_seq AND _hi_seq
              AND ao.block_num BETWEEN _from_block AND _to_block
            GROUP BY ao.op_type_id, bv.created_at::DATE
        ),
        priced AS (
            SELECT
                COALESCE(replace(ot.name, 'hive::protocol::', ''),
                         'op_type_' || ao.op_type_id)                          AS label,
                ao.op_count,
                (ao.op_count * haf_stats_app.rc_avg_cost(ao.op_type_id, ao.day))::BIGINT AS rc
            FROM acct_ops ao
            LEFT JOIN hafd.operation_types ot ON ot.id = ao.op_type_id
        ),
        agg AS (
            SELECT priced.label,
                   SUM(priced.rc)::BIGINT       AS rc_consumed,
                   SUM(priced.op_count)::BIGINT AS op_count
            FROM priced GROUP BY priced.label
        ),
        tot AS (SELECT SUM(agg.rc_consumed) AS gt FROM agg)
        SELECT agg.label, agg.rc_consumed, agg.op_count,
               ROUND(agg.rc_consumed * 100.0 / NULLIF(t.gt, 0), 2)
        FROM agg, tot t
        ORDER BY agg.rc_consumed DESC, agg.label;
    ELSE
        -- group_by = 'app': size-aware custom_json apps from the pre-aggregated
        -- account_custom_json_daily (op_count + op_bytes per json_id, base+byte op-18 rate),
        -- plus one 'non-custom_json' bucket for all other signed ops (op_count * avg_cost).
        -- Each json_id is resolved to its registered DApp name via a longest-prefix
        -- starts_with match against custom_json_app_registry (mirrors
        -- get_account_dapp_footprint); an unmatched id keeps its raw json_id, and
        -- distinct json_ids that map to the same app (e.g. 'sm_' and 'splinterlands')
        -- roll up into a single labelled bucket.
        RETURN QUERY
        WITH cj AS (
            SELECT haf_stats_app.resolve_dapp_name(acj.json_id)  AS label,
                   SUM(acj.op_count)::BIGINT     AS op_count,
                   SUM(acj.op_count * dr.base_rc + acj.op_bytes * dr.byte_rc)::BIGINT AS rc_consumed
            FROM haf_stats_backend.account_custom_json_daily acj
            CROSS JOIN LATERAL haf_stats_app.rc_rate(18::SMALLINT, acj.day) dr
            WHERE acj.account_id = _account_id
              AND acj.day BETWEEN _from AND _to
            GROUP BY haf_stats_app.resolve_dapp_name(acj.json_id)
        ),
        noncj AS (
            SELECT 'non-custom_json'::TEXT       AS label,
                   SUM(t.op_count)::BIGINT        AS op_count,
                   SUM(t.op_count * haf_stats_app.rc_avg_cost(t.op_type_id, t.day))::BIGINT AS rc_consumed
            FROM (
                SELECT ao.op_type_id, bv.created_at::DATE AS day, COUNT(*)::BIGINT AS op_count
                FROM hive.account_operations_view ao
                JOIN hafd.blocks bv ON bv.num = ao.block_num
                JOIN hafd.operation_types ot ON ot.id = ao.op_type_id AND ot.is_virtual = FALSE
                WHERE ao.account_id = _account_id
                  AND ao.transacting_account_id = ao.account_id
                  AND ao.account_op_seq_no BETWEEN _lo_seq AND _hi_seq
                  AND ao.block_num BETWEEN _from_block AND _to_block
                  AND ao.op_type_id <> 18
                GROUP BY ao.op_type_id, bv.created_at::DATE
            ) t
        ),
        combined AS (
            SELECT cj.label, cj.rc_consumed, cj.op_count FROM cj
            UNION ALL
            SELECT noncj.label, noncj.rc_consumed, noncj.op_count FROM noncj WHERE noncj.op_count > 0
        ),
        tot AS (SELECT SUM(combined.rc_consumed) AS gt FROM combined)
        SELECT combined.label, combined.rc_consumed, combined.op_count,
               ROUND(combined.rc_consumed * 100.0 / NULLIF(t.gt, 0), 2)
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
      id), block, timestamp and estimated RC consumed. rc_consumed is an ESTIMATE (op_count model
      priced from the calibrated rc_op_stats_daily rates), as real per-op RC cost is unavailable
      on this node; summing rc_consumed over a window reconciles with the rc-footprint
      group_by=op_type total (the op-count model). Optional op_type_filter / app_filter narrow the
      timeline to the events of one op type or DApp (the same events as the matching rc-footprint
      bucket; per-event rc_consumed stays the op-count estimate, so an app_filter sum matches the
      op_type total, not the byte-aware group_by=app figure). Pages via limit_count/offset_start,
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
              x-sql-datatype: 'TABLE("timestamp" TIMESTAMP, block_num INT, op_type TEXT, app TEXT, custom_json_id TEXT, rc_consumed BIGINT, op_seq BIGINT)'
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
                    type: string
                    nullable: true
                    description: >-
                      Resolved DApp name for custom_json ops (custom_json_app_registry match,
                      falling back to the raw id); null for non-custom_json ops
                  custom_json_id:
                    type: string
                    nullable: true
                    description: Raw custom_json id (null for non-custom_json ops)
                  rc_consumed:
                    type: integer
                    description: Estimated RC consumed by this operation
                  op_seq:
                    type: integer
                    description: >-
                      Per-account operation sequence number (dense, monotonic with time); pass the
                      last row's value as before_seq to fetch the next page
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_account_rc_footprint_timeline;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_account_rc_footprint_timeline(
    "account" TEXT,
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "op_type_filter" TEXT = NULL,
    "app_filter" TEXT = NULL,
    "limit_count" INT = 100,
    "offset_start" INT = 0,
    "before_seq" BIGINT = NULL
)
RETURNS TABLE("timestamp" TIMESTAMP, block_num INT, op_type TEXT, app TEXT, custom_json_id TEXT, rc_consumed BIGINT, op_seq BIGINT)
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
    -- app_filter matches the RESOLVED DApp name (e.g. Splinterlands), so the caller can drill into
    -- the exact get_account_rc_footprint group_by=op_type / group_by=app bucket it clicked.
    _op_type_filter := NULLIF(TRIM('"' FROM COALESCE("op_type_filter", '')), '');
    _app_filter := NULLIF(TRIM('"' FROM COALESCE("app_filter", '')), '');

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

    -- app_filter selects only custom_json (op 18) events; pairing it with an op_type_filter for a
    -- different type is contradictory -> empty.
    IF _app_filter IS NOT NULL AND _filter_op_type_id IS NOT NULL AND _filter_op_type_id <> 18 THEN
        RETURN;
    END IF;

    -- Window bounding (same as get_account_rc_footprint): date range -> block range -> this
    -- account's account_op_seq_no range (binary search), so a narrow window rides the indexed
    -- (account_id, seq) scan instead of the whole history.
    SELECT num INTO _from_block FROM hafd.blocks
        WHERE created_at >= _from::timestamp ORDER BY created_at ASC LIMIT 1;
    SELECT num INTO _to_block FROM hafd.blocks
        WHERE created_at < (_to + 1)::timestamp ORDER BY created_at DESC LIMIT 1;
    IF _from_block IS NULL OR _to_block IS NULL THEN
        RETURN;
    END IF;

    SELECT lo_seq, hi_seq INTO _lo_seq, _hi_seq
    FROM haf_stats_app.account_op_seq_range(_account_id, _from_block, _to_block);
    IF _lo_seq IS NULL OR _hi_seq IS NULL OR _lo_seq > _hi_seq THEN
        RETURN;   -- no ops in the window
    END IF;

    -- One row per signed op (account_id = transacting_account_id = the RC payer). rc_consumed is
    -- the read-time ESTIMATE rc_avg_cost(op_type, day) (issue #33: no per-op RC log exists), so
    -- SUM(rc_consumed) over a window reconciles with the aggregate's group_by=op_type total (the
    -- op-count model). Order by account_op_seq_no DESC alone: within an account it is dense and
    -- MONOTONIC with block_num (the invariant account_op_seq_range relies on), so it equals
    -- timestamp DESC while being served by the (account_id, seq) index - an Index Scan Backward
    -- that stops at OFFSET+LIMIT. Adding the computed block_num to the ORDER BY would instead force
    -- a full-window Sort. app is the resolved DApp name via haf_stats_app.resolve_dapp_name (the
    -- SAME resolver group_by=app uses, so the labels match by construction); custom_json_id keeps
    -- the raw id.
    -- NOTE on app_filter reconciliation: app_filter selects the SET of events in a group_by=app
    -- bucket, but each event's rc_consumed stays the op-count estimate, so SUM over an app_filter
    -- drill-down reconciles with the group_by=op_type custom_json total, NOT the byte-aware
    -- group_by=app bucket figure (the aggregate prices custom_json two ways - flat for op_type,
    -- size-aware for app; the timeline follows the op_type model end to end).
    -- before_seq is the keyset cursor: ORDER BY account_op_seq_no DESC means "seq < before_seq" is
    -- served by the same (account_id, seq) index with no offset walk, so deep paging stays O(1).
    IF _app_filter IS NULL THEN
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
        )
        SELECT
            bv.created_at::TIMESTAMP,
            page.block_num,
            replace(ot.name, 'hive::protocol::', ''),
            CASE WHEN page.op_type_id = 18
                 THEN haf_stats_app.resolve_dapp_name(ov.body -> 'value' ->> 'id') END,
            CASE WHEN page.op_type_id = 18 THEN ov.body -> 'value' ->> 'id' END,
            haf_stats_app.rc_avg_cost(page.op_type_id, bv.created_at::DATE)::BIGINT,
            page.account_op_seq_no::BIGINT
        FROM page
        JOIN hafd.blocks bv ON bv.num = page.block_num
        JOIN hafd.operation_types ot ON ot.id = page.op_type_id
        LEFT JOIN hive.operations_view ov ON page.op_type_id = 18 AND ov.id = page.operation_id
        ORDER BY page.account_op_seq_no DESC;
    ELSE
        -- app filter set. The resolved DApp name is a body-derived value, so filtering on it via a
        -- raw op-18 body scan is O(op-18 count in the window) and can't early-terminate for a rare
        -- or absent app (a heavy game account -> tens of seconds). Instead resolve the candidate
        -- json_ids from the per-account custom_json rollup (account_custom_json_daily, the same
        -- table + signer attribution get_account_rc_footprint group_by=app trusts): the resolver
        -- runs once per DISTINCT id the account used (~dozens), not per event. If none resolve to
        -- app_filter, the account never signed that DApp in the window -> return empty WITHOUT
        -- touching the raw op stream (the op-volume-independent fast path). Otherwise scan the raw
        -- op-18 rows filtered by the exact json_id set (a plain = ANY match, no per-row resolver),
        -- which the (account_id, seq) index still serves backward and early-terminates at
        -- OFFSET+LIMIT / before_seq. NOTE: this ties app_filter to the rollup's freshness the same
        -- way group_by=app already is; per-event rc_consumed stays the op-count estimate.
        SELECT ARRAY(
            SELECT acj.json_id
            FROM haf_stats_backend.account_custom_json_daily acj
            WHERE acj.account_id = _account_id
              AND acj.day BETWEEN _from AND _to
            GROUP BY acj.json_id
            HAVING haf_stats_app.resolve_dapp_name(acj.json_id) = _app_filter
        ) INTO _matching_ids;
        IF _matching_ids IS NULL OR cardinality(_matching_ids) = 0 THEN
            RETURN;
        END IF;

        RETURN QUERY
        WITH page AS (
            SELECT ao.block_num,
                   ao.account_op_seq_no,
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
        )
        SELECT
            bv.created_at::TIMESTAMP,
            page.block_num,
            'custom_json_operation'::TEXT,
            _app_filter,
            page.json_id,
            haf_stats_app.rc_avg_cost(18::SMALLINT, bv.created_at::DATE)::BIGINT,
            page.account_op_seq_no::BIGINT
        FROM page
        JOIN hafd.blocks bv ON bv.num = page.block_num
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
      (custom_json operations signed by the account); RC figures are a calibrated ESTIMATE
      (rc_op_stats_daily rates sampled from rc_api), as real per-op RC cost is unavailable on
      this node. Defaults to the last 30 days.
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
                  description: Estimated total RC consumed (op_count*base_rc + op_bytes*byte_rc from rc_op_stats_daily; a calibrated estimate, not real RC spend)
                top_category:
                  type: string
                  nullable: true
                top_dapp:
                  type: string
                  nullable: true
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
                        type: number
                      rc_estimated:
                        type: integer
                      rc_pct:
                        type: number
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
                        type: number
                      rc_estimated:
                        type: integer
                      rc_pct:
                        type: number
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
            'total_ops', 0, 'total_rc_estimated', 0, 'top_category', NULL, 'top_dapp', NULL,
            'categories', '[]'::jsonb, 'dapps', '[]'::jsonb);
    END IF;

    -- Per-day estimated RC (issue #33): each activity day is priced at the custom_json
    -- (op_type 18) rate effective on/before that day, so historical activity keeps its era's
    -- rate as the rc_op_stats_daily series grows. Activity predating every sampled rate falls
    -- back to the earliest sample, and an empty rate table to the seeded constants, so the
    -- estimate is never zeroed. The rate is resolved ONCE per distinct activity day (not per
    -- (json_id, day) row) so cost stays bounded as the rate history grows.
    WITH day_rate AS (
        SELECT
            d.day,
            COALESCE(rate.base_rc, 23428456) AS base_rc,
            COALESCE(rate.byte_rc, 475000)   AS byte_rc
        FROM (
            SELECT DISTINCT acj.day
            FROM haf_stats_backend.account_custom_json_daily acj
            WHERE acj.account_id = _account_id
              AND acj.day BETWEEN _from AND _to
        ) d
        LEFT JOIN LATERAL (
            SELECT r.base_rc, r.byte_rc
            FROM haf_stats_backend.rc_op_stats_daily r
            WHERE r.op_type_id = 18
            ORDER BY (r.day <= d.day) DESC,
                     CASE WHEN r.day <= d.day THEN r.day END DESC,
                     r.day ASC
            LIMIT 1
        ) rate ON TRUE
    ),
    -- Price each (json_id, day) row at its day's rate and roll up to json_id, then resolve
    -- each to its registered app + category via a longest-prefix starts_with match against
    -- custom_json_app_registry (an unmatched id falls to 'Uncategorized' with the raw id as
    -- the app name). Rolled up to apps (drill-down bars) and categories (donut); all in one object.
    per_json AS (
        SELECT
            acj.json_id,
            SUM(acj.op_count)::BIGINT AS op_count,
            SUM(acj.op_count * dr.base_rc + acj.op_bytes * dr.byte_rc)::BIGINT AS rc_consumed
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
            pj.rc_consumed
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
        SELECT category, app_name, SUM(op_count) AS op_count, SUM(rc_consumed) AS rc_consumed
        FROM resolved GROUP BY category, app_name
    ),
    per_cat AS (
        SELECT category, SUM(op_count) AS op_count, SUM(rc_consumed) AS rc_consumed
        FROM resolved GROUP BY category
    ),
    tot AS (SELECT COALESCE(SUM(op_count), 0) AS total, COALESCE(SUM(rc_consumed), 0) AS total_rc FROM resolved)
    SELECT jsonb_build_object(
        'account', "account",
        'from_date', _from,
        'to_date', _to,
        'total_ops', (SELECT total FROM tot),
        -- total_rc is a calibrated ESTIMATE (rc_op_stats_daily rates), not real RC spend.
        'total_rc_estimated', (SELECT total_rc FROM tot),
        'top_category', (SELECT category FROM per_cat ORDER BY op_count DESC, category LIMIT 1),
        'top_dapp', (SELECT app_name FROM per_app ORDER BY op_count DESC, app_name LIMIT 1),
        'categories', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'category', category,
                       'op_count', op_count,
                       'pct', ROUND(op_count * 100.0 / NULLIF((SELECT total FROM tot), 0), 2),
                       'rc_estimated', rc_consumed,
                       'rc_pct', ROUND(rc_consumed * 100.0 / NULLIF((SELECT total_rc FROM tot), 0), 2))
                       ORDER BY op_count DESC, category)
            FROM per_cat), '[]'::jsonb),
        'dapps', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'category', category,
                       'app_name', app_name,
                       'op_count', op_count,
                       'pct', ROUND(op_count * 100.0 / NULLIF((SELECT total FROM tot), 0), 2),
                       'rc_estimated', rc_consumed,
                       'rc_pct', ROUND(rc_consumed * 100.0 / NULLIF((SELECT total_rc FROM tot), 0), 2))
                       ORDER BY op_count DESC, app_name)
            FROM per_app), '[]'::jsonb)
    ) INTO _result;

    RETURN _result;
END;
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
      Time-series of estimated total RC consumption across the network, broken down by
      operation type, aggregated by the chosen granularity. RC is a calibrated ESTIMATE
      (op_count*base_rc + op_bytes*byte_rc from rc_op_stats_daily, the rate effective on/before
      each day), as real per-op RC cost is unavailable on this node.
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
              x-sql-datatype: "TABLE(period TEXT, rc_total BIGINT, by_label JSONB)"
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
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_rc_utilization;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_rc_utilization(
    "from_date" TEXT = NULL,
    "to_date" TEXT = NULL,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, rc_total BIGINT, by_label JSONB)
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
    -- Resolve each op type's rate schedule into [valid_from, valid_to) intervals ONCE (the rate
    -- is a step function -- rc_op_stats_daily holds only a handful of dated samples per op type),
    -- then range-join each network_op_daily row to the interval covering its day and price it.
    -- RC = op_count*base_rc + op_bytes*byte_rc. Days before the earliest sample use that earliest
    -- sample (rn = 1); days with no rate row at all fall back to generic constants via COALESCE.
    -- This replaces a per-(op_type, day) LATERAL that re-scanned the rate table once per pair
    -- (~100k times over full history) and dominated the latency; the as-of join is ~10x faster
    -- with identical output (issue #35).
    WITH rate_iv AS (
        SELECT
            r.op_type_id,
            r.base_rc,
            r.byte_rc,
            r.day                                                            AS valid_from,
            LEAD(r.day)    OVER (PARTITION BY r.op_type_id ORDER BY r.day)    AS valid_to,
            ROW_NUMBER()   OVER (PARTITION BY r.op_type_id ORDER BY r.day)    AS rn
        FROM haf_stats_backend.rc_op_stats_daily r
    ),
    priced AS (
        SELECT
            DATE_TRUNC(granularity, nod.day)                                AS period,
            COALESCE(replace(ot.name, 'hive::protocol::', ''),
                     'op_type_' || nod.op_type_id)                          AS label,
            (nod.op_count  * COALESCE(ri.base_rc, 120000000)
             + nod.op_bytes * COALESCE(ri.byte_rc, 475000))::BIGINT         AS rc
        FROM haf_stats_backend.network_op_daily nod
        LEFT JOIN rate_iv ri
               ON ri.op_type_id = nod.op_type_id
              AND (nod.day < ri.valid_to OR ri.valid_to IS NULL)
              AND (nod.day >= ri.valid_from OR ri.rn = 1)
        LEFT JOIN hafd.operation_types ot ON ot.id = nod.op_type_id
        WHERE nod.day BETWEEN _from AND _to
    ),
    per_label AS (
        -- Qualify period/label: bare "period" collides with the RETURNS TABLE OUT variable.
        SELECT priced.period, priced.label, SUM(priced.rc)::BIGINT AS rc_label_total
        FROM priced
        GROUP BY priced.period, priced.label
    )
    SELECT
        TO_CHAR(per_label.period, 'YYYY-MM-DD')                     AS period,
        SUM(per_label.rc_label_total)::BIGINT                       AS rc_total,
        jsonb_object_agg(per_label.label, per_label.rc_label_total) AS by_label
    FROM per_label
    GROUP BY per_label.period
    ORDER BY 1;
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
                    type: number
                    description: Percentage of all accounts in this bucket
                  total_hp:
                    type: number
                    description: Total HP held by all accounts in this bucket (sum of actual VESTS-converted balances)
                  pct_hp:
                    type: number
                    description: This bucket's total_hp as a percentage of the sum of all buckets' total_hp
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
                    type: number
                    description: Gini coefficient of HP across all holders (0 = perfect equality, 1 = one account holds everything)
                    example: 0.94
                  top_1pct_hp_share:
                    type: number
                    description: Percentage of total HP held by the richest 1% of accounts
                    example: 71.2
                  top_10pct_hp_share:
                    type: number
                    description: Percentage of total HP held by the richest 10% of accounts
                    example: 93.4
                  total_hp_holders:
                    type: integer
                    description: Number of accounts holding a positive VESTS balance
                    example: 164780
                  median_hp:
                    type: number
                    description: Median HP per holder
                    example: 12.4
                  mean_hp:
                    type: number
                    description: Mean HP per holder
                    example: 284.1
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
                    type: integer
                    nullable: true
                  active_at_7d:
                    type: integer
                    nullable: true
                  pct_7d:
                    type: number
                    nullable: true
                  eligible_at_30d:
                    type: integer
                    nullable: true
                  active_at_30d:
                    type: integer
                    nullable: true
                  pct_30d:
                    type: number
                    nullable: true
                  eligible_at_90d:
                    type: integer
                    nullable: true
                  active_at_90d:
                    type: integer
                    nullable: true
                  pct_90d:
                    type: number
                    nullable: true
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
                    type: integer
                    nullable: true
                  active_at_30d:
                    type: integer
                    nullable: true
                  pct_30d:
                    type: number
                    nullable: true
                  eligible_at_90d:
                    type: integer
                    nullable: true
                  active_at_90d:
                    type: integer
                    nullable: true
                  pct_90d:
                    type: number
                    nullable: true
                  eligible_at_180d:
                    type: integer
                    nullable: true
                  active_at_180d:
                    type: integer
                    nullable: true
                  pct_180d:
                    type: number
                    nullable: true
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
                    type: number
                    nullable: true
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
          x-sql-default-value: "'day'"
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
                    type: number
                  avg_comments_per_post:
                    type: number
                  zero_vote_post_pct:
                    type: number
                  zero_comment_post_pct:
                    type: number
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
    -- (natural column, desc) we keep the existing covering-index fast paths byte-for-byte.
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
    -- we fall through to the existing covering-index fast paths below (byte-identical to
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
            -- pre-summed per-account rollup — no re-aggregation, so top-N is an Index-Only Scan
            -- on idx_afa_reward_rank (~0.1ms) rather than a GroupAggregate over ~2M rows. _alltime
            -- is Var-free ⇒ a one-time filter, so exactly one of these two arms scans (#38).
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
            -- all-time fast path: DIRECT index-ordered read (Index-Only Scan on
            -- idx_afa_transfer_rank), no re-aggregation (#38). One-time filter picks one arm.
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

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;

RESET ROLE;
