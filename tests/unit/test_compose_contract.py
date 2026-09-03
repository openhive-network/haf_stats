"""The operational invariants that live in docker/docker-compose.yml and .gitlab-ci.yml.

Mutation testing found that these two files had NO coverage of any kind: every unit
test in this directory opens one of the shell scripts, the two healthcheck files or
uninstall_verify.sql, and nothing opens the compose file. Seven deliberate breakages
survived the whole suite, including the two below that are worse than anything the
scripts themselves can do wrong.

The worst is `profiles:` on the teardown service. Remove that one key and
`docker compose up` starts haf-stats-uninstall alongside everything else -- a
DROP SCHEMA CASCADE of all three schemas, run by default, on a stack the operator
thought they were bringing up. Nothing in the repo noticed.

These are structural assertions, not behavioural: they parse the YAML and check the
keys. That is the right instrument here -- the failure modes are all "a key changed
value" or "a key went missing", and the alternative (starting containers in CI) belongs
in docker-build, which already smoke-tests the image.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

try:
    import yaml
except ImportError:  # pragma: no cover - depends on the environment, not the code
    yaml = None


def _require_yaml():
    """Same rule shell_harness.require_bash applies to bash.

    A plain importorskip would let these tests vanish from CI the moment pyyaml fell
    out of the install line, and the pipeline would stay green with the compose file
    uncovered -- which is the state this module was written to end.
    """
    if yaml is not None:
        return yaml
    if os.environ.get("CI"):
        pytest.fail("PyYAML is unavailable, so the compose-contract tests cannot run in CI")
    pytest.skip("PyYAML is required to parse the compose file")

ROOT = Path(__file__).resolve().parents[2]
COMPOSE = ROOT / "docker" / "docker-compose.yml"
CI = ROOT / ".gitlab-ci.yml"

APP = "haf_stats"
SETUP = "haf-stats-setup"
PROCESS = "haf-stats-process"
API = "haf-stats-api"
UNINSTALL = "haf-stats-uninstall"


@pytest.fixture(scope="module")
def services() -> dict:
    doc = _require_yaml().safe_load(COMPOSE.read_text(encoding="utf-8"))
    assert "services" in doc, "compose file has no services block"
    return doc["services"]


# --- the teardown must never start by accident ------------------------------------

def test_the_uninstall_service_is_behind_a_profile(services):
    """Without `profiles:`, `docker compose up` runs the destructive teardown.

    Compose starts every service that has no profile. This one drops three schemas
    CASCADE and both roles. It is the single most dangerous key in the file and it had
    no test.
    """
    svc = services[UNINSTALL]
    profiles = svc.get("profiles")
    assert profiles, f"{UNINSTALL} must be profile-gated or `up` will run the teardown"
    assert UNINSTALL in profiles, (
        f"the profile must be namespaced to this app, not a shared name: {profiles}"
    )


def test_no_other_service_is_profile_gated(services):
    """The reason `run --rm` is documented instead of `--profile ... up`.

    Upstream profiles every app service, so `--profile x up` is safe there. Here only
    the teardown is gated, so `up` with that profile ALSO starts haf-stats-setup --
    install_app -- concurrently with the uninstall. If a second service ever gains a
    profile, that reasoning needs revisiting, so fail loudly rather than silently.
    """
    gated = sorted(n for n, s in services.items() if s.get("profiles"))
    assert gated == [UNINSTALL], f"unexpected profile-gated services: {gated}"


def test_the_teardown_runs_non_interactively(services):
    """It refuses without a TTY unless --force, and a compose run has no TTY. Without
    the flag the service hangs at a prompt nobody can answer."""
    assert services[UNINSTALL]["command"] == ["uninstall_app", "--force"]


# --- the verbs are the contract this MR exists to deliver -------------------------

@pytest.mark.parametrize(
    ("service", "verb"),
    [(SETUP, "install_app"), (PROCESS, "process_blocks"), (UNINSTALL, "uninstall_app")],
)
def test_services_invoke_the_entrypoint_verbs(services, service, verb):
    """Reverting these to /app/scripts/*.sh paths undoes the point of #57. The paths
    still WORK -- the entrypoint execs anything runnable -- so nothing else notices."""
    assert services[service]["command"][0] == verb


# --- the healthcheck this MR replaced ---------------------------------------------

def test_the_block_processing_healthcheck_is_the_in_image_script(services):
    """It replaced `psql -U haf_stats_user -c 'SELECT 1'`, which proved only that
    PostgreSQL answers -- and connected as a role that cannot see hafd.contexts, so any
    real check written that way reports unhealthy forever."""
    test = services[PROCESS]["healthcheck"]["test"]
    assert test == ["CMD", "/app/block-processing-healthcheck.sh"], test


def test_the_api_does_not_gate_on_block_processing_health(services):
    """#57 changed what `healthy` MEANS for haf-stats-process, from `SELECT 1` to a
    committed block-processing iteration. Left as service_healthy, PostgREST may never
    start on a fresh node -- and `start_period: 72h` makes it worse, since the container
    reports `starting` and the gate never releases. Upstream's postgrest does not depend
    on block-processing at all."""
    condition = services[API]["depends_on"][PROCESS]["condition"]
    assert condition == "service_started", (
        "haf-stats-api must not wait for block-processing to be HEALTHY"
    )


def test_the_processor_still_waits_for_the_install(services):
    """The relaxation above must not let PostgREST start before the schemas exist. The
    gate is transitive: api -> process -> setup(completed)."""
    assert services[PROCESS]["depends_on"][SETUP]["condition"] == "service_completed_successfully"


# --- CI assertions that cannot fail ------------------------------------------------

def test_no_inverted_pipeline_assertions_in_ci():
    """`! grep -q X file` can never fail a job: bash exempts a !-inverted pipeline from
    errexit. This MR fixed one instance; the class needs pinning, because the mutation
    is invisible to every other test in the repo and only a real pipeline run would
    catch it -- which is exactly what it stops from catching anything.
    """
    offenders = [
        (n, line.strip())
        for n, line in enumerate(CI.read_text(encoding="utf-8").splitlines(), 1)
        # Any !-inverted COMMAND, not any !-prefixed LINE. The old anchored form
        # (`^\s*!`) could not match a single YAML script item, because those are
        # `    - <cmd>` -- so `- ! grep`, `cmd && ! grep` and `x=1; ! grep` all survived,
        # i.e. everything in the class except the one instance this MR fixed.
        if re.search(r"(?:^|&&|\|\||;|\bthen\b|\bdo\b|^\s*-)\s+!\s+\S", line)
        and "#" not in line.split("!")[0]
    ]
    assert not offenders, f"inverted-pipeline assertions cannot fail a job: {offenders}"
