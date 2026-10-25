# The image AIDEV runs this project's checks in (`environment.image` in
# .aidev/project.yaml). Checks run with the caller's uid and, for the slots that
# start the test stack (.aidev/test-stack.compose.yml), on that stack's network.
#
#   the rewriter's own base, common-ci-configuration/nginx (openresty, Alpine; the
#   tag Dockerfile.rewriter names), so endpoints/rewrite_rules.conf and
#   docker/haf_stats_nginx.conf.template are served by the openresty production runs
#   + bash, psql, python3, git, the psycopg2 module, and install_with_app_lock.py /
#     haf_app_driver.py from common-ci-configuration/psql:14-3 (the app image's base),
#     so scripts/install_app.sh runs as it does in the app image
#   + postgrest v12.2.3 (the binary docker/docker-compose-ci.yml's postgrest service runs)
#   + shellcheck 0.11.0, hadolint (the latest-alpine CI's hadolint job ran on
#     2026-10-24), the docker CLI and its compose plugin (`docker compose config` only;
#     no daemon is used)
#   + /opt/venv: tavern 3.7.1 + pytest 8.4.2 (what CI's tavern lanes resolved),
#     pyyaml, openapi-spec-validator 0.9.0; /opt/sqlfluff: sqlfluff 3.3.0;
#     /opt/openapi-venv + /opt/openapi/process_openapi.py: scripts/openapi_rewrite.sh's
#     pinned generator and venv, for its COMMON_CI_OFFLINE=1 mode
#   + /app -> /tmp/aidev-app, which .aidev/compose_lane.py points at the db/,
#     endpoints/ and scripts/ an app-image service of the CI compose files mounts
#
# Pinned: a step's verdict must not move with a new release. The Dockerfile is the
# only input (nothing is copied from the tree). Build and pin it with
# .aidev/runtime/build.sh; see .aidev/README.md.
FROM postgrest/postgrest:v12.2.3@sha256:729bf65c733b73f5b52777f0e4b853f22ed73aa67a22d38269d289779b0a8401 AS postgrest
FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:14-3@sha256:6a3794d9fdc4e0590789fc01e48539bcd73273715e3b69dd1f45d3ecde8b1cde AS psql
FROM koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d AS shellcheck
FROM hadolint/hadolint:latest-alpine@sha256:a1d49ae1a4e83c1dbad26b8c1ad7588c8bd1e04f4866b34ad3cac50335198552 AS hadolint
FROM docker:24-cli@sha256:2b62f89aaab9e4df0ff843f0d9a7bbd17340a9ba7c660ba6f40b1f00b38c2a4d AS docker

FROM registry.gitlab.syncad.com/hive/common-ci-configuration/nginx:9f5e12cd984bf12746ce9af081868e09ced8068f@sha256:1008ee680742d09b3542393f8c3c5212162fab2893a3f5e13c546100de821ebe

USER root
RUN apk add --no-cache bash coreutils findutils grep sed gawk git curl postgresql-client python3 py3-psycopg2 \
    && python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir tavern==3.7.1 pytest==8.4.2 pyyaml==6.0.3 openapi-spec-validator==0.9.0 \
    && python3 -m venv /opt/sqlfluff \
    && /opt/sqlfluff/bin/pip install --no-cache-dir sqlfluff==3.3.0 \
    && python3 -m venv /opt/openapi-venv \
    && /opt/openapi-venv/bin/pip install --no-cache-dir deepmerge==2.0 jsonpointer==3.1.1 pyyaml==6.0.3 \
    && ln -s /opt/sqlfluff/bin/sqlfluff /usr/local/bin/sqlfluff \
    && ln -s /tmp/aidev-app /app

# scripts/openapi_rewrite.sh's generator at the COMMON_CI_REF .gitlab-ci.yml pins.
ADD --checksum=sha256:292e8825e36117357983f8d669ba5d9805a33127ace28869feaa29731ecb6f0a \
    https://gitlab.syncad.com/hive/common-ci-configuration/-/raw/96889a650b3f45244cecc4bb3f250af439a71900/haf-app-tools/python/process_openapi.py \
    /opt/openapi/process_openapi.py

COPY --from=postgrest /bin/postgrest /usr/local/bin/postgrest
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=hadolint /bin/hadolint /usr/local/bin/hadolint
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
COPY --from=psql /usr/local/bin/install_with_app_lock.py /usr/local/bin/haf_app_driver.py /usr/local/bin/

RUN chmod 0644 /opt/openapi/process_openapi.py \
    && chmod -R a+rwX /usr/local/openresty/nginx

ENV HOME=/tmp PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/venv/bin:/usr/local/openresty/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENTRYPOINT []
CMD ["bash"]
