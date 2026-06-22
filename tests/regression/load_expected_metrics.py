#!/usr/bin/env python3
"""
Load the external hived ground-truth fixture into haf_stats_test.expected_account_metrics.

Mirrors balance_tracker/tests/regression/load_expected_balances.py, but emits SQL to
stdout (piped into psql by run_test.sh) so it needs no database driver — keeping the
CI image dependency-free.

Usage:  python3 load_expected_metrics.py [account_metrics_dump.json.gz] | psql "$DB"
"""
import gzip, json, os, sys


def q(s):  # quote a SQL string literal
    return "'" + str(s).replace("'", "''") + "'"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "account_metrics_dump.json.gz")
    with gzip.open(path, "rt") as f:
        fixture = json.load(f)

    print("TRUNCATE haf_stats_test.expected_account_metrics;")
    for a in fixture["accounts"]:
        print(
            "INSERT INTO haf_stats_test.expected_account_metrics "
            "(account, posts, comments, votes_cast, transfer_income_hive_nai, "
            "transfer_income_ops, transfer_expense_hive_nai, transfer_expense_ops) VALUES ("
            f"{q(a['account'])}, {int(a['posts'])}, {int(a['comments'])}, {int(a['votes_cast'])}, "
            f"{int(a['transfer_income_hive_nai'])}, {int(a['transfer_income_ops'])}, "
            f"{int(a['transfer_expense_hive_nai'])}, {int(a['transfer_expense_ops'])});"
        )


if __name__ == "__main__":
    main()
