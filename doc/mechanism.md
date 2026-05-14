# Mechanism

How relocatable-root detection works, why the Windows loader picks
the right `cygwin1.dll`, what each directory in the layout is for,
and what ABI compatibility means between the variant DLL and the
user-space binaries co-located with it.

For the procedure that uses these mechanisms, see
[`procedure.md`](procedure.md). For the source-line citations into
`winsup/cygwin/`, see [`source-references.md`](source-references.md).

## 1. Relocatable root detection

Cygwin 1.7 and later releases are relocatable. `cygwin1.dll`
determines its own installation root at process initialization by
inspecting its own loaded module path.

The implementation is in `winsup/cygwin/mm/cygheap.cc:166–230`
(`init_cygheap::init_installation_root`):

1. `GetModuleFileNameW(cygwin_hmodule, …)` returns the full Win32
   path of the loaded `cygwin1.dll`.
2. The trailing `\cygwin1.dll` is stripped.
3. The next path component (conventionally `\bin`) is stripped.
4. The remaining prefix is treated as `installation_root`.

A `cygwin1.dll` loaded from `C:\path\to\instance\bin\cygwin1.dll`
therefore causes the process to treat `C:\path\to\instance` as `/`.
POSIX paths within that process resolve against this root via the
variant DLL's mount table.

### Shared-region isolation is automatic

From `cygheap.cc:217–219`:

```c
RtlInt64ToHexUnicodeString(hash_path_name(0, installation_root_buf),
                           &installation_key, FALSE);
```

The `installation_key` is a hash of the DLL's full path. Cygwin
incorporates this key into the NT object names of its shared regions,
including `SH_CYGWIN_SHARED` and `SH_USER_SHARED`. Distinct
`installation_root` paths produce distinct keys. Distinct keys
produce distinct NT object names. Distinct NT object names produce
independent shared regions. The result is independent POSIX PID
spaces, independent mount tables, and independent file-descriptor
tables across installations.

Multiple mini-cygroots may operate concurrently on a single host
without cross-installation interference and without disturbing the
system Cygwin installation.

### Registry entry (informational)

`init_installation_root` writes
`Software\Cygwin\Installations\<key>` to HKLM with HKCU as fallback.
The entry maps `<key>` to the installation root path. Write failure
is non-fatal. The entry is read by Cygwin Setup and by `cygcheck` for
installation enumeration. The running DLL does not depend on the
entry's presence.

## 2. Windows loader behavior

When an executable that imports `cygwin1.dll` is launched, the
Windows loader resolves the import using the following search order:

1. The directory of the executable. This is the mechanism the
   procedure relies on.
2. System32, Known DLLs, current directory, PATH.

`cygwin1.dll` is not registered as a Known DLL. The first search rule
therefore governs DLL selection. An executable launched from
`<instance-root>/bin/foo.exe` loads `<instance-root>/bin/cygwin1.dll`
when that file is present.

`PATH` does not select the DLL. `PATH` affects `execvp()` name
resolution within a running process. Setting
`PATH=<instance-root>/bin:$PATH` is acceptable as a redundant control
over `execvp()` of bare names within a variant process. It is not the
mechanism that selects the DLL at load time.

## 3. Function of recommended directories

The directories listed in the procedure layout (`tmp/`, `dev/`,
`proc/`, `var/`, `usr/`, `lib/`, `home/<USER>/`) are not required by
`cygwin1.dll` initialization. They are required by user-space
utilities that probe them.

`mountinfo.init` (`mm/shared.cc:201, 209`) reads `/etc/fstab` and
`/etc/fstab.d/$USER` at initialization. Both files are optional. When
absent, Cygwin synthesizes the `/usr/bin`, `/usr/lib`, and `/` mounts
documented in [`procedure.md`](procedure.md#2-configuration-file-contents).
The contents of `/proc/*` and `/dev/*` are virtualized by
`fhandler_proc` and `fhandler_dev`. Path resolution requires that the
directory nodes exist. The standard Cygwin installation satisfies
this requirement with zero-byte placeholder directories.

The initialization-time user lookup requires explicit consideration.
`user_info::initialize` (`mm/shared.cc:191`) calls
`internal_getpwsid(sid)` (`passwd.cc:85`) during DLL initialization,
before application code executes. The lookup order is:

1. Cygserver cache. Not enabled by default.
2. `/etc/passwd`. The `nss_pwd_files` source is enabled by default.
3. Windows account database (`add_user_from_windows`). This call
   issues LSA queries and, on domain-joined hosts, an AD/LDAP query.
   This is the high-latency path observed when `/etc/passwd` does
   not contain an entry for the current SID.

Populating the three files described in `procedure.md` §2
short-circuits the lookup at the file-cache step.

## 4. Build-time and run-time identity of `cygwin1.dll`

The variant DLL must present the same ABI as the pre-built binaries
co-located with it. Cygwin's shared structures (`shared_info`,
`user_info`, `cygheap`) include `CURR_*_MAGIC` version words
(`mm/shared.cc:293, 211`). A variant DLL with a structure layout
that differs from the layout expected by the user-space binaries will
fail the magic-number check in `multiple_cygwin_problem` and abort.

Performance and bug-fix patches that do not alter shared structures
preserve the magic and the ABI. Host-built `bash.exe` and `true.exe`
operate correctly with such variant DLLs. Patches that modify
shared-region layout, syscall signatures, or `cygwin_version_info`
require rebuilt user-space binaries. Variant installations that
combine modified DLLs with unmodified user-space binaries must not be
permitted.

A pre-flight check is straightforward: a launcher binary built
against the variant headers, executed inside the variant cygroot,
that returns success when `cygwin_internal(CW_GET_CYGWIN_VERSION_INFO,
…)` reports the expected build.
