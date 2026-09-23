FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:14-3

USER root

WORKDIR /app

COPY db/             /app/db/
COPY endpoints/      /app/endpoints/
COPY --chmod=755 scripts/ /app/scripts/
# Both at /app/<name>, matching where every other HAF app image keeps them, so a module
# file or runbook that reaches for the path rather than for image metadata finds them.
# reputation_tracker.yaml, the reference #57 cites, hardcodes
# `test: ["CMD-SHELL","/app/block-processing-healthcheck.sh"]` -- put the script anywhere
# else and a compose file copied from it gets file-not-found, i.e. permanently unhealthy.
COPY --chmod=755 docker/docker_entrypoint.sh            /app/docker_entrypoint.sh
COPY --chmod=755 docker/block-processing-healthcheck.sh /app/block-processing-healthcheck.sh
# The predicate is a file rather than a shell-interpolated string so it can be compared
# whole in a test -- a substring assertion cannot tell `a - b` from `b - a`, and that
# swap makes the check permanently healthy.
COPY docker/block-processing-healthcheck.sql            /app/block-processing-healthcheck.sql

ARG GIT_HASH="unknown"
# TRUNCATE first so app_version is a singleton: install_app.sh re-runs version.sql
# on every (re)install, and the table has no unique constraint, so a plain INSERT
# would accumulate rows and get_version()/get_health.version could return a stale one.
RUN echo "TRUNCATE haf_stats_app.app_version; INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('${GIT_HASH}');" \
    > /app/db/version.sql

# Verb dispatcher: install_app | process_blocks | uninstall_app (#57). Every other
# haf_api_node app image exposes that trio, which is what lets a module file say
# `command: [install_app]` instead of naming a script path inside someone else's image.
# This used to be a bare /bin/bash, so haf_stats' compose services had to spell out
# /app/scripts/install_app.sh -- workable in this repo's own compose, a blocker for
# shipping haf_stats as a standard module.
#
# Not a breaking change: an argument that is not a verb but IS runnable is exec'd as-is
# (see the script), so the existing `command: ["/app/scripts/process_blocks.sh"]` form
# keeps working and an operator mid-migration is not stranded.
ENTRYPOINT ["/app/docker_entrypoint.sh"]

# NO `HEALTHCHECK` instruction here, deliberately. Upstream does not -- reputation_tracker's
# and balance_tracker's Dockerfiles ship the script and let each app's compose attach it
# to the block-processing service -- so declaring it here would be a DEVIATION from the
# contract this change exists to meet. It would also apply to every container built from
# the image, including the one-shot install and uninstall containers, for which "is the
# block loop advancing" is meaningless.
#
# docker/docker-compose.yml attaches it to haf-stats-process, the only service it
# describes.
