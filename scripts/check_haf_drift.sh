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
    # grep -m1, not `grep | head -1`: head closes the pipe, and under pipefail that is a
    # SIGPIPE status (141) waiting for the day someone adds `set -e`. need_col's comment
    # forbids exactly this pattern, so the file should not contradict itself.
    REF="$(grep -m1 -E '^HAF_VERSION=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"'"'"' \r')"
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
EXPECTED_CHECKS=63

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
    FETCHED_FLAT=""
    # --connect-timeout, because --max-time is PER ATTEMPT: measured, 30s x 4 attempts
    # plus 3 x 2s backoff is up to ~126s for ONE file, and this fetches twelve. A lint job
    # that hangs for twenty minutes before reporting gets ignored.
    if ! curl -sfL --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 "${BASE}/${rel}" -o "${dest}"; then
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

# need_col <view-create-pattern> <column> <what breaks HERE if it is gone>
#
# A bare column name is far too common to grep for file-wide -- `block_num` occurs in a
# dozen different views in block_views_for_head_block.sql -- so an unscoped check for one
# would be satisfied by any of them and mean nothing. This extracts the ONE statement the
# view is defined by (its CREATE, up to the line before the next top-level CREATE) and
# greps only that.
#
# WHAT IT PROVES, AND WHAT IT DOES NOT. Upstream names some of these columns explicitly
# (`... as block_num`) and some implicitly, by projecting a source column (`t.body_value`).
# For the explicit ones this is the output name. For the implicit ones it is the SOURCE
# column's name, which is the output name only while no alias is added -- so it catches a
# renamed column, which is the event #89 is about, and not a re-aliased one. Say so rather
# than letting the check look stronger than it is.
need_col() {
    local start="$1" col="$2" why="$3"
    ran=$((ran + 1))
    local starts sl creates el n region
    # `grep | cut`, never `grep | head`: cut drains its input, so there is no EPIPE for
    # pipefail to convert into a failure. That distinction has already cost this repo a
    # job once -- see the openapi-drift note in .gitlab-ci.yml.
    starts="$(grep -nE -- "${start}" "${FETCHED}" | cut -d: -f1)"
    sl="${starts%%$'\n'*}"
    if [ -z "${sl}" ]; then
        echo "  DRIFT  ${col} -- the view it belongs to did not match ${start}"
        echo "         ${why}"
        fail=1
        return
    fi
    creates="$(grep -nE -- '^CREATE[[:space:]]' "${FETCHED}" | cut -d: -f1)"
    el=""
    for n in ${creates}; do
        if [ "${n}" -gt "${sl}" ]; then el=$((n - 1)); break; fi
    done
    # grep -c '' and not wc -l: wc counts NEWLINES, so a file with no trailing newline
    # loses its last line. Two of the eleven fetched files have none.
    if [ -z "${el}" ]; then el="$(grep -c '' "${FETCHED}")"; fi
    # Strip `--` comments from the region before looking. Preventative, not a live fix:
    # measured, none of the ten columns checked here is comment-only today. But this is
    # the same class need()'s ^CREATE anchor exists for -- an unanchored check was once
    # satisfied by `-- removed: CREATE FUNCTION hive.x` -- and prose should never be able
    # to stand in for the SQL.
    # Comments, then string literals, then STOP at the statement terminator. All three
    # were needed: a `COMMENT ON VIEW ... IS 'renamed: body -> op_json'` sitting after the
    # view's own `;` but before the next CREATE satisfied a column check -- measured. The
    # literal strip also stops a `;` inside a string from truncating the region early.
    #
    # The awk drains its input rather than exiting at the terminator, so no stage takes
    # EPIPE and pipefail has nothing to convert into a failure.
    region="${WORK}/region"
    sed -n "${sl},${el}p" "${FETCHED}" \
        | sed 's/--.*$//' \
        | sed "s/'[^']*'//g" \
        | awk '{ if (!stop) print } /;/ { stop = 1 }' > "${region}"
    if grep -qE -- "${B}${col}${B}" "${region}"; then
        echo "  ok     ${col}  (within lines ${sl}-${el})"
    else
        echo "  DRIFT  ${col}"
        echo "         ${why}"
        fail=1
    fi
}

C='^[[:space:]]*CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?'
# End-of-identifier, for every pattern that ENDS in an object name.
#
# Without it `hive\.operations_view` matched `CREATE OR REPLACE VIEW
# hive.operations_view_extended`, so the check stayed GREEN with hive.operations_view
# itself renamed away -- vacuous in exactly the case it exists for. Found by negative
# control (rename the object in a local mirror, require the check to go red), not by
# review and not by CI, because a vacuous check is green by construction.
#
# \b, not [^A-Za-z0-9_], because the haf-drift job runs alpine:3.20 and BusyBox grep -E
# there supports \b -- measured in that image, not assumed. A pattern that CONTINUES past
# the name (`...AS hafd.application_stage[]`, `...ON hafd.contexts FOR INSERT`) already
# has its boundary and does not take this.
B='\b'

# Top-level-only CREATE, for files where the same object is ALSO created inside a
# function body.
#
# block_views_for_head_block.sql defines hive.operations_view, hive.accounts_view and
# hive.account_operations_view TWICE: once at top level, and again -- indented -- inside
# hive.recreate_head_block_views_lite(). ${C}'s leading [[:space:]]* cannot tell those
# apart, so renaming the REAL definition left the job green and, worse, slid need_col's
# region onto the lite copy (measured: 233-274 -> 403-412), where the ten column checks
# went on passing against a different, shorter view. Column 0 is the only thing in the
# file that distinguishes a top-level statement from a nested one.
#
# This deliberately trades the whitespace tolerance ${C} exists for: indenting a
# top-level CREATE upstream would now go red. That is the right direction to fail, and
# it costs nothing today -- measured, all 11 fetched files write every top-level CREATE
# at column 0, and only this one file has indented CREATEs at all (8 of them).
C0='^CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?'

S='[[:space:]]*'

echo "Checking hive/haf@${REF} for the fragments haf_stats transcribes or calls..."

# ======================================================================================
echo
echo "compatibility_with_old_haf_apps.sql -- the aliases, and how long they last"
if fetch "types/operation/compatibility_with_old_haf_apps.sql"; then
    need "${C}DOMAIN${S}hive\.application_stages${B}" \
        "tests/ci_haf_stub.sql reproduces this alias. db/haf_stats_app.sql no longer uses it (#87), so removal is survivable -- drop it from the shim to match."
    need "${C}FUNCTION${S}hive\.live_stage${B}" \
        "Same: reproduced in the shim, no longer used by db/."
    need "${C}DOMAIN${S}hive\.context_name${B}" \
        "tests/ci_haf_stub.sql reproduces it."
    need "${C}DOMAIN${S}hive\.contexts_group${B}" \
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
    # These three were bare, unanchored greps of the WHOLE file, so a routine `--`
    # changelog line naming the old field satisfied them, and so did a rename to
    # stage_min_head_block_distance. Both measured green. need_col scopes them to the
    # composite's own statement and strips comments, which is what they always meant.
    need_col "${C0}TYPE${S}hafd\.application_stage${S}AS" "min_head_block_distance" \
        "tests/ci_haf_stub.sql transcribes this field name; hive.stage() populates it positionally."
    need_col "${C0}TYPE${S}hafd\.application_stage${S}AS" "blocks_limit_in_group" "As above."
    need_col "${C0}TYPE${S}hafd\.application_stage${S}AS" "processing_alarm_threshold" "As above."
    need "${C}DOMAIN${S}hafd\.application_stages${S}AS${S}hafd\.application_stage\[\]" \
        "db/haf_stats_app.sql declares _stages of this type."
    need "${C}FUNCTION${S}hafd\.live_stage${B}" \
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
    need "${C}FUNCTION${S}hive\.stage${B}" \
        "db/haf_stats_app.sql calls hive.stage(); its own comment cites this file as why it was not migrated to hafd.*."
    need "^${S}RETURNS${S}hafd\.application_stage${B}" \
        "hive.stage() must keep returning hafd.application_stage, or the ARRAY[...]::hafd.application_stages cast in db/haf_stats_app.sql stops typechecking."
    need "${C}FUNCTION${S}hive\.validate_stages${B}" \
        "What a node runs over the stages array we build -- a change here changes what HAF will accept from us."
else
    skip 3
fi

# ======================================================================================
echo
echo "authorization.sql -- the privilege model tests/ci_haf_stub.sql transcribes"
if fetch "authorization.sql"; then
    need "${C}FUNCTION${S}hive\.can_impersonate${B}" \
        "scripts/uninstall_app.sh guard 2 calls it directly; tests/ci_haf_stub.sql copies its body verbatim."
    need "^${S}GRANT${S}ALL${S}ON${S}hafd\.contexts${S}TO.*hive_applications_group${B}" \
        "tests/ci_haf_stub.sql reproduces this grant; the column REVOKE is inert without it."
    need "^${S}REVOKE${S}UPDATE${S}\([^)]*is_forking[^)]*\)${S}ON${S}hafd\.contexts${B}" \
        "Reproduced in the shim, including the fact that it is inert. Argument ORDER deliberately not asserted -- reordering is not drift."
    # Table and role were inside the old pattern's .* -- retargeting the policy to another
    # table left it green. Both asserted now.
    need "${C}POLICY${S}dp_hive_context${S}ON${S}hafd\.contexts${S}FOR${S}INSERT" \
        "The one policy install-test actually enforces -- it produced red run 4, and the owner assertion in tests/ci_install_verify.sql defends it."
    need "${C}POLICY${S}sp_applications_update_hive_context${S}ON${S}hafd\.contexts${S}FOR${S}UPDATE${S}TO${S}hive_applications_group${B}" \
        "Table and role matter as much as the body; the shim transcribes all three."
    need_flat "CREATE${S}POLICY${S}sp_applications_update_hive_context${B}[^;]*USING\(${S}TRUE${S}\)[^;]*WITH${S}CHECK\(${S}hive\.can_impersonate${B}" \
        "USING(TRUE) vs a restricted USING is the difference between a hard error and a silent zero-row no-op."
    need "${C}POLICY${S}sp_applications_delete_hive_context${S}ON${S}hafd\.contexts${S}FOR${S}DELETE" \
        "scripts/uninstall_app.sh reasons about exactly this policy."
    need "^${S}REVOKE${S}EXECUTE${S}ON${S}ALL${S}FUNCTIONS${S}IN${S}SCHEMA${S}hive${S}FROM${S}PUBLIC${B}" \
        "tests/ci_haf_stub.sql reproduces it; it is what makes db/builtin_roles.sql:130 falsifiable in CI."
    need "^${S}GRANT${S}EXECUTE${S}ON${S}ALL${S}FUNCTIONS${S}IN${S}SCHEMA${S}hive${S}TO.*hive_applications_group${B}" \
        "The paired grant. The REVOKE alone is the half that cannot break anything."
else
    skip 9
fi

# ======================================================================================
echo
echo "app_api.sql -- the lifecycle calls db/ and scripts/ make"
if fetch "app_api.sql"; then
    # The NAME of the context constructor, which nothing checked. The _stages assertion
    # below pins its argument list, but renaming hive.app_create_context itself left the
    # whole guard green -- measured -- while db/haf_stats_app.sql calls it by that name.
    need "${C}FUNCTION${S}hive\.app_create_context${S}\(" \
        "db/haf_stats_app.sql's create_context_if_not_exists() calls it; nothing else creates the context."

    # Single upstream overload, or not called by us directly -- the name is the whole
    # dependency.
    for fn in app_context_exists app_context_is_attached app_remove_context; do
        need "${C}FUNCTION${S}hive\.${fn}${B}" \
            "db/haf_stats_app.sql or scripts/uninstall_app.sh calls it; tests/ci_haf_stub.sql stubs it."
    done

    # hive.app_context_attach is NOT called by this repo -- hive.app_next_iteration()
    # attaches on its first call, which is why db/haf_stats_app.sql clamps the seed so
    # that attach cannot reject it. The name is still a dependency; the overload is not
    # ours to pin.
    need "${C}FUNCTION${S}hive\.app_context_attach${B}" \
        "hive.app_next_iteration() attaches through it, and db/haf_stats_app.sql's LEAST() clamp exists to keep that call from raising."

    # THE OVERLOAD WE CALL, for the four that have two. Every call site in db/ passes a
    # single context ('haf_stats' or a hafd.context_name), never a contexts_group -- so
    # deleting the single-context overload breaks a real node while leaving a name-only
    # check green. Measured on all four. Note upstream spells the parameter _context for
    # three of them and _context_name for app_get_current_block_num.
    for fn in app_context_set_non_forking app_context_detach \
              app_set_current_block_num app_get_current_block_num; do
        need "${C}FUNCTION${S}hive\.${fn}${S}\(${S}_context(_name)?${S}hafd\.context_name" \
            "db/haf_stats_app.sql calls the SINGLE-CONTEXT overload; the sibling takes hive.contexts_group and would not match that call."
    done
    # The OVERLOAD we call, not just the name. Deleting the _stages overload -- the only
    # one db/haf_stats_app.sql uses, and precisely the one a hive.*->hafd.* migration
    # would retype -- left a name-only check green. Measured.
    need "^${S},?${S}_stages${S}hafd\.application_stages${B}" \
        "db/haf_stats_app.sql calls the STAGED overload by name (_name/_schema/_stages). The sibling overload takes (_is_forking, _is_attached) and would not match that call."
else
    skip 10
fi

# ======================================================================================
echo
echo "app_api_impl.sql -- hive.blocks_range, which haf_stats_app.main() DECLAREs"
# NOT in app_api.sql, where an earlier revision of this script looked for it. The guard
# reported that as DRIFT on its first run and was right to: a check pointed at the wrong
# file is indistinguishable from the symbol being gone, and both should be loud.
if fetch "app_api_impl.sql"; then
    need "${C}TYPE${S}hive\.blocks_range${B}" \
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

# ======================================================================================
echo
echo "the DATA-MODEL shim: what tests/ci_setup.sql transcribes (#89)"
# tests/ci_haf_stub.sql is not the only hand-written HAF copy here, and it is the smaller
# one. tests/ci_setup.sql stubs the data model endpoint-tests runs against, and it has the
# identical failure mode: it is the ONLY definition of these objects in that lane, so an
# upstream rename cannot reach it and endpoint-tests stays green while a node fails.
#
# These messages name FILES, not reference counts. An earlier revision counted
# occurrences across db/, endpoints/ and scripts/; the counting script globbed both
# `scripts/*.sh` and `scripts/**/*.sh` into a list rather than a set and so counted every
# shell file twice, and a reviewer re-measuring with a stricter lexer produced a third set
# of numbers again. A figure three careful passes cannot agree on does not belong in a
# failure message -- and when a check fires, the file to go and look at is the useful
# thing anyway.
if fetch "irreversible_blocks.sql"; then
    need "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.blocks${B}" \
        "Every per-day rollup in db/process_*.sql joins it for block timestamps; tests/ci_setup.sql stubs num, created_at, the two vesting totals and producer_account_id."
    need "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.operations${B}" \
        "db/process_*.sql read operations from it, and hafd.operation_id_to_block_num is applied to its id column."
    need "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.operation_types${B}" \
        "db/op_type_registry.sql resolves every op NAME through it (ot.name = e.op_name), and scripts/install_app.sh's assert_op_types gates install on it."
    need "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.accounts${B}" \
        "The account-scoped endpoints in endpoints/endpoint_schema.sql resolve names to ids here, as do the db/process_* writers."
    need "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.hive_state${B}" \
        "db/haf_stats_app.sql:232 clamps its context seed with LEAST(_app_block, MAX(hs.consistent_block)) so app_context_attach cannot be asked to start above HAF, and db/sync_status.sql reports it."
    # #44: db/exact_rc.sql finds an operation's transaction through these. rc_cost itself is
    # deliberately NOT checked: it exists only from HAF 1.28.8, the pin can be older, and the
    # function checks for the column at run time and falls back to the estimate without it.
    need "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.transactions${B}" \
        "db/exact_rc.sql reads each transaction's rc_cost from it; tests/ci_setup.sql stubs block_num, trx_in_block and rc_cost."
    need_col "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.transactions${B}" "block_num" \
        "db/exact_rc.sql joins an operation's block to its transaction on it."
    need_col "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.transactions${B}" "trx_in_block" \
        "db/exact_rc.sql joins an operation to its transaction on it."
    need_col "${C}TABLE${S}(IF${S}NOT${S}EXISTS${S})?hafd\.operations${B}" "trx_in_block" \
        "db/exact_rc.sql groups a transaction's operations by it to split the transaction's RC cost; tests/ci_setup.sql stubs it."
else
    skip 9
fi

# ======================================================================================
echo
echo "types/operation/operation_id.sql -- the id encoding db/ depends on"
if fetch "types/operation/operation_id.sql"; then
    # These encode block_num and position into one BIGINT. A change to the ENCODING would
    # not move the name, so this check cannot see that -- it catches a rename or removal
    # only, which is the class #89 is about.
    need "${C}FUNCTION${S}hafd\.operation_id${B}" \
        "db/process_block_range.sql, db/process_content_cohorts.sql and db/process_content_stats.sql call it; tests/ci_setup.sql transcribes the encoding."
    need "${C}FUNCTION${S}hafd\.operation_id_to_block_num${B}" \
        "The most-used single HAF function in this repo -- every block-range bound in db/ goes through it."
else
    skip 2
fi

# ======================================================================================
echo
echo "block_views_for_head_block.sql -- the hive.* views endpoint-tests stubs"
if fetch "block_views_for_head_block.sql"; then
    need "${C0}VIEW${S}hive\.operations_view${B}" \
        "Five db/process_*.sql files and endpoints/endpoint_schema.sql select from it; tests/ci_setup.sql transcribes it over hafd.operations, so a renamed view leaves endpoint-tests green."
    need "${C0}VIEW${S}hive\.account_operations_view${B}" \
        "endpoints/endpoint_schema.sql and db/process_rc.sql's account_op_seq_range() read it."
    need "${C0}VIEW${S}hive\.accounts_view${B}" \
        "db/process_block_range.sql and db/process_custom_json.sql."

    # The COLUMNS, not just the names (#89 asks for this decision explicitly). Measured:
    # db/ and endpoints/ select 5 of hive.operations_view's 8 columns and ALL 6 of
    # hive.account_operations_view's. A renamed column breaks a real node exactly as hard
    # as a renamed view and is invisible to a name-only check -- and this repo has already
    # measured that class once, on the first version of this guard in !90.
    #
    # hive.operations_view's `id` is deliberately NOT checked: within the view's own
    # statement `\bid\b` also matches `ot.id` (hafd.operation_types.id, in the JOIN), so
    # renaming the operations id would leave the check green. It is vacuous, so it is not
    # here -- see the negative-control note in the MR.
    need_col "${C0}VIEW${S}hive\.operations_view${B}" "body_value" \
        "The raw operation body every processor parses: db/process_content_stats.sql, db/process_community_registry.sql, db/process_content_cohorts.sql, db/process_block_range.sql and endpoints/endpoint_schema.sql."
    need_col "${C0}VIEW${S}hive\.operations_view${B}" "block_num" \
        "Five db/process_*.sql files filter on it. Upstream computes it as hafd.operation_id_to_block_num(t.id) AS block_num -- an explicit alias, so this is the output name."
    need_col "${C0}VIEW${S}hive\.operations_view${B}" "op_type_id" \
        "Five db/process_*.sql files use it; every op-type filter in the repo goes through it."
    need_col "${C0}VIEW${S}hive\.operations_view${B}" "body" \
        "endpoints/endpoint_schema.sql, db/process_account_cohorts.sql and db/process_block_range.sql. Upstream builds it with jsonb_build_object(...) AS body -- an explicit alias."

    need_col "${C0}VIEW${S}hive\.account_operations_view${B}" "account_id" \
        "endpoints/endpoint_schema.sql, plus the four unaliased probes in db/process_rc.sql's account_op_seq_range() (:215, :217, :227, :236)."
    need_col "${C0}VIEW${S}hive\.account_operations_view${B}" "account_op_seq_no" \
        "endpoints/endpoint_schema.sql, and db/process_rc.sql binary-searches on it -- the whole point of that helper is riding the (account_id, account_op_seq_no) index."
    need_col "${C0}VIEW${S}hive\.account_operations_view${B}" "op_type_id" \
        "The most-used column of this view here, throughout endpoints/endpoint_schema.sql."
    need_col "${C0}VIEW${S}hive\.account_operations_view${B}" "block_num" \
        "endpoints/endpoint_schema.sql, and the bisection bound in db/process_rc.sql. Explicitly aliased upstream."
    need_col "${C0}VIEW${S}hive\.account_operations_view${B}" "transacting_account_id" \
        "endpoints/endpoint_schema.sql."
    need_col "${C0}VIEW${S}hive\.account_operations_view${B}" "operation_id" \
        "endpoints/endpoint_schema.sql."
else
    skip 13
fi

# ======================================================================================
echo
echo "two more hive.* functions: one db/ wraps, one install_app.sh and sync_status.sql call"
if fetch "get_required_authorities.sql"; then
    # The jsonb overload specifically. Upstream has three (hafd.operation, text, jsonb);
    # haf_stats_app.get_required_authorities_safe(_body JSONB) calls the jsonb one, and
    # deleting just that one left a name-only check green -- measured.
    need "${C}FUNCTION${S}hive\.get_required_authorities${S}\(${S}(IN${S})?_[a-z_]+${S}jsonb${S}\)" \
        "db/haf_stats_app.sql:160 wraps it as get_required_authorities_safe(), which db/process_block_range.sql calls. NOT called by scripts/install_app.sh, and endpoints/endpoint_schema.sql only cites it in a comment."
else
    skip 1
fi
if fetch "app_api_impl.sql"; then
    need "${C}FUNCTION${S}hive\.is_instance_ready${B}" \
        "install_app.sh's final step runs it as haf_stats_user, and db/sync_status.sql gates on it."
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
