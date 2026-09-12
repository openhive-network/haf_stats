#!/bin/bash
# Assert that the HAF fragments this repo depends on still exist upstream. (#87)
#
# WHY THIS EXISTS. tests/ci_haf_stub.sql and tests/ci_setup.sql hand-transcribe parts of
# hive/haf so that install-test and endpoint-tests can run without a replayed HAF. Nothing
# compared those transcriptions against upstream: no pinned SHA, no version, no check. The
# failure mode is the bad one -- the shims are the ONLY definition of hive.*/hafd.* in
# those lanes, so an upstream rename cannot reach them and both stay GREEN while
# production breaks. sync would catch it, but sync is the 380-570s lane install-test
# exists to let people skip, so the fast lane and the slow lane disagree and the fast one
# is the one that gets trusted.
#
# It is deliberately greps rather than a schema diff: the point is to notice a rename or a
# removal early and loudly, not to prove equivalence. Each check names the thing in THIS
# repo that breaks. A failure is not "upstream did something wrong" -- it is "our
# transcription is now stale, go look".
#
# ------------------------------------------------------------------------------------
# HOW THIS SCRIPT CAN LIE TO YOU, and what stops it.
#
# The FIRST version of this file reported "No drift" and exit 0 while running ZERO
# checks. `fail=1` was set inside `if f=$(fetch ...)` -- a command substitution runs in a
# SUBSHELL, so the assignment was discarded -- and the error text went to stdout, where it
# was captured into the variable instead of printed. A bad ref, an unreachable host, and a
# MOVED FILE all produced a green checkmark. The moved-file case is the single upstream
# event this job exists to anticipate, so the guard was blind to exactly its own purpose.
#
# Three things prevent that now. None of them should be removed:
#   1. fetch() runs in the MAIN shell and writes the global FETCHED. No subshell.
#   2. Every diagnostic goes to stderr, so a substitution can never swallow it.
#   3. EXPECTED_CHECKS is asserted against the number that actually ran, so a silent skip
#      is a hard failure whatever caused it.
# ------------------------------------------------------------------------------------

set -uo pipefail

# HAF_DRIFT_REF selects what to compare against:
#
#   unset      develop -- early warning. Upstream moves on its own schedule, so this is
#              the advisory mode: it can go yellow for something that has not reached the
#              version we run.
#   pinned     whatever docker/.env's HAF_VERSION says. DERIVED, not duplicated: an
#              earlier design hardcoded the tag in .gitlab-ci.yml, which is a second place
#              to forget when the pin moves. This mode is deterministic -- it only changes
#              when WE bump the pin -- which is what makes it safe to hard-fail on.
#   <ref>      any tag or branch. Note the tags here are '1.28.6', not 'v1.28.6'.
REF="${HAF_DRIFT_REF:-develop}"

if [ "${REF}" = "pinned" ]; then
    ENV_FILE="$(dirname "$0")/../docker/.env"
    if [ ! -r "${ENV_FILE}" ]; then
        echo "ERROR: HAF_DRIFT_REF=pinned but ${ENV_FILE} is not readable." >&2
        exit 1
    fi
    REF="$(grep -E '^HAF_VERSION=' "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
    if [ -z "${REF}" ]; then
        echo "ERROR: HAF_DRIFT_REF=pinned but no HAF_VERSION= line in ${ENV_FILE}." >&2
        echo "       If the pin moved somewhere else, update this script -- do not fall" >&2
        echo "       back to develop, which would silently stop checking what we run." >&2
        exit 1
    fi
    echo "HAF_DRIFT_REF=pinned resolved to '${REF}' from docker/.env"
fi

BASE="https://gitlab.syncad.com/hive/haf/-/raw/${REF}/src/hive_fork_manager"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Bump when you add or remove a check. This is the assertion that makes every other
# assertion trustworthy: it turns "the fetch quietly failed" into a red job.
EXPECTED_CHECKS=36

fail=0
ran=0
FETCHED=""
FETCHED_FLAT=""

soft() { echo "$*" >&2; fail=1; }

# Sets FETCHED; returns 0 on success. MUST be called in the main shell -- never as
# `$(fetch ...)`, or `fail` is lost again.
fetch() {
    local rel="$1"
    local dest="${WORK}/${rel//\//_}"
    FETCHED=""
    if ! curl -sfL --max-time 30 --retry 3 --retry-delay 2 "${BASE}/${rel}" -o "${dest}"; then
        soft "ERROR: could not fetch ${rel} from hive/haf@${REF} (HTTP error or network failure)."
        soft "       If the file MOVED, that is itself drift -- update this script, do not delete the check."
        soft "       If the ref is wrong: the tags here are '1.28.6', not 'v1.28.6'."
        return 1
    fi
    if [ ! -s "${dest}" ]; then
        soft "ERROR: ${rel} came back EMPTY from hive/haf@${REF}."
        return 1
    fi
    # A maintenance page or a sign-in redirect is HTTP 200 with an HTML body, which -f
    # does not reject and -L follows. Without this, every check against that file reports
    # DRIFT and blames our transcription for someone else's outage.
    if head -c 400 "${dest}" | grep -qiE '<!doctype html|<html'; then
        soft "ERROR: ${rel} came back as HTML, not SQL -- upstream is unreachable or redirecting."
        soft "       This is an INFRASTRUCTURE problem, not drift. Do not edit the transcription."
        return 1
    fi
    if ! grep -qiE '^[[:space:]]*(CREATE|GRANT|REVOKE|ALTER|--)' "${dest}"; then
        soft "ERROR: ${rel} does not look like SQL. Refusing to draw conclusions from it."
        return 1
    fi
    FETCHED="${dest}"
    # A newline-flattened copy, for the ONE pattern that must span lines. Kept
    # separate because grep -z makes ^ anchor to the start of the whole FILE, which
    # silently defeats every anchored pattern -- measured: all 35 reported DRIFT at
    # once when this script briefly used -z everywhere.
    tr '\n' ' ' < "${dest}" > "${dest}.flat"
    FETCHED_FLAT="${dest}.flat"
    return 0
}

# skip <n> -- account for checks that could not run, so the ran-count assertion fires.
skip() { ran=$((ran + $1)); }

# need <pattern> <what breaks HERE if it is gone>
#
# Patterns are ANCHORED and whitespace-tolerant on purpose:
#   ^[[:space:]]*CREATE   a comment or a DROP mentioning the name must NOT satisfy a
#                         check. Unanchored `FUNCTION hive.x` passed against
#                         `-- removed: CREATE FUNCTION hive.x` and against
#                         `DROP FUNCTION hive.x` -- both measured.
#   [[:space:]]*          upstream already wraps some statements across lines and spaces
#                         its parens inconsistently. A reformat is not drift, and a guard
#                         that yellows on whitespace is a guard that gets ignored.
#   (OR REPLACE)? optional -- adding or dropping OR REPLACE is not drift either.
need() {
    local pat="$1" why="$2"
    ran=$((ran + 1))
    if grep -Eq -- "${pat}" "${FETCHED}"; then
        echo "  ok     ${pat}"
    else
        echo "  DRIFT  ${pat}"
        echo "         ${why}"
        fail=1
    fi
}

# Same contract as need(), but against the flattened copy, so a pattern may span the
# line breaks upstream's house style already uses for some policies. No ^ anchor is
# possible there -- the file is one line -- so keep these patterns specific by naming
# the table and the role rather than relying on the anchor.
need_flat() {
    local pat="$1" why="$2"
    ran=$((ran + 1))
    if grep -Eq -- "${pat}" "${FETCHED_FLAT}"; then
        echo "  ok     ${pat}  (multiline-tolerant)"
    else
        echo "  DRIFT  ${pat}"
        echo "         ${why}"
        fail=1
    fi
}

C='^[[:space:]]*CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?'
S='[[:space:]]*'

echo "Checking hive/haf@${REF} for the fragments haf_stats transcribes or calls..."

# ======================================================================================
echo
echo "compatibility_with_old_haf_apps.sql -- the aliases, and how long they last"
if fetch "types/operation/compatibility_with_old_haf_apps.sql"; then
    need "${C}DOMAIN${S}hive\.application_stages" \
        "tests/ci_haf_stub.sql reproduces this alias. db/haf_stats_app.sql no longer uses it (#87), so removal is survivable -- drop it from the shim to match."
    need "${C}FUNCTION${S}hive\.live_stage" \
        "Same: reproduced in the shim, no longer used by db/."
    need "${C}DOMAIN${S}hive\.context_name" \
        "tests/ci_haf_stub.sql reproduces it."
    need "${C}DOMAIN${S}hive\.contexts_group" \
        "The THIRD alias, which an earlier revision of this script and of the shim both missed. It is the argument type of the group overloads of app_context_attach/detach/set_non_forking that ci_haf_stub.sql's own comments cite. The shim now reproduces it and its non-empty CHECK."
else
    skip 4
fi

# ======================================================================================
echo
echo "application_loop/stages.sql -- the canonical names db/haf_stats_app.sql now uses"
if fetch "application_loop/stages.sql"; then
    need "${C}TYPE${S}hafd\.application_stage${S}AS" \
        "db/haf_stats_app.sql builds its stages array of these; tests/ci_haf_stub.sql defines the same composite."
    # The FIELDS, not just the name: replacing all four with different ones left a
    # name-only check green -- measured.
    need "min_head_block_distance" \
        "tests/ci_haf_stub.sql transcribes this field name; hive.stage() populates it positionally."
    need "blocks_limit_in_group" "As above."
    need "processing_alarm_threshold" "As above."
    need "${C}DOMAIN${S}hafd\.application_stages${S}AS${S}hafd\.application_stage\[\]" \
        "db/haf_stats_app.sql declares _stages of this type."
    need "${C}FUNCTION${S}hafd\.live_stage" \
        "db/haf_stats_app.sql calls it."
    need "${C}DOMAIN${S}hafd\.blocks_count${S}AS${S}INTEGER${S}CHECK${S}\(${S}VALUE${S}>${S}0${S}\)" \
        "Reproduced verbatim in tests/ci_haf_stub.sql; the shim's probe asserts the CHECK fires."
    need "${C}DOMAIN${S}hafd\.blocks_distance${S}AS${S}INTEGER${S}CHECK${S}\(${S}VALUE${S}>=${S}0${S}\)" "As above."
    need "${C}DOMAIN${S}hafd\.stage_name${S}AS${S}TEXT${S}CHECK" "As above."
else
    skip 9
fi

# ======================================================================================
echo
echo "application_loop/stages_functions.sql -- the HAF symbol db/ deliberately KEPT"
if fetch "application_loop/stages_functions.sql"; then
    # #87 moved db/haf_stats_app.sql off the compat aliases, and the first version of this
    # script then guarded only the names it moved TO. hive.stage() is the one it KEPT --
    # canonical, not an alias -- so an upstream move of it is exactly the silent-green
    # case this job exists to close.
    need "${C}FUNCTION${S}hive\.stage" \
        "db/haf_stats_app.sql calls hive.stage(); its own comment cites this file as why it was not migrated to hafd.*."
    need "RETURNS${S}hafd\.application_stage" \
        "hive.stage() must keep returning hafd.application_stage, or the ARRAY[...]::hafd.application_stages cast in db/haf_stats_app.sql stops typechecking."
    need "${C}FUNCTION${S}hive\.validate_stages" \
        "What a node runs over the stages array we build -- a change here changes what HAF will accept from us."
else
    skip 3
fi

# ======================================================================================
echo
echo "authorization.sql -- the privilege model tests/ci_haf_stub.sql transcribes"
if fetch "authorization.sql"; then
    need "${C}FUNCTION${S}hive\.can_impersonate" \
        "scripts/uninstall_app.sh guard 2 calls it directly; tests/ci_haf_stub.sql copies its body verbatim."
    need "GRANT${S}ALL${S}ON${S}hafd\.contexts${S}TO.*hive_applications_group" \
        "tests/ci_haf_stub.sql reproduces this grant; the column REVOKE is inert without it."
    need "REVOKE${S}UPDATE${S}\([^)]*is_forking[^)]*\)${S}ON${S}hafd\.contexts" \
        "Reproduced in the shim, including the fact that it is inert. Argument ORDER deliberately not asserted -- reordering is not drift."
    # Table and role were inside the old pattern's .* -- retargeting the policy to another
    # table left it green. Both asserted now.
    need "${C}POLICY${S}dp_hive_context${S}ON${S}hafd\.contexts${S}FOR${S}INSERT" \
        "The one policy install-test actually enforces -- it produced red run 4, and the owner assertion in tests/ci_install_verify.sql defends it."
    need "${C}POLICY${S}sp_applications_update_hive_context${S}ON${S}hafd\.contexts${S}FOR${S}UPDATE${S}TO${S}hive_applications_group" \
        "Table and role matter as much as the body; the shim transcribes all three."
    need_flat "sp_applications_update_hive_context.*USING\(${S}TRUE${S}\).*WITH${S}CHECK\(${S}hive\.can_impersonate" \
        "USING(TRUE) vs a restricted USING is the difference between a hard error and a silent zero-row no-op."
    need "${C}POLICY${S}sp_applications_delete_hive_context${S}ON${S}hafd\.contexts${S}FOR${S}DELETE" \
        "scripts/uninstall_app.sh reasons about exactly this policy."
    need "REVOKE${S}EXECUTE${S}ON${S}ALL${S}FUNCTIONS${S}IN${S}SCHEMA${S}hive${S}FROM${S}PUBLIC" \
        "tests/ci_haf_stub.sql reproduces it; it is what makes db/builtin_roles.sql:86 falsifiable in CI."
    need "GRANT${S}EXECUTE${S}ON${S}ALL${S}FUNCTIONS${S}IN${S}SCHEMA${S}hive${S}TO.*hive_applications_group" \
        "The paired grant. The REVOKE alone is the half that cannot break anything."
else
    skip 9
fi

# ======================================================================================
echo
echo "app_api.sql -- the lifecycle calls db/ and scripts/ make"
if fetch "app_api.sql"; then
    for fn in app_context_exists app_context_set_non_forking app_context_detach \
              app_context_attach app_context_is_attached app_set_current_block_num \
              app_get_current_block_num app_remove_context; do
        need "${C}FUNCTION${S}hive\.${fn}" \
            "haf_stats_app.create_context_if_not_exists() or scripts/uninstall_app.sh calls it; tests/ci_haf_stub.sql stubs it."
    done
    # The OVERLOAD we call, not just the name. Deleting the _stages overload -- the only
    # one db/haf_stats_app.sql uses, and precisely the one a hive.*->hafd.* migration
    # would retype -- left a name-only check green. Measured.
    need "_stages${S}hafd\.application_stages" \
        "db/haf_stats_app.sql calls the STAGED overload by name (_name/_schema/_stages). The sibling overload takes (_is_forking, _is_attached) and would not match that call."
else
    skip 9
fi

# ======================================================================================
echo
echo "app_api_impl.sql -- hive.blocks_range, which haf_stats_app.main() DECLAREs"
# NOT in app_api.sql, where an earlier revision of this script looked for it. The guard
# reported that as DRIFT on its first run and was right to: a check pointed at the wrong
# file is indistinguishable from the symbol being gone, and both should be loud.
if fetch "app_api_impl.sql"; then
    need "${C}TYPE${S}hive\.blocks_range" \
        "haf_stats_app.main() DECLAREs a variable of this type, and plpgsql resolves declared types at CREATE -- a rename stops db/haf_stats_app.sql loading at all. It is a hive.* TYPE in a repo whose premise is that hive.* types get relocated to hafd.*."
else
    skip 1
fi

# ======================================================================================
echo
echo "context_rewind/data_schema.sql -- hafd.context_name, cast to by db/"
if fetch "context_rewind/data_schema.sql"; then
    need "${C}DOMAIN${S}hafd\.context_name${S}AS${S}TEXT" \
        "db/haf_stats_app.sql casts to it and tests/ci_haf_stub.sql defines it; it is also hive.app_create_context's first parameter type."
else
    skip 1
fi

echo
if [ "${ran}" -ne "${EXPECTED_CHECKS}" ]; then
    echo "ERROR: ${ran} checks ran, expected ${EXPECTED_CHECKS}." >&2
    echo "       Either a fetch failed, or a check was added/removed without bumping" >&2
    echo "       EXPECTED_CHECKS. This assertion exists because an earlier version of this" >&2
    echo "       script reported 'No drift' having run ZERO checks." >&2
    fail=1
fi

if [ "${fail}" -ne 0 ]; then
    cat >&2 <<'MSG'

DRIFT DETECTED, or the check could not run, against hive/haf.

This does not mean upstream broke anything. It means a fragment this repo transcribes or
calls has moved, and something here is now stale:

  tests/ci_haf_stub.sql     the HAF context-lifecycle shim used by install-test
  tests/ci_setup.sql        the HAF data-model shim used by endpoint-tests
  db/haf_stats_app.sql      the context lifecycle the processor depends on
  scripts/uninstall_app.sh  its guard 2 calls hive.can_impersonate directly

Neither install-test nor endpoint-tests can catch this class on their own -- the shims are
the only definition of hive.*/hafd.* in those lanes, so they stay green while a real node
fails. That is the whole reason this job exists (#87). Fix the transcription; do not
delete the check.
MSG
    exit 1
fi

echo "No drift: all ${ran} fragments haf_stats depends on are present in hive/haf@${REF}."
