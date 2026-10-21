FROM registry.gitlab.syncad.com/hive/common-ci-configuration/psql:14-3

# Root for the BUILD steps only: WORKDIR creates /app root-owned and the RUN below writes
# /app/db/version.sql into it. The runtime user is dropped to at the end of this file.
# `0`, not `root`: hadolint's DL3066 flags every non-numeric USER, not only the last.
USER 0

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

# EMPTY by default, deliberately. This used to default to the literal "unknown", which
# GET /version and get_health.version then reported with exactly the authority of a real
# commit -- a node claiming a version it was not running, which is worse than having no
# version endpoint at all.
#
# The placeholder is `unspecified`, matching hive/haf_fyp rather than inventing a second
# convention for the same condition across sibling apps -- two apps on one node answering
# /version with two different "not set" strings is a monitor that matches one and misses
# the other. One word, not a sentence: /version is declared "Git hash string" in the
# OpenAPI annotation, so the remedy does not belong in the VALUE. install_app.sh logs it
# and README.md documents it.
#
# CI always passes the real value (.gitlab-ci.yml). For a hand-build, README.md's
# "Building the image" gives the command, including --short=8 so the value matches
# CI_COMMIT_SHORT_SHA.
ARG GIT_HASH=""
# TRUNCATE first so app_version is a singleton: install_app.sh re-runs version.sql
# on every (re)install, and the table has no unique constraint, so a plain INSERT
# would accumulate rows and get_version()/get_health.version could return a stale one.
# REJECTED, not repaired: anything outside [A-Za-z0-9._-] makes the whole value
# `unspecified` rather than a scrubbed version of itself. A half-cleaned string would be
# reported by GET /version as though someone had chosen it, which is the class of bug this
# whole change exists to remove.
#
# It has to be checked, because this value is interpolated into SQL that install_app
# executes as haf_admin: `--build-arg GIT_HASH="x'; DROP SCHEMA ...; --"` would otherwise
# be baked into version.sql verbatim. Reachable non-maliciously too -- git refs permit
# quotes, so $(git describe --tags) of an oddly-named tag is enough. The same test catches
# a whitespace-only argument, which scripts/common.sh refuses for POSTGRES_* in the same
# spirit: "the same operator error, opposite verdicts, depending only on which channel it
# arrived through".
#
# `case`, not `tr`, because a pipe in a RUN trips hadolint DL4006 (pipefail), and the
# alternative -- a SHELL with -o pipefail -- is not portable to this image's BusyBox sh.
RUN case "${GIT_HASH}" in \
      "" | *[!A-Za-z0-9._-]*) GIT_HASH_BAKED="unspecified" ;; \
      *) GIT_HASH_BAKED="${GIT_HASH}" ;; \
    esac \
 && echo "TRUNCATE haf_stats_app.app_version; INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('${GIT_HASH_BAKED}');" \
    > /app/db/version.sql

# Runtime user (#64): a dedicated, unprivileged account with a FIXED uid/gid, 10001.
#
# Not the base image's haf_admin, although nft_tracker runs as that: the base gives
# haf_admin passwordless sudo (Dockerfile.psql in hive/common-ci-configuration), so
# running as it is root one `sudo` away. Not uid 1000 either -- that is haf_admin's in
# the base (Alpine's first adduser), so `adduser -u 1000` would collide.
#
# Nothing at runtime writes under /app, so /app stays ROOT-owned and read-only to this
# user; nothing here is chowned to it. The only things the image's processes write are:
#   * /tmp/block_processing_startup_time.txt (+ a .tmp.$$ beside it, renamed into place)
#     -- scripts/process_blocks.sh, read back by /app/block-processing-healthcheck.sh;
#     overridable with HAF_STATS_STARTUP_TIME_FILE. /tmp is 1777.
#   * mktemp files under /tmp (tests/ci_install_no_upgrade.sh, scripts/check_haf_drift.sh).
#   * haf_app_driver.py's LOG_FILE, only if that env var is set (unset everywhere here).
# No port is bound (the API is postgrest and the rewriter, separate images), and every
# connection names its role (POSTGRES_USER), so the OS user only matters to a `peer`
# pg_hba rule, which neither this repo's stacks nor haf_api_node use for app containers.
#
# `chmod -R a+rX /app` because COPY keeps the BUILD CONTEXT's file modes, and those are
# not always 644: scripts/openapi_rewrite.sh writes endpoints/rewrite_rules.conf through
# mktemp, i.e. 0600, and CI's openapi-drift job runs it in the runner's shared checkout.
# The first pipeline of this change built exactly that image -- a root-owned 0600 file
# the runtime user could not read, invisible while the image ran as root.
#
# Added AFTER the version.sql RUN on purpose: tests/unit/test_version_provenance.py
# extracts that RUN with a non-greedy match from the FIRST `^RUN`, so a RUN placed above
# it would be swept into the script it executes.
RUN addgroup -S -g 10001 haf_stats \
 && adduser -S -D -u 10001 -G haf_stats -h /home/haf_stats -s /bin/bash haf_stats \
 && chmod -R a+rX /app

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

# NUMERIC, so a runtime that enforces non-root (Kubernetes runAsNonRoot) can verify it
# without resolving a name, and hadolint's DL3002/DL3066 no longer need ignoring.
USER 10001:10001

# NO `HEALTHCHECK` instruction here, deliberately. Upstream does not -- reputation_tracker's
# and balance_tracker's Dockerfiles ship the script and let each app's compose attach it
# to the block-processing service -- so declaring it here would be a DEVIATION from the
# contract this change exists to meet. It would also apply to every container built from
# the image, including the one-shot install and uninstall containers, for which "is the
# block loop advancing" is meaningless.
#
# docker/docker-compose.yml attaches it to haf-stats-process, the only service it
# describes.
