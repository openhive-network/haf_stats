# Tavern API tests

The tests follow the same endpoint-oriented layout as `balance_tracker`:

```text
tests/tavern/
├── common.yaml
├── pytest.ini
├── {rpc_endpoint}/
│   ├── {rpc_endpoint}.tavern.yaml
│   └── negative/
│       └── validation.tavern.yaml
└── rewriter/
    ├── rewriter_common.yaml
    └── public_paths.tavern.yaml
```

`rewriter/` is the one directory not named after an RPC function, because it is
the one suite that does not address PostgREST directly: it requests the public
clean URLs through the nginx rewriter so that `endpoints/rewrite_rules.conf` --
which every third-party caller depends on and no other test traverses -- cannot
regress silently. Its variables are scoped to `rewriter_common.yaml` rather than
`common.yaml` so that lanes without a rewriter are unaffected.

The endpoint file contains successful real-replay requests. Validation and
error-contract tests belong in `negative/`, use the `negative` marker, and
assert the complete PostgREST error body (`code`, `details`, `hint`, and
`message`). Fixture-only edge cases use the `synthetic` marker.

Exact response values follow the `balance_tracker` convention: each
`name.tavern.yaml` has a sibling `name.pat.json` and calls
`validate_response:compare_rest_response_with_pattern`. Real-data endpoint
values must not use permissive sentinels such as `!anylist`. Shared values
belong in `common.yaml`.

### Environment variables

Every command below needs `API_URL`. Any command that passes a bare
`tests/tavern` path may also need `REWRITER_URL` set to *something*, even when
the selection deselects `tests/tavern/rewriter/`: tavern resolves an include's
variables while **collecting** the file, before pytest applies `-m`, so an
unresolvable variable can abort collection of the whole suite with
`MissingFormatError` rather than of that directory alone.

Whether it actually does depends on the environment — CI's Python 3.14 venv
fails this way and some local checkouts collect clean without it — so set it
unconditionally rather than finding out:

```bash
export API_URL=http://localhost:3000
export REWRITER_URL=http://rewriter.invalid
```

`rewriter.invalid` is fine for every selection **except** one that includes
`synthetic`, because that selects the rewriter suite and those stages really do
issue requests. To run those you need an actual rewriter in front of PostgREST;
the `endpoint-tests` lane builds one from `Dockerfile.rewriter`
(`docker/docker-compose-ci.yml`), which is the supported way to run them:

```bash
docker compose -f docker/docker-compose-ci.yml up --build
```

If you are running a rewriter by hand instead, point `REWRITER_URL` at it.

Run one endpoint while developing with:

```bash
pytest tests/tavern/get_daily_active_users --tb=short -v
```

The real and synthetic selections target different databases and are
intentionally disjoint. Run only negative validation tests with:

```bash
pytest tests/tavern -m negative --tb=short -v
```

Run the stub-only validation and synthetic edge set with (this selection
includes `tests/tavern/rewriter/`, so `REWRITER_URL` must point at a running
rewriter, not at the `.invalid` placeholder above):

```bash
pytest tests/tavern -m "negative or synthetic" --tb=short -v
```

Run the real-replay suite with:

```bash
pytest tests/tavern -m "not synthetic" --tb=short -v
```
