"""scripts/ci-helpers/extract_ci_shell.py, which feeds .gitlab-ci.yml's shell to shellcheck (#90).

The extractor fails quietly in every way that matters: a block it drops is a block that
is never linted, and a wrong shell either hides real findings (bash on a busybox image)
or invents SC3xxx noise (sh on a bash image). ci-shell-lint stays green in all three
cases, so the extractor is pinned here instead.
"""

from __future__ import annotations

import importlib.util
import os
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
CI = ROOT / ".gitlab-ci.yml"
SCRIPT = ROOT / "scripts" / "ci-helpers" / "extract_ci_shell.py"


@pytest.fixture(scope="module")
def ex():
    # Same rule as test_compose_contract._require_yaml: FAIL under CI, never skip.
    try:
        import yaml  # noqa: F401
    except ImportError:  # pragma: no cover - depends on the environment
        if os.environ.get("CI"):
            pytest.fail("PyYAML is unavailable, so the CI-shell extractor cannot be tested")
        pytest.skip("PyYAML is required")
    spec = importlib.util.spec_from_file_location("extract_ci_shell", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


SAMPLE = """\
# header
.tmpl:
  image: python:3.11-slim
  before_script:
  - echo before
job-a:
  extends: .tmpl
  script:
  - !reference [.included, script]
  - |
    one
    two
  - single
  after_script: !reference [.included, after_script]
job-b:
  image: docker:24
  script:
  - >-
    folded
    line
  - [nested]
  after_script:
  - cleanup
not-a-job:
  FOO: bar
"""


def test_blocks_are_line_aligned_with_the_ci_file(ex):
    lines = ex.extract(SAMPLE)["job-a.script.sh"].splitlines()
    assert lines[10:13] == ["one", "two", "single"]  # CI lines 11-13


def test_before_script_and_script_share_a_file_after_script_does_not(ex):
    files = ex.extract(SAMPLE)
    assert "echo before" in files["tmpl.script.sh"]
    assert "cleanup" not in files["job-b.script.sh"]
    assert "cleanup" in files["job-b.after_script.sh"]


def test_references_are_skipped_not_linted_as_text(ex):
    files = ex.extract(SAMPLE)
    assert ".included" not in files["job-a.script.sh"]
    # A whole-key !reference must not produce a file of template names.
    assert "job-a.after_script.sh" not in files
    assert "not-a-job.script.sh" not in files


def test_the_shell_follows_the_image_including_through_extends(ex):
    files = ex.extract(SAMPLE)
    assert files["job-a.script.sh"].startswith("# shellcheck shell=bash\n")
    assert files["job-b.script.sh"].startswith("# shellcheck shell=sh\n")
    assert "folded line" in files["job-b.script.sh"]
    assert "nested" in files["job-b.script.sh"]


def test_every_literal_block_in_the_real_ci_file_is_extracted_in_place(ex):
    """The real file, not the sample: if a job shape appears that the extractor does not
    understand, its block silently stops being linted, and this is where that shows."""
    text = CI.read_text(encoding="utf-8")
    ci_lines = text.splitlines()
    extracted = [f.splitlines() for f in ex.extract(text).values()]
    starts = [n for n, line in enumerate(ci_lines) if re.match(r"^\s*- [|>][-+]?\s*$", line)]
    assert len(starts) >= 20  # 26 when this was written; guards a parse returning nothing
    for n in starts:
        first = ci_lines[n + 1].strip()
        if "|" in ci_lines[n]:
            # A literal block must sit on its own line numbers, or findings point nowhere.
            ok = any(len(f) > n + 1 and f[n + 1].strip() == first for f in extracted)
        else:
            # A folded block is joined by YAML, so it can only be found, not aligned.
            ok = any(first in line for f in extracted for line in f)
        assert ok, f".gitlab-ci.yml:{n + 2} ({first!r}) is missing or misplaced"
