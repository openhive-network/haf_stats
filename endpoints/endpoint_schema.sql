SET ROLE haf_stats_owner;

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
        "description": "Aggregated HBD/HIVE/VESTS flows for an account over a time range, grouped by financial category and direction (in/out).",
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
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '1 year')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 1 year ago"
          },
          {
            "in": "query",
            "name": "to_date",
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
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '30 days')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
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
        "description": "Breakdown of Resource Credit consumption for an account over a time range, grouped by operation type or DApp.",
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
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '30 days')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
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
            "name": "from_date",
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
            "name": "to_date",
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
        "description": "Bucketed distribution of Hive Power (HP) stake across all accounts. Reads current VESTS balances from balance_tracker; its schema is deployment-dependent so the function auto-detects the first readable relation (btracker_app / btracker_backend / hafbe_bal) - grant SELECT to haf_stats_user on whichever applies. Returns an empty array (HTTP 200, not an error) when the data source is unavailable - no readable balance relation, or hafd.blocks has no rows yet (fresh node, no VESTS/HP ratio). Consumers should treat an empty array as \"distribution not available yet\", not \"zero accounts\". (#20.5)",
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
                        "example": "1-10 HP"
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
    },
    "/network/account-funnel": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "New account cohort retention",
        "description": "Cohort retention for new accounts - percentage still active at 7, 30, and 90 days after creation, grouped by month of account creation. active_at_Nd is null for cohorts whose Nd window has not yet elapsed.",
        "operationId": "haf_stats_endpoints.get_network_account_funnel",
        "parameters": [
          {
            "in": "query",
            "name": "from_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '1 year')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start cohort month (inclusive), defaults to 1 year ago"
          },
          {
            "in": "query",
            "name": "to_date",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "NOW()::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "End cohort month (inclusive), defaults to today"
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
                        "type": "integer"
                      },
                      "pct_7d": {
                        "type": "number"
                      },
                      "active_at_30d": {
                        "type": "integer"
                      },
                      "pct_30d": {
                        "type": "number"
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
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '30 days')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
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
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '30 days')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
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
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '30 days')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 30 days ago"
          },
          {
            "in": "query",
            "name": "to_date",
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
    "/network/top-accounts": {
      "get": {
        "tags": [
          "Network"
        ],
        "summary": "Top accounts per metric",
        "description": "Top N accounts ranked by the chosen metric. Reward and transfer metrics sum haf_stats financial data over [_from, _to]; transaction_count sums authored (signed) operations over the same range; hp_balance ranks the CURRENT own vesting balance from balance_tracker and ignores _from/_to (empty result if no balance_tracker schema is readable on the deployment). Sort keys - author_rewards and curation_rewards: vests, then hbd, then hive sums; transfer_volume_in/out: hive, then hbd sums; transaction_count: op count; hp_balance: vesting balance. Ties broken by account id (creation order). Value fields not applicable to a metric are 0.",
        "operationId": "haf_stats_endpoints.get_network_top_accounts",
        "parameters": [
          {
            "in": "query",
            "name": "_metric",
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
            "name": "_from",
            "required": false,
            "schema": {
              "x-sql-datatype": "DATE",
              "x-sql-default-value": "(NOW() - INTERVAL '30 days')::DATE",
              "type": "string",
              "format": "date"
            },
            "description": "Start date (inclusive), defaults to 30 days ago; ignored for hp_balance"
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
            "description": "End date (inclusive), defaults to today; ignored for hp_balance"
          },
          {
            "in": "query",
            "name": "_limit",
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
      grouped by financial category and direction (in/out).
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
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '1 year')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 1 year ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
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
    "account" TEXT,
    "from_date" DATE = (NOW() - INTERVAL '1 year')::DATE,
    "to_date" DATE = NOW()::DATE,
    "granularity" TEXT = 'month'
)
RETURNS TABLE(period TEXT, category TEXT, direction TEXT, hive_nai BIGINT, hbd_nai BIGINT, vests_nai BIGINT, op_count INT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
BEGIN
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
      AND afd.day BETWEEN "from_date" AND "to_date"
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
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
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
    "from_date" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "to_date" DATE = NOW()::DATE,
    "granularity" TEXT = 'month'
)
RETURNS TABLE(period TEXT, posts BIGINT, comments BIGINT, votes_cast BIGINT, votes_received BIGINT, replies_received BIGINT, author_reward_hive_nai BIGINT, author_reward_hbd_nai BIGINT, author_reward_vests_nai BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _account_id INT;
BEGIN
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
          AND acd.day BETWEEN "from_date" AND "to_date"
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
          AND afd.day BETWEEN "from_date" AND "to_date"
          AND afd.category = 'Author Reward'
          AND afd.direction = 'income'
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
      Breakdown of Resource Credit consumption for an account over a time range,
      grouped by operation type or DApp.
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
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
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
    "from_date" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "to_date" DATE = NOW()::DATE,
    "group_by" TEXT = 'op_type'
)
RETURNS TABLE(label TEXT, rc_consumed BIGINT, op_count BIGINT, pct NUMERIC)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    -- Tolerate Wax's JSON-encoded string params (e.g. "op_type"); see issue #22.
    group_by := TRIM('"' FROM group_by);
    IF group_by IS NULL OR group_by NOT IN ('op_type', 'app') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid group_by: ' || COALESCE(group_by, '(null)'),
            HINT = 'Must be one of: op_type, app';
    END IF;
    RETURN QUERY
    WITH base AS (
        SELECT
            CASE group_by
                WHEN 'app' THEN COALESCE(rol.custom_json_id, 'non-custom_json')
                ELSE            COALESCE(ot.name, 'unknown')
            END      AS label,
            rol.rc_cost
        FROM haf_stats_backend.rc_operation_log rol
        JOIN hafd.accounts a ON a.id = rol.account_id
        LEFT JOIN hafd.operation_types ot ON ot.id = rol.op_type_id
        WHERE a.name             = account
          AND rol."timestamp"::DATE BETWEEN from_date AND to_date
    ),
    totals AS (SELECT SUM(base.rc_cost) AS grand_total FROM base)
    SELECT
        base.label,
        SUM(base.rc_cost)::BIGINT                                       AS rc_consumed,
        COUNT(*)::BIGINT                                                AS op_count,
        ROUND(SUM(base.rc_cost) * 100.0 / NULLIF(t.grand_total, 0), 2)  AS pct
    FROM base, totals t
    GROUP BY base.label, t.grand_total
    ORDER BY 2 DESC;
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
      Time-series of total RC consumption across the network, broken down
      by operation type or DApp, aggregated by the chosen granularity.
    operationId: haf_stats_endpoints.get_network_rc_utilization
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
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
    "from_date" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "to_date" DATE = NOW()::DATE,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, rc_total BIGINT, by_label JSONB)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
BEGIN
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
    WITH per_label AS (
        SELECT
            DATE_TRUNC(granularity, rol."timestamp")            AS period,
            COALESCE(rol.custom_json_id, ot.name, 'unknown')    AS label,
            SUM(rol.rc_cost)::BIGINT                             AS rc_label_total
        FROM haf_stats_backend.rc_operation_log rol
        LEFT JOIN hafd.operation_types ot ON ot.id = rol.op_type_id
        WHERE rol."timestamp"::DATE BETWEEN from_date AND to_date
        GROUP BY 1, 2
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
      Bucketed distribution of Hive Power (HP) stake across all accounts.
      Reads current VESTS balances from balance_tracker; its schema is
      deployment-dependent so the function auto-detects the first readable
      relation (btracker_app / btracker_backend / hafbe_bal) - grant SELECT to
      haf_stats_user on whichever applies.
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
              x-sql-datatype: "TABLE(bucket TEXT, account_count BIGINT, pct_accounts NUMERIC)"
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
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS haf_stats_endpoints.get_network_hp_distribution;
CREATE OR REPLACE FUNCTION haf_stats_endpoints.get_network_hp_distribution()
RETURNS TABLE(bucket TEXT, account_count BIGINT, pct_accounts NUMERIC)
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
                COUNT(*) AS cnt
            FROM %s b, ratio r
            WHERE b.nai = 37   -- VESTS (btracker nai smallint code: 13=HBD, 21=HIVE, 37=VESTS)
              AND b.balance > 0
            GROUP BY 1
        ),
        total AS (SELECT SUM(cnt) AS n FROM balances)
        SELECT
            balances.bucket,
            cnt::BIGINT                              AS account_count,
            ROUND(cnt * 100.0 / total.n, 2)         AS pct_accounts
        FROM balances, total
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
      Cohort retention for new accounts - percentage still active at 7, 30,
      and 90 days after creation, grouped by month of account creation.
      active_at_Nd is null for cohorts whose Nd window has not yet elapsed.
    operationId: haf_stats_endpoints.get_network_account_funnel
    parameters:
      - in: query
        name: from_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '1 year')::DATE"
          type: string
          format: date
        description: Start cohort month (inclusive), defaults to 1 year ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End cohort month (inclusive), defaults to today
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
                  pct_7d:
                    type: number
                  active_at_30d:
                    type: integer
                  pct_30d:
                    type: number
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
    "from_date" DATE = (NOW() - INTERVAL '1 year')::DATE,
    "to_date" DATE = NOW()::DATE
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
    WHERE acr.cohort_month BETWEEN from_date AND to_date
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
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
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
    "from_date" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "to_date" DATE = NOW()::DATE,
    "granularity" TEXT = 'day',
    "operation_types" TEXT = 'all'
)
RETURNS TABLE(period TEXT, active_accounts BIGINT, operations BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    -- op_class codes resolved from operation_types. -1 is the reserved ALL rollup
    -- (every authored op); 1 post, 2 comment, 3 vote, 4 transfer, 5 custom_json.
    _classes SMALLINT[];
    _bad     TEXT;
BEGIN
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

    RETURN QUERY
    -- active_accounts counts the distinct presence set at the requested grain (rolling
    -- daily membership up to week/month - summing daily counts would overcount). For a
    -- multi-class request COUNT(DISTINCT) unions the classes (an account active in two
    -- categories counts once). operations sums the additive per-class counters; each op
    -- belongs to exactly one named class, so a subset never double-counts.
    WITH accounts AS (
        SELECT
            DATE_TRUNC(granularity, aud.day)  AS period,
            COUNT(DISTINCT aud.account_id)      AS active_accounts
        FROM haf_stats_backend.active_users_daily aud
        WHERE aud.op_class = ANY(_classes)
          AND aud.day BETWEEN from_date AND to_date
        GROUP BY 1
    ),
    ops AS (
        SELECT
            DATE_TRUNC(granularity, auo.day)  AS period,
            SUM(auo.operations)                 AS operations
        FROM haf_stats_backend.active_user_ops_daily auo
        WHERE auo.op_class = ANY(_classes)
          AND auo.day BETWEEN from_date AND to_date
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
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
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
    "from_date" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "to_date" DATE = NOW()::DATE,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, total_votes BIGINT, upvotes BIGINT, downvotes BIGINT, unvotes BIGINT, self_votes BIGINT, unique_voters BIGINT, downvote_pct NUMERIC)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    -- Tolerate Wax's JSON-encoded string params (e.g. "day"); see issue #22.
    "granularity" := TRIM('"' FROM "granularity");
    -- IS NULL is required: "NULL NOT IN (...)" evaluates to NULL (not TRUE), so
    -- a NULL granularity would otherwise slip past and reach DATE_TRUNC.
    IF "granularity" IS NULL OR "granularity" NOT IN ('day', 'week', 'month') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid granularity: ' || COALESCE("granularity", '(null)'),
            HINT = 'Must be one of: day, week, month';
    END IF;

    RETURN QUERY
    -- Counters and unique voters live in separate tables (unique_voters is not
    -- additive across batches, so it is counted from the (day, voter) presence set
    -- here). Both are pre-aggregated to the period, so the join is 1:1 on period.
    WITH counts AS (
        SELECT
            DATE_TRUNC("granularity", nvd.day) AS period,
            SUM(nvd.upvotes)    AS upvotes,
            SUM(nvd.downvotes)  AS downvotes,
            SUM(nvd.unvotes)    AS unvotes,
            SUM(nvd.self_votes) AS self_votes
        FROM haf_stats_backend.network_vote_daily nvd
        WHERE nvd.day BETWEEN "from_date" AND "to_date"
        GROUP BY 1
    ),
    voters AS (
        SELECT
            DATE_TRUNC("granularity", nvd.day) AS period,
            COUNT(DISTINCT nvd.voter_id)        AS unique_voters
        FROM haf_stats_backend.network_voter_daily nvd
        WHERE nvd.day BETWEEN "from_date" AND "to_date"
        GROUP BY 1
    )
    SELECT
        TO_CHAR(c.period, 'YYYY-MM-DD'),
        (c.upvotes + c.downvotes + c.unvotes)::BIGINT,
        c.upvotes::BIGINT,
        c.downvotes::BIGINT,
        c.unvotes::BIGINT,
        c.self_votes::BIGINT,
        COALESCE(v.unique_voters, 0)::BIGINT,
        ROUND(c.downvotes * 100.0 / NULLIF(c.upvotes + c.downvotes, 0), 2)
    FROM counts c
    LEFT JOIN voters v ON v.period = c.period
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
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago
      - in: query
        name: to_date
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today
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
    "from_date" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "to_date" DATE = NOW()::DATE,
    "granularity" TEXT = 'day'
)
RETURNS TABLE(period TEXT, posts BIGINT, comments BIGINT, unique_authors BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
BEGIN
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
        WHERE ncd.day BETWEEN "from_date" AND "to_date"
        GROUP BY 1
    ),
    authors AS (
        SELECT
            DATE_TRUNC("granularity", nad.day) AS period,
            COUNT(DISTINCT nad.author_id)       AS unique_authors
        FROM haf_stats_backend.network_author_daily nad
        WHERE nad.day BETWEEN "from_date" AND "to_date"
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
      haf_stats financial data over [_from, _to]; transaction_count sums authored
      (signed) operations over the same range; hp_balance ranks the CURRENT own
      vesting balance from balance_tracker and ignores _from/_to (empty result if
      no balance_tracker schema is readable on the deployment). Sort keys -
      author_rewards and curation_rewards: vests, then hbd, then hive sums;
      transfer_volume_in/out: hive, then hbd sums; transaction_count: op count;
      hp_balance: vesting balance. Ties broken by account id (creation order).
      Value fields not applicable to a metric are 0.
    operationId: haf_stats_endpoints.get_network_top_accounts
    parameters:
      - in: query
        name: _metric
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
        name: _from
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "(NOW() - INTERVAL '30 days')::DATE"
          type: string
          format: date
        description: Start date (inclusive), defaults to 30 days ago; ignored for hp_balance
      - in: query
        name: _to
        required: false
        schema:
          x-sql-datatype: DATE
          x-sql-default-value: "NOW()::DATE"
          type: string
          format: date
        description: End date (inclusive), defaults to today; ignored for hp_balance
      - in: query
        name: _limit
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
    "_metric" TEXT = 'author_rewards',
    "_from" DATE = (NOW() - INTERVAL '30 days')::DATE,
    "_to" DATE = NOW()::DATE,
    "_limit" INT = 25
)
RETURNS TABLE(rank INT, account TEXT, value_hive_nai BIGINT, value_hbd_nai BIGINT, value_vests_nai BIGINT, op_count BIGINT)
-- openapi-generated-code-end
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _category TEXT;
    _direction TEXT;
    _balance_rel TEXT;
BEGIN
    IF "_metric" IS NULL OR "_metric" NOT IN ('author_rewards', 'curation_rewards',
        'transfer_volume_in', 'transfer_volume_out', 'hp_balance', 'transaction_count') THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid _metric: ' || COALESCE("_metric", '(null)'),
            HINT = 'Must be one of: author_rewards, curation_rewards, transfer_volume_in, '
                || 'transfer_volume_out, hp_balance, transaction_count';
    END IF;

    IF "_limit" IS NULL OR "_limit" < 1 OR "_limit" > 100 THEN
        RAISE SQLSTATE '22023' USING
            MESSAGE = 'invalid _limit: ' || COALESCE("_limit"::TEXT, '(null)'),
            HINT = 'Must be between 1 and 100';
    END IF;

    -- Reward + transfer metrics share account_financial_daily; the
    -- (category, direction, day) index makes each branch a targeted range scan.
    -- Accounts are resolved AFTER aggregation + LIMIT (top N names only).
    IF "_metric" IN ('author_rewards', 'curation_rewards') THEN
        _category := CASE "_metric"
            WHEN 'author_rewards' THEN 'Author Reward'
            ELSE 'Curation Reward'
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
              AND f.direction = 'income'
              AND f.day BETWEEN "_from" AND "_to"
            GROUP BY f.account_id
            ORDER BY SUM(f.vests_nai) DESC, SUM(f.hbd_nai) DESC,
                SUM(f.hive_nai) DESC, f.account_id ASC
            LIMIT "_limit"
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

    ELSIF "_metric" IN ('transfer_volume_in', 'transfer_volume_out') THEN
        _direction := CASE "_metric"
            WHEN 'transfer_volume_in' THEN 'income'
            ELSE 'expense'
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
            WHERE f.category = 'Transfer'
              AND f.direction = _direction
              AND f.day BETWEEN "_from" AND "_to"
            GROUP BY f.account_id
            ORDER BY SUM(f.hive_nai) DESC, SUM(f.hbd_nai) DESC, f.account_id ASC
            LIMIT "_limit"
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

    ELSIF "_metric" = 'transaction_count' THEN
        RETURN QUERY
        -- op_class -1 is the ALL rollup: every authored op, counted once per
        -- distinct signer (see process_active_users.sql).
        WITH top AS (
            SELECT au.account_id, SUM(au.ops) AS ops
            FROM haf_stats_backend.active_users_daily au
            WHERE au.op_class = -1
              AND au.day BETWEEN "_from" AND "_to"
            GROUP BY au.account_id
            ORDER BY SUM(au.ops) DESC, au.account_id ASC
            LIMIT "_limit"
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
        $q$, _balance_rel) USING "_limit";
    END IF;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA haf_stats_endpoints TO haf_stats_user;

RESET ROLE;
