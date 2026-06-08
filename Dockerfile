FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:14-2

USER root

WORKDIR /app

COPY db/             /app/db/
COPY endpoints/      /app/endpoints/
COPY --chmod=755 scripts/ /app/scripts/

ARG GIT_HASH="unknown"
# TRUNCATE first so app_version is a singleton: install_app.sh re-runs version.sql
# on every (re)install, and the table has no unique constraint, so a plain INSERT
# would accumulate rows and get_version()/get_health.version could return a stale one.
RUN echo "TRUNCATE haf_stats_app.app_version; INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('${GIT_HASH}');" \
    > /app/db/version.sql

ENTRYPOINT ["/bin/bash"]
