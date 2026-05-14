#!/usr/bin/env bash
#
# launch-mini-cygroot.sh
#
# Launch a command inside a mini-cygroot via PowerShell, ensuring the
# variant cygwin1.dll loads under a non-Cygwin parent process.
#
# The variant entry chain is:
#     host bash (this script)
#       -> powershell.exe (non-Cygwin parent of the variant)
#         -> <instance-root>/bin/bash.exe (variant; loads variant cygwin1.dll)
#           -> the user command
#
# Stdio is redirected to disk to avoid the PowerShell -NoNewWindow stall
# documented in the mini-cygroot gist.

set -euo pipefail

# -- usage -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: launch-mini-cygroot.sh [options] <instance-root> [-- command...]

    Run a command inside <instance-root> by launching the variant
    bash.exe through PowerShell with redirected stdio.

    If no command is given, a default diagnostic runs:
        mount; cygpath -w /; cygpath -w /bin/true

Options:
    -h, --help          Show this usage and exit.
    -v, --verbose       Echo the generated PowerShell before running it.
    -i, --interactive   Open a visible console window running variant
                        bash --login.  No stdio capture; this script
                        returns once the window is dismissed.
    -t, --timeout SECS  Wait at most SECS for the variant to exit
                        (default 120).  On timeout the process is killed
                        and the launcher exits 124.
    -o, --stdout FILE   Capture variant stdout to FILE (default: a temp
                        file whose contents are echoed before exit).
    -e, --stderr FILE   Capture variant stderr to FILE (default: a temp
                        file whose contents are echoed before exit).
    --keep-temps        Do not delete captured stdio temp files on exit.
    --                  End of options.  The remainder is joined with
                        single spaces and passed to variant bash -c.

Exit codes:
    The variant's exit code on a successful launch.
    124 if the variant exceeded --timeout.
    1   on launcher error (invalid arguments, missing files, etc).

Examples:
    launch-mini-cygroot.sh /tmp/cyg-test
    launch-mini-cygroot.sh -v /tmp/cyg-test -- 'cygpath -w /bin/bash'
    launch-mini-cygroot.sh -i /tmp/cyg-test
    launch-mini-cygroot.sh -t 30 --keep-temps /tmp/cyg-test -- 'sleep 5; echo ok'
EOF
}

# -- output discipline -------------------------------------------------------

err()  { printf '%s: error: %s\n' "$prog" "$*" >&2; }
log()  { [ "$verbose" = 1 ] && printf '%s\n' "$*"; return 0; }

# -- argument parsing --------------------------------------------------------

parse_args() {
    verbose=0
    interactive=0
    timeout=120
    stdout_file=
    stderr_file=
    keep_temps=0
    inst=
    cmd_args=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)        usage; exit 0 ;;
            -v|--verbose)     verbose=1; shift ;;
            -i|--interactive) interactive=1; shift ;;
            -t|--timeout)
                [ "$#" -ge 2 ] || { err "--timeout requires a value"; exit 1; }
                case "$2" in (*[!0-9]*|'') err "--timeout must be a positive integer"; exit 1 ;; esac
                timeout="$2"; shift 2 ;;
            -o|--stdout)
                [ "$#" -ge 2 ] || { err "--stdout requires a value"; exit 1; }
                stdout_file="$2"; shift 2 ;;
            -e|--stderr)
                [ "$#" -ge 2 ] || { err "--stderr requires a value"; exit 1; }
                stderr_file="$2"; shift 2 ;;
            --keep-temps)     keep_temps=1; shift ;;
            --)               shift; cmd_args=("$@"); break ;;
            -*)               err "unknown option: $1"; usage >&2; exit 1 ;;
            *)
                if [ -n "$inst" ]; then
                    err "unexpected positional argument: $1"
                    usage >&2; exit 1
                fi
                inst="$1"; shift ;;
        esac
    done

    if [ -z "$inst" ]; then
        err "missing required argument: <instance-root>"
        usage >&2; exit 1
    fi
}

# -- target validation -------------------------------------------------------

validate_target() {
    if [ ! -d "$inst" ]; then
        err "<instance-root> not a directory: $inst"; exit 1
    fi
    if [ ! -e "$inst/bin/cygwin1.dll" ]; then
        err "missing $inst/bin/cygwin1.dll"; exit 1
    fi
    if [ ! -x "$inst/bin/bash.exe" ]; then
        err "missing or non-executable $inst/bin/bash.exe"; exit 1
    fi
    if ! command -v powershell.exe >/dev/null 2>&1; then
        err "powershell.exe not on PATH; this script must run on Windows"
        exit 1
    fi
}

# -- temp-file plumbing ------------------------------------------------------

cleanup() {
    if [ "$keep_temps" = 1 ]; then return 0; fi
    [ -n "${ps1_tmp:-}" ]    && rm -f "$ps1_tmp"    2>/dev/null || true
    [ -n "${stdin_file:-}" ] && rm -f "$stdin_file" 2>/dev/null || true
    [ "${auto_stdout:-0}" = 1 ] && [ -n "$stdout_file" ] && rm -f "$stdout_file" 2>/dev/null || true
    [ "${auto_stderr:-0}" = 1 ] && [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null || true
}

ensure_temps() {
    auto_stdout=0
    auto_stderr=0
    if [ -z "$stdout_file" ]; then
        stdout_file=$(mktemp -t mini-cygroot-out.XXXXXX)
        auto_stdout=1
    fi
    if [ -z "$stderr_file" ]; then
        stderr_file=$(mktemp -t mini-cygroot-err.XXXXXX)
        auto_stderr=1
    fi
    # The variant command is piped into bash via stdin redirection, not
    # passed as `bash -c <string>`.  Reason: Start-Process -ArgumentList
    # flattens the array with naive space-joining (no quoting), so a
    # multi-word -c argument gets re-split at spaces by bash's CRT-style
    # argv parsing.  Routing through stdin avoids the boundary entirely.
    stdin_file=$(mktemp -t mini-cygroot-in.XXXXXX)
    trap cleanup EXIT
}

# -- launch ------------------------------------------------------------------

# Build a single-quoted PowerShell literal from an arbitrary bash string.
# PowerShell single-quoted strings escape ' as ''.
ps1_quote() {
    local s=$1
    s=${s//\'/\'\'}
    printf "'%s'" "$s"
}

launch_redirected() {
    local cmd="$1"
    # Write the command(s) to the stdin file.  Bash reads stdin and exits
    # at EOF, which gives us a clean way to pass a multi-line script
    # without any Windows-side quoting.
    #
    # PATH is reset to variant-resident paths before user commands run.
    # The variant inherits the host environment via CreateProcess, and the
    # host PATH contains entries like /cygdrive/c/-/cygwin/root/bin that
    # point at HOST Cygwin binaries.  Variant bash performing a PATH lookup
    # would find host binaries first; exec'ing them is a cross-DLL exec
    # which Cygwin's shared-region hand-off cannot complete (failures
    # surface as exit 127 / "command not found").  /usr/bin and /bin
    # resolve via the variant's own mount table to <instance-root>/bin/.
    {
        printf 'PATH=/usr/bin:/bin\n'
        printf '%s\n' "$cmd"
    } > "$stdin_file"

    local bash_win out_win err_win in_win
    bash_win=$(cygpath -w "$inst/bin/bash.exe")
    out_win=$(cygpath -w "$stdout_file")
    err_win=$(cygpath -w "$stderr_file")
    in_win=$(cygpath  -w "$stdin_file")

    local q_bash q_out q_err q_in
    q_bash=$(ps1_quote "$bash_win")
    q_out=$(ps1_quote "$out_win")
    q_err=$(ps1_quote "$err_win")
    q_in=$(ps1_quote  "$in_win")

    ps1_tmp=$(mktemp -t mini-cygroot-ps1.XXXXXX).ps1
    cat >"$ps1_tmp" <<EOF
\$ErrorActionPreference = 'Stop'
\$p = Start-Process -FilePath $q_bash \`
    -RedirectStandardOutput $q_out \`
    -RedirectStandardError  $q_err \`
    -RedirectStandardInput  $q_in \`
    -NoNewWindow -PassThru
# Required: without EnableRaisingEvents, \$p.ExitCode is empty in a
# -File script context after WaitForExit, even though .HasExited is true.
# This is a known interaction between Start-Process -PassThru and
# powershell.exe -File; setting the flag ensures the exit-code wiring
# is in place before the child exits.
\$p.EnableRaisingEvents = \$true
\$exited = \$p.WaitForExit($((timeout * 1000)))
if (-not \$exited) {
    try { \$p.Kill() } catch {}
    exit 124
}
exit \$p.ExitCode
EOF

    log "+ powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(cygpath -w "$ps1_tmp")"
    log "  variant cmd: $cmd"
    log "  stdout: $stdout_file"
    log "  stderr: $stderr_file"

    local rc=0
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$ps1_tmp")" || rc=$?

    if [ -s "$stdout_file" ]; then cat "$stdout_file"; fi
    if [ -s "$stderr_file" ]; then cat "$stderr_file" >&2; fi

    return "$rc"
}

launch_interactive() {
    local bash_win
    bash_win=$(cygpath -w "$inst/bin/bash.exe")

    local q_bash
    q_bash=$(ps1_quote "$bash_win")

    ps1_tmp=$(mktemp -t mini-cygroot-ps1.XXXXXX).ps1
    cat >"$ps1_tmp" <<EOF
\$ErrorActionPreference = 'Stop'
\$p = Start-Process -FilePath $q_bash -ArgumentList @('--login','-i') -PassThru
\$p.WaitForExit()
exit \$p.ExitCode
EOF

    log "+ powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(cygpath -w "$ps1_tmp")"
    log "  launching interactive variant bash --login in a new window"

    local rc=0
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$ps1_tmp")" || rc=$?
    return "$rc"
}

build_command() {
    if [ "${#cmd_args[@]}" -eq 0 ]; then
        printf 'mount; cygpath -w /; cygpath -w /bin/true'
    else
        printf '%s' "${cmd_args[*]}"
    fi
}

# -- main --------------------------------------------------------------------

main() {
    prog=$(basename "$0")
    parse_args "$@"
    validate_target

    if [ "$interactive" = 1 ]; then
        ps1_tmp=
        trap cleanup EXIT
        launch_interactive
        exit "$?"
    fi

    ensure_temps
    local cmd
    cmd=$(build_command)
    launch_redirected "$cmd"
    exit "$?"
}

main "$@"
