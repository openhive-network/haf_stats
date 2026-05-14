# Stage 1: base psql image provided by the HAF CI configuration
FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:14-2 AS base

# Stage 2: inject version (populated by CI from git describe)
FROM base AS version
ARG GIT_HASH="unknown"
RUN echo "INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('${GIT_HASH}') ON CONFLICT DO NOTHING;" \
    > /version.sql

# Stage 3: final image
FROM base AS final

WORKDIR /app

COPY --from=version /version.sql /app/db/version.sql
COPY db/         /app/db/
COPY endpoints/  /app/endpoints/
COPY scripts/    /app/scripts/

RUN chmod +x /app/scripts/*.sh

ENTRYPOINT ["/bin/bash"]
