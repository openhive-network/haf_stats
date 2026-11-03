# Changelog

Changes to the haf_stats **public API**: the OpenAPI document served at `/` and the
behaviour of the endpoints it describes. Internal changes (processors, rebuild tooling,
CI, the image) are not listed unless a caller can observe them.

## Versioning policy

`info.version` in the OpenAPI document (`endpoints/endpoint_schema.sql`) is the version
of the **API contract**, not of the application build. It follows
[Semantic Versioning](https://semver.org/). `GET /version` keeps reporting the git hash
of the deployed build; the two answer different questions and move at different rates.
haf_stats is released with the HAF stack, so a stack release ships whatever
`info.version` the tip carries.

**MAJOR** — a caller written against the previous version can stop working or silently
get a different answer:

* a path, query parameter or response field is removed or renamed;
* a parameter becomes required, or accepts fewer values than before;
* a response field changes type, **including widening to nullable** — the wire is
  unchanged, but a regenerated typed client stops compiling;
* the default for an omitted parameter changes what is returned (for example the
  default date window);
* a returned value changes definition or unit.

**MINOR** — the contract only grows, or wrong data is corrected:

* a new path, an optional parameter, or a response field is added;
* a new response code is documented (e.g. `400`), or schemas move into `components`
  and are referenced with `$ref`, resolving to the same shapes;
* a fix changes returned values back to what the documentation already promised. The
  entry goes under **Corrected** with the size of the change and any rebuild a node
  needs before it serves the corrected figures.

**PATCH** — descriptions, examples and performance only; no request or response changes
shape or value.

**How to bump:** the MR that makes the change also adds its entry under
`## Unreleased`, and when that MR is the one that changes the version it renames the
heading to the new version and sets `info.version` in the YAML block of
`endpoints/endpoint_schema.sql` (then runs `scripts/openapi_rewrite.sh`, which
regenerates the embedded JSON). `tests/unit/test_api_version.py` fails when the
newest released heading here and `info.version` disagree.

## Unreleased

## 2.0.0

The first version issued under this policy. Everything below shipped under an unchanged
`1.0.0`, so a document that reports `1.0.0` may be any of them. Additive changes made
before this policy (new endpoints and fields) are not itemized.

### Breaking

* Every query and path parameter lost its leading underscore (`04551bb`, 2026-06-14):
  `_account` → `account`, `_from` → `from_date`, `_to` → `to_date`,
  `_granularity` → `granularity`, `_group_by` → `group_by`,
  `_operation_types` → `operation_types`. The old names are not accepted.
* With no `from_date`, `GET /network/daily-active-users` (`50e3781`, #34) and
  `GET /network/rc-utilization` (`07f1106`, #35) now start at chain genesis
  (2016-03-24) instead of 30 days back (2026-07-01). A caller relying on the default
  gets the full history, and the request costs much more.
* 55 response fields widened to `[type, "null"]` (`10d73d9`, #68/#69/#71, 2026-09-09).
  Those fields could already be `null` on the wire (for example `last_missed_block` on
  `GET /witnesses/missed-blocks` for a witness that never missed a block), so
  responses are unchanged. A regenerated typed client gets nullable types, though.

### Added

* All 24 paths document a `400` response; the document gained `components.schemas`
  and `components.responses`, referenced by `$ref` (`10d73d9`).

### Corrected

* `GET /network/content-volume`: posts and comments had been counted twice. They are
  now half of what was served before (`f983019`, `d4807d0`, #42, 2026-07-15). A node
  serves the corrected figures only after `scripts/rebuild_content_volume.sh`.
* `GET /account/{account}/content-stats`: post counts were about 19% too high in the
  stored daily rows (`6f3452b`, #45, 2026-07-17); corrected after the same rebuild.

## 1.0.0

The first published OpenAPI document.
