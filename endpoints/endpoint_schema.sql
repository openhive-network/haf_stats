SET ROLE haf_stats_owner;

/** openapi
openapi: 3.1.0
info:
  title: HAF Stats — Blockchain Analytics
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
-- root() — serves the full OpenAPI spec at GET /
-- ---------------------------------------------------------------------------

DO $__$
DECLARE
    swagger_url TEXT;
BEGIN
    swagger_url := COALESCE(current_setting('custom.swagger_url', TRUE), 'localhost');

    EXECUTE FORMAT(
        'CREATE OR REPLACE FUNCTION haf_stats_endpoints.root() RETURNS json
        LANGUAGE plpgsql STABLE
        AS $_$
        DECLARE
        -- openapi-spec
-- openapi-generated-code-begin
  openapi json = $$
{
  "openapi": "3.1.0",
  "info": {
    "title": "HAF Stats \u00e2\u20ac\u201d Blockchain Analytics",
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
        "description": "Returns service health and last processed block number.",
        "operationId": "haf_stats_endpoints.get_health",
        "responses": {
          "200": {
            "description": "Health status",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(status TEXT, last_processed_block INT, version TEXT)",
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
                    }
                  }
                }
              }
            }
          }
        }
      }
    },
    "/account/{_account}/financial-summary": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account financial summary",
        "description": "Aggregated HBD/HIVE/VESTS flows for an account over a time range, grouped by financial category and direction (in/out).",
        "operationId": "haf_stats_endpoints.get_account_financial_summary",
        "parameters": [
          {
            "in": "path",
            "name": "_account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "_from",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '1 year')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 1 year ago"
          },
          {
            "in": "query",
            "name": "_to",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "NOW()::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "End date (inclusive), defaults to today"
          },
          {
            "in": "query",
            "name": "_granularity",
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
                        "type": "string"
                      },
                      "direction": {
                        "type": "string",
                        "enum": [
                          "in",
                          "out"
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
    "/account/{_account}/rc-footprint": {
      "get": {
        "tags": [
          "Account"
        ],
        "summary": "Account RC footprint",
        "description": "Breakdown of Resource Credit consumption for an account over a time range, grouped by operation type or DApp.",
        "operationId": "haf_stats_endpoints.get_account_rc_footprint",
        "parameters": [
          {
            "in": "path",
            "name": "_account",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Hive account name"
          },
          {
            "in": "query",
            "name": "_from",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '30 days')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "_to",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "NOW()::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "End date (inclusive), defaults to today"
          },
          {
            "in": "query",
            "name": "_group_by",
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
    "/network/rc-utilization": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Network RC utilization",
        "description": "Time-series of total RC consumption across the network, broken down by operation type or DApp, aggregated by the chosen granularity.",
        "operationId": "haf_stats_endpoints.get_network_rc_utilization",
        "parameters": [
          {
            "in": "query",
            "name": "_from",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '30 days')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "_to",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "NOW()::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "End date (inclusive), defaults to today"
          },
          {
            "in": "query",
            "name": "_granularity",
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
        "description": "Bucketed distribution of Hive Power (HP) stake across all accounts. Reads from btracker_app \u00e2\u20ac\u201d requires cross-schema grant.",
        "operationId": "haf_stats_endpoints.get_network_hp_distribution",
        "responses": {
          "200": {
            "description": "HP distribution buckets ordered from smallest to largest",
            "content": {
              "application/json": {
                "schema": {
                  "x-sql-datatype": "TABLE(bucket TEXT, account_count BIGINT, pct_accounts NUMERIC)",
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "bucket": {
                        "type": "string",
                        "example": "1\u00e2\u20ac\u201c10 HP"
                      },
                      "account_count": {
                        "type": "integer"
                      },
                      "pct_accounts": {
                        "type": "number",
                        "description": "Percentage of all accounts in this bucket"
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
        -- openapi-generated-code-begin
          openapi json = $${}$$;
        -- openapi-generated-code-end
        BEGIN
          RETURN openapi;
        END
        $_$;'
    , swagger_url);
END
$__$;

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
    description: Returns service health and last processed block number.
    operationId: haf_stats_endpoints.get_health
    responses:
      '200':
        description: Health status
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(status TEXT, last_processed_block INT, version TEXT)"
              type: object
              properties:
                status:
                  type: string
                  example: ok
                last_processed_block:
                  type: integer
                version:
                  type: string
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_health;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_health()
RETURNS TABLE(status TEXT, last_processed_block INT, version TEXT) 
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        'ok'::TEXT                                               AS status,
        s.last_processed_block,
        (SELECT git_hash FROM haf_stats_app.app_version LIMIT 1) AS version
    FROM haf_stats_app.app_status s
    LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-account financial summary
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{_account}/financial-summary:
  get:
    tags:
      - Account
    summary: Account financial summary
    description: >-
      Aggregated HBD/HIVE/VESTS flows for an account over a time range,
      grouped by financial category and direction (in/out).
    operationId: haf_stats_endpoints.get_account_financial_summary
    parameters:
      - in: path
        name: _account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: _from
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '1 year')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 1 year ago
      - in: query
        name: _to
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
      - in: query
        name: _granularity
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
                  direction:
                    type: string
                    enum: [in, out]
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
    "_account" TEXT,
    "_from" DATE = (NOW() - INTERVAL '1 year')::DATE,
    "_to" DATE = NOW()::DATE,
    "_granularity" TEXT = 'month'
)
RETURNS TABLE(period TEXT, category TEXT, direction TEXT, hive_nai BIGINT, hbd_nai BIGINT, vests_nai BIGINT, op_count INT) 
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        TO_CHAR(DATE_TRUNC(_granularity, afd.day), 'YYYY-MM-DD') AS period,
        afd.category,
        afd.direction,
        SUM(afd.hive_nai)::BIGINT,
        SUM(afd.hbd_nai)::BIGINT,
        SUM(afd.vests_nai)::BIGINT,
        SUM(afd.op_count)::INT
    FROM haf_stats_backend.account_financial_daily afd
    JOIN hafd.accounts ha ON ha.id = afd.account_id
    WHERE ha.name  = _account
      AND afd.day BETWEEN _from AND _to
    GROUP BY 1, 2, 3
    ORDER BY 1, 2, 3;
$$;

-- ---------------------------------------------------------------------------
-- Feature: per-account RC footprint
-- ---------------------------------------------------------------------------

/** openapi:paths
/account/{_account}/rc-footprint:
  get:
    tags:
      - Account
    summary: Account RC footprint
    description: >-
      Breakdown of Resource Credit consumption for an account over a time range,
      grouped by operation type or DApp.
    operationId: haf_stats_endpoints.get_account_rc_footprint
    parameters:
      - in: path
        name: _account
        required: true
        schema:
          type: string
        description: Hive account name
      - in: query
        name: _from
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago
      - in: query
        name: _to
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
      - in: query
        name: _group_by
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
    "_account" TEXT,
    "_from" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "_to" DATE = NOW()::DATE,
    "_group_by" TEXT = 'op_type'
)
RETURNS TABLE(label TEXT, rc_consumed BIGINT, op_count BIGINT, pct NUMERIC) 
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    WITH base AS (
        SELECT
            CASE _group_by
                WHEN 'app' THEN COALESCE(rol.custom_json_id, 'non-custom_json')
                ELSE            COALESCE(ot.name, 'unknown')
            END      AS label,
            rol.rc_cost
        FROM haf_stats_backend.rc_operation_log rol
        JOIN hafd.accounts a ON a.id = rol.account_id
        LEFT JOIN hive.operation_types ot ON ot.id = rol.op_type_id
        WHERE a.name             = _account
          AND rol.timestamp::DATE BETWEEN _from AND _to
    ),
    totals AS (SELECT SUM(rc_cost) AS grand_total FROM base)
    SELECT
        label,
        SUM(rc_cost)::BIGINT                                          AS rc_consumed,
        COUNT(*)::BIGINT                                              AS op_count,
        ROUND(SUM(rc_cost) * 100.0 / NULLIF(t.grand_total, 0), 2)   AS pct
    FROM base, totals t
    GROUP BY label, t.grand_total
    ORDER BY rc_consumed DESC;
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
      Time-series of total RC consumption across the network, broken down
      by operation type or DApp, aggregated by the chosen granularity.
    operationId: haf_stats_endpoints.get_network_rc_utilization
    parameters:
      - in: query
        name: _from
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago
      - in: query
        name: _to
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
      - in: query
        name: _granularity
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
    "_from" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "_to" DATE = NOW()::DATE,
    "_granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, rc_total BIGINT, by_label JSONB) 
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        TO_CHAR(DATE_TRUNC(_granularity, rol."timestamp"), 'YYYY-MM-DD') AS period,
        SUM(rol.rc_cost)::BIGINT                                          AS rc_total,
        jsonb_object_agg(
            COALESCE(rol.custom_json_id, ot.name, 'unknown'),
            SUM(rol.rc_cost)::BIGINT
        )                                                                 AS by_label
    FROM haf_stats_backend.rc_operation_log rol
    LEFT JOIN hive.operation_types ot ON ot.id = rol.op_type_id
    WHERE rol."timestamp"::DATE BETWEEN _from AND _to
    GROUP BY DATE_TRUNC(_granularity, rol."timestamp")
    ORDER BY 1;
$$;

-- ---------------------------------------------------------------------------
-- Feature: network HP stake distribution (bucketed)
-- Reads cross-schema from btracker_app (Balance Tracker).
-- Requires: GRANT SELECT ON btracker_app.current_account_balances TO haf_stats_user
--
-- TODO: calibrate VESTS thresholds against live data. Current values assume
-- ~2,000,000,000 raw units per HP (VESTS precision=6, 1 HP ≈ 2000 VESTS).
-- Run: SELECT MIN(balance), MAX(balance), AVG(balance)
--      FROM btracker_app.current_account_balances WHERE nai = '@@000000037';
-- to verify the unit scale before deploying.
-- ---------------------------------------------------------------------------

/** openapi:paths
/network/hp-distribution:
  get:
    tags:
      - Network
    summary: HP stake distribution
    description: >-
      Bucketed distribution of Hive Power (HP) stake across all accounts.
      Reads from btracker_app — requires cross-schema grant.
    operationId: haf_stats_endpoints.get_network_hp_distribution
    responses:
      '200':
        description: HP distribution buckets ordered from smallest to largest
        content:
          application/json:
            schema:
              x-sql-datatype: "TABLE(bucket TEXT, account_count BIGINT, pct_accounts NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  bucket:
                    type: string
                    example: "1–10 HP"
                  account_count:
                    type: integer
                  pct_accounts:
                    type: number
                    description: Percentage of all accounts in this bucket
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_hp_distribution;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_hp_distribution()
RETURNS TABLE(bucket TEXT, account_count BIGINT, pct_accounts NUMERIC) 
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    WITH balances AS (
        SELECT
            CASE
                WHEN balance < 2000000000            THEN '0–1 HP'
                WHEN balance < 20000000000           THEN '1–10 HP'
                WHEN balance < 200000000000          THEN '10–100 HP'
                WHEN balance < 2000000000000         THEN '100–1K HP'
                WHEN balance < 20000000000000        THEN '1K–10K HP'
                WHEN balance < 200000000000000       THEN '10K–100K HP'
                WHEN balance < 2000000000000000      THEN '100K–1M HP'
                ELSE                                      '1M+ HP'
            END   AS bucket,
            COUNT(*) AS cnt
        FROM btracker_app.current_account_balances
        WHERE nai = '@@000000037'
          AND balance > 0
        GROUP BY 1
    ),
    total AS (SELECT SUM(cnt) AS n FROM balances)
    SELECT
        bucket,
        cnt::BIGINT                              AS account_count,
        ROUND(cnt * 100.0 / total.n, 2)         AS pct_accounts
    FROM balances, total
    ORDER BY
        CASE bucket
            WHEN '0–1 HP'      THEN 1
            WHEN '1–10 HP'     THEN 2
            WHEN '10–100 HP'   THEN 3
            WHEN '100–1K HP'   THEN 4
            WHEN '1K–10K HP'   THEN 5
            WHEN '10K–100K HP' THEN 6
            WHEN '100K–1M HP'  THEN 7
            ELSE                    8
        END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;

RESET ROLE;
