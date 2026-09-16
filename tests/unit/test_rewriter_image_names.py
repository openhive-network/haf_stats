"""The rewriter image is published under BOTH names until #83 retires the old one.

haf_stats published its rewriter as `haf_stats/rewriter`; every sibling app publishes
`postgrest-rewriter`. By the time that was noticed the old name had consumers -- testapi
pins it by SHA and haf_api_node's haf_stats.yaml defaults to it -- so the rename runs
through a transition: every publish site emits both names, from one image, until those
consumers move, and then the old name is dropped everywhere at once.

The failure this module exists for is a PARTIAL edit. Four jobs publish the rewriter
(docker-build-rewriter, publish_latest, publish_tag, publish_images). Miss one and
nothing goes red: the old name simply stops moving at that site, and whoever still
follows it keeps running a stale rewriter without being told. The same is true of
tagging the old name from the wrong image, which leaves two names that no longer mean
the same thing.

So these tests do not grep the YAML for names -- a name mentioned in a shell comment
inside a block scalar would satisfy that. They RUN each job's script under bash with a
stub `docker` that records every call, replay those calls to work out which image each
pushed reference actually holds, and assert on the result.

RETIRING THE OLD NAME is an edit to REWRITER_NAMES below, made together with the four
sites. That is deliberate: it turns the last step of #83 into a visible change here
rather than something that can happen by accident. The same step must DELETE
`rewriter:latest` from the registry, which no test here can check: left behind, it
freezes while haf_stats:latest moves on, and pre-rename checkouts pair the two.
"""

from __future__ import annotations

import os
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
OLD = "rewriter"
# The first entry is the name; the rest are aliases published from the same image.
# #83's last step removes OLD from this tuple and from the four publish sites together.
REWRITER_NAMES = (NEW, OLD)

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
            refs = [args[i + 1] for i, a in enumerate(args) if a == "-t"]
            assert refs, f"docker build with no -t: {call}"
            for ref in refs:
                local[ref] = f"built#{builds}"
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


def _rewriter_refs(tag: str) -> set[str]:
    return {f"{IMG}/{name}:{tag}" for name in REWRITER_NAMES}


# --- the build ---------------------------------------------------------------------

def test_docker_build_rewriter_pushes_every_name_from_one_build(jobs, tmp_path):
    """Both names, one build. Two builds would be two digests: BUILD_TIME is baked into
    an OCI label, so an old name built separately would stop being an alias."""
    pushed, verbs = _replay(_run_job(jobs["docker-build-rewriter"], tmp_path,
                                     CI_COMMIT_BRANCH="develop"))
    assert verbs.count("build") == 1, verbs
    assert set(pushed) == _rewriter_refs(SHA), sorted(pushed)
    assert len(set(pushed.values())) == 1, f"the names hold different images: {pushed}"


def test_docker_build_rewriter_pushes_nothing_on_a_tag(jobs, tmp_path):
    """#66's property, which the extra push must not have broken: a tag pipeline rebuilds
    and must not overwrite the SHA tags a develop pipeline already published."""
    pushed, _ = _replay(_run_job(jobs["docker-build-rewriter"], tmp_path,
                                 CI_COMMIT_TAG=TAG, CI_COMMIT_REF_PROTECTED="true"))
    assert pushed == {}, sorted(pushed)


def test_sync_pins_the_new_name(jobs):
    """The only pre-release lane that pulls the rewriter. Left on the old name, it would
    say nothing about whether the new one was published."""
    assert (jobs["sync"]["variables"]["HAF_STATS_REWRITER_IMAGE"]
            == "${CI_REGISTRY_IMAGE}/" + NEW + ":${CI_COMMIT_SHORT_SHA}")
    # ...and that variable is what reaches compose: sync writes it into ci.env, which is
    # the --env-file compose reads. A literal there would bypass the pin entirely.
    lines = [line.strip() for item in jobs["sync"]["script"] if isinstance(item, str)
             for line in item.splitlines()]
    assert "HAF_STATS_REWRITER_IMAGE=${HAF_STATS_REWRITER_IMAGE}" in lines, (
        "sync's ci.env no longer passes HAF_STATS_REWRITER_IMAGE through to compose")


def test_sync_cannot_silently_build_the_rewriter(jobs):
    """Without --no-build, a rewriter image that was never published does not fail sync.

    haf-stats-rewriter has a build: stanza, so a failed pull makes `docker compose up`
    build the working tree and carry on -- job 3270294 went green that way. Pinning the
    new name above would then prove nothing, because a missing image is indistinguishable
    from a present one. Checked on the command lines themselves, not the comments.
    """
    lines = [line.strip() for item in jobs["sync"]["script"] if isinstance(item, str)
             for line in item.splitlines() if not line.strip().startswith("#")]
    # Shell-tokenised, so `--no-build; then` yields `--no-build` and `;` separately. Only
    # candidate lines are tokenised: others in this script (heredoc bodies, trailing
    # backslashes) are not complete shell words on their own.
    candidates = [line for line in lines if "compose" in line and " up " in f" {line} "]
    commands = [list(shlex.shlex(line, posix=True, punctuation_chars=True))
                for line in candidates]
    ups = [words for words in commands if "compose" in words and "up" in words]
    assert ups, "sync no longer runs `docker compose ... up`; update this test"
    for words in ups:
        assert "--no-build" in words, (
            f"sync's `up` can fall back to building: {' '.join(words)}")


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
    # half-moved. With a third reference it is easy to push one inside the tag loop.
    last_prep = max(i for i, v in enumerate(verbs) if v in ("pull", "tag"))
    first_push = min(i for i, v in enumerate(verbs) if v == "push")
    assert first_push > last_prep, f"a push precedes the last pull/tag: {verbs}"


@pytest.mark.parametrize("job_name, target, ci_vars", [
    ("publish_latest", "latest", {"CI_COMMIT_BRANCH": "develop"}),
    ("publish_tag", TAG, {"CI_COMMIT_TAG": TAG, "CI_COMMIT_REF_PROTECTED": "true"}),
])
@pytest.mark.parametrize("failing", ["pull app", "pull rewriter", "push rewriter"])
def test_retag_jobs_stop_at_a_failed_docker_call(jobs, tmp_path, job_name, target, ci_vars,
                                                 failing):
    """A failed pull publishes NOTHING, and a failed push fails the job.

    The stub never fails unless told to, so without this a `|| continue` on the pull or a
    `|| true` on a push -- both plausible edits, e.g. to tolerate a SHA that predates #83
    -- passes every other test here. For real, the first releases the app under the new
    tag with no rewriter beside it; the second reports a release that did not happen.
    """
    verb, what = failing.split()
    tag = SHA if verb == "pull" else target
    ref = {"app": f"{IMG}:{tag}", "rewriter": f"{IMG}/{NEW}:{tag}"}[what]
    calls = _run_job(jobs[job_name], tmp_path, fail=f"{verb} {ref}", **ci_vars)
    if verb == "pull":
        pushes = [c for c in calls if c[0] == "push"]
        assert not pushes, f"pushed after a failed pull: {pushes}"


def test_docker_build_rewriter_stops_at_a_failed_push(jobs, tmp_path):
    _run_job(jobs["docker-build-rewriter"], tmp_path, fail=f"push {IMG}/{NEW}:{SHA}",
             CI_COMMIT_BRANCH="develop")


# --- the mirror --------------------------------------------------------------------

def test_the_mirror_list_is_exactly_what_publish_tag_creates(jobs, tmp_path):
    """.docker_publish_job_template pulls each PUBLISH_IMAGES entry from the GitLab
    registry BY TAG. An entry publish_tag does not create fails the release; a name
    publish_tag creates but the mirror omits never reaches registry.hive.blog -- which
    is where haf_api_node's default resolves the old name."""
    publish_images = jobs["publish_images"]["variables"]["PUBLISH_IMAGES"].split()
    project = "haf_stats"
    mirrored = {f"{IMG}:{TAG}" if entry == project else f"{IMG}/{entry}:{TAG}"
                for entry in publish_images}

    pushed, _ = _replay(_run_job(jobs["publish_tag"], tmp_path,
                                 CI_COMMIT_TAG=TAG, CI_COMMIT_REF_PROTECTED="true"))
    assert mirrored == set(pushed), (
        f"PUBLISH_IMAGES {publish_images} does not match what publish_tag pushes: "
        f"{sorted(pushed)}")
    assert len(publish_images) == len(set(publish_images)), publish_images
