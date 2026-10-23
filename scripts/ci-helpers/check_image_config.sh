#!/bin/sh
# check_image_config.sh IMAGE -- the CONFIG half of the built-image guarantee (#64).
#
# Runs on the CI host (needs only the docker CLI), against the image's FINAL config as
# `docker image inspect` reports it -- so the last ENV/USER wins exactly as at runtime,
# whatever order or spelling the Dockerfile used:
#   * .Config.User is exactly 10001:10001;
#   * PYTHONNOUSERSITE is exactly 1;
#   * none of PYTHONPATH, PYTHONHOME, PYTHONSTARTUP, LD_PRELOAD, LD_LIBRARY_PATH is set
#     (each redirects what python3 or the dynamic loader loads, i.e. code, into a place
#     the image does not otherwise vouch for -- PYTHONPATH=/tmp is a writable code path).
set -u
set -f

img="${1:?usage: check_image_config.sh IMAGE}"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

user="$(docker image inspect -f '{{.Config.User}}' "${img}")" || { echo "FAIL: cannot inspect ${img}" >&2; exit 1; }
if [ "${user}" != "10001:10001" ]; then
    bad "image config User is '${user}', want 10001:10001"
fi

env="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${img}")" \
    || { echo "FAIL: cannot inspect ${img}" >&2; exit 1; }
nousersite=""
while IFS= read -r line; do
    case "${line}" in
        PYTHONPATH=*|PYTHONHOME=*|PYTHONSTARTUP=*|LD_PRELOAD=*|LD_LIBRARY_PATH=*)
            bad "image config sets ${line}" ;;
        PYTHONNOUSERSITE=*)
            nousersite="${line#PYTHONNOUSERSITE=}" ;;
    esac
done <<EOF
${env}
EOF
if [ "${nousersite}" != 1 ]; then
    bad "image config PYTHONNOUSERSITE is '${nousersite}', want exactly 1"
fi

if [ "${fail}" -ne 0 ]; then
    exit 1
fi
echo "image config ok"
