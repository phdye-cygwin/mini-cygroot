# Manual construction procedure

For readers who want to build a mini-cygroot by hand, or who want to
adapt the procedure to a build system that doesn't use the companion
scripts. The reference implementation is `create-mini-cygroot.sh` in
the repo root; the quick path is in the README's "Quick start"
section.

Why each directory exists and why these configuration choices are
correct is in [`mechanism.md`](mechanism.md). The launcher rules
that must be honored when entering the variant from PowerShell are
in [`launcher-constraints.md`](launcher-constraints.md).

## 1. Required layout

```
<instance-root>/
├── bin/
│   ├── cygwin1.dll              # the variant DLL; this path is load-bearing
│   ├── <transitive DLLs>        # cygintl-8.dll, cygiconv-2.dll, cygncursesw-10.dll,
│   │                            # cygreadline7.dll, as required by the binaries above
│   ├── bash.exe                 # required for shell-driven harnesses
│   ├── true.exe                 # required if test cases exec /bin/true
│   ├── cygpath.exe              # diagnostic; path conversion
│   ├── mount.exe                # diagnostic; confirms relocatable-root detection
│   └── <other utilities>        # additional utilities as required
├── etc/
│   ├── passwd                   # see §2; optional; eliminates the slow init path
│   ├── group                    # see §2
│   ├── nsswitch.conf            # see §2; pins lookups to files
│   └── fstab                    # optional; default mounts apply when absent
├── tmp/                         # bash emits a warning when /tmp is absent
├── dev/                         # zero-byte placeholder; fhandler_dev virtualizes contents
├── proc/                        # zero-byte placeholder; fhandler_proc virtualizes contents
├── var/                         # /var/run, /var/log used by some utilities
├── usr/                         # parent for default mounts /usr/bin and /usr/lib
├── lib/                         # target of the default /usr/lib mount
└── home/
    └── <USER>/                  # default home from /etc/passwd
```

`<instance-root>` may be any directory on the Windows host. The
single load-bearing path is `<instance-root>/bin/cygwin1.dll`.
Cygwin's relocatable-root logic strips `\cygwin1.dll` and the next
path component (`\bin`) to determine that `<instance-root>` is the
installation root and therefore corresponds to `/`. Other directories
in the tree serve as default-mount targets or as locations probed by
user-space utilities.

## 2. Configuration file contents

### `etc/nsswitch.conf`

Two lines:

```
passwd: files
group: files
```

This configuration pins `getpwuid()` and `getgrgid()` to the local
`passwd` and `group` files. With a `/etc/passwd` populated by
`mkpasswd -c`, the default lookup order (`files db`) locates the
current user at the first lookup step. Specifying `passwd: files`
provides a redundant override. It suppresses the `db` (Windows
account database) fallback that engages when a queried SID is not
present in `/etc/passwd`. On a domain-joined host that fallback
issues an AD/LDAP query and delays DLL initialization by an interval
measured in seconds.

### `etc/passwd` and `etc/group`

Generate from the host Cygwin installation:

```sh
mkpasswd -c > <instance-root>/etc/passwd
mkgroup  -c > <instance-root>/etc/group
```

`mkpasswd -c` produces a single entry for the current user, with the
Windows SID, primary GID, home directory, and login shell. `mkgroup
-c` produces a single entry for the primary group. These two files
satisfy the requirements of `cygwin1.dll`'s init-time `getpwsid()`
call.

A representative entry pair (UID, GID, and SID values vary per host):

```
# passwd  (non-domain host; mkpasswd -c emits U-DOMAIN\... on a domain-joined host)
your_username:*:11111:11111:U-MACHINE\your_username,S-1-5-21-…-1001:/home/your_username:/bin/bash
```

```
# group
None:*:11111:
```

### `etc/fstab` (optional)

Do not create this file unless non-default mounts are required. In
its absence, Cygwin synthesizes the following defaults:

```
<instance-root>/bin   /usr/bin   ntfs   binary,auto         0 0
<instance-root>/lib   /usr/lib   ntfs   binary,auto         0 0
<instance-root>       /          ntfs   binary,auto         0 0
none                  /cygdrive  cygdrive   binary,posix=0,user,noumount,auto   0 0
```

These defaults match standard Cygwin behavior.

## 3. Assembly procedure (six commands)

`INST` must reference a directory outside any existing Cygwin
installation. It must not equal `/`, `$(cygpath /)`, or any directory
containing a host `cygwin1.dll`. The `cp` step would otherwise
overwrite a live host installation. The shell guard at the head of
the procedure enforces these conditions for the documented failure
modes; `create-mini-cygroot.sh` in this repo applies the same guard
plus the host-DLL hardlink-break safety step described in
[`limitations.md`](limitations.md).

```sh
INST=/tmp/test-cygroot                              # any path on the same NTFS volume
USER=$(whoami)

# Refuse to proceed if INST references a Cygwin root
[ "$INST" != "/" ] && \
[ ! -f "$INST/bin/cygwin1.dll.host" ] && \
[ "$(cygpath -w "$INST")" != "$(cygpath -w /)" ] || \
    { echo "INST must not be the host Cygwin root"; exit 1; }

mkdir -p $INST/{bin,etc,tmp,dev,proc,var,usr,lib,home/$USER}

# Hard-link the host /usr/bin tree into the variant bin/.
# Errors on multi-hardlinked llvm-* binaries are non-fatal.
cp -rl /usr/bin/. $INST/bin/ 2>/dev/null || true

# Install the variant cygwin1.dll under test:
cp /path/to/variant/cygwin1.dll $INST/bin/cygwin1.dll

# Eliminate the Windows-account-lookup path:
mkpasswd -c >  $INST/etc/passwd
mkgroup  -c >  $INST/etc/group
printf 'passwd: files\ngroup: files\n' > $INST/etc/nsswitch.conf
```

## 4. Launching the variant

Launch the variant from a non-Cygwin parent process. Acceptable
parents include `cmd.exe`, PowerShell, and native Windows services.
Redirect standard input, output, and error. The command to run inside
the variant must be supplied via redirected stdin rather than
`-ArgumentList '-c', '<command>'`; see
[`launcher-constraints.md`](launcher-constraints.md) for the
rationale.

```powershell
# Write commands to a script file, then feed it to variant bash via stdin.
@'
PATH=/usr/bin:/bin
mount
cygpath -w /
'@ | Set-Content -Encoding ascii cmd.sh

Start-Process "$INST\bin\bash.exe" `
    -RedirectStandardOutput out.txt `
    -RedirectStandardError  err.txt `
    -RedirectStandardInput  cmd.sh `
    -NoNewWindow -PassThru -Wait
Get-Content out.txt
```

The first line of expected output is `<instance-root>/bin on /usr/bin
type ntfs (binary,auto)`. This line confirms three conditions: the
variant DLL is loaded, the relocatable-root detection completed, and
the variant mount table is active.

The `PATH=/usr/bin:/bin` reset at the top of the script is required,
not optional; see [`launcher-constraints.md`](launcher-constraints.md)
for the rationale.
