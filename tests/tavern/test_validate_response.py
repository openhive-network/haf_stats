"""Unit tests for the assert_rows_present verifier core (validate_response).

Marked `synthetic` so they run in the fixture-only stub lane (`pytest -m 'negative or
synthetic'`) alongside the tavern synthetic tests, and are excluded from the real-replay lane.
These guard the custom subset/order verifier itself: without them, a regression that neutered
`_check_rows_present` (e.g. dropping the membership or ordering assert) would silently make the
get_custom_json_app_registry tavern test vacuous.
"""

import pytest

from validate_response import _check_rows_present

pytestmark = pytest.mark.synthetic


def test_present_subset_in_order_passes():
    _check_rows_present(
        [{"a": 1}, {"a": 2}, {"a": 3}],
        [{"a": 1}, {"a": 3}],
    )


def test_missing_row_fails():
    with pytest.raises(AssertionError, match="not found"):
        _check_rows_present([{"a": 1}], [{"a": 2}])


def test_out_of_order_fails_when_ordered():
    with pytest.raises(AssertionError, match="out of order"):
        _check_rows_present([{"a": 2}, {"a": 1}], [{"a": 1}, {"a": 2}])


def test_out_of_order_allowed_when_unordered():
    _check_rows_present([{"a": 2}, {"a": 1}], [{"a": 1}, {"a": 2}], ordered=False)


def test_dict_equality_is_key_order_insensitive():
    # PostgREST may serialise object keys in any order; dict equality must still match.
    _check_rows_present([{"a": 1, "b": 2}], [{"b": 2, "a": 1}])


def test_non_list_response_fails():
    with pytest.raises(AssertionError, match="Expected a JSON array"):
        _check_rows_present({"not": "a list"}, [{"a": 1}])
