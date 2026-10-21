#!/bin/sh
# check_runtime_user.sh -- the RUNTIME-USER half of the built-image guarantee (#64).
#
# Run INSIDE the built image, as its default user (no --user override), by the
# docker-build smoke test:
#
#     docker run --rm --entrypoint /app/scripts/ci-helpers/check_runtime_user.sh "$IMG"
#
# THE BUILT-IMAGE CHECKS ARE THE GUARANTEE. This script, check_image_root.sh (the same
# tree as root, by mode bits) and check_image_config.sh (the image's final config) look
# at what actually shipped, so they hold whatever the Dockerfile says.
# tests/unit/test_dockerfile_user.py is only a fast lint over the Dockerfile text.
#
# This half asks the kernel what the runtime user can do -- `test -r/-w/-x` are access(2)
# for the CURRENT user -- by construction over the WHOLE filesystem rather than over a
# list of places someone thought of:
#   * identity: uid and gid 10001, name haf_stats, no supplementary groups;
#   * nothing on / (-xdev; pruned: /proc /sys /dev /tmp /var/tmp) is writable by this
#     user; /tmp and /var/tmp are exactly 1777;
#   * HOME (and the passwd home) and every ancestor up to / not writable, so a missing
#     home cannot be created either;
#   * /app: every file readable, every directory searchable, and fully walkable (the
#     "find could not walk" sentinel);
#   * Python's user site off and usercustomize not loaded;
#   * the one runtime write, the startup file, works.
#
# Directories this user cannot list are invisible to the whole-filesystem scan; the root
# half covers them by mode. Nothing is read from the environment except PATH and HOME,
# which are among the things being checked. Exits 1 if any check failed.
set -u
set -f

APP_DIR=/app
WANT_ID=10001
WANT_NAME=haf_stats
STARTUP_FILE=/tmp/block_processing_startup_time.txt
fail=0

bad() { echo "FAIL: $*" >&2; fail=1; }

# --- identity -------------------------------------------------------------------------------
if [ "$(id -u):$(id -g)" != "${WANT_ID}:${WANT_ID}" ]; then
    bad "running as $(id -u):$(id -g), want ${WANT_ID}:${WANT_ID}"
fi
if [ "$(id -un)" != "${WANT_NAME}" ]; then
    bad "uid $(id -u) is named '$(id -un)', want ${WANT_NAME}"
fi
if [ "$(id -G)" != "${WANT_ID}" ]; then
    bad "groups are '$(id -G)' ($(id -Gn)), want only ${WANT_ID}"
fi

# --- nothing writable, whole filesystem -------------------------------------------------------
# Errors (directories this user cannot list) are expected here and covered by the root
# half; what this half adds is the kernel's own answer for every path it CAN see.
writable="$(find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /tmp -o -path /var/tmp \) -prune \
    -o -exec sh -c 'for p; do if [ -w "$p" ] && [ ! -L "$p" ]; then echo "$p"; fi; done' sh {} + 2>/dev/null)"
if [ -n "${writable}" ]; then
    bad "writable by $(id -un):"; echo "${writable}" >&2
fi
owned="$(find / -xdev \( -path /proc -o -path /sys -o -path /dev \) -prune \
    -o \( -user "${WANT_ID}" -o -group "${WANT_ID}" \) -print 2>/dev/null)"
if [ -n "${owned}" ]; then
    bad "owned by uid or gid ${WANT_ID}:"; echo "${owned}" >&2
fi
for t in /tmp /var/tmp; do
    if [ -e "${t}" ] && [ "$(stat -c %a "${t}")" != 1777 ]; then
        bad "${t} is mode $(stat -c %a "${t}"), want 1777"
    fi
done

# --- HOME and its ancestors ---------------------------------------------------------------------
home_passwd="$(awk -F: -v u="${WANT_NAME}" '$1 == u { print $6 }' /etc/passwd)"
for h in "${HOME:-}" "${home_passwd}"; do
    [ -n "${h}" ] || continue
    p="${h}"
    while :; do
        if [ -e "${p}" ] && { [ -w "${p}" ] || [ "$(stat -c %u "${p}")" = "${WANT_ID}" ]; }; then
            bad "HOME ${h}: ancestor ${p} is writable or owned by $(id -un)"
        fi
        [ "${p}" = / ] && break
        p="$(dirname "${p}")"
    done
done

# --- /app readable and walkable ------------------------------------------------------------------
# Files must be readable and directories searchable; directory LISTABILITY is what the
# walk itself proves -- a directory find cannot read makes find fail, and that is the
# sentinel. Each condition has a negative control in CI, the sentinel included.
unreadable="$(find "${APP_DIR}" -exec sh -c '
    for p; do
        if [ -d "$p" ]; then [ -x "$p" ] || echo "$p"
        else [ -r "$p" ] || echo "$p"; fi
    done' sh {} + 2>/dev/null)" || unreadable="${unreadable}
<find could not walk ${APP_DIR}>"
if [ -n "${unreadable}" ]; then
    bad "not readable by $(id -un):"; echo "${unreadable}" >&2
fi

# --- Python user site off ----------------------------------------------------------------------
py_site="$(python3 -c 'import site, sys
print(site.ENABLE_USER_SITE, "usercustomize" in sys.modules)' 2>&1)"
if [ "${py_site}" != "False False" ]; then
    bad "python3 user site is not disabled (ENABLE_USER_SITE, usercustomize loaded): ${py_site}"
fi

# --- the one runtime write ---------------------------------------------------------------------
tmp="${STARTUP_FILE}.tmp.$$"
if ! { echo probe > "${tmp}" && mv "${tmp}" "${STARTUP_FILE}" && rm "${STARTUP_FILE}"; }; then
    bad "cannot write and rename ${STARTUP_FILE}"
fi

if [ "${fail}" -ne 0 ]; then
    exit 1
fi
echo "runtime user ok: $(id)"
