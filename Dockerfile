FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:14-2

USER root

WORKDIR /app

COPY db/             /app/db/
COPY endpoints/      /app/endpoints/
COPY --chmod=755 scripts/ /app/scripts/

ARG GIT_HASH="unknown"
RUN echo "INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('${GIT_HASH}') ON CONFLICT DO NOTHING;" \
    > /app/db/version.sql

ENTRYPOINT ["/bin/bash"]
