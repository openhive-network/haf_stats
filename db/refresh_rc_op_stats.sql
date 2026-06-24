SET ROLE haf_stats_owner;

-- RC rate auto-refresh sampler (issue #33).
--
-- rc_op_stats_daily is seeded once at install (seed_data.sql); this sampler keeps it current
-- by pulling live per-op-type rates from hived rc_api and upserting today's row, so the
-- read-time RC estimate tracks chain conditions and the per-day read path accumulates a real
-- rate history going forward. Each daily run derives, per non-virtual op type:
--   base_rc = avg_cost_rc - history_rc   (size-independent RC per op)
--   byte_rc = history_rc / history_bytes (RC per payload byte)
-- from rc_api.get_rc_operation_stats (same formula as the seed).
--
-- plpython3u is untrusted (superuser) and the function needs network access to rc_api - both
-- are deployment concerns. Where plpython3u is unavailable (e.g. CI), the whole block is a
-- successful no-op so install never fails; the seeded rate keeps the estimate calibrated.
--
-- Scheduling is a deploy step (pg_cron, like the other haf_stats cron jobs), e.g. run once as
-- haf_stats_owner on a node whose container reaches hived at http://127.0.0.1:8091:
--   SELECT cron.schedule('haf_stats_rc_rates', '30 3 * * *',
--       $cron$ SELECT haf_stats_app.refresh_rc_op_stats() $cron$);

RESET ROLE;

DO $sampler$
BEGIN
    BEGIN
        CREATE EXTENSION IF NOT EXISTS plpython3u;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'plpython3u unavailable; rc_op_stats sampler not installed (%).', SQLERRM;
        RETURN;
    END;

    EXECUTE $ddl$
        CREATE OR REPLACE FUNCTION haf_stats_app.refresh_rc_op_stats(
            _rc_api_url TEXT DEFAULT 'http://127.0.0.1:8091'
        )
        RETURNS INTEGER
        LANGUAGE plpython3u
        AS $py$
import json
import urllib.request

# One non-virtual op type per row; rc_api operation names = operation_types.name minus the
# 'hive::protocol::' prefix (e.g. custom_json_operation).
rows = plpy.execute("SELECT id, replace(name, 'hive::protocol::', '') AS opname "
                    "FROM hafd.operation_types WHERE is_virtual = false ORDER BY id")

upsert = plpy.prepare(
    "INSERT INTO haf_stats_backend.rc_op_stats_daily "
    "(day, op_type_id, base_rc, byte_rc, avg_cost_rc, avg_bytes, sample_count) "
    "VALUES (CURRENT_DATE, $1, $2, $3, $4, $5, $6) "
    "ON CONFLICT (day, op_type_id) DO UPDATE SET "
    "base_rc = EXCLUDED.base_rc, byte_rc = EXCLUDED.byte_rc, "
    "avg_cost_rc = EXCLUDED.avg_cost_rc, avg_bytes = EXCLUDED.avg_bytes, "
    "sample_count = EXCLUDED.sample_count",
    ["int2", "int8", "numeric", "int8", "int4", "int8"])

written = 0
for r in rows:
    body = json.dumps({"jsonrpc": "2.0", "method": "rc_api.get_rc_operation_stats",
                       "params": {"operation": r["opname"]}, "id": 1}).encode()
    try:
        req = urllib.request.Request(_rc_api_url, data=body,
                                     headers={"Content-Type": "application/json"})
        res = json.loads(urllib.request.urlopen(req, timeout=20).read()).get("result") or {}
    except Exception as ex:
        plpy.warning("rc_api fetch failed for %s: %s" % (r["opname"], ex))
        continue
    count = res.get("count") or 0
    if not count:
        continue
    avg_cost = int(res.get("avg_cost_rc") or 0)
    hist_rc = int((res.get("resource_cost") or {}).get("history_rc") or 0)
    hist_bytes = int((res.get("resource_usage") or {}).get("history_bytes") or 0)
    if hist_bytes <= 0:
        continue
    base_rc = max(0, avg_cost - hist_rc)
    byte_rc = float(hist_rc) / hist_bytes
    plpy.execute(upsert, [r["id"], base_rc, byte_rc, avg_cost, hist_bytes, int(count)])
    written += 1
return written
        $py$;
    $ddl$;

    EXECUTE 'GRANT EXECUTE ON FUNCTION haf_stats_app.refresh_rc_op_stats(TEXT) TO haf_stats_owner';
    RAISE NOTICE 'rc_op_stats auto-refresh sampler installed';
END
$sampler$;
