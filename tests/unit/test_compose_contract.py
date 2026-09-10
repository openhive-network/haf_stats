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
REWRITER = "haf-stats-rewriter"
ENV_FILE = ROOT / "docker" / ".env"


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

# --- the published surface (#61) ---------------------------------------------------
#
# Each assertion below names the failure it catches. They were chosen by mutation --
# breaking the thing on purpose and checking that exactly one test fails -- because what
# survives a mutation is the only honest measure of what a test asserts.

CI_COMPOSE = ROOT / "docker" / "docker-compose-ci.yml"
NETWORK = "haf-network"

# The two ports whose OWNER is a contract, not a preference: 3001 is the base URL the
# README documents, and it must be the rewriter. A uniqueness check alone is blind to
# identity -- swapping the API and the rewriter keeps every port unique while putting raw
# /rpc/ back on the documented URL, silently restoring the bug this MR fixes.
#
# 5432 is deliberately NOT here. `${HAF_PORT:-5432}` exists so an operator can move it,
# and pinning it turned a legal change into a test failure.
# port -> (service that must publish it, container port it must reach). The container
# half is not decoration: PostgREST listens on 3000 and the rewriter's public server is
# :80, so forwarding a correct host port to the wrong container port gives a published
# port that connects to nothing -- with the host map, and any uniqueness check over it,
# completely unchanged.
PORT_OWNERS = {"3000": (API, "3000"), "3001": (REWRITER, "80")}

_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):-([^{}]*)\}")


def _read_env(path: Path) -> dict:
    """Parse a .env the way compose does, not the way a first draft assumed.

    `export API_PORT=3001`, `API_PORT="3001"`, `API_PORT=3001 # front door` and the
    COMBINATION of the last two are all compose-legal and all set the port. Mishandling
    any of them reports no collision on a file that cannot start.
    """
    env = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip().lstrip("﻿")
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        key, value = line.split("=", 1)
        value = value.strip()
        if value[:1] in ("'", '"'):
            # Quoted: the closing quote ends the value; anything after it is a comment.
            # Handling this only when the quote is the LAST character missed
            # `API_PORT="3001" # front door` entirely.
            close = value.find(value[0], 1)
            value = value[1:close] if close != -1 else value[1:]
        else:
            value = value.split(" #", 1)[0].strip()
        env[key.strip()] = value
    return env


def _resolve(text, env: dict) -> str:
    """Expand ${VAR:-default} with compose's semantics.

    `:-` falls back when the variable is unset OR EMPTY. `env.get(name, default)` gets
    the empty case wrong, and an empty value is what someone leaves behind when they
    blank a line out rather than deleting it.
    """
    out, passes = str(text), 0
    while "${" in out and passes < 10:                # ${A:-${B:-3001}} nests
        out = _VAR.sub(lambda m: env.get(m.group(1)) or m.group(2), out)
        passes += 1
    assert "$" not in out, (
        f"unresolved variable in {text!r}. Only ${{VAR:-default}} is handled -- give it a "
        f"default, or teach _resolve the form you need.")
    return out


def _ports(spec, env: dict):
    """(host, container) for one `ports:` entry, in every form compose accepts.

    A mis-parsed entry is silent: it yields a key that collides with nothing. The
    container half matters as much as the host half -- moving the rewriter's target from
    :80 to :81 publishes the health stub, an unconditional 204, as the front door, while
    every host port stays exactly where it was.
    """
    if isinstance(spec, dict):                        # long form
        host = _resolve(spec.get("published", ""), env).split("/")[0]
        return host, _resolve(spec.get("target", ""), env)
    text = _resolve(spec, env).split("/")[0]          # drop a /tcp suffix
    parts = text.split(":")
    if len(parts) == 1:
        return "", parts[0]                           # `- "80"` is a CONTAINER port
    host, container = parts[-2], parts[-1]
    assert re.fullmatch(r"\d+(-\d+)?", host), f"unparsed host port {host!r} in {spec!r}"
    return host, container


def _expand(host: str) -> list:
    lo, _, hi = host.partition("-")
    if not hi:
        return [lo]
    lo_n, hi_n = int(lo), int(hi)
    assert lo_n <= hi_n, f"reversed port range {host!r}"
    # A wide range would otherwise render thousands of entries into the assertion
    # message, burying the diagnosis in the CI log.
    assert hi_n - lo_n <= 64, f"port range {host!r} is too wide to check meaningfully"
    return [str(n) for n in range(lo_n, hi_n + 1)]


def _published(doc: dict, env: dict) -> dict:
    seen = {}
    for name, svc in doc["services"].items():
        for spec in (svc or {}).get("ports", []) or []:
            host, _container = _ports(spec, env)
            if not host:
                continue
            for port in _expand(host):
                assert port not in seen, (
                    f"{name} and {seen[port]} both publish host port {port}. "
                    f"`docker compose up -d` fails with `port is already allocated` and "
                    f"whichever service loses the race never starts.")
                seen[port] = name
    return seen


def _check_ports(doc: dict, env: dict, lane: str):
    seen = _published(doc, env)
    targets = {}
    for name, svc in doc["services"].items():
        for spec in (svc or {}).get("ports", []) or []:
            host, container = _ports(spec, env)
            if host:
                targets[host] = container
    for port, (owner, container) in PORT_OWNERS.items():
        assert seen.get(port) == owner, (
            f"[{lane}] host port {port} is published by {seen.get(port)}, not {owner}. "
            f"3001 is the base URL the README documents and must reach the rewriter; "
            f"swapping these keeps every port unique and silently restores the bug.")
        assert targets.get(port) == container, (
            f"[{lane}] host port {port} forwards to container port {targets.get(port)}, "
            f"not {container}. The published port then connects to nothing, or -- for "
            f"the rewriter's :81 -- to the health stub that answers everything.")


def test_no_two_services_publish_the_same_host_port():
    """The defect this module existed for and still missed.

    #61's first revision added the rewriter on ${REWRITER_PORT:-3001} while the TRACKED
    docker/.env said API_PORT=3001, so `docker compose up -d` bound 3001 twice and the
    rewriter -- the whole point of the change -- was the service that failed to start.
    `docker compose config` performs no cross-service host-port check (verified: it exits
    0 on the colliding file), so compose-validate passed it.

    Checked under BOTH resolutions, because they differ:

      * with docker/.env applied -- what an operator gets; both READMEs `cd docker` first
      * with nothing applied     -- the in-file defaults, which are what CI sees, since
        `--env-file ci.env` REPLACES docker/.env rather than layering over it

    A drift in the compose defaults alone passes the first and breaks the second. Note
    the CI lane also merges overrides/ci.yml, which this does not model -- that file
    replaces `haf`'s ports wholesale, so the defaults pass is a close proxy, not CI's
    exact resolution.
    """
    y = _require_yaml()
    doc = y.safe_load(COMPOSE.read_text(encoding="utf-8"))
    _check_ports(doc, _read_env(ENV_FILE), "docker/.env applied")
    _check_ports(doc, {}, "compose defaults only")


def test_every_service_is_on_the_app_network():
    """The generalisation of the mutation that started this.

    Deleting the rewriter's `networks:` key drops it onto compose's implicit `default`
    while everything else is on haf-network, so `proxy_pass http://haf-stats-api:3000`
    cannot resolve and EVERY documented path 502s -- while the container still reports
    HEALTHY, because the :81 probe is an unconditional 204 that never touches the
    upstream. `docker compose config` accepts it.

    Asserted for every service, not just the rewriter: the same deletion on `haf` breaks
    PGRST_DB_URI's `@haf`, and on haf-stats-setup it breaks the install -- each as total
    as the original, each with `config` still exiting 0.
    """
    y = _require_yaml()
    doc = y.safe_load(COMPOSE.read_text(encoding="utf-8"))
    for name, svc in doc["services"].items():
        nets = list((svc or {}).get("networks") or [])
        assert nets == [NETWORK], (
            f"{name} is on {nets or 'the implicit default network'}, not [{NETWORK}]. "
            f"It cannot resolve its siblings by name, and nothing in the stack reports "
            f"that as unhealthy.")


def test_no_service_carries_a_restart_policy(services):
    """scripts/install_app.sh:136 and README.md both state this about the WHOLE file.

    install_app.sh reasons from it, to justify WARN-rather-than-fail on a missing
    --is_forking. It has to hold for every service, not just the rewriter, or the key can
    be added elsewhere and falsify both documents silently.
    """
    for name, svc in services.items():
        assert "restart" not in (svc or {}), (
            f"{name} has a restart policy; install_app.sh and README.md both assert that "
            f"no service in this file does, and install_app.sh reasons from it.")


def test_the_rewriter_serves_the_public_paths(services):
    """Without this service the documented API does not exist.

    Every public path -- /network/engagement, /account/{account}/interactions -- is a
    rewrite rule mapping onto a PostgREST /rpc/ call. Delete this service and
    `docker compose up -d` gives bare PostgREST, where all 24 of them 404.
    """
    assert REWRITER in services, "the rewriter service is gone; every documented path 404s"
    svc = services[REWRITER]

    # It must be the REWRITER image. Repointed at the app image, `up` starts the wrong
    # container on the front-door port.
    assert "/rewriter:" in svc["image"], svc["image"]

    # build: matters on its own -- CI publishes SHA tags only, never :latest, so the
    # default image reference does not resolve and compose falls back to building. The
    # context must be the REPO ROOT: Dockerfile.rewriter COPYs from endpoints/ and docker/.
    assert "build" in svc, "no build: -- the default :latest tag has never been published"
    assert svc["build"]["dockerfile"] == "Dockerfile.rewriter"
    assert svc["build"]["context"] == "..", svc["build"]["context"]

    # The CONTAINER side, not just the host side. :81 is a separate server block that
    # answers /health with an unconditional 204; publishing it as the front door serves
    # the health stub for every documented path while leaving the host port map -- and
    # therefore test_no_two_services_publish_the_same_host_port -- completely unchanged.
    targets = [_ports(spec, {})[1] for spec in svc.get("ports", [])]
    assert targets == ["80"], (
        f"the rewriter must publish container port 80, not {targets}. :81 is the health "
        f"server: an unconditional 204 that answers everything and proxies nothing.")

    # Resolved under BOTH lanes, for the same reason the port test is: a value set in
    # docker/.env overrides the compose default, and pointing the proxy at a host that
    # does not exist 502s every path while the container still reports healthy.
    for lane, env in (("compose defaults", {}), ("docker/.env applied", _read_env(ENV_FILE))):
        e = svc.get("environment", {})
        assert _resolve(e.get("POSTGREST_HOST", ""), env) == API, (lane, e.get("POSTGREST_HOST"))
        assert _resolve(e.get("POSTGREST_PORT", ""), env) == "3000", (lane, e.get("POSTGREST_PORT"))

    # service_started, not service_healthy: haf-stats-api has no healthcheck, so a health
    # condition here is accepted by `config` and refused by `up`.
    dep = (svc.get("depends_on") or {}).get(API)
    assert dep and dep.get("condition") == "service_started", dep

    # :81 is a separate server block serving only /health. :80/health is a REWRITE RULE
    # reaching get_health in the database, so probing it would report the APP healthy
    # rather than the PROXY alive -- and would fail while the database is still syncing.
    # Loopback specifically: pointed elsewhere it reports another host's liveness.
    probe = " ".join(svc["healthcheck"]["test"])
    assert "127.0.0.1:81/health" in probe, f"healthcheck must probe its own :81: {probe}"


def test_the_install_sets_a_base_url_this_stack_can_serve(services):
    """#70: the document has to advertise a base URL that resolves HERE.

    endpoint_schema.sql defaults `servers` to `/haf-stats-api`, which is the node's
    route. On this stack the rewriter IS the root, so a document carrying the node's
    prefix sends every Swagger "Try it out" to /rpc/haf-stats-api/<path> -> 404.

    root() accepts only an absolute path or an http(s) origin, so a bare hostname here
    would be silently ignored and the wrong default would ship -- which is exactly what
    happened for as long as haf_api_node passed ${PUBLIC_HOSTNAME}. Assert the shape,
    not just the presence.
    """
    cmd = services[SETUP].get("command") or []
    flags = [c for c in cmd if str(c).startswith("--swagger-url=")]
    assert len(flags) == 1, f"{SETUP} must pass exactly one --swagger-url: {cmd}"

    value = flags[0].split("=", 1)[1]
    assert value.startswith("/") or value.startswith(("http://", "https://")), (
        f"--swagger-url={value!r} is neither an absolute path nor an http(s) origin, so "
        f"root() will ignore it and publish the node's /haf-stats-api prefix instead")


# The PostgREST settings that decide whether the documented surface answers at all. A
# wrong DB_SCHEMA 404s all 24 paths -- the same user-visible symptom as the missing root
# spec, and a likelier edit -- so pinning only the root spec covered one of four.
PGRST_CONTRACT = {
    "PGRST_DB_ROOT_SPEC": "root",
    "PGRST_DB_SCHEMA": "haf_stats_endpoints",
    "PGRST_DB_ANON_ROLE": "haf_stats_user",
}


@pytest.mark.parametrize("path", [COMPOSE, CI_COMPOSE], ids=lambda p: p.name)
@pytest.mark.parametrize("key,expected", sorted(PGRST_CONTRACT.items()))
def test_the_api_serves_the_curated_openapi_document(path: Path, key: str, expected: str):
    """PGRST_DB_ROOT_SPEC was absent from every compose file in this repo.

    Unset, PostgREST answers GET / with its own auto-generated introspection document
    instead of haf_stats_endpoints.root(), and the rewriter's `rewrite ^/$ /` rule is
    inert. The live node served the right document only because the PRIVATE node config
    set it -- so an operator following this repo got the wrong spec with nothing to say
    so. Neither document is identifiable from its content type: PostgREST serves its own
    as application/openapi+json and a function-backed root spec as plain
    application/json, the same as every /rpc/ route -- only the body distinguishes them.

    Both compose files, because the CI one is what public_paths.tavern.yaml's body
    assertion depends on. Removing it there would surface as a confusing title mismatch
    inside a tavern stage rather than as the missing variable it is.
    """
    y = _require_yaml()
    doc = y.safe_load(path.read_text(encoding="utf-8"))
    svc = next((s for n, s in doc["services"].items()
                if "postgrest" in (s or {}).get("image", "")), None)
    assert svc is not None, f"no PostgREST service in {path.name}"

    env = svc.get("environment", {})
    assert key in env, f"{path.name}: {key} is unset"
    # Equality, not a substring: `"root" in ...` also passes on `notroot` and `root_v2`,
    # either of which makes PostgREST 404 the root spec.
    assert _resolve(env[key], {}) == expected, (path.name, key, env[key])
