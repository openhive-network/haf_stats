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
        "description": "Per-account posting and engagement summary \u2014 posts, comments, votes cast, votes received, replies received, and author rewards \u2014 aggregated by the chosen granularity. Author reward figures are sourced from the account's financial daily aggregates.",
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
                        "description": "Root posts authored (parent_author = '')"
                      },
                      "comments": {
                        "type": "integer",
                        "description": "Replies authored (parent_author <> '')"
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
    "/network/account-funnel": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "New account cohort retention",
        "description": "Day-7, day-30, and day-90 retention for all newly created accounts, including accounts created through legacy pow/pow2 mining. An account is retained at day N when it signs at least one non-virtual operation during the exact 24-hour window [N, N+1) days after creation. Results are grouped by creation month; active_at_Nd is null until every account in that cohort has completed the corresponding observation window.",
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
                  "x-sql-datatype": "TABLE(cohort_month TEXT, new_accounts INT, active_at_7d INT, pct_7d NUMERIC, active_at_30d INT, pct_30d NUMERIC, active_at_90d INT, pct_90d NUMERIC)",
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
                      "active_at_7d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "pct_7d": {
                        "type": "number",
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
        "description": "Month cohorts of accounts whose first-ever root post falls in the cohort month, with the share that created content again in the 30-, 90-, and 180-day windows after that first post day. \"Created content again\" means a new post or comment create under chain comment_operation semantics; edits are excluded. Windows are contiguous and non-overlapping: (0,30], (30,90], and (90,180] days. Results are grouped by first-post month; active_at_Nd is null until the full cohort month plus that observation horizon has elapsed. The usual retention decay ordering is empirical, not a mathematical guarantee.",
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
                  "x-sql-datatype": "TABLE(cohort_month TEXT, first_post_accounts INT, active_at_30d INT, pct_30d NUMERIC, active_at_90d INT, pct_90d NUMERIC, active_at_180d INT, pct_180d NUMERIC)",
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
                      "active_at_30d": {
                        "type": "integer",
                        "nullable": true
                      },
                      "pct_30d": {
                        "type": "number",
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
        "description": "Top N accounts ranked by the chosen metric. Reward and transfer metrics sum haf_stats financial data over [from_date, to_date]; transaction_count sums authored (signed) operations over the same range; hp_balance ranks the CURRENT own vesting balance from balance_tracker and ignores from_date/to_date (empty result if no balance_tracker schema is readable on the deployment). Sort keys - author_rewards and curation_rewards: vests, then hbd, then hive sums; transfer_volume_in/out: hive, then hbd sums; transaction_count: op count; hp_balance: vesting balance. Ties broken by account id (creation order). Value fields not applicable to a metric are 0.",
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
            "description": "Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago; ignored for hp_balance"
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
      financial daily aggregates.
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
                    description: Root posts authored (parent_author = '')
                  comments:
                    type: integer
                    description: Replies authored (parent_author <> '')
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
        RETURN QUERY
        WITH cj AS (
            SELECT acj.json_id                  AS label,
                   SUM(acj.op_count)::BIGINT     AS op_count,
                   SUM(acj.op_count * dr.base_rc + acj.op_bytes * dr.byte_rc)::BIGINT AS rc_consumed
            FROM haf_stats_backend.account_custom_json_daily acj
            CROSS JOIN LATERAL haf_stats_app.rc_rate(18::SMALLINT, acj.day) dr
            WHERE acj.account_id = _account_id
              AND acj.day BETWEEN _from AND _to
            GROUP BY acj.json_id
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
            ORDER BY LENGTH(reg.app_id_pattern) DESC
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
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '30 days')::DATE);
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
    -- Resolve the effective rate per (op_type, day) ONCE for the distinct pairs in range (the
    -- rate on/before that day; else the earliest sample; else generic constants), then price
    -- each network_op_daily row and roll up per period. RC = op_count*base_rc + op_bytes*byte_rc.
    WITH op_days AS (
        SELECT DISTINCT nod.op_type_id, nod.day
        FROM haf_stats_backend.network_op_daily nod
        WHERE nod.day BETWEEN _from AND _to
    ),
    day_rate AS (
        SELECT
            od.op_type_id,
            od.day,
            COALESCE(rate.base_rc, 120000000) AS base_rc,
            COALESCE(rate.byte_rc, 475000)    AS byte_rc
        FROM op_days od
        LEFT JOIN LATERAL (
            SELECT r.base_rc, r.byte_rc
            FROM haf_stats_backend.rc_op_stats_daily r
            WHERE r.op_type_id = od.op_type_id
            ORDER BY (r.day <= od.day) DESC,
                     CASE WHEN r.day <= od.day THEN r.day END DESC,
                     r.day ASC
            LIMIT 1
        ) rate ON TRUE
    ),
    priced AS (
        SELECT
            DATE_TRUNC(granularity, nod.day)                                AS period,
            COALESCE(replace(ot.name, 'hive::protocol::', ''),
                     'op_type_' || nod.op_type_id)                          AS label,
            (nod.op_count * dr.base_rc + nod.op_bytes * dr.byte_rc)::BIGINT  AS rc
        FROM haf_stats_backend.network_op_daily nod
        JOIN day_rate dr ON dr.op_type_id = nod.op_type_id AND dr.day = nod.day
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
AS $_$
DECLARE
    -- balance_tracker installs under different schemas depending on deployment:
    -- standalone (btracker_app) vs. installed via the block explorer, which
    -- exposes current balances as a btracker_backend view and/or the hafbe_bal
    -- base table. Resolve the first current-balances relation this role can read.
    -- information_schema.tables only lists relations we have privileges on, so the
    -- pick is guaranteed to both exist and be readable; if none is found the
    -- endpoint returns [] (documented contract), same as a fresh node.
    _balance_rel TEXT;
BEGIN
    SELECT format('%I.%I', t.table_schema, t.table_name)
      INTO _balance_rel
      FROM (VALUES
                ('btracker_app',     'current_account_balances',      1),
                ('btracker_backend', 'current_account_balances_view',  2),
                ('hafbe_bal',        'current_account_balances',      3)
            ) AS cand (sch, rel, prio)
      JOIN information_schema.tables t
        ON t.table_schema = cand.sch AND t.table_name = cand.rel
     ORDER BY cand.prio
     LIMIT 1;

    IF _balance_rel IS NULL THEN
        RETURN;  -- no readable balance relation on this deployment
    END IF;

    -- #20.5: if hafd.blocks is empty (fresh node) the ratio CTE yields no row and
    -- the result is [] (HTTP 200) rather than an error - intentional graceful
    -- degradation; the empty-array contract is documented in the OpenAPI spec.
    -- _balance_rel is built from format('%I.%I', ...) over a fixed allowlist, so
    -- interpolating it (%s) into the dynamic query is injection-safe.
    RETURN QUERY EXECUTE format($q$
        WITH ratio AS (
            SELECT (total_vesting_shares::NUMERIC * 1000)
                   / NULLIF(total_vesting_fund_hive, 0) AS r
            FROM hafd.blocks
            ORDER BY num DESC
            LIMIT 1
        ),
        balances AS (
            SELECT
                CASE
                    WHEN b.balance < 1       * r.r THEN '0-1 HP'
                    WHEN b.balance < 10      * r.r THEN '1-10 HP'
                    WHEN b.balance < 100     * r.r THEN '10-100 HP'
                    WHEN b.balance < 1000    * r.r THEN '100-1K HP'
                    WHEN b.balance < 10000   * r.r THEN '1K-10K HP'
                    WHEN b.balance < 100000  * r.r THEN '10K-100K HP'
                    WHEN b.balance < 1000000 * r.r THEN '100K-1M HP'
                    ELSE                               '1M+ HP'
                END   AS bucket,
                COUNT(*)       AS cnt,
                -- Sum of actual VESTS balances in the bucket. For the unbounded 1M+
                -- bucket this is the real total, not a midpoint estimate (#28).
                SUM(b.balance) AS vests
            FROM %s b, ratio r
            WHERE b.nai = 37   -- VESTS (btracker nai smallint code: 13=HBD, 21=HIVE, 37=VESTS)
              AND b.balance > 0
            GROUP BY 1
        ),
        total AS (SELECT SUM(cnt) AS n, SUM(vests) AS v FROM balances)
        SELECT
            balances.bucket,
            cnt::BIGINT                              AS account_count,
            ROUND(cnt * 100.0 / total.n, 2)         AS pct_accounts,
            -- HP = VESTS / ratio (same conversion the bucket boundaries use).
            ROUND(balances.vests / NULLIF(ratio.r, 0), 2)         AS total_hp,
            -- Bucket's share of total HP; the ratio cancels, so this is the
            -- bucket's share of total VESTS.
            ROUND(balances.vests * 100.0 / NULLIF(total.v, 0), 2) AS pct_hp
        FROM balances, total, ratio
        ORDER BY
            CASE balances.bucket
                WHEN '0-1 HP'      THEN 1
                WHEN '1-10 HP'     THEN 2
                WHEN '10-100 HP'   THEN 3
                WHEN '100-1K HP'   THEN 4
                WHEN '1K-10K HP'   THEN 5
                WHEN '10K-100K HP' THEN 6
                WHEN '100K-1M HP'  THEN 7
                ELSE                    8
            END
    $q$, _balance_rel);
END
$_$;

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
      Day-7, day-30, and day-90 retention for all newly created accounts,
      including accounts created through legacy pow/pow2 mining. An account is
      retained at day N when it signs at least one non-virtual operation during
      the exact 24-hour window [N, N+1) days after creation. Results are grouped
      by creation month; active_at_Nd is null until every account in that
      cohort has completed the corresponding observation window.
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
              x-sql-datatype: "TABLE(cohort_month TEXT, new_accounts INT, active_at_7d INT, pct_7d NUMERIC, active_at_30d INT, pct_30d NUMERIC, active_at_90d INT, pct_90d NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  cohort_month:
                    type: string
                    example: "2026-01"
                  new_accounts:
                    type: integer
                  active_at_7d:
                    type: integer
                    nullable: true
                  pct_7d:
                    type: number
                    nullable: true
                  active_at_30d:
                    type: integer
                    nullable: true
                  pct_30d:
                    type: number
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
RETURNS TABLE(cohort_month TEXT, new_accounts INT, active_at_7d INT, pct_7d NUMERIC, active_at_30d INT, pct_30d NUMERIC, active_at_90d INT, pct_90d NUMERIC)
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        TO_CHAR(acr.cohort_month, 'YYYY-MM')                                   AS cohort_month,
        acr.new_accounts,
        acr.active_at_7d,
        ROUND(acr.active_at_7d  * 100.0 / NULLIF(acr.new_accounts, 0), 1)     AS pct_7d,
        acr.active_at_30d,
        ROUND(acr.active_at_30d * 100.0 / NULLIF(acr.new_accounts, 0), 1)     AS pct_30d,
        acr.active_at_90d,
        ROUND(acr.active_at_90d * 100.0 / NULLIF(acr.new_accounts, 0), 1)     AS pct_90d
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
      (30,90], and (90,180] days. Results are grouped by first-post month;
      active_at_Nd is null until the full cohort month plus that observation
      horizon has elapsed. The usual retention decay ordering is empirical, not
      a mathematical guarantee.
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
              x-sql-datatype: "TABLE(cohort_month TEXT, first_post_accounts INT, active_at_30d INT, pct_30d NUMERIC, active_at_90d INT, pct_90d NUMERIC, active_at_180d INT, pct_180d NUMERIC)"
              type: array
              items:
                type: object
                properties:
                  cohort_month:
                    type: string
                    example: "2026-01"
                  first_post_accounts:
                    type: integer
                  active_at_30d:
                    type: integer
                    nullable: true
                  pct_30d:
                    type: number
                    nullable: true
                  active_at_90d:
                    type: integer
                    nullable: true
                  pct_90d:
                    type: number
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
RETURNS TABLE(cohort_month TEXT, first_post_accounts INT, active_at_30d INT, pct_30d NUMERIC, active_at_90d INT, pct_90d NUMERIC, active_at_180d INT, pct_180d NUMERIC)
-- openapi-generated-code-end
LANGUAGE sql STABLE
AS $$
    SELECT
        TO_CHAR(acr.cohort_month, 'YYYY-MM')                                      AS cohort_month,
        acr.first_post_accounts,
        acr.active_at_30d,
        ROUND(acr.active_at_30d * 100.0 / NULLIF(acr.first_post_accounts, 0), 1)  AS pct_30d,
        acr.active_at_90d,
        ROUND(acr.active_at_90d * 100.0 / NULLIF(acr.first_post_accounts, 0), 1)  AS pct_90d,
        acr.active_at_180d,
        ROUND(acr.active_at_180d * 100.0 / NULLIF(acr.first_post_accounts, 0), 1) AS pct_180d
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
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '30 days')::DATE);
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

    RETURN QUERY
    -- Counters and unique authors live in separate tables (unique_authors is not
    -- additive across days, so it is counted from the (day, author) presence set
    -- here). Both are pre-aggregated to the period, so the join is 1:1 on period.
    WITH counts AS (
        SELECT
            DATE_TRUNC("granularity", ncd.day) AS period,
            SUM(ncd.posts)    AS posts,
            SUM(ncd.comments) AS comments
        FROM haf_stats_backend.network_content_daily ncd
        WHERE ncd.day BETWEEN _from AND _to
        GROUP BY 1
    ),
    authors AS (
        SELECT
            DATE_TRUNC("granularity", nad.day) AS period,
            COUNT(DISTINCT nad.author_id)       AS unique_authors
        FROM haf_stats_backend.network_author_daily nad
        WHERE nad.day BETWEEN _from AND _to
        GROUP BY 1
    )
    SELECT
        TO_CHAR(c.period, 'YYYY-MM-DD'),
        c.posts::BIGINT,
        c.comments::BIGINT,
        COALESCE(a.unique_authors, 0)::BIGINT
    FROM counts c
    LEFT JOIN authors a ON a.period = c.period
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
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '30 days')::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

    -- Tolerate Wax's JSON-encoded string params (e.g. "day"); see issue #22.
    "granularity" := TRIM('"' FROM "granularity");
    IF "granularity" IS NULL OR "granularity" NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE("granularity", '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;

    RETURN QUERY
    SELECT
        TO_CHAR(DATE_TRUNC("granularity", pe.post_day), 'YYYY-MM-DD'),
        COUNT(*)::BIGINT,
        ROUND(AVG(pe.vote_count), 2),
        ROUND(AVG(pe.reply_count), 2),
        ROUND(COUNT(*) FILTER (WHERE pe.vote_count = 0) * 100.0 / NULLIF(COUNT(*), 0), 2),
        ROUND(COUNT(*) FILTER (WHERE pe.reply_count = 0) * 100.0 / NULLIF(COUNT(*), 0), 2)
    FROM haf_stats_backend.post_engagement pe
    WHERE pe.post_day BETWEEN _from AND _to
    GROUP BY DATE_TRUNC("granularity", pe.post_day)
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
      no balance_tracker schema is readable on the deployment). Sort keys -
      author_rewards and curation_rewards: vests, then hbd, then hive sums;
      transfer_volume_in/out: hive, then hbd sums; transaction_count: op count;
      hp_balance: vesting balance. Ties broken by account id (creation order).
      Value fields not applicable to a metric are 0.
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
        description: Block number or start date (YYYY-MM-DD), inclusive, defaults to 30 days ago; ignored for hp_balance
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
    "limit_count" INT = 25
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
BEGIN
    _from := haf_stats_app.to_filter_date("from_date", (NOW() - INTERVAL '30 days')::DATE);
    _to := haf_stats_app.to_filter_date("to_date", NOW()::DATE);

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
        -- always-present component, so it leads the sort key.
        WITH top AS (
            SELECT
                f.account_id,
                SUM(f.hive_nai)  AS hive,
                SUM(f.hbd_nai)   AS hbd,
                SUM(f.vests_nai) AS vests,
                SUM(f.op_count)  AS ops
            FROM haf_stats_backend.account_financial_daily f
            WHERE f.category = _category
              AND f.direction = 'incoming'
              AND f.day BETWEEN _from AND _to
            GROUP BY f.account_id
            ORDER BY SUM(f.vests_nai) DESC, SUM(f.hbd_nai) DESC,
                SUM(f.hive_nai) DESC, f.account_id ASC
            LIMIT "limit_count"
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
        -- leads the sort key.
        WITH top AS (
            SELECT
                f.account_id,
                SUM(f.hive_nai) AS hive,
                SUM(f.hbd_nai)  AS hbd,
                SUM(f.op_count) AS ops
            FROM haf_stats_backend.account_financial_daily f
            WHERE f.category = 'transfer_operation'
              AND f.direction = _direction
              AND f.day BETWEEN _from AND _to
            GROUP BY f.account_id
            ORDER BY SUM(f.hive_nai) DESC, SUM(f.hbd_nai) DESC, f.account_id ASC
            LIMIT "limit_count"
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
        -- distinct signer (see process_active_users.sql).
        WITH top AS (
            SELECT au.account_id, SUM(au.ops) AS ops
            FROM haf_stats_backend.active_users_daily au
            WHERE au.op_class = -1
              AND au.day BETWEEN _from AND _to
            GROUP BY au.account_id
            ORDER BY SUM(au.ops) DESC, au.account_id ASC
            LIMIT "limit_count"
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
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;

RESET ROLE;
