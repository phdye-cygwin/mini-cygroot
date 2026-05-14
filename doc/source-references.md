# Source references

Two tables. The first is a requirement-rationale cheat sheet — every
load-bearing rule in the procedure mapped to its mechanism and to the
empirical or source-line citation that justifies it. The second is
the source-line index into `upstream-main/winsup/cygwin/` for the
Cygwin functions named throughout the documentation.

Line numbers and function names are verified against Cygwin 3.6.7.
Later releases may renumber lines and rename helpers; the symbol
names and call structure tend to remain stable.

## Requirement → rationale → reference

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

## Cygwin source-line index

Paths are relative to `upstream-main/winsup/cygwin/`.

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
