#!/bin/bash
# Regenerates the embedded OpenAPI JSON in endpoint_schema.sql and rewrites
# rewrite_rules.conf from the /** openapi:paths ... */ annotations.
#
# Run this after adding or changing endpoint annotations, then commit the result.
#
# Requires: python3 with the venv module, and network access -- it fetches
#           process_openapi.py from common-ci-configuration and installs three
#           pinned packages into a PRIVATE virtualenv at .openapi_venv/ in the
#           repo root (gitignored).
#           Nothing is installed into your system or user site-packages.
#
#           COMMON_CI_OFFLINE=1 reuses both the downloaded generator and the
#           existing virtualenv instead of touching the network at all -- for
#           working behind a proxy. It fails loudly if either is missing, rather
#           than silently falling back to a fetch.

set -euo pipefail
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPTDIR}/.."
ENDPOINTS_DIR="${REPO_ROOT}/endpoints"
OUTPUT_DIR="${SCRIPTDIR}/openapi_out"
# Deliberately at the repo ROOT, not under scripts/: shell-lint runs
# `find scripts/ docker/ -name "*.sh"` and sql-lint runs `sqlfluff lint scripts/`,
# and find descends dot-directories. A venv under scripts/ would put third-party
# package contents in both jobs' path.
VENV_DIR="${REPO_ROOT}/.openapi_venv"
OFFLINE="${COMMON_CI_OFFLINE:-0}"

# The generator drops rewrite_rules.conf into the CWD it is run from, which is the
# repo root; and OUTPUT_DIR is a staging tree. Neither is committed, and a failure
# part-way through used to leave both behind for `git add -A` to pick up.
cleanup() {
    rm -f "${REPO_ROOT}/rewrite_rules.conf"
    rm -rf "${OUTPUT_DIR}"
}
trap cleanup EXIT

# PINNED, not "develop": the generator is fetched at run time, so a moving ref
# means the same annotations can produce different artifacts on different days
# with nothing to signal it.
#
# This default MUST match COMMON_CI_REF in .gitlab-ci.yml, which the repo already
# pins and which GitLab injects into every job -- so in CI this line never fires.
# It only applies to a developer running the script by hand, and the whole point
# is that they regenerate with the same generator CI validates against. An earlier
# revision defaulted to the 1.28.6 TAG here, which silently made local and CI use
# different refs: exactly the divergence this comment claims to prevent.
COMMON_CI_REF="${COMMON_CI_REF:-96889a650b3f45244cecc4bb3f250af439a71900}"
COMMON_CI_URL="https://gitlab.syncad.com/hive/common-ci-configuration/-/raw/${COMMON_CI_REF}"
PROCESS_OPENAPI="${SCRIPTDIR}/process_openapi.py"

# Always re-fetch. Skipping when the file already exists (it is gitignored) meant a
# stale cached helper from an older ref silently produced different artifacts than a
# colleague's -- the same class of drift the pin above prevents, one level down.
if [[ "${OFFLINE}" == "1" ]]; then
    if [[ ! -f "${PROCESS_OPENAPI}" ]]; then
        echo "ERROR: COMMON_CI_OFFLINE=1 but ${PROCESS_OPENAPI} has never been downloaded." >&2
        echo "       Run once with network access first." >&2
        exit 1
    fi
    echo "Using cached process_openapi.py (COMMON_CI_OFFLINE=1)"
else
    echo "Fetching process_openapi.py from common-ci-configuration (ref: ${COMMON_CI_REF})..."
    curl -fsSL "${COMMON_CI_URL}/haf-app-tools/python/process_openapi.py" -o "${PROCESS_OPENAPI}"
fi

# A private virtualenv, for three separate reasons:
#  - `pip install` and `python3` are frequently different interpreters (pyenv or
#    Homebrew pip alongside /usr/bin/python3), so installing with one and running
#    with the other fails with ModuleNotFoundError right after reporting success;
#  - a system Python on Debian 12 / Ubuntu 24.04 refuses to install at all
#    (PEP 668 externally-managed-environment), and set -e would kill the script
#    here -- leaving a developer unable to run the regeneration the CI drift gate
#    requires;
#  - the pins below are exact, so installing them globally would silently
#    DOWNGRADE whatever the developer has for other projects.
# The versions are pinned for the same reason as the generator itself: this
# script's contract is byte-identical output, and deepmerge's Merger drives the
# fragment merge -- a strategy change there would rewrite the blob repo-wide.
# Every sibling CI job pins its tooling (sqlfluff==3.3.0, pytest<9, shellcheck
# v0.11.0); this was the one reproducibility input left floating at PyPI latest.
if [[ "${OFFLINE}" == "1" ]]; then
    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        echo "ERROR: COMMON_CI_OFFLINE=1 but ${VENV_DIR} does not exist." >&2
        echo "       Run once with network access first." >&2
        exit 1
    fi
    echo "Using cached virtualenv (COMMON_CI_OFFLINE=1)"
else
    python3 -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip
    "${VENV_DIR}/bin/python" -m pip install --quiet \
        deepmerge==2.0 jsonpointer==3.1.1 pyyaml==6.0.3
fi
VENV_PYTHON="${VENV_DIR}/bin/python"

echo "Running process_openapi.py..."
# IMPORTANT: pass a RELATIVE input path and run from the repo root. The generator
# writes its output to "${OUTPUT_DIR}/<input_path>"; since Python's
# `Path(out) / Path("/abs/...")` discards the left side and returns the absolute
# path, passing an absolute input would make it open (and truncate) the source
# file itself. A relative path keeps the output inside OUTPUT_DIR. The generator
# also writes rewrite_rules.conf into the CWD, hence the repo-root cd.
# PYTHONUTF8=1 forces UTF-8 for all file I/O regardless of the host locale. Without it,
# process_openapi.py reads the UTF-8 source under the platform default (e.g. cp1252 on
# Windows) and mangles non-ASCII in the regenerated JSON blob — em-dashes become mojibake
# (â€”) in unrelated endpoint descriptions. No effect where UTF-8 is already
# the default (Linux/CI).
( cd "${REPO_ROOT}" && PYTHONUTF8=1 "${VENV_PYTHON}" "${PROCESS_OPENAPI}" "${OUTPUT_DIR}" "endpoints/endpoint_schema.sql" )

# Copy generated endpoint_schema.sql back (contains the embedded JSON blob), then
# strip trailing whitespace the generator leaves on "RETURNS <type> " lines so the
# file passes `git diff --check`.
cp "${OUTPUT_DIR}/endpoints/endpoint_schema.sql" "${ENDPOINTS_DIR}/endpoint_schema.sql"
sed -i 's/[[:space:]]*$//' "${ENDPOINTS_DIR}/endpoint_schema.sql"

# Build endpoints/rewrite_rules.conf from the generated rewrite_rules.conf:
#  - the generator emits "# comment" then "rewrite ...", with the catch-all first;
#    reverse the BLOCK order so the catch-all/default ends up LAST (first match
#    wins in nginx) while keeping each comment above its rewrite;
#  - anchor specific patterns with a trailing "$" (the generator omits it, so
#    "^/health" would also match "/healthXYZ"); "^/$" and "^/(.*)$" already end in $;
#  - prepend a header.
#
# Written to a temp file and moved into place only on success. A redirect straight
# at the destination TRUNCATES it before the pipeline runs, so any failure in awk
# or sed left a committed artifact holding nothing but the three header lines --
# no rules at all, not even the catch-all, which would make the rewriter 404 every
# public path. `git add -A` after a failed run would have shipped that.
GENERATED_RULES="$(mktemp)"
trap 'cleanup; rm -f "${GENERATED_RULES}"' EXIT
{
    echo "# nginx rewrite rules — auto-generated from OpenAPI annotations in endpoint_schema.sql."
    echo "# Run scripts/openapi_rewrite.sh to regenerate after changing endpoint paths."
    echo "# Specific rules must precede the default catch-all (first match wins in nginx)."
    awk 'BEGIN { RS=""; FS="\n" } { block[NR]=$0 }
         END { for (i=NR; i>=1; i--) if (block[i] != "") { print ""; print block[i] } }' \
        "${REPO_ROOT}/rewrite_rules.conf"
} | sed -E 's#^(rewrite \^[^ ]*[^$]) #\1$ #' > "${GENERATED_RULES}"
mv "${GENERATED_RULES}" "${ENDPOINTS_DIR}/rewrite_rules.conf"

echo "Done. Review and commit endpoints/endpoint_schema.sql and endpoints/rewrite_rules.conf."
