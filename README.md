# Mini-Cygroot: Procedure for Side-by-Side Cygwin Installations Used in Testing Alternate `cygwin1.dll` Builds

Verified-Against: Cygwin 3.6.7 (`upstream-main/winsup/cygwin/`).
Test-Platform: Windows 11.

A mini-cygroot is a self-contained Cygwin installation located at an arbitrary directory on a Windows host. It operates independently of the system Cygwin installation. Use cases include A/B testing of alternate `cygwin1.dll` builds, benchmark variant execution, and regression bisection.

Part 1 contains the complete construction procedure. Part 2 contains the supporting analysis: mechanism, constraints, verification, limitations, and source references.

---

# Part 1 — Construction procedure

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

`<instance-root>` may be any directory on the Windows host. The single load-bearing path is `<instance-root>/bin/cygwin1.dll`. Cygwin's relocatable-root logic strips `\cygwin1.dll` and the next path component (`\bin`) to determine that `<instance-root>` is the installation root and therefore corresponds to `/`. Other directories in the tree serve as default-mount targets or as locations probed by user-space utilities.

## 2. Configuration file contents

### `etc/nsswitch.conf`

Two lines:

```
passwd: files
group: files
```

This configuration pins `getpwuid()` and `getgrgid()` to the local `passwd` and `group` files. With a `/etc/passwd` populated by `mkpasswd -c`, the default lookup order (`files db`) locates the current user at the first lookup step. Specifying `passwd: files` provides a redundant override. It suppresses the `db` (Windows account database) fallback that engages when a queried SID is not present in `/etc/passwd`. On a domain-joined host that fallback issues an AD/LDAP query and delays DLL initialization by an interval measured in seconds.

### `etc/passwd` and `etc/group`

Generate from the host Cygwin installation:

```sh
mkpasswd -c > <instance-root>/etc/passwd
mkgroup  -c > <instance-root>/etc/group
```

`mkpasswd -c` produces a single entry for the current user, with the Windows SID, primary GID, home directory, and login shell. `mkgroup -c` produces a single entry for the primary group. These two files satisfy the requirements of `cygwin1.dll`'s init-time `getpwsid()` call.

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

Do not create this file unless non-default mounts are required. In its absence, Cygwin synthesizes the following defaults:

```
<instance-root>/bin   /usr/bin   ntfs   binary,auto         0 0
<instance-root>/lib   /usr/lib   ntfs   binary,auto         0 0
<instance-root>       /          ntfs   binary,auto         0 0
none                  /cygdrive  cygdrive   binary,posix=0,user,noumount,auto   0 0
```

These defaults match standard Cygwin behavior.

### Assembly procedure (six commands)

`INST` must reference a directory outside any existing Cygwin installation. It must not equal `/`, `$(cygpath /)`, or any directory containing a host `cygwin1.dll`. The `cp` step would otherwise overwrite a live host installation. The shell guard at the head of the script enforces these conditions for the documented failure modes.

A reference implementation of this procedure, with idempotent semantics, `--dry-run` and `--verbose` modes, and the host-DLL hardlink-break safety step described in §9, is published as a companion gist: `https://gist.github.com/phdye/a9fddc5a9a52d125c060d434e0ec9680` (`create-mini-cygroot.sh`).

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

Launch the variant from a non-Cygwin parent process. Acceptable parents include `cmd.exe`, PowerShell, and native Windows services. Redirect standard input, output, and error. The command to run inside the variant must be supplied via redirected stdin rather than `-ArgumentList '-c', '<command>'`; see §6 for the rationale.

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

The first line of expected output is `<instance-root>/bin on /usr/bin type ntfs (binary,auto)`. This line confirms three conditions: the variant DLL is loaded, the relocatable-root detection completed, and the variant mount table is active.

The `PATH=/usr/bin:/bin` reset at the top of the script is required, not optional; see §6 for the rationale.

---

# Part 2 — Analysis

## 3. Mechanism

Cygwin 1.7 and later releases are relocatable. `cygwin1.dll` determines its own installation root at process initialization by inspecting its own loaded module path.

The implementation is in `winsup/cygwin/mm/cygheap.cc:166–230` (`init_cygheap::init_installation_root`):

1. `GetModuleFileNameW(cygwin_hmodule, …)` returns the full Win32 path of the loaded `cygwin1.dll`.
2. The trailing `\cygwin1.dll` is stripped.
3. The next path component (conventionally `\bin`) is stripped.
4. The remaining prefix is treated as `installation_root`.

A `cygwin1.dll` loaded from `C:\path\to\instance\bin\cygwin1.dll` therefore causes the process to treat `C:\path\to\instance` as `/`. POSIX paths within that process resolve against this root via the variant DLL's mount table.

### Shared-region isolation is automatic

From `cygheap.cc:217–219`:

```c
RtlInt64ToHexUnicodeString(hash_path_name(0, installation_root_buf),
                           &installation_key, FALSE);
```

The `installation_key` is a hash of the DLL's full path. Cygwin incorporates this key into the NT object names of its shared regions, including `SH_CYGWIN_SHARED` and `SH_USER_SHARED`. Distinct `installation_root` paths produce distinct keys. Distinct keys produce distinct NT object names. Distinct NT object names produce independent shared regions. The result is independent POSIX PID spaces, independent mount tables, and independent file-descriptor tables across installations.

Multiple mini-cygroots may operate concurrently on a single host without cross-installation interference and without disturbing the system Cygwin installation.

### Registry entry (informational)

`init_installation_root` writes `Software\Cygwin\Installations\<key>` to HKLM with HKCU as fallback. The entry maps `<key>` to the installation root path. Write failure is non-fatal. The entry is read by Cygwin Setup and by `cygcheck` for installation enumeration. The running DLL does not depend on the entry's presence.

---

## 4. Windows loader behavior

When an executable that imports `cygwin1.dll` is launched, the Windows loader resolves the import using the following search order:

1. The directory of the executable. This is the mechanism the procedure relies on.
2. System32, Known DLLs, current directory, PATH.

`cygwin1.dll` is not registered as a Known DLL. The first search rule therefore governs DLL selection. An executable launched from `<instance-root>/bin/foo.exe` loads `<instance-root>/bin/cygwin1.dll` when that file is present.

`PATH` does not select the DLL. `PATH` affects `execvp()` name resolution within a running process. Setting `PATH=<instance-root>/bin:$PATH` is acceptable as a redundant control over `execvp()` of bare names within a variant process. It is not the mechanism that selects the DLL at load time.

---

## 5. Function of recommended directories

The directories listed in §1 (`tmp/`, `dev/`, `proc/`, `var/`, `usr/`, `lib/`, `home/<USER>/`) are not required by `cygwin1.dll` initialization. They are required by user-space utilities that probe them.

`mountinfo.init` (`mm/shared.cc:201, 209`) reads `/etc/fstab` and `/etc/fstab.d/$USER` at initialization. Both files are optional. When absent, Cygwin synthesizes the `/usr/bin`, `/usr/lib`, and `/` mounts shown in §2. The contents of `/proc/*` and `/dev/*` are virtualized by `fhandler_proc` and `fhandler_dev`. Path resolution requires that the directory nodes exist. The standard Cygwin installation satisfies this requirement with zero-byte placeholder directories.

The initialization-time user lookup requires explicit consideration. `user_info::initialize` (`mm/shared.cc:191`) calls `internal_getpwsid(sid)` (`passwd.cc:85`) during DLL initialization, before application code executes. The lookup order is:

1. Cygserver cache. Not enabled by default.
2. `/etc/passwd`. The `nss_pwd_files` source is enabled by default.
3. Windows account database (`add_user_from_windows`). This call issues LSA queries and, on domain-joined hosts, an AD/LDAP query. This is the high-latency path observed when `/etc/passwd` does not contain an entry for the current SID.

Populating the three files described in §2 short-circuits the lookup at the file-cache step.

---

## 6. Launcher constraints

### The launcher process must not be a Cygwin process

A Cygwin parent that performs `exec` into a variant binary causes shared-region state to be mixed across DLL builds. Cygwin's POSIX-exec hand-off uses a shared section to transfer file descriptors, signal state, and POSIX identity. Cross-DLL `exec` is not supported.

The variant must be entered from a non-Cygwin parent. Acceptable parents include `cmd.exe` and its wrappers (batch files, scheduled tasks), PowerShell (via `Start-Process` or the call operator `&`), and native Windows services or supervisors.

Within the variant process tree, `fork` and `exec` operate normally. The constraint applies only to the entry into the variant environment.

### Pipe-based stdio is required for the entry process (open issue)

The following invocation reliably stalls in `cygwin1.dll` initialization for periods exceeding sixty seconds, with no observed completion on the test platform:

```powershell
Start-Process <variant>\bin\true.exe -NoNewWindow -PassThru
```

The same `true.exe` completes within milliseconds when launched with redirected standard streams:

```powershell
Start-Process <variant>\bin\true.exe `
    -RedirectStandardOutput out.txt `
    -RedirectStandardError  err.txt `
    -RedirectStandardInput  nul `
    -NoNewWindow -PassThru
```

The proximate cause has not been isolated. Candidate factors include stdio and console-handle setup in the variant DLL on a process that has inherited the parent console without TTY emulation, and the `CreateFileW(GENERIC_READ)` re-open of the DLL in `init_installation_root` (`cygheap.cc:174`) under antivirus scan latency for binaries in non-standard paths.

The operational recommendation is to redirect standard input, output, and error when launching the entry process from PowerShell. Equivalent alternatives are to launch via `cmd.exe /c <variant>\bin\foo.exe …` from a hidden window, or to use a bridge process that pipes the standard streams.

### Sanitize `PATH` before the variant runs commands

The variant inherits the parent's environment, including `PATH`. On a Cygwin host the inherited `PATH` contains entries such as `/cygdrive/c/-/cygwin/root/bin`, which the variant's cygdrive mount resolves to the **host** Cygwin `bin/` directory. PATH-based command lookups inside variant bash therefore find host binaries first. Executing those host binaries is a cross-DLL exec: the host binary loads the host `cygwin1.dll`, which has a different `installation_key` from the variant DLL and therefore a different shared-memory region. Cygwin's exec hand-off cannot complete across this boundary. The observed failure mode is exit code 127, surfaced by variant bash as "command not found."

Reset `PATH` to variant-resident entries before any user command runs:

```bash
PATH=/usr/bin:/bin
```

These two paths resolve via the variant's mount table to `<instance-root>/bin/`, keeping every PATH-based lookup inside the variant cygroot. Full-path executions (`/bin/true`) bypass PATH and are unaffected; the constraint applies only to bare-name invocations.

### Pass commands via stdin, not via `-ArgumentList '-c', '<command>'`

PowerShell's `Start-Process -ArgumentList @('-c', '<command-string>')` flattens the array into a single command line with naive space-joining. The multi-word command-string is not quoted. Bash's CRT-style argv parser then re-splits the string at spaces. The first token becomes the script body for `-c`; the remaining tokens become positional parameters (`$0`, `$1`, …). Observed failure mode: only the first whitespace-delimited word of the intended command executes.

Pass the command to variant bash through redirected stdin instead. Bash with no `-c` reads its script from stdin until EOF:

```powershell
@'
PATH=/usr/bin:/bin
<command-line-1>
<command-line-2>
'@ | Set-Content -Encoding ascii cmd.sh

Start-Process "$INST\bin\bash.exe" `
    -RedirectStandardInput cmd.sh `
    -RedirectStandardOutput out.txt `
    -RedirectStandardError  err.txt `
    -NoNewWindow -PassThru -Wait
```

The stdin-file path is a normal Windows file path. There is no Windows-side command-line construction; no quoting is required.

### Capture the variant's exit code reliably

When a launcher uses `Start-Process -PassThru` and enforces a timeout by calling `WaitForExit($timeoutMs)` (in preference to the parameter `-Wait`, which does not support a timeout), the returned process object's `.ExitCode` property is empty in `powershell.exe -File` script context after the process exits, even though `.HasExited` reports `True`. The observed consequence is that `exit $p.ExitCode` terminates the launcher with code 0 regardless of the variant's actual exit. Non-zero exits from the variant are silently lost.

The fix is to set `EnableRaisingEvents` on the process object before calling `WaitForExit`:

```powershell
$p = Start-Process ... -PassThru
$p.EnableRaisingEvents = $true
$exited = $p.WaitForExit($timeoutMs)
if (-not $exited) { $p.Kill(); exit 124 }
exit $p.ExitCode
```

Setting this flag wires up .NET's internal exit-code capture path in `System.Diagnostics.Process`. Without it, the property accessor returns the default value when read after `WaitForExit`.

The parameter `-Wait` on `Start-Process` is an alternative that also populates `.ExitCode` reliably, but it does not accept a timeout argument.

### Reference implementation

A reference launcher, callable from a host Cygwin bash and producing the variant process under a non-Cygwin parent with redirected stdio, sanitized `PATH`, stdin-based command delivery, and reliable exit-code propagation, is published as a companion gist: `https://gist.github.com/phdye/691e93c4db4083b8ed7057ee27246091` (`launch-mini-cygroot.sh`).

---

## 7. Build-time and run-time identity of `cygwin1.dll`

The variant DLL must present the same ABI as the pre-built binaries co-located with it. Cygwin's shared structures (`shared_info`, `user_info`, `cygheap`) include `CURR_*_MAGIC` version words (`mm/shared.cc:293, 211`). A variant DLL with a structure layout that differs from the layout expected by the user-space binaries will fail the magic-number check in `multiple_cygwin_problem` and abort.

Performance and bug-fix patches that do not alter shared structures preserve the magic and the ABI. Host-built `bash.exe` and `true.exe` operate correctly with such variant DLLs. Patches that modify shared-region layout, syscall signatures, or `cygwin_version_info` require rebuilt user-space binaries. Variant installations that combine modified DLLs with unmodified user-space binaries must not be permitted.

A pre-flight check is straightforward: a launcher binary built against the variant headers, executed inside the variant cygroot, that returns success when `cygwin_internal(CW_GET_CYGWIN_VERSION_INFO, …)` reports the expected build.

---

## 8. Verification

Three verification experiments were performed against `/tmp/test-cygroot` on Windows 11 with Cygwin 3.6.7. The outputs below are reproduced verbatim.

### Experiment 1: Relocatable root detection

A variant binary that prints mount table information was launched.

```
=== mount ===
C:/-/cygwin/root/tmp/test-cygroot/bin on /usr/bin type ntfs (binary,auto)
C:/-/cygwin/root/tmp/test-cygroot/lib on /usr/lib type ntfs (binary,auto)
C:/-/cygwin/root/tmp/test-cygroot on / type ntfs (binary,auto)
C: on /cygdrive/c type ntfs (binary,posix=0,user,noumount,auto)
...

=== cygpath -w / ===
C:\-\cygwin\root\tmp\test-cygroot

=== cygpath -w /bin/true ===
C:\-\cygwin\root\tmp\test-cygroot\bin\true.exe
```

`mount` reports `<instance-root>` mounted on `/`. `cygpath -w /` returns `<instance-root>`. `cygpath -w /bin/true` returns the variant `true.exe`. The variant mount table is in effect.

### Experiment 2: Variant DLL load verification

The variant `true.exe` was launched and its loaded modules enumerated from a non-Cygwin tool:

```powershell
$p = Start-Process '<instance-root>\bin\true.exe' -NoNewWindow -PassThru
Start-Sleep -Milliseconds 1500
foreach ($m in (Get-Process -Id $p.Id).Modules) {
    if ($m.ModuleName -match '(?i)cyg') { $m.FileName }
}
$p.Kill()
```

Output:

```
C:\-\cygwin\root\tmp\test-cygroot\bin\cygwin1.dll
C:\-\cygwin\root\tmp\test-cygroot\bin\cygintl-8.dll
C:\-\cygwin\root\tmp\test-cygroot\bin\cygiconv-2.dll
```

All Cygwin DLLs mapped into the variant process are variant copies. No DLLs from the host installation are loaded. The process stalls in initialization under `-NoNewWindow` per §6; however, the modules are mapped before the stall, so a short sleep is sufficient for the enumeration.

### Experiment 3: Shared-region isolation

Two independent verifications.

3a. Distinct installation keys. Cygwin records one registry entry per installation root, keyed by the hash of the root path. A query against `HKCU:\Software\Cygwin\Installations` after launching both host and variant returned:

```
key=b9441769d2745a4a   root=\??\C:\-\cygwin\root                       # host
key=813a12c15ca103a5   root=\??\C:\-\cygwin\root\tmp\test-cygroot      # variant
```

Two distinct 64-bit hashes for two distinct paths. Cygwin uses these hashes in the NT object names of its shared regions; therefore the shared regions are distinct by construction.

3b. Distinct POSIX PID spaces. The `ps -ef` command was executed from inside the variant and from inside the host concurrently:

```
# Inside variant:
     UID     PID    PPID    COMMAND
  user      637       1    /usr/bin/true.exe
  user      638       1    /usr/bin/python3.12 run_agent.py
  user      646     638    /bin/bash -l -c …
  user      647     646    ps -ef
  user      648     646    head -20
# Total: 5 processes; PID range near 637; init is PID 1.

# Inside host (same time):
# Total: 82 processes; PID range in the millions (3845824, 769934, …).
```

Each Cygwin installation maintains an independent POSIX PID counter in its own shared region. The variant enumerates only variant processes. The host enumerates only host processes. The two PID spaces do not interact.

---

## 9. Limitations

The mini-cygroot is identified by its path, not by its contents. The install_key value is `hash_path_name(installation_root)`. Moving the directory changes the key, which orphans the per-install shared region and invalidates references stored under the prior path, including the `Software\Cygwin\Installations\<key>` registry entry and any paths embedded in `/etc/passwd` home fields or shell startup scripts. The directory must therefore be treated as immutable once populated, or the installation must be rebuilt after a move.

A single `cygwin1.dll` file cannot be shared between two cygroots via hardlink. The Windows loader's `GetModuleFileNameW` returns the path used to map the module. Each hardlinked path therefore constitutes a separate installation with a separate install_key.

Cygwin versions prior to 1.7 are not relocatable. This procedure applies to versions 1.7 and later (1.7 released 2010-12). Prior versions determined the installation root from the registry, not from the loaded DLL path.

The same-volume hardlink technique (`cp -rl`) requires an NTFS-to-NTFS copy within a single volume. Cross-volume installation and installation on FAT filesystems require a recursive copy (`cp -r`). Disk usage in those configurations scales with the size of the `bin/` directory.

---

## 10. Removal

A mini-cygroot leaves no persistent state that requires manual cleanup, with the exceptions documented below:

- The `HKLM` or `HKCU` `Software\Cygwin\Installations\<key>` registry entry persists across reboots. The entry is benign and is self-overwriting on the next initialization.
- NT shared-region objects are session-scoped and are released when the last process in the variant cygroot exits.
- No filesystem mount, Windows service, or kernel driver is installed.

To remove the installation, execute `rm -rf <instance-root>` after all processes within the variant have exited. While any process holds the variant `cygwin1.dll`, the loader prevents unlink and the operation fails.

---

## 11. Source references

Line numbers reference `upstream-main/winsup/cygwin/` of the newlib-cygwin tree (Cygwin 3.6.7 source).

| Concern | File | Function |
|---|---|---|
| Entry to DLL init | `dcrt0.cc:714` | `dll_crt0_0` |
| Cygheap setup | `mm/cygheap.cc:308` | `setup_cygheap` |
| Installation root from DLL path | `mm/cygheap.cc:162–263` | `init_cygheap::init_installation_root` |
| Installation key (hash of DLL path) | `mm/cygheap.cc:217–219` | inside `init_installation_root` |
| Shared region creation | `mm/shared.cc:278` | `shared_info::create` |
| Per-user shared region | `mm/shared.cc:191, 221` | `user_info::initialize`, `user_info::create` |
| Mount table init (call sites) | `mm/shared.cc:201, 209` | `mountinfo.init(false)` then `(true)` inside `user_info::initialize` |
| Mount table init (implementation) | `mount.cc:569` | `mount_info::init` |
| Token-based user init (fast path) | `uinfo.cc:39` | `cygheap_user::init` |
| SID to passwd lookup (slow path) | `passwd.cc:85` | `internal_getpwsid` |
| Windows account lookup | `uinfo.cc:1942` | `pwdgrp::fetch_account_from_windows` |

---

## 12. Summary

| Requirement | Rationale | Reference |
|---|---|---|
| `<instance-root>/bin/cygwin1.dll` | Relocatable-root mechanism strips `\cygwin1.dll` and the next path component (`\bin`) | `cygheap.cc:166, 221–230` |
| Co-located transitive DLLs (`cygintl-8`, …) | Windows loader exe-directory search rule | Windows DLL search order |
| `<instance-root>/{tmp,dev,proc,var,usr,lib,home/<USER>}` | Prevent runtime warnings; ensure standard paths resolve | empirical |
| Non-Cygwin parent process for entry | Cross-DLL `exec` is not supported | `mm/shared.cc` exec hand-off |
| Pipe-based stdio for the entry process | PowerShell `-NoNewWindow` produces a stall in DLL initialization | empirical; root cause not isolated |
| Command delivered via redirected stdin, not via `-c` ArgumentList | PowerShell `Start-Process -ArgumentList` does not quote multi-word array elements; bash re-splits at spaces | empirical |
| `PATH=/usr/bin:/bin` reset before user commands | Inherited host `PATH` causes variant bash to PATH-resolve into host `bin/`, producing cross-DLL `exec` failures (exit 127) | empirical; cross-DLL `exec` hand-off |
| `$p.EnableRaisingEvents = $true` before `WaitForExit` in custom launchers | `Start-Process -PassThru` + `WaitForExit` leaves `$p.ExitCode` empty under `powershell.exe -File`; non-zero variant exits would otherwise be reported as 0 | empirical; `System.Diagnostics.Process` asynchronous exit-code capture |
| `/etc/{passwd,group,nsswitch.conf}` (optional) | Avoid the Windows account lookup path | `passwd.cc:85`, `uinfo.cc:1942` |
| Identical ABI between variant DLL and pre-built user-space binaries | Shared-structure magic-number checks abort on mismatch | `mm/shared.cc:293, 211` |
