"""Unit tests for the custom verifier cores in validate_response.

Marked `synthetic` so they run in the fixture-only stub lane (`pytest -m 'negative or
synthetic'`) alongside the tavern synthetic tests, and are excluded from the real-replay lane.
These guard the custom subset/order verifier itself: without them, a regression that neutered
`_check_rows_present` (e.g. dropping the membership or ordering assert) would silently make the
get_custom_json_app_registry tavern test vacuous.
"""
# private-test-exempt: tests the private cores of validate_response's public verifiers; must
# remain in tests/tavern/ so pytest.mark.synthetic places them in the endpoint lane's stub run

from datetime import date

import pytest

from validate_response import _check_default_window_first_bucket, _check_rows_present

pytestmark = pytest.mark.synthetic


def test_present_subset_in_order_passes() -> None:
    _check_rows_present(
        [{"a": 1}, {"a": 2}, {"a": 3}],
        [{"a": 1}, {"a": 3}],
    )


def test_missing_row_fails() -> None:
    with pytest.raises(AssertionError, match="not found"):
        _check_rows_present([{"a": 1}], [{"a": 2}])


def test_out_of_order_fails_when_ordered() -> None:
    with pytest.raises(AssertionError, match="out of order"):
        _check_rows_present([{"a": 2}, {"a": 1}], [{"a": 1}, {"a": 2}])


def test_out_of_order_allowed_when_unordered() -> None:
    _check_rows_present([{"a": 2}, {"a": 1}], [{"a": 1}, {"a": 2}], ordered=False)


def test_dict_equality_is_key_order_insensitive() -> None:
    # PostgREST may serialise object keys in any order; dict equality must still match.
    _check_rows_present([{"a": 1, "b": 2}], [{"b": 2, "a": 1}])


def test_non_list_response_fails() -> None:
    with pytest.raises(AssertionError, match="Expected a JSON array"):
        _check_rows_present({"not": "a list"}, [{"a": 1}])


def test_default_window_whole_month_passes() -> None:
    # 2026-11-12 minus 30 days is 2026-10-13: the bucket must be all of October.
    _check_default_window_first_bucket(
        [{"period": "2026-10-01", "votes_cast": 31}, {"period": "2026-11-01", "votes_cast": 12}],
        date(2026, 11, 12), "month", 30, 0, "votes_cast",
    )


def test_default_window_rolling_start_fails() -> None:
    with pytest.raises(AssertionError, match="want the month starting 2026-10-01"):
        _check_default_window_first_bucket(
            [{"period": "2026-10-13", "votes_cast": 19}],
            date(2026, 11, 12), "month", 30, 0, "votes_cast",
        )


def test_default_window_partial_first_bucket_fails() -> None:
    with pytest.raises(AssertionError, match="want 31"):
        _check_default_window_first_bucket(
            [{"period": "2026-10-01", "votes_cast": 19}],
            date(2026, 11, 12), "month", 30, 0, "votes_cast",
        )


def test_default_window_week_starts_monday() -> None:
    # 2026-10-13 is a Tuesday.
    _check_default_window_first_bucket(
        [{"period": "2026-10-12", "op_count": 7}],
        date(2026, 11, 12), "week", 30, 0, "op_count",
    )


def test_default_window_years_clamp_leap_day() -> None:
    # 2028-02-29 minus one year is 2027-02-28, as in PostgreSQL.
    _check_default_window_first_bucket(
        [{"period": "2027-02-28", "op_count": 1}],
        date(2028, 2, 29), "day", 0, 1, "op_count",
    )


def test_default_window_empty_response_fails() -> None:
    with pytest.raises(AssertionError, match="non-empty"):
        _check_default_window_first_bucket([], date(2026, 11, 12), "day", 30, 0, "votes_cast")
