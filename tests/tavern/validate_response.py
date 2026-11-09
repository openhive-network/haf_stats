"""Tavern response-pattern validation, following balance_tracker's convention."""

from __future__ import annotations

import difflib
import http.client
import json
import os
import socket
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


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


def assert_head_then_get_framed(response: Any, **_kwargs: Any) -> None:
    """Assert a HEAD of this stage's URL, then a GET on the same connection, answer as it did.

    The HEAD must carry the stage's status and no body, and the GET after it must come
    back with the stage's status and JSON. A body after a HEAD's headers is read as the
    start of the next answer on a keep-alive connection; ``requests`` and a plain
    ``http.client`` connection drop it with the HEAD's read buffer, so this sends both
    requests at once over one socket and reads the bytes exactly as they arrive.
    """

    url = urlsplit(response.request.url)
    target = url.path + (f"?{url.query}" if url.query else "")
    pipelined = (
        f"HEAD {target} HTTP/1.1\r\nHost: {url.netloc}\r\n\r\n"
        f"GET {target} HTTP/1.1\r\nHost: {url.netloc}\r\nConnection: close\r\n\r\n"
    )
    with socket.create_connection((url.hostname, url.port or 80), timeout=30) as sock:
        sock.sendall(pipelined.encode())
        stream = b"".join(iter(lambda: sock.recv(65536), b""))

    head_end = stream.find(b"\r\n\r\n")
    assert head_end >= 0, f"no complete answer to a HEAD of {target}: {stream[:200]!r}"
    head_line = stream.split(b"\r\n", 1)[0]
    assert head_line.split(b" ")[1:2] == [str(response.status_code).encode()], (
        f"HEAD of {target} answered {head_line!r}, the GET {response.status_code}"
    )
    after_head = stream[head_end + 4 :]
    assert after_head.startswith(b"HTTP/1.1 "), (
        f"the HEAD of {target} was followed by a body, not the GET's answer: "
        f"{after_head[:120]!r}"
    )

    # http.client parses (and de-chunks) only from a socket: replay the received bytes
    # through a local pair. They are one small answer, well within the pair's buffer.
    replay, reader = socket.socketpair()
    with replay, reader:
        replay.sendall(after_head)
        replay.shutdown(socket.SHUT_WR)
        get = http.client.HTTPResponse(reader)
        get.begin()
        body = get.read()
    assert get.status == response.status_code, (
        f"the GET after a HEAD of {target} answered {get.status}, want {response.status_code}"
    )
    assert json.loads(body) == response.json(), (
        f"the GET after a HEAD of {target} answered another body:\n{body!r}"
    )
