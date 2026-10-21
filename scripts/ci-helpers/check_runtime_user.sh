#!/bin/sh
# check_runtime_user.sh -- assert the image runs unprivileged (#64).
#
# Run INSIDE the image, as its default user, by the docker-build smoke test:
#
#     docker run --rm --entrypoint /app/scripts/ci-helpers/check_runtime_user.sh "$IMG"
#
# What "unprivileged" means here, one section per item below: the expected uid, gid and
# NO supplementary groups; /app readable; nothing under /app, on PATH, in the home
# directory or in Python's user site writable or owned by the runtime user; Python's
# user site disabled; no setuid/setgid file except sudo; no file capabilities; no sudo
# rule of any kind; and the one runtime write (the startup file) working.
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
#
# NOTHING here is read from the environment except PATH and HOME, which are the values
# being checked: the image controls its own environment (`ENV ...`), so an env-supplied
# allow-list or expected uid would let the image widen its own check.
set -u
set -f  # no pathname expansion anywhere: file NAMES are data here, never patterns

APP_DIR=/app
WANT_ID=10001
WANT_NAME=haf_stats
STARTUP_FILE=/tmp/block_processing_startup_time.txt
# The only setuid/setgid file the base image carries. Allowed only because the sudo
# check below proves this user has no sudo rule at all.
SETID_ALLOWED=/usr/bin/sudo
fail=0

bad() { echo "FAIL: $*" >&2; fail=1; }

# Prints each path under the given roots for which the sh condition "$1" holds, with "$p"
# bound to the path.
paths_where() {
    cond="$1"; shift
    find "$@" -exec sh -c '
        cond="$1"; shift
        for p; do if eval "${cond}"; then echo "${p}"; fi; done
    ' sh "${cond}" {} + || echo "<find could not walk: $*>"
}

# --- identity ---------------------------------------------------------------------------
if [ "$(id -u):$(id -g)" != "${WANT_ID}:${WANT_ID}" ]; then
    bad "running as $(id -u):$(id -g), want ${WANT_ID}:${WANT_ID}"
fi
if [ "$(id -un)" != "${WANT_NAME}" ]; then
    bad "uid $(id -u) is named '$(id -un)', want ${WANT_NAME}"
fi
# Supplementary groups grant whatever their gid owns: membership of root or wheel is
# read access to root-group files and, with a group-writable path, a write.
if [ "$(id -G)" != "${WANT_ID}" ]; then
    bad "groups are '$(id -G)' ($(id -Gn)), want only ${WANT_ID}"
fi

# --- /app readable ------------------------------------------------------------------------
# Everything must be readable, and every directory searchable -- an unreadable SQL file
# is an install that cannot open its own schema.
unreadable="$(paths_where '[ ! -r "$p" ] || { [ -d "$p" ] && [ ! -x "$p" ]; }' "${APP_DIR}")"
if [ -n "${unreadable}" ]; then
    bad "not readable by $(id -un):"; echo "${unreadable}" >&2
fi

# --- nothing writable or owned: /app, PATH, home, Python user site ------------------------
# PATH matters as much as /app: process_blocks.sh execs haf_app_driver.py from PATH, so a
# writable file there is the block loop rewriting itself. The home directory and Python's
# user site matter because haf_app_driver.py is `#!/usr/bin/env python3` without -s: a
# usercustomize.py or a planted psycopg2/ under ~/.local would run inside the block loop.
# `test -w` follows a symlink to its target, which is the file that would be executed.
roots="${APP_DIR}"
_ifs="${IFS}"; IFS=:
for d in ${PATH}; do
    if [ -d "${d}" ]; then roots="${roots}:${d}"; fi
done
IFS="${_ifs}"

home_passwd="$(awk -F: -v u="${WANT_NAME}" '$1 == u { print $6 }' /etc/passwd)"
user_base="$(python3 -c 'import site; print(site.getuserbase())' 2>/dev/null || true)"
for h in "${HOME:-}" "${home_passwd}" "${user_base}"; do
    if [ -n "${h}" ] && [ -e "${h}" ]; then roots="${roots}:${h}"; fi
done
# A home that does not exist must also be impossible to CREATE: its parent must not be
# writable either (the Dockerfile points it at /nonexistent, under a root-owned /).
for h in "${HOME:-}" "${home_passwd}" "${user_base}"; do
    if [ -n "${h}" ] && [ ! -e "${h}" ] && [ -w "$(dirname "${h}")" ]; then
        bad "${h} does not exist but $(id -un) can create it"
    fi
done

IFS=:
# shellcheck disable=SC2086  # split on ':' deliberately (and set -f is on)
set -- ${roots}
IFS="${_ifs}"
writable="$(paths_where '[ -w "$p" ]' "$@")"
if [ -n "${writable}" ]; then
    bad "writable by $(id -un):"; echo "${writable}" >&2
fi
owned="$(find "$@" \( -user "${WANT_ID}" -o -group "${WANT_ID}" \) -print 2>&1)"
if [ -n "${owned}" ]; then
    bad "owned by uid or gid ${WANT_ID}:"; echo "${owned}" >&2
fi

# --- Python user site off -------------------------------------------------------------------
# Belt and braces with the home check: even a root-owned user site would be imported.
# `-c` runs with the same site processing as the driver's shebang.
py_site="$(python3 -c 'import site, sys
print(site.ENABLE_USER_SITE, "usercustomize" in sys.modules)' 2>&1)"
if [ "${py_site}" != "False False" ]; then
    bad "python3 user site is not disabled (ENABLE_USER_SITE, usercustomize loaded): ${py_site}"
fi

# --- setuid / setgid ------------------------------------------------------------------------
# Regular files anywhere on the root filesystem (a setgid DIRECTORY only sets group
# inheritance). One is root for the asking: a setuid python3 is os.setuid(0). Paths this
# user cannot search are not listed -- and a setuid file there is not executable by this
# user either. Read line by line, compared as a literal string: a file NAMED like a
# pattern must not match the allow-list (set -f above, and the quoted case word).
setid="$(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null)"
unexpected=""
while IFS= read -r f; do
    case "${f}" in
        "") ;;
        "${SETID_ALLOWED}") ;;
        *) unexpected="${unexpected}${f}
" ;;
    esac
done <<EOF
${setid}
EOF
if [ -n "${unexpected}" ]; then
    bad "unexpected setuid/setgid files:"; printf '%s' "${unexpected}" >&2
fi

# --- file capabilities ----------------------------------------------------------------------
# security.capability is the other way to hand out root powers (cap_setuid+ep on an
# interpreter). The image has no getcap (libcap is not installed) and BusyBox has no
# getfattr, so read the xattr through Python's os.getxattr, which any user may do. Same
# filesystem as /, regular files only, unreadable directories skipped (as for setuid).
caps="$(python3 - <<'PY' 2>&1
import os
root_dev = os.stat("/").st_dev
for top, dirs, files in os.walk("/", onerror=lambda e: None):
    dirs[:] = [d for d in dirs
               if not os.path.islink(os.path.join(top, d))
               and os.lstat(os.path.join(top, d)).st_dev == root_dev]
    for name in files:
        path = os.path.join(top, name)
        try:
            if os.path.islink(path):
                continue
            os.getxattr(path, "security.capability", follow_symlinks=False)
        except OSError:
            continue
        print(path)
PY
)"
if [ -n "${caps}" ]; then
    bad "files with capabilities (security.capability):"; echo "${caps}" >&2
fi

# --- sudo -----------------------------------------------------------------------------------
# The base image gives haf_admin passwordless sudo; this user must have NO rule at all.
# `sudo -n true` only proved there is no NOPASSWD rule for `true`: a command-scoped
# `NOPASSWD: /usr/bin/python3` passed it. `sudo -n -l` succeeds whenever any rule lets
# this user list without a password (sudo's default listpw=any: one NOPASSWD entry is
# enough), and fails with "may not run sudo" when there is none.
if command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
        bad "$(id -un) can sudo without a password"
    fi
    if sudo_l="$(sudo -n -l 2>&1)"; then
        bad "$(id -un) has sudo rules: ${sudo_l}"
    fi
fi

# --- the one runtime write --------------------------------------------------------------------
# process_blocks.sh's temp-file-and-rename of the startup file.
tmp="${STARTUP_FILE}.tmp.$$"
if ! { echo probe > "${tmp}" && mv "${tmp}" "${STARTUP_FILE}" && rm "${STARTUP_FILE}"; }; then
    bad "cannot write and rename ${STARTUP_FILE}"
fi

if [ "${fail}" -ne 0 ]; then
    exit 1
fi
echo "runtime user ok: $(id)"
