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
  - "quoted item"
  - 'single quoted'
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
job-c:
  image:
    name: python:3.12-slim
  script: echo single string
tmpl:
  image: alpine:3.20
  script:
  - echo plain twin
.anchored: &anchored
  image: python:3.12-alpine
  script:
  - echo from anchor
job-merge:
  <<: *anchored
job-spill:
  image: docker:24
  script:
  - "echo a\\necho b"
  - echo after spill
job-alias:
  image: docker:24
  before_script: &shared
  - echo shared
  script: *shared
not-a-job:
  FOO: bar
"""


@pytest.fixture(scope="module")
def files(ex):
    return ex.extract(SAMPLE)


def at(text: str, n: int) -> str:
    """Line n (1-based, as an editor counts .gitlab-ci.yml) of an extracted file."""
    return text.splitlines()[n - 1]


def test_items_are_line_aligned_with_the_ci_file(files):
    a = files["job-a.script.sh"]
    assert [at(a, n) for n in (11, 12, 13)] == ["one", "two", "single"]
    # Quoted items are items too, and sit on their own line.
    assert at(a, 14) == "quoted item"
    assert at(a, 15) == "single quoted"


def test_a_folded_block_starts_on_the_line_after_its_indicator(files):
    assert at(files["job-b.script.sh"], 21) == "folded line"


def test_a_single_string_script_is_linted(files):
    assert at(files["job-c.script.sh"], 29) == "echo single string"


def test_before_script_and_script_share_a_file_after_script_does_not(files):
    assert at(files["template.tmpl.script.sh"], 5) == "echo before"
    assert "cleanup" not in files["job-b.script.sh"]
    assert at(files["job-b.after_script.sh"], 25) == "cleanup"


def test_references_are_skipped_not_linted_as_text(files):
    assert ".included" not in files["job-a.script.sh"]
    # A whole-key !reference must not produce a file of template names.
    assert "job-a.after_script.sh" not in files
    assert not any(name.startswith("not-a-job") for name in files)


def test_a_hidden_template_and_a_job_of_the_same_name_both_survive(files):
    assert "echo before" in files["template.tmpl.script.sh"]
    assert "echo plain twin" in files["tmpl.script.sh"]
    assert files["template.tmpl.script.sh"].startswith("# shellcheck shell=bash\n")
    assert files["tmpl.script.sh"].startswith("# shellcheck shell=sh\n")


def test_names_that_sanitise_alike_do_not_overwrite(ex):
    out = ex.extract("# h\njob x:\n  script:\n  - echo one\njob_x:\n  script:\n  - echo two\n")
    assert sorted(out) == ["job_x.script.sh", "job_x~2.script.sh"]


def test_three_names_that_sanitise_alike_all_survive(ex):
    # Two would pass with `if` instead of `while`; the third is what needs the loop.
    ci = "# h\n" + "".join(f"{n}:\n  script:\n  - echo {i}\n"
                           for i, n in enumerate(("a b", "a_b", "a/b")))
    out = ex.extract(ci)
    assert sorted(out) == ["a_b.script.sh", "a_b~2.script.sh", "a_b~3.script.sh"]
    assert all(any(f"echo {i}" in text for text in out.values()) for i in range(3))


def test_merge_keys_are_followed(files):
    merged = files["job-merge.script.sh"]
    assert at(merged, 37) == "echo from anchor"
    assert merged.startswith("# shellcheck shell=sh\n")  # python:*-alpine is not bash


MERGES = """\
# h
.a: &a
  script:
  - echo first
.b: &b
  script:
  - echo second
.base: &base
  script:
  - echo base
.mid: &mid
  <<: *base
  image: docker:24
two-anchors:
  <<: [*a, *b]
own-wins:
  <<: *a
  script:
  - echo own
nested:
  <<: *mid
"""


@pytest.fixture(scope="module")
def merges(ex):
    return ex.extract(MERGES)


def test_the_first_of_several_merged_anchors_wins(merges):
    text = merges["two-anchors.script.sh"]
    assert "echo first" in text and "echo second" not in text


def test_a_jobs_own_key_beats_a_merged_one(merges):
    text = merges["own-wins.script.sh"]
    assert "echo own" in text and "echo first" not in text


def test_a_merge_inside_a_merged_anchor_is_followed(merges):
    assert "echo base" in merges["nested.script.sh"]


def test_with_several_extends_parents_the_last_image_wins(ex):
    # GitLab merges parents in order, so a later parent's image overrides an earlier one.
    ci = ("# h\n.sh-img:\n  image: docker:24\n.bash-img:\n  image: python:3.12-slim\n"
          "last-bash:\n  extends: [.sh-img, .bash-img]\n  script:\n  - true\n"
          "last-sh:\n  extends: [.bash-img, .sh-img]\n  script:\n  - true\n")
    out = ex.extract(ci)
    assert out["last-bash.script.sh"].startswith("# shellcheck shell=bash\n")
    assert out["last-sh.script.sh"].startswith("# shellcheck shell=sh\n")


def test_an_unresolvable_winning_parent_makes_the_image_unknown(ex):
    # .included is not in this file and comes last, so it decides the image; the bash
    # image of the earlier in-file parent must not leak through. Same one level down.
    ci = ("# h\n.local-bash:\n  image: python:3.12-slim\n"
          "direct:\n  extends: [.local-bash, .included]\n  script:\n  - true\n"
          ".mid:\n  extends: .included\n"
          "nested:\n  extends: [.local-bash, .mid]\n  script:\n  - true\n"
          "control:\n  extends: [.included, .local-bash]\n  script:\n  - true\n")
    out = ex.extract(ci)
    assert out["direct.script.sh"].startswith("# shellcheck shell=sh\n")
    assert out["nested.script.sh"].startswith("# shellcheck shell=sh\n")
    # A later in-file parent that sets an image still wins over the unresolvable one.
    assert out["control.script.sh"].startswith("# shellcheck shell=bash\n")


def test_an_extends_cycle_terminates(ex):
    ci = ("# h\n.a:\n  extends: .b\n.b:\n  extends: .a\n"
          "job:\n  extends: .a\n  script:\n  - true\n")
    assert ex.extract(ci)["job.script.sh"].startswith("# shellcheck shell=sh\n")


def test_a_block_at_end_of_file_without_newline_stays_in_place(ex):
    # No trailing newline: the end mark is mid-line, not at column 0 of the next line.
    out = ex.extract("# h\njob:\n  script:\n  - |\n    echo a\n    echo b")["job.script.sh"]
    assert [at(out, 5), at(out, 6)] == ["echo a", "echo b"]
    assert "# .gitlab-ci.yml:" not in out


def test_an_item_that_spills_moves_alone(files):
    spill = files["job-spill.script.sh"]
    # The quoted item expands to two lines but owns one; it moves after the last CI
    # line, and the item below it keeps its own line number.
    assert at(spill, 44) == "echo after spill"
    assert spill.splitlines()[-3:] == ["# .gitlab-ci.yml:43", "echo a", "echo b"]


def test_one_node_used_twice_in_a_shell_is_linted_twice_without_shifting(files):
    alias = files["job-alias.script.sh"]
    assert at(alias, 48) == "echo shared"
    assert alias.splitlines()[-2:] == ["# .gitlab-ci.yml:48", "echo shared"]
    assert len(alias.splitlines()) == len(SAMPLE.splitlines()) + 2


def test_the_shell_follows_the_image_including_through_extends(files):
    assert files["job-a.script.sh"].startswith("# shellcheck shell=bash\n")
    assert files["job-b.script.sh"].startswith("# shellcheck shell=sh\n")
    assert files["job-c.script.sh"].startswith("# shellcheck shell=bash\n")  # image: {name:}
    assert "nested" in files["job-b.script.sh"]


@pytest.mark.parametrize(
    "image, shell",
    [
        ("python:3.11-slim", "bash"),
        ("python:3.12-slim", "bash"),
        ("python:3.12", "bash"),
        ("python:3.12-slim-bookworm", "bash"),
        ('"${HAF_APP_TEST_RUNNER_IMAGE}"', "bash"),
        ("$HAF_APP_TEST_RUNNER_IMAGE", "bash"),
        # busybox ash: linting these as bash would hide every SC3xxx finding.
        ("python:3.12-alpine", "sh"),
        ("python:3.12-alpine3.20", "sh"),
        ("alpine:3.20", "sh"),
        ("postgres:14-alpine", "sh"),
        ("docker:24", "sh"),
        ("koalaman/shellcheck-alpine:v0.11.0", "sh"),
        ("docker.io/library/python:3.12-slim", "bash"),
        ("python:3.12-slim@sha256:" + "0" * 64, "bash"),
        ("docker.io/python:3", "bash"),
        ("library/python:3.12-slim", "bash"),
        # A tag that only LOOKS like a version, a malformed digest, a trailing newline.
        ("python:alpine3.20", "sh"),
        ("python:3.12@sha256:abc", "sh"),
        ("python@sha256:abc", "sh"),
        ('"python:3.12-slim\\n"', "sh"),  # YAML escape: the value ends in a real newline
        ("python:3.12.4-slim", "bash"),
        ("python:3.12-buster", "sh"),
        # The runner variable only as itself: a longer name or unbalanced braces is not it.
        ("$HAF_APP_TEST_RUNNER_IMAGE_ALPINE", "sh"),
        ('"${HAF_APP_TEST_RUNNER_IMAGE_X}"', "sh"),
        ('"${HAF_APP_TEST_RUNNER_IMAGE"', "sh"),
        ('"$HAF_APP_TEST_RUNNER_IMAGE}"', "sh"),
        # Any other registry path is unknown, so it gets the stricter shell.
        ("registry.example/python:3.12-slim", "sh"),
    ],
)
def test_image_to_shell(ex, image, shell):
    ci = f"# h\njob:\n  image: {image}\n  script:\n  - true\n"
    assert ex.extract(ci)["job.script.sh"].startswith(f"# shellcheck shell={shell}\n")


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
