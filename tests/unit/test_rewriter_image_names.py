"""What every job that publishes the rewriter image actually publishes.

The rewriter is published as `haf_stats/postgrest-rewriter`, the name every sibling app
uses. Until #83 it was `haf_stats/rewriter`; the rename ran through a transition that
published both names from one image, and the old name is now retired -- published by
no job at all.

Four jobs publish the rewriter (docker-build-rewriter, publish_latest, publish_tag,
publish_images). A partial edit to any of them goes unnoticed in CI: a name that stops
moving at one site, a reference tagged from the wrong image, a push swallowed by
`|| true`. So these tests do not grep the YAML for names -- a name mentioned in a shell
comment inside a block scalar would satisfy that. They RUN each job's script under bash
with a stub `docker` that records every call, replay those calls to work out which image
each pushed reference actually holds, and assert on the EXACT set of references pushed.
That exactness is also what keeps the retired name retired: re-adding it anywhere
changes the set.
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
from pathlib import Path

import pytest

from tests.unit.shell_harness import clean_env, require_bash, write_exec

try:
    import yaml
except ImportError:  # pragma: no cover - depends on the environment, not the code
    yaml = None

ROOT = Path(__file__).resolve().parents[2]
CI = ROOT / ".gitlab-ci.yml"

NEW = "postgrest-rewriter"
# Retired by #83 step 3. Kept only so the tests can say, explicitly, that it is gone.
OLD = "rewriter"
# Every name the rewriter is published under. One, since #83 retired OLD.
REWRITER_NAMES = (NEW,)
# PUBLISH_IMAGES, exactly, in order: the template pushes entries in order and stops at
# the first refusal.
MIRROR_ORDER = ("haf_stats", NEW)

IMG = "registry.example.com/hive/haf_stats"
SHA = "0badc0de"
TAG = "1.28.6"
TIMEOUT = 60


def _require_yaml():
    # Same rule as test_compose_contract: vanishing from CI would be the silent hole.
    if yaml is not None:
        return yaml
    if os.environ.get("CI"):
        pytest.fail("PyYAML is unavailable, so the image-name tests cannot run in CI")
    pytest.skip("PyYAML is required to parse .gitlab-ci.yml")


@pytest.fixture(scope="module")
def jobs() -> dict:
    y = _require_yaml()

    class Loader(y.SafeLoader):
        pass

    # GitLab's !reference is not YAML; keep it as the list it contains.
    Loader.add_constructor("!reference",
                           lambda loader, node: loader.construct_sequence(node))
    return y.load(CI.read_text(encoding="utf-8"), Loader=Loader)


def _run_job(job: dict, tmp_path: Path, fail: str | None = None,
             **ci_vars: str) -> list[list[str]]:
    """Run a job's `script:` under bash with a recording docker; return the calls.

    Items are joined into one script under `set -eo pipefail`, which is how the GitLab
    runner executes them: in one shell, stopping at the first failing command. With
    `fail`, that docker call exits 1 and the JOB must then fail too.
    """
    bash = require_bash()
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    log = tmp_path / "docker.log"
    # One line per call, arguments separated by \037, so an argument containing a space
    # (CI_COMMIT_TITLE does) is recorded as the single argument it was.
    # DOCKER_FAIL="<verb> <last argument>" makes that one call exit 1 after recording it,
    # so the tests can check a job STOPS at a failed pull or push rather than carrying on.
    write_exec(bindir / "docker",
               "#!/bin/sh\n"
               "for a in \"$@\"; do printf '%s\\037' \"$a\"; done >> \"$DOCKER_LOG\"\n"
               "printf '\\n' >> \"$DOCKER_LOG\"\n"
               "for last in \"$@\"; do :; done\n"
               "if [ -n \"$DOCKER_FAIL\" ] && [ \"$1 $last\" = \"$DOCKER_FAIL\" ]; then\n"
               "  exit 1\n"
               "fi\n"
               "exit 0\n")
    script = tmp_path / "job.sh"
    body = "\n".join(item for item in job["script"] if isinstance(item, str))
    with open(script, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("set -eo pipefail\n" + body + "\n")

    env = clean_env(bindir)
    for key in [k for k in env if k.startswith("CI_")]:
        del env[key]
    env.update({
        "DOCKER_LOG": log.as_posix(),
        "CI_REGISTRY_IMAGE": IMG,
        "CI_COMMIT_SHORT_SHA": SHA,
        "CI_COMMIT_SHA": SHA + "f" * 32,
        "CI_COMMIT_TITLE": "a title with spaces",
        "CI_JOB_STARTED_AT": "2026-09-16T00:00:00Z",
        "DOCKER_FAIL": fail or "",
        **ci_vars,
    })
    result = subprocess.run([bash, script.as_posix()], env=env, capture_output=True,
                            text=True, timeout=TIMEOUT)
    if fail is None:
        assert result.returncode == 0, (
            f"job script failed:\n{result.stdout}\n{result.stderr}")
    else:
        assert result.returncode != 0, (
            f"`docker {fail}` failed and the job carried on to succeed")
    if not log.exists():
        return []
    lines = log.read_text(encoding="utf-8").splitlines()
    return [line.split("\x1f")[:-1] for line in lines]


def _replay(calls: list[list[str]]) -> tuple[dict, list[str]]:
    """Work out which image every PUSHED reference holds.

    Returns ({pushed_ref: image_identity}, [verb per call]). An image's identity is
    where its bytes came from: `built#N` for the Nth build, or `pulled:<ref>`. `tag`
    copies identity; a tag or push of a reference nothing produced is a script bug and
    fails here, since on a real runner it fails too.
    """
    local, pushed, verbs, builds = {}, {}, [], 0
    for call in calls:
        verb, args = call[0], call[1:]
        verbs.append(verb)
        if verb == "build":
            builds += 1
            refs, context, i = [], [], 0
            while i < len(args):
                if args[i] in ("-t", "--tag"):
                    refs.append(args[i + 1])
                    i += 2
                elif args[i] in ("-f", "--file", "--build-arg", "--label", "--target",
                                 "--platform", "--cache-from", "--cache-to", "--output",
                                 "--secret", "--ssh", "--network"):
                    i += 2
                elif args[i].startswith("-"):
                    i += 1
                else:
                    context.append(args[i])
                    i += 1
            assert refs, f"docker build with no -t: {call}"
            # Exactly one build context. ` .` shares a line with the last -t, so deleting
            # that line -- e.g. while resolving a conflict -- drops the context too; docker
            # then fails, but nothing here would notice without this.
            assert len(context) == 1, (
                f"docker build needs one build context, got {context}: {call}")
            for ref in refs:
                local[ref] = f"built#{builds}"
            # `docker build --push` publishes every -t directly, without a docker push.
            if "--push" in args or any("push=true" in a for a in args):
                for ref in refs:
                    pushed[ref] = local[ref]
        elif verb == "pull":
            local[args[-1]] = f"pulled:{args[-1]}"
        elif verb == "tag":
            src, dst = args[-2], args[-1]
            assert src in local, f"tagged {src}, which was never built or pulled"
            local[dst] = local[src]
        elif verb == "push":
            assert args[-1] in local, f"pushed {args[-1]}, which does not exist locally"
            pushed[args[-1]] = local[args[-1]]
        elif verb != "login":
            pytest.fail(f"unexpected docker call: {call}")
    return pushed, verbs


def _shell_lines(script: str) -> list[str]:
    """Command lines of a script item: comments dropped, backslash continuations joined.

    Joined the way the shell does, so a command split across lines is tokenised whole --
    and a comment line is dropped BEFORE joining, because a trailing backslash does not
    continue a comment.
    """
    out, pending = [], ""
    for raw in script.splitlines():
        line = raw.strip()
        if not pending and line.startswith("#"):
            continue
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        out.append(pending + line)
        pending = ""
    if pending:
        out.append(pending)
    return out


def _rewriter_refs(tag: str) -> set[str]:
    return {f"{IMG}/{name}:{tag}" for name in REWRITER_NAMES}


# --- the build ---------------------------------------------------------------------

def test_docker_build_rewriter_pushes_what_it_built(jobs, tmp_path):
    """One build, exactly the rewriter references expected -- no more -- and each holds
    that build. BUILD_TIME is baked into an OCI label, so a second build is a second
    digest."""
    pushed, verbs = _replay(_run_job(jobs["docker-build-rewriter"], tmp_path,
                                     CI_COMMIT_BRANCH="develop"))
    assert verbs.count("build") == 1, verbs
    assert set(pushed) == _rewriter_refs(SHA), sorted(pushed)
    assert set(pushed.values()) == {"built#1"}, (
        f"pushed something it did not build: {pushed}")


def test_docker_build_rewriter_pushes_nothing_on_a_tag(jobs, tmp_path):
    """#66's property: a tag pipeline rebuilds, and must not overwrite the SHA tags a
    develop pipeline already published."""
    pushed, _ = _replay(_run_job(jobs["docker-build-rewriter"], tmp_path,
                                 CI_COMMIT_TAG=TAG, CI_COMMIT_REF_PROTECTED="true"))
    assert pushed == {}, sorted(pushed)


def test_sync_pins_the_new_name(jobs):
    """The only pre-release lane that pulls the rewriter. Left on the old name, it would
    say nothing about whether the new one was published."""
    assert (jobs["sync"]["variables"]["HAF_STATS_REWRITER_IMAGE"]
            == "${CI_REGISTRY_IMAGE}/" + NEW + ":${CI_COMMIT_SHORT_SHA}")
    # ...and no other compose file sync merges replaces it. An image: or build: on the
    # rewriter in an override wins over the interpolated default outright. (An earlier
    # revision pinned the `HAF_STATS_REWRITER_IMAGE=...` line sync writes into ci.env
    # instead. That checked nothing: the variable is also in the job's environment, and
    # compose lets the shell environment win over --env-file, so a literal in ci.env is
    # ignored.)
    y = _require_yaml()
    words = jobs["sync"]["variables"]["COMPOSE_OPTIONS_STRING"].split()
    compose_files = [words[i + 1] for i, word in enumerate(words) if word == "--file"]
    assert compose_files[:1] == ["docker-compose.yml"], compose_files
    for name in compose_files[1:]:
        doc = y.safe_load((ROOT / "docker" / name).read_text(encoding="utf-8")) or {}
        svc = (doc.get("services") or {}).get("haf-stats-rewriter") or {}
        assert not {"image", "build"} & set(svc), (
            f"docker/{name} sets haf-stats-rewriter's image or build, bypassing the pin")


def test_sync_cannot_silently_build_the_rewriter(jobs):
    """Without --no-build, a rewriter image that was never published does not fail sync.

    haf-stats-rewriter has a build: stanza, so a failed pull makes `docker compose up`
    build the working tree and carry on -- job 3270294 went green that way. Pinning the
    new name above would then prove nothing, because a missing image is indistinguishable
    from a present one. Checked on the command lines themselves, not the comments.
    """
    lines = [line for item in jobs["sync"]["script"] if isinstance(item, str)
             for line in _shell_lines(item)]
    # Shell-tokenised, so `--no-build; then` yields `--no-build` and `;` separately, then
    # split into simple commands at the separators, so a `--no-build` in a DIFFERENT
    # command on the same line (`up ...; then : --no-build`) does not count. Only lines
    # mentioning compose are tokenised: others in this script (heredoc bodies, trailing
    # backslashes) are not complete shell words on their own.
    separators = {";", "&&", "||", "|", "&", "!", "(", ")", "if", "then", "do", "else", "elif"}
    commands = []
    for line in lines:
        if "compose" not in line:
            continue
        current = []
        for word in shlex.shlex(line, posix=True, punctuation_chars=True):
            if word in separators:
                commands.append(current)
                current = []
            else:
                current.append(word)
        commands.append(current)
    composes = [words for words in commands if words[:2] == ["docker", "compose"]]
    ups = [words for words in composes if "up" in words]
    assert ups, "sync no longer runs `docker compose ... up`; update this test"
    for words in ups:
        assert "--no-build" in words, (
            f"sync's `up` can fall back to building: {' '.join(words)}")
    # A `compose build` first, or `up --build`, satisfies --no-build with a LOCAL image:
    # nothing is pulled, and the pin proves nothing again.
    builds = [words for words in composes if "build" in words or "--build" in words]
    assert not builds, f"sync builds the stack's images itself: {builds}"


# --- the retag jobs ----------------------------------------------------------------

@pytest.mark.parametrize("job_name, target, ci_vars", [
    ("publish_latest", "latest", {"CI_COMMIT_BRANCH": "develop"}),
    ("publish_tag", TAG, {"CI_COMMIT_TAG": TAG, "CI_COMMIT_REF_PROTECTED": "true"}),
])
def test_retag_jobs_publish_every_name_from_the_tested_image(jobs, tmp_path, job_name, target,
                                                             ci_vars):
    pushed, verbs = _replay(_run_job(jobs[job_name], tmp_path, **ci_vars))

    assert set(pushed) == {f"{IMG}:{target}"} | _rewriter_refs(target), sorted(pushed)

    # The released bytes are the tested bytes: each name holds the SHA image the develop
    # pipeline built -- every rewriter name the one published under the NEW name.
    assert pushed[f"{IMG}:{target}"] == f"pulled:{IMG}:{SHA}"
    for ref in _rewriter_refs(target):
        assert pushed[ref] == f"pulled:{IMG}/{NEW}:{SHA}", (
            f"{ref} holds {pushed[ref]}, not the image published as {NEW}:{SHA}")

    # Tag everything, THEN push everything (#66): a failed pull must not leave a name
    # half-moved -- easy to break by pushing inside the tag loop.
    last_prep = max(i for i, v in enumerate(verbs) if v in ("pull", "tag"))
    first_push = min(i for i, v in enumerate(verbs) if v == "push")
    assert first_push > last_prep, f"a push precedes the last pull/tag: {verbs}"


@pytest.mark.parametrize("job_name, target, ci_vars", [
    ("publish_latest", "latest", {"CI_COMMIT_BRANCH": "develop"}),
    ("publish_tag", TAG, {"CI_COMMIT_TAG": TAG, "CI_COMMIT_REF_PROTECTED": "true"}),
])
@pytest.mark.parametrize("verb, name", [("pull", None), ("pull", NEW), ("push", None)]
                         + [("push", rewriter) for rewriter in REWRITER_NAMES])
def test_retag_jobs_stop_at_a_failed_docker_call(jobs, tmp_path, job_name, target, ci_vars,
                                                 verb, name):
    """A failed pull publishes NOTHING, and a failed push fails the job.

    The stub never fails unless told to, so without this a `|| continue` on the pull or a
    `|| true` on a push -- both plausible edits, e.g. to tolerate a SHA that predates #83
    -- passes every other test here. For real, the first releases the app under the new
    tag with no rewriter beside it; the second reports a release that did not happen.
    Every push is failed in turn. (`name` None is the app image.)
    """
    tag = SHA if verb == "pull" else target
    ref = f"{IMG}:{tag}" if name is None else f"{IMG}/{name}:{tag}"
    calls = _run_job(jobs[job_name], tmp_path, fail=f"{verb} {ref}", **ci_vars)
    if verb == "pull":
        pushes = [c for c in calls if c[0] == "push"]
        assert not pushes, f"pushed after a failed pull: {pushes}"


@pytest.mark.parametrize("name", REWRITER_NAMES)
def test_docker_build_rewriter_stops_at_a_failed_push(jobs, tmp_path, name):
    _run_job(jobs["docker-build-rewriter"], tmp_path, fail=f"push {IMG}/{name}:{SHA}",
             CI_COMMIT_BRANCH="develop")


def _repository(ref: str) -> str:
    """`registry/path/name:tag` -> `registry/path/name`. A tag is a colon after the last
    slash; a colon before it would be a registry port."""
    head, slash, tail = ref.rpartition("/")
    return head + slash + tail.split(":", 1)[0]


# Any reference to the retired repository -- $CI_REGISTRY_IMAGE/rewriter,
# ${CI_REGISTRY_IMAGE}/rewriter or .../haf_stats/rewriter, tagged or not. Deliberately
# broad: a loop, a variable holding the path, `docker image push` or `buildx imagetools
# create` all publish without a `docker push .../rewriter` line. The price is flagging a
# harmless mention in an echo too; that failure names the line, so adjust this test if a
# reference is ever legitimate.
_RETIRED_REF = re.compile(
    r"(?:\$\{?CI_REGISTRY_IMAGE\}?|/haf_stats)/" + re.escape(OLD) + r"(?![\w-])")


def test_the_retired_rewriter_name_is_published_nowhere(jobs, tmp_path):
    """#83 retired `haf_stats/rewriter`. Checked two ways, because each sees what the other
    cannot.

    RUN the three publishing jobs' scripts and compare the REPOSITORY of every pushed
    reference -- so an untagged push (implicitly `:latest`) is caught too.

    SCAN every job in the file -- script, before_script, after_script, variables and
    rules[].variables -- for ANY reference to the retired repository in a script line or
    a variable value, or an old-name PUBLISH_IMAGES entry. The run only sees the
    `script:` of known jobs on the pipeline types it simulates; an after_script, a new
    job, a branch-guarded push or a rules:variables override of PUBLISH_IMAGES would get
    past it.
    """
    old_repo = f"{IMG}/{OLD}"
    runs = [("docker-build-rewriter", {"CI_COMMIT_BRANCH": "develop"}),
            ("publish_latest", {"CI_COMMIT_BRANCH": "develop"}),
            ("publish_tag", {"CI_COMMIT_TAG": TAG, "CI_COMMIT_REF_PROTECTED": "true"})]
    for job_name, ci_vars in runs:
        job_dir = tmp_path / job_name
        job_dir.mkdir()
        pushed, _ = _replay(_run_job(jobs[job_name], job_dir, **ci_vars))
        bad = sorted(ref for ref in pushed if _repository(ref) == old_repo)
        assert not bad, f"{job_name} publishes the retired {OLD} name again: {bad}"

    offenders = []
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        for key in ("before_script", "script", "after_script"):
            for item in job.get(key) or []:
                if isinstance(item, str):
                    offenders += [f"{job_name}.{key}: {line}"
                                  for line in _shell_lines(item)
                                  if _RETIRED_REF.search(line)]
        variable_sets = [job] if job_name == "variables" else [job.get("variables") or {}]
        variable_sets += [rule.get("variables") or {} for rule in job.get("rules") or []
                          if isinstance(rule, dict)]
        for variables in variable_sets:
            if not isinstance(variables, dict):
                continue
            entries = str(variables.get("PUBLISH_IMAGES", "")).split()
            if OLD in entries:
                offenders.append(f"{job_name}: PUBLISH_IMAGES={entries}")
            # A variable holding the retired path, pushed later as "$VAR:tag".
            for name, value in variables.items():
                text = str(value.get("value", "") if isinstance(value, dict) else value)
                if _RETIRED_REF.search(text):
                    offenders.append(f"{job_name}: variable {name}={text!r}")
    assert not offenders, (
        "the retired rewriter name is published again:\n" + "\n".join(offenders))


# --- the mirror --------------------------------------------------------------------

def test_the_mirror_list_is_exactly_what_publish_tag_creates(jobs, tmp_path):
    """.docker_publish_job_template pulls each PUBLISH_IMAGES entry from the GitLab
    registry BY TAG. An entry publish_tag does not create fails the release; a name
    publish_tag creates but the mirror omits never reaches registry.hive.blog -- which
    is where haf_api_node's default resolves the rewriter."""
    publish_images = jobs["publish_images"]["variables"]["PUBLISH_IMAGES"].split()
    project = "haf_stats"
    mirrored = {f"{IMG}:{TAG}" if entry == project else f"{IMG}/{entry}:{TAG}"
                for entry in publish_images}

    pushed, _ = _replay(_run_job(jobs["publish_tag"], tmp_path,
                                 CI_COMMIT_TAG=TAG, CI_COMMIT_REF_PROTECTED="true"))
    assert mirrored == set(pushed), (
        f"PUBLISH_IMAGES {publish_images} does not match what publish_tag pushes: "
        f"{sorted(pushed)}")
    # ORDER too, which the set comparison above cannot see. See MIRROR_ORDER.
    assert tuple(publish_images) == MIRROR_ORDER, publish_images
    assert len(publish_images) == len(set(publish_images)), publish_images
    # Everything this test reasons from -- pull-by-tag, the root-vs-subpath mapping,
    # push order and stop-at-first-failure -- is .docker_publish_job_template's
    # behaviour. A job that stopped extending it, or overrode the target project name,
    # would leave the checks above passing against a mirror that no longer works
    # this way.
    job = jobs["publish_images"]
    assert job.get("extends") == ".docker_publish_job_template", job.get("extends")
    assert "PUBLISH_PROJECT_NAME" not in (job.get("variables") or {}), job.get("variables")
    # ...nor replaced the template's script while still extending it.
    assert "script" not in job, job.get("script")
