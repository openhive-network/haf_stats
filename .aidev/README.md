# haf_stats under AIDEV

AIDEV verifies changes to this repository through the slots in `project.yaml`,
integrates them into `aidev/integration`, and hands that off to `develop` by merge
request (`branches.handoff`), gated by this project's GitLab CI. Merge those merge
requests **keeping the source branch**: `aidev/integration` is protected, and AIDEV's
running work is based on it. GitLab CI doesn't run for AIDEV branches (`ai/*`,
`session/*`, pushes to `aidev/integration`); see `.gitlab-ci.yml` `workflow:`. A
pipeline started from the web UI or the API still runs on `aidev/integration`.

## Suites

`.aidev/run-checks.sh <suite> <step>...` runs the named steps and writes
`test-results/<suite>/junit.xml`, one test case per step, with the step's log tail as
the failure body. `unit` also writes one case per pytest test (`unit.xml`);
`endpoint` and `install` write one case per compose service
(`endpoint/endpoint.xml`, `install/install.xml`, each service's log beside it), and
`endpoint` one per tavern test (`endpoint/tavern.xml`).

Every step is one of `.gitlab-ci.yml`'s jobs, run as that job runs it:

| Step | CI job | What |
|---|---|---|
| `shellcheck` | shell-lint | `shellcheck --severity=warning` on `scripts/` and `docker/` (and at the default severity on `.aidev/`'s own scripts) |
| `ci-shell-lint` | ci-shell-lint | `.gitlab-ci.yml`'s shell blocks, extracted by `scripts/ci-helpers/extract_ci_shell.py`, through shellcheck |
| `unit` | shell-tests | `pytest tests/unit/` |
| `sql-lint` | sql-lint | sqlfluff 3.3.0 over `db/ endpoints/`, `scripts/`, `docker/` |
| `hadolint` | hadolint | `hadolint --ignore DL3006 Dockerfile` |
| `compose-validate` | compose-validate | `docker compose config` on the six compose files, with that job's placeholder variables (no daemon is used) |
| `openapi-drift` | openapi-drift | `scripts/openapi_rewrite.sh` on a copy of the tree must reproduce `endpoints/`, and the served OpenAPI document must validate. It runs in the script's `COMMON_CI_OFFLINE=1` mode, over the generator (`process_openapi.py` at `.gitlab-ci.yml`'s `COMMON_CI_REF`) and venv baked into the runtime image; the step fails if `COMMON_CI_REF` moves until the image is rebuilt |
| `stack-pins` | — | the images `.aidev/` runs stand in for the ones CI names: the stack's `postgres:<tag>` is the CI compose files' tag, the runtime image copies `docker/docker-compose-ci.yml`'s postgrest tag and is built `FROM` `Dockerfile.rewriter`'s base (reads only the tree) |
| `endpoint` | endpoint-tests | `docker/docker-compose-ci.yml`: the mock `hafd` schema, the real processors over the fixtures, the parity and oracle checks, PostgREST, the shipped rewriter and `tavern -m 'negative or synthetic'` |
| `install` | install-test | `docker/docker-compose-ci-install.yml`: the baseline install from `.baseline/`, upgrade, reset, install, seed repair, break-schema + install-again, install under a lock holder, verify, `uninstall_app --force`, verify-gone |
| `sync` | sync | a clone of the shared 5M-block HAF for this run; `scripts/install_app.sh` into it, then the block processing (`haf_app_driver.py`, as `scripts/process_blocks.sh` runs it) to block 5,000,000 |
| `pattern` | pattern-test | `tavern -m 'not negative and not synthetic'` (the exact mainnet values) against PostgREST over the clone, anon role `haf_stats_user`; one junit case per test in `pattern.xml` |
| `regression` | regression-test | `scripts/run_verification.sh` over the clone |
| `reinstall` | reinstall-test | `scripts/install_app.sh` again over the synced clone: the three schemas' definitions unchanged, the synced block unchanged, and each install's privileges (`tests/privileges.sql`) are `tests/expected_privileges.txt` |

`endpoint` and `install` replay the compose file itself with
`.aidev/compose_lane.py`, so a service added to either lane runs here too: a slot has
no docker daemon, so each service runs as a process in the runtime container (the
`postgres` service is the stack's). Container paths of bind mounts are rewritten to
the tree's files, also inside mounted shell scripts; services that run the app image
run `docker/docker_entrypoint.sh` over `/app` (a link the runtime image points at the
`db/`, `endpoints/` and `scripts/` the service mounts, else the tree's); the rewriter
is openresty over the tree's `docker/haf_stats_nginx.conf.template` and
`endpoints/rewrite_rules.conf`, rendered as `docker/rewriter_entrypoint.sh` renders
them, on ports 18080/18081 instead of 80/81. A compose service shape the driver does
not know fails the step with its name.

`install`'s baseline is CI's rule moved onto the checkout: `HEAD`, or `HEAD~1` when
`db/`, `endpoints/` and `scripts/` are unchanged against `HEAD`
(`AIDEV_INSTALL_BASELINE=<rev>` overrides). Each of the two lanes starts on a freshly
created `haf_block_log` with every role but `postgres` dropped, as a new container
gives CI.

| Slot | Steps | Stack |
|---|---|---|
| quick | shellcheck, ci-shell-lint, unit, sql-lint, hadolint, compose-validate, openapi-drift, stack-pins | no |
| coverage | shellcheck, unit, sql-lint | no |
| full, canary | quick's plus endpoint, install | yes |
| baseline | unit, endpoint, install | yes |

`static` and `system` are unbound: AIDEV runs neither for a project.

### The synced lane

`sync`, `pattern`, `regression` and `reinstall` are CI's synced lane over a
copy-on-write clone of AIDEV's shared 5M-block HAF (`sandbox.external` provider
`haf/haf`, `haf_shared.clone_run_database`), dropped when the script exits. CI installs
and syncs as `haf_admin`; here everything runs as `haf_shared_consumer`, the clone's
only login, which hive/haf's `.aidev/shared-haf/app-roles/haf_stats.sql` makes a member
of `haf_stats_owner` (haf#391). That is why `db/builtin_roles.sql` touches a role,
membership or role setting only when it lacks what the file sets, and grants
`hafd`/`hive` only as a role holding their grant option: the consumer may do neither.
Where it differs from CI:

- the block processing runs `haf_app_driver.py` as `haf_stats_owner` with
  `--stop-at-block=5000000`, not the `haf-stats-process` container; the
  block-processing healthcheck and the rewriter request in CI's `sync` are not run;
- PostgREST logs in as the consumer, not `haf_stats_owner`, and switches to the same
  anon role;
- `reinstall` compares a catalog snapshot (`.aidev/schema_snapshot.sql`), not
  `pg_dump --schema-only`: the runtime's pg_dump is older than the shared HAF's
  server, which it refuses. It leaves out the consumer's own membership of
  `haf_stats_owner`, and `haf_stats_app.refresh_rc_op_stats()` when the install could
  not create it (PL/Python is untrusted: only a superuser may);
- `regression` runs as the consumer, which reads `hafd.contexts` through
  `hive_applications_owner_group`.

**Not bound yet.** In the clone `haf_stats_user` cannot read `hafd` or `hive`: it is
in no HAF group, the shared HAF grants it nothing there, and the consumer holds no
grant option on either schema, so `db/builtin_roles.sql` warns instead of granting.
The install then stops at its `GET /sync-status` assertion (`hive.is_instance_ready()`
as `haf_stats_user`), and every endpoint that reads `hafd` would answer 42501. The
shared HAF has to grant `haf_stats_user` `USAGE` on `hafd` and `hive`, `SELECT` on
their tables and `EXECUTE` on `hive`'s functions in its template, as
`db/builtin_roles.sql` does as `haf_admin`. Until it does, `full` and `canary` do not
run the lane (every haf_stats change would fail them), and the profile does not
declare `sandbox.external`. Binding it then is two edits to `project.yaml`: the
external service

```yaml
sandbox:
  external:
    - name: haf
      provider: "haf/haf"
```

beside `compose`, and `sync pattern regression reinstall` appended to `full`'s and
`canary`'s args with a `timeout:` sized from a recorded run (CI's sync takes about
7 minutes and regression-test about 4.5). Run by hand meanwhile, with the provider's
endpoint (`api_v1.shared_service_endpoints` on central) in
`AIDEV_EXTERNAL_HAF_HOST`/`_PORT`:

```bash
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/w" -w /w \
    -e AIDEV_EXTERNAL_HAF_HOST=<host> -e AIDEV_EXTERNAL_HAF_PORT=<port> "$image" \
    .aidev/run-checks.sh synced sync pattern regression reinstall
```

### Not bound

- **haf-drift, haf-drift-develop** — they fetch hive/haf over the network.

New exact-value tavern patterns (the synced lane's) cannot be produced by AIDEV: it
has no synced data. Push the test with a placeholder expected value to a scratch
branch, run its pipeline, take the `pattern-test` job's actual output, and **check
each value against independent data** before committing it: an unchecked value
records whatever bug the change has as the expected one. The `synthetic` tests'
fixtures (`tests/*_fixture.sql`) are closed-world and can be derived from the
fixture by hand.

## The test stack (`test-stack.compose.yml`)

One service, `postgres`: the `postgres:14-alpine` both CI stub lanes start, pinned by
digest, with the same database, user and password. Nothing is replayed.

To run the stack checks by hand:

```bash
docker compose -p haf-stats-checks -f .aidev/test-stack.compose.yml up -d --wait
image="$(grep -o 'registry[^"]*aidev-tests@sha256:[0-9a-f]*' .aidev/project.yaml)"
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/w" -w /w --network haf-stats-checks_default "$image" \
    .aidev/run-checks.sh full shellcheck ci-shell-lint unit sql-lint hadolint compose-validate openapi-drift stack-pins endpoint install
docker compose -p haf-stats-checks -f .aidev/test-stack.compose.yml down -v
```

When the CI compose files' `postgres` tag moves, re-pin the stack's image to that
tag's digest; when their postgrest tag or `Dockerfile.rewriter`'s base moves, rebuild
the runtime image (below). `stack-pins` fails until they match.

## The test runtime image (`runtime/`)

The checks run in a container with your uid: `Dockerfile.rewriter`'s base
(common-ci-configuration's openresty image), plus bash, `psql`, python3 and git,
`install_with_app_lock.py` and `haf_app_driver.py` from `psql:14-3` (the app image's
base), PostgREST 12.2.3, ShellCheck 0.11.0, hadolint, the docker CLI and its compose
plugin, tavern 3.7.1 + pytest 8.4.2 (what CI's tavern lanes install) with pyyaml and
openapi-spec-validator in `/opt/venv`, sqlfluff 3.3.0, and `scripts/openapi_rewrite.sh`'s
generator and venv; every base pinned by digest, nothing installed at run time.

When `runtime/Dockerfile` changes, rebuild and re-pin **in the same commit**:

```bash
.aidev/runtime/build.sh --push   # registry digest if aidev-<input hash> exists, else build + push
# put the printed repo@sha256:<digest> into project.yaml environment.image
```

To build through a pull-through registry cache near the build host, set
`AIDEV_IMAGE_CACHE_BY_REGION` to `region=host:port` pairs, e.g.
`eu=cache.example.org:5001,*=cache2.example.org:5001`: a pair applies when its region is
a label of the host's FQDN, and `*` applies to any other host. Unset, the image is built
straight from `registry.gitlab.syncad.com`.
