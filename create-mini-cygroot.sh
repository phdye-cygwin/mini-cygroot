#!/usr/bin/env bash
#
# create-mini-cygroot.sh
#
# Generate a comprehensive mini-cygroot skeleton at an arbitrary directory
# on a Windows host running Cygwin 1.7+.  Idempotent: re-running is safe.
#
# After this script completes, replace <instance-root>/bin/cygwin1.dll with
# the variant DLL under test and launch via a non-Cygwin parent process
# (cmd.exe, PowerShell, Windows service) with stdio redirected.
#
# See the companion document for mechanism, launcher rules, and
# verification recipes:
#   https://gist.github.com/phdye/7921d26c0f7b8cb17d308a384a75518c

set -euo pipefail

# -- usage -------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: create-mini-cygroot.sh [options] <instance-root>

    Generate a mini-cygroot skeleton at <instance-root>.

Options:
    -h, --help          Show this usage and exit.
    -v, --verbose       Print each step to stdout.
    -n, --dry-run       Print actions without executing.
        --no-bin        Skip hard-linking /usr/bin into <instance-root>/bin/.
        --no-etc        Skip /etc/{passwd,group,nsswitch.conf} generation.
        --force         Re-populate bin/ even if cygwin1.dll already present.

Exit codes:
    0   Success.
    1   Error (invalid argument, refused target, command failure).

Examples:
    create-mini-cygroot.sh /tmp/test-cygroot
    create-mini-cygroot.sh -v /var/tmp/cyg-variant-a
    create-mini-cygroot.sh --dry-run /tmp/test-cygroot

After it completes:
    cp /path/to/variant/cygwin1.dll <instance-root>/bin/cygwin1.dll
    # then launch <instance-root>/bin/bash.exe from cmd.exe or PowerShell
EOF
}

# -- output discipline -------------------------------------------------------

err()  { printf '%s: error: %s\n' "$prog" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$prog" "$*" >&2; }
log()  { [ "$verbose" = 1 ] && printf '%s\n' "$*"; return 0; }

run() {
    log "+ $*"
    [ "$dry_run" = 1 ] && return 0
    "$@"
}

run_sh() {
    log "+ $1"
    [ "$dry_run" = 1 ] && return 0
    bash -c "$1"
}

# -- argument parsing --------------------------------------------------------

parse_args() {
    verbose=0
    dry_run=0
    no_bin=0
    no_etc=0
    force=0
    inst=

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -v|--verbose) verbose=1; shift ;;
            -n|--dry-run) dry_run=1; shift ;;
            --no-bin)     no_bin=1; shift ;;
            --no-etc)     no_etc=1; shift ;;
            --force)      force=1; shift ;;
            --)           shift; break ;;
            -*)           err "unknown option: $1"; usage >&2; exit 1 ;;
            *)
                if [ -n "$inst" ]; then
                    err "unexpected positional argument: $1"
                    usage >&2; exit 1
                fi
                inst="$1"; shift ;;
        esac
    done

    if [ "$#" -gt 0 ]; then
        if [ -n "$inst" ]; then
            err "unexpected positional argument: $1"
            usage >&2; exit 1
        fi
        inst="$1"
    fi

    if [ -z "$inst" ]; then
        err "missing required argument: <instance-root>"
        usage >&2; exit 1
    fi
}

# -- target validation -------------------------------------------------------

validate_target() {
    # Absolute path, normalised.
    case "$inst" in
        /*) ;;
        *)  err "<instance-root> must be an absolute POSIX path: $inst"; exit 1 ;;
    esac

    # Refuse the host Cygwin root, regardless of how it was named.
    local inst_win host_win
    inst_win=$(cygpath -w "$inst" 2>/dev/null || true)
    host_win=$(cygpath -w / 2>/dev/null || true)

    if [ -z "$inst_win" ] || [ -z "$host_win" ]; then
        err "cygpath unavailable; this script must run inside Cygwin"; exit 1
    fi

    if [ "$inst" = "/" ] || [ "$inst_win" = "$host_win" ]; then
        err "<instance-root> must not be the host Cygwin root ($host_win)"
        exit 1
    fi

    # If the target already contains a cygwin1.dll, ensure it is not the
    # host DLL via hardlink (which we would corrupt on later cp).
    if [ -e "$inst/bin/cygwin1.dll" ] && [ -e /usr/bin/cygwin1.dll ]; then
        local a b
        a=$(stat -c '%d:%i' "$inst/bin/cygwin1.dll" 2>/dev/null || true)
        b=$(stat -c '%d:%i' /usr/bin/cygwin1.dll 2>/dev/null || true)
        if [ -n "$a" ] && [ "$a" = "$b" ]; then
            warn "$inst/bin/cygwin1.dll is hardlinked to host /usr/bin/cygwin1.dll"
            warn "this script will break the hardlink before exit"
        fi
    fi
}

# -- skeleton construction ---------------------------------------------------

make_dirs() {
    local user="${USER:-$(whoami)}"
    log "creating directory layout under $inst"
    run mkdir -p \
        "$inst/bin" \
        "$inst/etc" \
        "$inst/tmp" \
        "$inst/dev" \
        "$inst/proc" \
        "$inst/var/run" \
        "$inst/var/log" \
        "$inst/usr" \
        "$inst/lib" \
        "$inst/home/$user"
}

populate_bin() {
    if [ "$no_bin" = 1 ]; then
        log "skipping bin/ population (--no-bin)"
        return 0
    fi

    if [ ! -d /usr/bin ]; then
        err "/usr/bin not found on host"; exit 1
    fi

    if [ -e "$inst/bin/cygwin1.dll" ] && [ "$force" != 1 ]; then
        log "bin/cygwin1.dll already present; skipping bulk hardlink (use --force to redo)"
    else
        log "hardlinking host /usr/bin/* into $inst/bin/ (errors on multi-hardlinks are benign)"
        # cp -rl fails on individual multi-hardlink files; tolerate.
        run_sh "cp -rl /usr/bin/. \"$inst/bin/\" 2>/dev/null || true"
    fi

    # Break any hardlink so a later cp of the variant DLL cannot
    # corrupt the host cygwin1.dll through a shared inode.
    if [ -e "$inst/bin/cygwin1.dll" ]; then
        local a b
        a=$(stat -c '%d:%i' "$inst/bin/cygwin1.dll" 2>/dev/null || true)
        b=$(stat -c '%d:%i' /usr/bin/cygwin1.dll 2>/dev/null || true)
        if [ -n "$a" ] && [ "$a" = "$b" ]; then
            log "breaking cygwin1.dll hardlink to host"
            run rm -f "$inst/bin/cygwin1.dll"
            run cp /usr/bin/cygwin1.dll "$inst/bin/cygwin1.dll"
        fi
    fi
}

populate_etc() {
    if [ "$no_etc" = 1 ]; then
        log "skipping etc/ population (--no-etc)"
        return 0
    fi

    if ! command -v mkpasswd >/dev/null 2>&1; then
        err "mkpasswd not found; install cygwin's 'cygwin' package or pass --no-etc"
        exit 1
    fi
    if ! command -v mkgroup >/dev/null 2>&1; then
        err "mkgroup not found; install cygwin's 'cygwin' package or pass --no-etc"
        exit 1
    fi

    log "generating $inst/etc/passwd from mkpasswd -c"
    if [ "$dry_run" = 1 ]; then
        log "+ mkpasswd -c > $inst/etc/passwd"
    else
        mkpasswd -c > "$inst/etc/passwd"
    fi

    log "generating $inst/etc/group from mkgroup -c"
    if [ "$dry_run" = 1 ]; then
        log "+ mkgroup -c > $inst/etc/group"
    else
        mkgroup -c > "$inst/etc/group"
    fi

    log "writing $inst/etc/nsswitch.conf (passwd: files, group: files)"
    if [ "$dry_run" = 1 ]; then
        log "+ printf 'passwd: files\\ngroup: files\\n' > $inst/etc/nsswitch.conf"
    else
        printf 'passwd: files\ngroup: files\n' > "$inst/etc/nsswitch.conf"
    fi
}

report() {
    local user="${USER:-$(whoami)}"
    cat <<EOF

mini-cygroot skeleton ready at: $inst

Layout:
    $inst/bin/                 (host /usr/bin hard-linked; cygwin1.dll standalone)
    $inst/etc/passwd           (mkpasswd -c)
    $inst/etc/group            (mkgroup -c)
    $inst/etc/nsswitch.conf    (passwd: files; group: files)
    $inst/{tmp,dev,proc,var,usr,lib,home/$user}/

Next:
    cp /path/to/variant/cygwin1.dll $inst/bin/cygwin1.dll
    # launch from cmd.exe or PowerShell with stdio redirected:
    #   Start-Process "$inst\\bin\\bash.exe" -ArgumentList '-c','mount' \\
    #       -RedirectStandardOutput out.txt -RedirectStandardError err.txt \\
    #       -RedirectStandardInput nul -NoNewWindow -PassThru -Wait
EOF
}

# -- main --------------------------------------------------------------------

main() {
    prog=$(basename "$0")
    parse_args "$@"
    validate_target
    make_dirs
    populate_bin
    populate_etc
    report
}

main "$@"
