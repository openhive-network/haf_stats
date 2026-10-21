#!/bin/sh
# check_runtime_user.sh -- assert the image runs unprivileged and /app is read-only to it (#64).
#
# Run INSIDE the image, as its default user, by the docker-build smoke test:
#
#     docker run --rm --entrypoint /app/scripts/ci-helpers/check_runtime_user.sh "$IMG"
#
# POSIX sh, because the image's /bin/sh is BusyBox. Every check reports what it found and
# the script exits 1 at the end if any failed, so one run lists every problem.
#
# Readability and writability are tested with `test -r/-w/-x`, which ask the kernel
# (access(2)) on behalf of the CURRENT user -- the same answer the image's processes get.
# Not `find -writable`, which BusyBox find does not have, and not a mode-bit pattern,
# which would have to re-derive owner/group/other logic by hand. Ownership is checked
# separately because an owner can chmod a path writable even when it is not right now.
#
# Every finding is collected into a variable rather than relied on as an exit status:
# a `find -exec ... {} +` status is only as good as the find implementation reporting
# it, and an assignment's status would trip `set -e` without saying which path failed.
set -u

APP_DIR="${1:-/app}"
WANT_ID="${2:-10001}"
WANT_NAME="${3:-haf_stats}"
STARTUP_FILE="${4:-/tmp/block_processing_startup_time.txt}"
fail=0

bad() { echo "FAIL: $*" >&2; fail=1; }

# Prints each path under APP_DIR for which the sh condition "$1" holds, with "$p" bound.
paths_where() {
    find "${APP_DIR}" -exec sh -c '
        cond="$1"; shift
        for p; do if eval "${cond}"; then echo "${p}"; fi; done
    ' sh "$1" {} + || echo "<find could not walk ${APP_DIR}>"
}

if [ "$(id -u):$(id -g)" != "${WANT_ID}:${WANT_ID}" ]; then
    bad "running as $(id -u):$(id -g), want ${WANT_ID}:${WANT_ID}"
fi
if [ "$(id -un)" != "${WANT_NAME}" ]; then
    bad "uid $(id -u) is named '$(id -un)', want ${WANT_NAME}"
fi

# Everything must be readable, and every directory searchable -- an unreadable SQL file
# is an install that cannot open its own schema.
unreadable="$(paths_where '[ ! -r "$p" ] || { [ -d "$p" ] && [ ! -x "$p" ]; }')"
if [ -n "${unreadable}" ]; then
    bad "not readable by $(id -un):"; echo "${unreadable}" >&2
fi

# Nothing under /app may be writable by, or owned by, the runtime user or its group.
writable="$(paths_where '[ -w "$p" ]')"
if [ -n "${writable}" ]; then
    bad "writable by $(id -un):"; echo "${writable}" >&2
fi
owned="$(find "${APP_DIR}" \( -user "${WANT_ID}" -o -group "${WANT_ID}" \) -print 2>&1)"
if [ -n "${owned}" ]; then
    bad "owned by uid or gid ${WANT_ID}:"; echo "${owned}" >&2
fi

# The one runtime write: process_blocks.sh's temp-file-and-rename of the startup file.
tmp="${STARTUP_FILE}.tmp.$$"
if ! { echo probe > "${tmp}" && mv "${tmp}" "${STARTUP_FILE}" && rm "${STARTUP_FILE}"; }; then
    bad "cannot write and rename ${STARTUP_FILE}"
fi

# The base image gives haf_admin passwordless sudo; this user must not have it.
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    bad "$(id -un) can sudo without a password"
fi

if [ "${fail}" -ne 0 ]; then
    exit 1
fi
echo "runtime user ok: $(id)"
