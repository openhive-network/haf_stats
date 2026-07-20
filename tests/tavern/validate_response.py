"""Tavern response-pattern validation, following balance_tracker's convention."""

from __future__ import annotations

import difflib
import json
import os
from pathlib import Path
from typing import Any


TEST_SUFFIX = ".tavern.yaml"
PATTERN_SUFFIX = ".pat.json"


def _current_test_file() -> Path:
    current_test = os.environ.get("PYTEST_CURRENT_TEST")
    assert current_test, "PYTEST_CURRENT_TEST is not set"

    node_path = Path(current_test.split("::", 1)[0])
    tavern_root = Path(__file__).resolve().parent

    if node_path.is_absolute() and node_path.exists():
        return node_path

    parts = node_path.parts
    if "tavern" in parts:
        node_path = Path(*parts[parts.index("tavern") + 1 :])

    candidate = tavern_root / node_path
    if candidate.exists():
        return candidate

    matches = list(tavern_root.rglob(node_path.name))
    assert len(matches) == 1, f"Could not uniquely resolve Tavern test file: {node_path}"
    return matches[0]


def _pattern_file(test_file: Path) -> Path:
    test_name = str(test_file)
    assert test_name.endswith(TEST_SUFFIX), f"Unexpected Tavern filename: {test_file}"
    return Path(test_name[: -len(TEST_SUFFIX)] + PATTERN_SUFFIX)


def _pretty(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def compare_rest_response_with_pattern(
    response,
    error_response: bool = False,
    pattern_file: str | None = None,
    **_kwargs,
) -> None:
    """Compare the complete JSON response with a ``.pat.json`` file.

    By default the sibling ``<test>.pat.json`` is used. Pass ``pattern_file`` to
    reuse another test's pattern instead (resolved relative to the test file's
    directory) — e.g. a block-number variant asserting the same rows as the
    date-based test, so the expectation lives in exactly one place.
    """

    actual = response.json()

    if error_response:
        for required_key in ("code", "details", "hint", "message"):
            assert required_key in actual, (
                f"Error response does not contain required key: {required_key}"
            )

    test_file = _current_test_file()
    if pattern_file:
        pattern_path = (test_file.parent / pattern_file).resolve()
    else:
        pattern_path = _pattern_file(test_file)
    assert pattern_path.exists(), f"Pattern file does not exist: {pattern_path}"

    with pattern_path.open(encoding="utf-8") as pattern_stream:
        expected = json.load(pattern_stream)

    if actual != expected:
        diff = "".join(
            difflib.unified_diff(
                _pretty(expected).splitlines(keepends=True),
                _pretty(actual).splitlines(keepends=True),
                fromfile=str(pattern_path),
                tofile="actual response",
            )
        )
        raise AssertionError(f"Response differs from pattern:\n{diff}")


def assert_rows_present(
    response,
    pattern_file: str | None = None,
    ordered: bool = True,
    **_kwargs,
) -> None:
    """Assert every row listed in the sibling ``.pat.json`` is present in the response array.

    Unlike :func:`compare_rest_response_with_pattern` (a full exact match), this checks only a
    representative SUBSET, so a growing source table — e.g. custom_json_app_registry gaining or
    re-categorising apps — does not break the test on every registry edit. With ``ordered=True``
    (default) the listed rows must also appear in the same relative order in the response, so an
    ``ORDER BY`` is exercised without pinning every row. The pattern file is a JSON array of the
    expected row objects.
    """

    actual = response.json()

    test_file = _current_test_file()
    if pattern_file:
        pattern_path = (test_file.parent / pattern_file).resolve()
    else:
        pattern_path = _pattern_file(test_file)
    assert pattern_path.exists(), f"Pattern file does not exist: {pattern_path}"

    with pattern_path.open(encoding="utf-8") as pattern_stream:
        expected = json.load(pattern_stream)

    _check_rows_present(actual, expected, ordered=ordered)


def _check_rows_present(actual: Any, expected: Any, ordered: bool = True) -> None:
    """Core subset/order check behind :func:`assert_rows_present`.

    Kept pure (no file or HTTP-response access) so it can be unit-tested directly. Raises
    AssertionError unless every row in ``expected`` is present in ``actual`` (and, when
    ``ordered``, in the same relative order). Row equality is dict equality, so it is
    insensitive to JSON key ordering.
    """

    assert isinstance(actual, list), (
        f"Expected a JSON array response, got {type(actual).__name__}"
    )
    assert isinstance(expected, list), (
        "Pattern for assert_rows_present must be a JSON array of expected rows"
    )

    positions = []
    for row in expected:
        assert row in actual, f"Expected row not found in response:\n{_pretty(row)}"
        positions.append(actual.index(row))

    if ordered:
        assert positions == sorted(positions), (
            "Expected rows are present but out of order relative to the response "
            f"(positions {positions}); the endpoint's ORDER BY is not honoured."
        )
