"""The API contract version has one value, and CHANGELOG.md names it (#64).

`info.version` is written twice in endpoints/endpoint_schema.sql -- once in the YAML
annotation a maintainer edits, once in the JSON blob the generator embeds and root()
serves -- and the rewriter tavern suite asserts it on the wire. A bump that touches one
of them, or none of them while CHANGELOG.md gains a new version heading, would publish
a document a consumer cannot key a change off, which is the thing the policy exists to
prevent.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

try:
    import yaml
except ImportError:  # pragma: no cover - depends on the environment, not the code
    yaml = None

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "endpoints" / "endpoint_schema.sql"
CHANGELOG = ROOT / "CHANGELOG.md"
REWRITER_TEST = ROOT / "tests" / "tavern" / "rewriter" / "public_paths.tavern.yaml"

SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")

needs_yaml = pytest.mark.skipif(yaml is None, reason="PyYAML is not installed")


def _released_versions(text: str) -> list[str]:
    headings = re.findall(r"^## (.+?)\s*$", text, re.MULTILINE)
    return [h for h in headings if h not in ("Versioning policy", "Unreleased")]


def _annotation_version(sql: str) -> str:
    block = re.search(r"^/\*\* openapi\n(.*?)^ \*/$", sql, re.MULTILINE | re.DOTALL)
    assert block, "no /** openapi ... */ annotation block in endpoint_schema.sql"
    return str(yaml.safe_load(block.group(1))["info"]["version"])


def _served_version(sql: str) -> str:
    blob = re.search(r"openapi json = \$\$\n(.*?)^\$\$;", sql, re.MULTILINE | re.DOTALL)
    assert blob, "no generated `openapi json = $$ ... $$;` blob in endpoint_schema.sql"
    return str(json.loads(blob.group(1))["info"]["version"])


def _asserted_on_the_wire(text: str) -> str:
    # A regex rather than yaml: the suite uses tavern's custom tags (`!anystr`), which
    # safe_load refuses.
    asserted = re.findall(r"^ +info:\n +title: .*\n +version: \"([^\"]+)\"$", text, re.MULTILINE)
    assert len(asserted) == 1, f"expected one stage asserting info.version, found {asserted}"
    return str(asserted[0])


def test_changelog_headings_are_semver_and_descending() -> None:
    versions = _released_versions(CHANGELOG.read_text())
    assert versions, "CHANGELOG.md has no released version heading"
    bad = [v for v in versions if not SEMVER.match(v)]
    assert not bad, f"CHANGELOG.md headings that are not MAJOR.MINOR.PATCH: {bad}"
    keys = [tuple(int(p) for p in v.split(".")) for v in versions]
    assert keys == sorted(keys, reverse=True), f"CHANGELOG.md versions not newest-first: {versions}"
    assert len(set(keys)) == len(keys), f"CHANGELOG.md repeats a version: {versions}"


def test_served_version_is_the_newest_changelog_version() -> None:
    newest = _released_versions(CHANGELOG.read_text())[0]
    assert _served_version(SCHEMA.read_text()) == newest


@needs_yaml
def test_annotation_and_wire_assertion_agree_with_the_changelog() -> None:
    newest = _released_versions(CHANGELOG.read_text())[0]
    assert _annotation_version(SCHEMA.read_text()) == newest
    assert _asserted_on_the_wire(REWRITER_TEST.read_text()) == newest


@pytest.mark.parametrize(
    "text, expected",
    [
        ("## Versioning policy\n## Unreleased\n## 2.1.0\n## 2.0.0\n", ["2.1.0", "2.0.0"]),
        ("## Unreleased\n### Breaking\n## 1.0.0\n", ["1.0.0"]),
    ],
)
def test_released_versions_skip_policy_and_unreleased(text: str, expected: list[str]) -> None:
    assert _released_versions(text) == expected
