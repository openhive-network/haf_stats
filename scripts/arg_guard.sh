#!/bin/bash
# Connection-flag value validation, shared by every script that accepts one.
#
# Deliberately side-effect free -- no defaults, no exports, no `set` -- because the
# scripts that need it most do NOT source common.sh, and inheriting its POSTGRES_*
# defaults would change what they connect to.
#
# The hazard: libpq does not treat an empty flag value as absent and does not error on
# it. It substitutes its own default. Measured on PostgreSQL 17:
#
#     pg_isready -h ""   ->  :5432 - accepting connections      (the LOCAL SOCKET)
#     pg_isready -p ""   ->  127.0.0.1: - accepting connections (the default port)
#     pg_isready -U ""   ->  accepting connections              (the OS user)
#
# So `uninstall_app --force --host=${HAF_HOST}` with HAF_HOST unset connects somewhere
# else entirely and drops the schemas there, and --force skips the
# type-the-database-name gate. The same shape reaches tests/regression/run_test.sh,
# which CREATEs a schema on whatever it lands on.
#
# Note this is a FLAG guard only. The environment path is already safe in shell:
# common.sh uses `: "${POSTGRES_HOST:=haf}"`, and the COLON form substitutes on unset
# OR null, so POSTGRES_HOST="" becomes haf. (haf_fyp's Python services use
# os.environ.get(k, default), which does NOT -- tracked separately.)

_arg_guard_msg() {
    # Use the caller's logger when it has one, so messages keep their prefix.
    if command -v log >/dev/null 2>&1; then
        log "$@"
    else
        printf '%s\n' "$*" >&2
    fi
}

require_flag_value() {
    local arg="$1"
    local flag="${arg%%=*}"
    local value="${arg#*=}"

    case "${value}" in
        "")
            _arg_guard_msg "ERROR: ${flag}= was given an empty value."
            _arg_guard_msg "       An empty value is NOT ignored -- libpq substitutes its own"
            _arg_guard_msg "       default: the local socket for --host, 5432 for --port, the"
            _arg_guard_msg "       OS user for --user. This is almost always an unset variable"
            _arg_guard_msg "       in a module file or runbook; fix the variable rather than"
            _arg_guard_msg "       removing the flag."
            exit 2
            ;;
    esac

    # A newline splits one value into what reads as two settings, and every message
    # that echoes it prints only the first line -- so the log names one target while
    # libpq is handed another. Refused outright rather than relying on resolution
    # failing.
    case "${value}" in
        *"
"*)
            _arg_guard_msg "ERROR: ${flag}= was given a value containing a newline."
            _arg_guard_msg "       Refused: messages that echo it would show only its first line,"
            _arg_guard_msg "       so the log would name a different target than the connection."
            exit 2
            ;;
    esac

    case "${value}" in
        *[![:space:]]*)
            : # at least one non-whitespace character -- fine
            ;;
        *)
            _arg_guard_msg "ERROR: ${flag}= was given a whitespace-only value."
            _arg_guard_msg "       Refused for the same reason as an empty value: it cannot be"
            _arg_guard_msg "       what the caller meant, and --user= accepts it silently."
            exit 2
            ;;
    esac
}
