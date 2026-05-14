# Verification

Three experiments performed against `/tmp/test-cygroot` on Windows 11
with Cygwin 3.6.7. Each is reproducible by anyone who has built a
mini-cygroot per [`procedure.md`](procedure.md). The outputs below
are reproduced verbatim from the original runs.

The mechanism each experiment exercises is documented in
[`mechanism.md`](mechanism.md).

## Experiment 1: Relocatable root detection

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

`mount` reports `<instance-root>` mounted on `/`. `cygpath -w /`
returns `<instance-root>`. `cygpath -w /bin/true` returns the variant
`true.exe`. The variant mount table is in effect.

## Experiment 2: Variant DLL load verification

The variant `true.exe` was launched and its loaded modules enumerated
from a non-Cygwin tool:

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

All Cygwin DLLs mapped into the variant process are variant copies.
No DLLs from the host installation are loaded. The process stalls in
initialization under `-NoNewWindow` per
[`launcher-constraints.md`](launcher-constraints.md) §2; however,
the modules are mapped before the stall, so a short sleep is
sufficient for the enumeration.

## Experiment 3: Shared-region isolation

Two independent verifications.

### 3a. Distinct installation keys

Cygwin records one registry entry per installation root, keyed by
the hash of the root path. A query against
`HKCU:\Software\Cygwin\Installations` after launching both host and
variant returned:

```
key=b9441769d2745a4a   root=\??\C:\-\cygwin\root                       # host
key=813a12c15ca103a5   root=\??\C:\-\cygwin\root\tmp\test-cygroot      # variant
```

Two distinct 64-bit hashes for two distinct paths. Cygwin uses these
hashes in the NT object names of its shared regions; therefore the
shared regions are distinct by construction.

### 3b. Distinct POSIX PID spaces

The `ps -ef` command was executed from inside the variant and from
inside the host concurrently:

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

Each Cygwin installation maintains an independent POSIX PID counter
in its own shared region. The variant enumerates only variant
processes. The host enumerates only host processes. The two PID
spaces do not interact.
