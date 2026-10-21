#!/bin/sh
# check_image_root.sh -- the ROOT half of the built-image guarantee (#64).
#
# Run INSIDE the built image AS ROOT by the docker-build smoke test:
#
#     docker run --rm --user 0 --entrypoint /app/scripts/ci-helpers/check_image_root.sh "$IMG"
#
# check_runtime_user.sh answers "what can the runtime user do"; it cannot see into
# directories it may not list, so a 0711 directory could hide a setuid file or a
# world-writable one from it. This half looks at the same tree as root, by MODE BITS and
# OWNERSHIP rather than by access(2), so nothing is hidden from it:
#
#   1. no path is world-writable, or owned by uid/gid 10001 (pruned: /proc, /sys, /dev,
#      /tmp, /var/tmp; /tmp and /var/tmp have their own rule in the user half);
#   2. no setuid/setgid regular file except /usr/bin/sudo, names compared as RAW BYTES
#      (a name containing a newline cannot split into an allowed one);
#   3. no file carries security.capability;
#   4. `/usr/bin/sudo -l -U haf_stats`, by absolute path, lists no rule for the runtime
#      user -- not inferred from an exit code, and not from a `sudo` found on PATH.
#
# Nothing is read from the environment; every expected value is a literal here. POSIX sh
# plus the image's python3 (for the byte-exact walk). Exits 1 if any check failed.
set -u
set -f

WANT_ID=10001
WANT_NAME=haf_stats
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

if [ "$(id -u)" != 0 ]; then
    echo "FAIL: check_image_root.sh must run as root (docker run --user 0), got uid $(id -u)" >&2
    exit 1
fi

# --- 1. world-writable or runtime-owned, by mode and owner ------------------------------
modes="$(find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /tmp -o -path /var/tmp \) -prune \
    -o ! -type l \( -perm -0002 -o -user "${WANT_ID}" -o -group "${WANT_ID}" \) -print 2>&1)" \
    || modes="${modes}
<find could not walk />"
if [ -n "${modes}" ]; then
    bad "world-writable, or owned by uid/gid ${WANT_ID} (mode scan as root):"; echo "${modes}" >&2
fi

# --- 2 + 3. setuid/setgid and file capabilities, byte-exact -----------------------------
setid_caps="$(python3 - <<'PY' 2>&1
import os, stat
ALLOWED = {b"/usr/bin/sudo"}
PRUNE = {b"/proc", b"/sys", b"/dev"}
root_dev = os.lstat(b"/").st_dev
def walk_error(e):
    print("<walk error: %r>" % (e,))
for top, dirs, files in os.walk(b"/", onerror=walk_error):
    keep = []
    for d in dirs:
        p = os.path.join(top, d)
        try:
            st = os.lstat(p)
        except OSError as e:
            print("<lstat error: %r>" % (e,))
            continue
        if p in PRUNE or stat.S_ISLNK(st.st_mode) or st.st_dev != root_dev:
            continue
        keep.append(d)
    dirs[:] = keep
    for name in files:
        p = os.path.join(top, name)
        try:
            st = os.lstat(p)
        except OSError as e:
            print("<lstat error: %r>" % (e,))
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        if st.st_mode & (stat.S_ISUID | stat.S_ISGID) and p not in ALLOWED:
            print("setuid/setgid: %r" % (p,))
        try:
            os.getxattr(p, "security.capability", follow_symlinks=False)
        except OSError:
            pass
        else:
            print("capability: %r" % (p,))
PY
)"
if [ -n "${setid_caps}" ]; then
    bad "unexpected setuid/setgid files or file capabilities:"; echo "${setid_caps}" >&2
fi

# --- 4. sudo rules for the runtime user ---------------------------------------------------
# Listed by root for the user, so a `Defaults listpw=always` (which makes the user's own
# `sudo -n -l` fail) or a fake `sudo` earlier on PATH changes nothing. A clean result is
# the POSITIVE "is not allowed to run sudo" with no "may run" anywhere.
if [ -e /usr/bin/sudo ]; then
    sudo_l="$(/usr/bin/sudo -l -U "${WANT_NAME}" 2>&1 || true)"
    case "${sudo_l}" in
        *"may run the following"*) bad "sudo rules for ${WANT_NAME}: ${sudo_l}" ;;
        *"is not allowed to run sudo"*) ;;
        *) bad "sudo -l -U ${WANT_NAME} gave no clear answer: ${sudo_l}" ;;
    esac
fi

if [ "${fail}" -ne 0 ]; then
    exit 1
fi
echo "image root scan ok"
