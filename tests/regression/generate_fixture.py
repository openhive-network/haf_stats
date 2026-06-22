#!/usr/bin/env python3
"""
Regression fixture generator — mirrors balance_tracker/tests/regression's use of a
hived-node snapshot as external ground truth (their accounts_dump.json.gz comes from
database_api.list_accounts; ours comes from condenser_api.get_account_history).

It fetches each account's FULL canonical operation history from a public hived node
and computes, from FIRST PRINCIPLES (sharing nothing with haf_stats), the same
per-account metrics the account-scoped endpoints expose for the 2016-04 window:

  - posts / comments : distinct (author, permlink) whose FIRST-EVER occurrence is in
                       2016-04 (parent_author '' => post, else comment). Excludes
                       edits, exactly like the chain's find_comment / our processor,
                       but derived purely from hived history.
  - votes_cast       : vote_operations signed by the account in 2016-04.
  - transfer income  : sum of HIVE transfer_operation amounts received (to=account).
  - transfer expense : sum of HIVE transfer_operation amounts sent (from=account).

Output: account_metrics_dump.json.gz  (committed; the CI regression test reads it,
so CI needs no network — same approach balance_tracker uses for its fixture).

Recreate:  python3 generate_fixture.py --node https://api.hive.blog
"""
import argparse, gzip, json, sys, urllib.request

WINDOW_LO = "2016-04-01T00:00:00"
WINDOW_HI = "2016-05-01T00:00:00"   # exclusive
HIVE_NAI  = "@@000000021"
ACCOUNTS  = ["tuck-fheman", "bittrex"]


def rpc(node, method, params):
    req = urllib.request.Request(
        node,
        data=json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        d = json.loads(r.read())
    if "result" not in d:
        raise RuntimeError(f"{method} -> {json.dumps(d)[:300]}")
    return d["result"]


def iter_history(node, account, page=1000):
    """Yield (index, timestamp, op_type, op_value) oldest-first across full history."""
    start = page - 1
    last_max = -1
    while True:
        hist = rpc(node, "condenser_api.get_account_history", [account, start, page])
        if not hist:
            break
        for idx, entry in hist:
            op_type, op_value = entry["op"][0], entry["op"][1]
            yield idx, entry["timestamp"], op_type, op_value
        cur_max = hist[-1][0]
        if cur_max <= last_max or len(hist) < page:   # reached the newest entry
            break
        last_max = cur_max
        start = cur_max + page


def hive_nai(asset_str):
    """condenser legacy asset string e.g. '320.700 HIVE' -> integer nai, or None if not HIVE."""
    val, _, sym = asset_str.partition(" ")
    if sym != "HIVE":          # 2016 STEEM is rendered as HIVE on the post-fork node
        return None
    return int(round(float(val) * 1000))


def compute(node, account):
    # condenser_api uses SHORT op names (comment/vote/transfer), not *_operation, and
    # virtual ops (effective_comment_vote, account_created, …) carry distinct names so
    # exact-matching the real op name excludes them automatically.
    seen_permlinks, posts, comments, votes_cast = set(), 0, 0, 0
    inc_sum = inc_ops = exp_sum = exp_ops = 0
    for _idx, ts, op_type, v in iter_history(node, account):
        if ts >= WINDOW_HI:
            break                       # chronological: everything after is out of window
        in_window = WINDOW_LO <= ts < WINDOW_HI
        if op_type == "comment":
            key = (v["author"], v["permlink"])
            first = key not in seen_permlinks
            seen_permlinks.add(key)
            if first and in_window and v["author"] == account:
                if v.get("parent_author", "") == "":
                    posts += 1
                else:
                    comments += 1
        elif op_type == "vote" and in_window and v["voter"] == account:
            votes_cast += 1
        elif op_type == "transfer" and in_window:
            amt = hive_nai(v["amount"])
            if amt is None:
                continue
            if v["to"] == account:
                inc_sum += amt; inc_ops += 1
            if v["from"] == account:
                exp_sum += amt; exp_ops += 1
    return {
        "account": account,
        "posts": posts, "comments": comments, "votes_cast": votes_cast,
        "transfer_income_hive_nai": inc_sum, "transfer_income_ops": inc_ops,
        "transfer_expense_hive_nai": exp_sum, "transfer_expense_ops": exp_ops,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", default="https://api.hive.blog")
    ap.add_argument("--out", default="account_metrics_dump.json.gz")
    a = ap.parse_args()
    fixture = {
        "source": a.node, "method": "condenser_api.get_account_history",
        "window": {"from": "2016-04-01", "to": "2016-04-30"},
        "note": "External ground truth from a canonical hived node; metrics computed "
                "independently of haf_stats. See generate_fixture.py.",
        "accounts": [compute(a.node, acc) for acc in ACCOUNTS],
    }
    for r in fixture["accounts"]:
        print(json.dumps(r), file=sys.stderr)
    with gzip.open(a.out, "wt") as f:
        json.dump(fixture, f, indent=2)
    print(f"wrote {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
