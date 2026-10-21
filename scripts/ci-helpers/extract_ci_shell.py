#!/usr/bin/env python3
"""Write the shell embedded in .gitlab-ci.yml out as files shellcheck can read (#90).

shell-lint covers scripts/ and docker/, but the CI file carries a lot of shell of its own
(docker-build's smoke test alone is ~85 lines) that nothing linted.

One file per job and shell: before_script + script go together, because the runner
executes them in one shell; after_script runs in a fresh shell, so it gets its own file.
Hidden templates (.name) are included -- their shell runs wherever they are extended.

Each file is LINE-ALIGNED with .gitlab-ci.yml: a script item sits on the line it has in
the CI file and everything else is blank, so a shellcheck finding at
`ci-shell/docker-build.script.sh:640` is .gitlab-ci.yml line 640. Literal blocks (`- |`)
align exactly; folded and plain items are placed at their first line.

`!reference [...]` items point at templates included from hive/common-ci-configuration,
which is not in this repo; they are skipped, not resolved.

Usage: extract_ci_shell.py [CI_FILE] OUT_DIR
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

SCRIPT_KEYS = ("before_script", "script", "after_script")

# The runner uses bash when the image has it and falls back to sh otherwise. Only these
# images are known to ship bash; anything else (docker:24 and alpine are busybox ash,
# and an image inherited from an included template is unknown here) is linted as POSIX
# sh, the common denominator.
BASH_IMAGES = re.compile(r"^(python:|\$\{?HAF_APP_TEST_RUNNER_IMAGE\}?$)")

# Jobs whose image is inherited from an included template, so the table above cannot
# see it. Each entry needs evidence that the job really runs bash, not a wish to silence
# SC3xxx: prepare_haf_data's own script is concatenated with .prepare_haf_data_5m's,
# which uses [[ ]] itself and has run green on that image.
JOB_SHELLS = {"prepare_haf_data": "bash"}

# The first line of the CI file is a comment, so the directive costs no alignment.
HEADER = "# shellcheck shell={shell}"


class _Loader(yaml.SafeLoader):
    """SafeLoader that accepts GitLab's !reference tag instead of refusing the file."""


def _reference(loader, node):
    return _Reference(loader.construct_sequence(node))


class _Reference(list):
    pass


_Loader.add_constructor("!reference", _reference)


def _items(node):
    """Yield (line, text) for each shell item of a script node, 0-based line."""
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
            # A block scalar's text starts on the line after its | or > indicator.
            first = item.start_mark.line + (1 if item.style in ("|", ">") else 0)
            yield first, item.value


def _mapping(node):
    return {k.value: v for k, v in node.value} if isinstance(node, yaml.MappingNode) else {}


def _image(jobs: dict, name: str, seen=()):
    """The job's image, following `extends` within this file; None if not found here."""
    job = jobs.get(name)
    if job is None or name in seen:
        return None
    image = job.get("image")
    if isinstance(image, dict):
        image = image.get("name")
    if image:
        return str(image)
    parents = job.get("extends") or []
    for parent in [parents] if isinstance(parents, str) else parents:
        found = _image(jobs, parent, seen + (name,))
        if found:
            return found
    return None


def shell_for(jobs: dict, name: str) -> str:
    if name in JOB_SHELLS:
        return JOB_SHELLS[name]
    image = _image(jobs, name)
    return "bash" if image and BASH_IMAGES.match(image) else "sh"


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
        groups = {"script": ("before_script", "script"), "after_script": ("after_script",)}
        for suffix, members in groups.items():
            lines = [""] * total
            used = False
            for member in members:
                for first, text in _items(keys.get(member)):
                    for offset, line in enumerate(text.splitlines()):
                        at = first + offset
                        if at >= len(lines):
                            lines.append("")
                        # Only a plain/folded item that YAML joined can collide; append
                        # rather than overwrite, at the cost of that item's alignment.
                        lines[at] = f"{lines[at]}\n{line}" if lines[at] else line
                    used = True
            if used:
                lines[0] = HEADER.format(shell=shell_for(jobs, name))
                # Leading dot dropped so a `*.sh` glob sees hidden templates too.
                safe = re.sub(r"[^A-Za-z0-9_.-]", "_", name).lstrip(".")
                out[f"{safe}.{suffix}.sh"] = "\n".join(lines) + "\n"
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
