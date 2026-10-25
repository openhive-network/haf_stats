#!/usr/bin/env python3
"""openapi-drift's last check: the OpenAPI document endpoint_schema.sql serves is valid.

    openapi_valid.py endpoints/endpoint_schema.sql

The same extraction and validator .gitlab-ci.yml's openapi-drift job runs inline.
"""
import json
import re
import sys

from openapi_spec_validator import OpenAPIV31SpecValidator

src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"openapi json = \$\$(.*?)\$\$;", src, re.S)
if not m:
    sys.exit("could not extract the embedded OpenAPI blob")
errs = list(OpenAPIV31SpecValidator(json.loads(m.group(1))).iter_errors())
for e in errs:
    print("INVALID:", list(e.absolute_path), "-", str(e)[:200])
if errs:
    sys.exit(1)
print("served OpenAPI document is valid.")
