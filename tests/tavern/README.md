# Tavern API tests

The tests follow the same endpoint-oriented layout as `balance_tracker`:

```text
tests/tavern/
├── common.yaml
├── pytest.ini
└── {rpc_endpoint}/
    ├── {rpc_endpoint}.tavern.yaml
    └── negative/
        └── validation.tavern.yaml
```

The endpoint file contains successful real-replay requests. Validation and
error-contract tests belong in `negative/`, use the `negative` marker, and
assert the complete PostgREST error body (`code`, `details`, `hint`, and
`message`). Fixture-only edge cases use the `synthetic` marker.

Exact response values follow the `balance_tracker` convention: each
`name.tavern.yaml` has a sibling `name.pat.json` and calls
`validate_response:compare_rest_response_with_pattern`. Real-data endpoint
values must not use permissive sentinels such as `!anylist`. Shared values
belong in `common.yaml`.

Run one endpoint while developing with:

```bash
pytest tests/tavern/get_daily_active_users --tb=short -v
```

The real and synthetic selections target different databases and are
intentionally disjoint. Run only negative validation tests with:

```bash
pytest tests/tavern -m negative --tb=short -v
```

Run the stub-only validation and synthetic edge set with:

```bash
pytest tests/tavern -m "negative or synthetic" --tb=short -v
```

Run the real-replay suite with:

```bash
pytest tests/tavern -m "not synthetic" --tb=short -v
```
