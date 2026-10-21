#!/usr/bin/env python3
"""Write the shell embedded in .gitlab-ci.yml out as files shellcheck can read (#90).

shell-lint covers scripts/ and docker/, but the CI file carries a lot of shell of its own
(docker-build's smoke test alone is ~85 lines) that nothing linted.

One file per job and shell: before_script + script go together, because the runner
executes them in one shell; after_script runs in a fresh shell, so it gets its own file.
Hidden templates (.name) are included, as template.<name>.*.sh -- their shell runs
wherever they are extended. Keys pulled in with a YAML merge (`<<: *anchor`) count.

Each file is LINE-ALIGNED with .gitlab-ci.yml: a script item sits on the line it has in
the CI file and everything else is blank, so a shellcheck finding at
`ci-shell/docker-build.script.sh:640` is .gitlab-ci.yml line 640. Block scalars start on
the line after their | or > indicator; a folded block is joined by YAML, so only its
first line is exact. An item that cannot sit on its own lines (a quoted "a\\nb" that
expands past its source line, or one anchored node used twice in the same shell) is
appended after the last CI line, under a `# .gitlab-ci.yml:N` comment, and only that
item loses alignment. Spilled items come after ALL in-place items of the file, so
flow-sensitive checks (unset variables, unreachable code, cd-then-use) see them out of
order.

NOT linted -- shell this repo runs but the extractor cannot see:
  * `!reference [...]` items. They point at templates included from
    hive/common-ci-configuration, which is not in this repo, and are skipped. Today
    that is 8 items in 4 jobs: find_haf_image, prepare_haf_data, sync
    (before_script x2, script, after_script) and pattern-test (before_script x2).
  * before_script/script/after_script inherited through `extends` from an included
    template. At the pinned include ref that is: detect_changes (before_script and
    script -- the whole job is template), regression-test and reinstall-test
    (before_script and after_script, from .haf_app_dind_complete_test), pattern-test
    (after_script), prepare_haf_data (after_script), publish_images (before_script and
    script) and cache_cleanup (script).
  * The template block that runs before prepare_haf_data's own block in the same shell,
    so prepare_haf_data is linted without the context that precedes it.
  * Templates extended WITHIN this file are linted as their own unit, not merged into
    the job: haf-drift's before_script is in template.haf_drift_template.script.sh, and
    haf-drift.script.sh holds only its own script.
  * `sh -c '...'` / `bash -c '...'` bodies are strings to shellcheck, not code.
Also:
  * find_haf_image runs bash (its image comes from the included template) but is
    linted as sh, which is stricter, not laxer.
  * shellcheck does not raise SC2164 (unchecked cd) in a block that already runs
    `set -e`, since errexit covers it.
  * A python image is bash only as `python:<version>[-slim|-bookworm|...]`, optionally
    prefixed `docker.io/`, `library/` or `docker.io/library/` and/or `@sha256:` pinned.
    Any other registry path, and tags without a version (`python:latest`,
    `python:slim`) or other variants (`-buster`), are linted as sh, which is stricter.

Usage: extract_ci_shell.py [CI_FILE] OUT_DIR
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

SCRIPT_KEYS = ("before_script", "script", "after_script")

# The runner uses bash when the image has it and falls back to sh otherwise. Only these
# images are known to ship bash: Debian-based python tags (plain, -slim, -bookworm, ...)
# and the HAF test runner. Anything else is linted as POSIX sh, the common denominator:
# docker:24, alpine, postgres:*-alpine and python:*-alpine are busybox ash, and an image
# inherited from an included template is unknown here.
BASH_IMAGES = re.compile(
    r"^((docker\.io/)?(library/)?python:\d+(\.\d+)*(-(slim|bookworm|bullseye|trixie))*"
    r"(@sha256:[0-9a-f]{64})?"
    r"|\$(HAF_APP_TEST_RUNNER_IMAGE|\{HAF_APP_TEST_RUNNER_IMAGE\}))$"
)

# Jobs whose image is inherited from an included template, so the table above cannot
# see it. Each entry needs evidence that the job really runs bash, not a wish to silence
# SC3xxx: prepare_haf_data's own script is concatenated with .prepare_haf_data_5m's,
# which uses [[ ]] itself and has run green on that image.
JOB_SHELLS = {"prepare_haf_data": "bash"}

# The first line of the CI file is a comment, so the directive costs no alignment.
HEADER = "# shellcheck shell={shell}"

MERGE = "tag:yaml.org,2002:merge"


class _Loader(yaml.SafeLoader):
    """SafeLoader that accepts GitLab's !reference tag instead of refusing the file."""


_Loader.add_constructor("!reference", lambda loader, node: loader.construct_sequence(node))


def _items(node):
    """Yield (line, span, text) for each shell item of a script node.

    line is 0-based; span is how many source lines the item occupies from there.
    """
    if node is None or node.tag == "!reference":
        return
    if isinstance(node, yaml.ScalarNode):
        node = yaml.SequenceNode("tag:yaml.org,2002:seq", [node])
    if not isinstance(node, yaml.SequenceNode):
        return
    for item in node.value:
        if isinstance(item, yaml.SequenceNode):
            # GitLab flattens nested lists; a nested !reference returns at the top.
            yield from _items(item)
        elif isinstance(item, yaml.ScalarNode):
            block = item.style in ("|", ">")
            first = item.start_mark.line + (1 if block else 0)
            # A block's end mark sits at the start of the line after it.
            last = item.end_mark.line - (1 if block and item.end_mark.column == 0 else 0)
            yield first, max(1, last - first + 1), item.value


def _mapping(node):
    """A mapping node's keys, with `<<: *anchor` merges followed (explicit keys win)."""
    if not isinstance(node, yaml.MappingNode):
        return {}
    own, merged = {}, {}
    for key, value in node.value:
        if key.tag == MERGE:
            for src in value.value if isinstance(value, yaml.SequenceNode) else [value]:
                for k, v in _mapping(src).items():
                    merged.setdefault(k, v)
        else:
            own[key.value] = value
    return {**merged, **own}


def _image(jobs: dict, name: str, seen=()):
    """The job's image, following `extends` within this file; None if not found here.

    With several parents GitLab lets the LAST one win, so they are searched in reverse.
    """
    job = jobs.get(name)
    if not isinstance(job, dict) or name in seen:
        return None
    image = job.get("image")
    if isinstance(image, dict):
        image = image.get("name")
    if image:
        return str(image)
    parents = job.get("extends") or []
    for parent in reversed([parents] if isinstance(parents, str) else parents):
        found = _image(jobs, parent, seen + (name,))
        if found:
            return found
    return None


def shell_for(jobs: dict, name: str) -> str:
    if name in JOB_SHELLS:
        return JOB_SHELLS[name]
    image = _image(jobs, name)
    # fullmatch: `$` alone would also match before a trailing newline.
    return "bash" if image and BASH_IMAGES.fullmatch(image) else "sh"


def _render(keys: dict, members, total: int):
    """Line-aligned text of the given script keys, or None when they hold no shell."""
    lines = [""] * total
    taken = [False] * total
    overflow = []
    used = False
    for member in members:
        for first, span, text in _items(keys.get(member)):
            used = True
            body = text.splitlines() or [""]
            spot = range(first, first + len(body))
            if len(body) <= span and spot.stop <= total and not any(taken[i] for i in spot):
                for i, line in zip(spot, body):
                    lines[i], taken[i] = line, True
            else:
                overflow += [f"# .gitlab-ci.yml:{first + 1}", *body]
    return "\n".join(lines + overflow) + "\n" if used else None


def _file_name(name: str, suffix: str, out: dict) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", name.lstrip("."))
    # Hidden templates get a prefix rather than a leading dot, so a `*.sh` glob sees
    # them and `.foo` cannot land on top of a job called `foo`.
    stem = f"template.{safe}" if name.startswith(".") else safe
    candidate, n = f"{stem}.{suffix}.sh", 1
    while candidate in out:  # two names that sanitise alike must not overwrite
        n += 1
        candidate = f"{stem}~{n}.{suffix}.sh"
    return candidate


def extract(ci_text: str) -> dict:
    """Map an output file name to its line-aligned contents."""
    jobs = yaml.load(ci_text, Loader=_Loader) or {}
    root = yaml.compose(ci_text, Loader=_Loader)
    total = len(ci_text.splitlines())
    out = {}
    for key_node, job_node in root.value:
        keys = _mapping(job_node)
        if not any(k in keys for k in SCRIPT_KEYS):
            continue
        name = key_node.value
        for suffix, members in (("script", ("before_script", "script")),
                                ("after_script", ("after_script",))):
            text = _render(keys, members, total)
            if text is not None:
                head, _, rest = text.partition("\n")
                assert not head, f"{name}: a script item on line 1 would lose the header"
                text = HEADER.format(shell=shell_for(jobs, name)) + "\n" + rest
                out[_file_name(name, suffix, out)] = text
    return out


def main(argv) -> int:
    if len(argv) not in (2, 3):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    ci = Path(argv[1] if len(argv) == 3 else ".gitlab-ci.yml")
    out_dir = Path(argv[-1])
    out_dir.mkdir(parents=True, exist_ok=True)
    files = extract(ci.read_text(encoding="utf-8"))
    if not files:
        # An empty directory would make the lint job pass on nothing.
        print(f"extract_ci_shell: no script blocks found in {ci}", file=sys.stderr)
        return 1
    for name, text in sorted(files.items()):
        (out_dir / name).write_text(text, encoding="utf-8", newline="\n")
    print(f"extract_ci_shell: {len(files)} files from {ci} -> {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
