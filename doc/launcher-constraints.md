# Launcher constraints

Five rules that anyone entering a mini-cygroot from PowerShell must
honor. The reference implementation in `launch-mini-cygroot.sh`
encodes all five; this document is for readers who are writing their
own launcher, or who need to diagnose a failure that traces back to
one of them.

## 1. The launcher process must not be a Cygwin process

A Cygwin parent that performs `exec` into a variant binary causes
shared-region state to be mixed across DLL builds. Cygwin's
POSIX-exec hand-off uses a shared section to transfer file
descriptors, signal state, and POSIX identity. Cross-DLL `exec` is
not supported.

The variant must be entered from a non-Cygwin parent. Acceptable
parents include `cmd.exe` and its wrappers (batch files, scheduled
tasks), PowerShell (via `Start-Process` or the call operator `&`),
and native Windows services or supervisors.

Within the variant process tree, `fork` and `exec` operate normally.
The constraint applies only to the entry into the variant
environment.

## 2. Pipe-based stdio is required for the entry process (open issue)

The following invocation reliably stalls in `cygwin1.dll`
initialization for periods exceeding sixty seconds, with no observed
completion on the test platform:

```powershell
Start-Process <variant>\bin\true.exe -NoNewWindow -PassThru
```

The same `true.exe` completes within milliseconds when launched with
redirected standard streams:

```powershell
Start-Process <variant>\bin\true.exe `
    -RedirectStandardOutput out.txt `
    -RedirectStandardError  err.txt `
    -RedirectStandardInput  nul `
    -NoNewWindow -PassThru
```

The proximate cause has not been isolated. Candidate factors include
stdio and console-handle setup in the variant DLL on a process that
has inherited the parent console without TTY emulation, and the
`CreateFileW(GENERIC_READ)` re-open of the DLL in
`init_installation_root` (`cygheap.cc:174`) under antivirus scan
latency for binaries in non-standard paths.

The operational recommendation is to redirect standard input, output,
and error when launching the entry process from PowerShell.
Equivalent alternatives are to launch via `cmd.exe /c
<variant>\bin\foo.exe …` from a hidden window, or to use a bridge
process that pipes the standard streams.

## 3. Sanitize `PATH` before the variant runs commands

The variant inherits the parent's environment, including `PATH`. On
a Cygwin host the inherited `PATH` contains entries such as
`/cygdrive/c/-/cygwin/root/bin`, which the variant's cygdrive mount
resolves to the **host** Cygwin `bin/` directory. PATH-based command
lookups inside variant bash therefore find host binaries first.
Executing those host binaries is a cross-DLL exec: the host binary
loads the host `cygwin1.dll`, which has a different
`installation_key` from the variant DLL and therefore a different
shared-memory region. Cygwin's exec hand-off cannot complete across
this boundary. The observed failure mode is exit code 127, surfaced
by variant bash as "command not found."

Reset `PATH` to variant-resident entries before any user command
runs:

```bash
PATH=/usr/bin:/bin
```

These two paths resolve via the variant's mount table to
`<instance-root>/bin/`, keeping every PATH-based lookup inside the
variant cygroot. Full-path executions (`/bin/true`) bypass PATH and
are unaffected; the constraint applies only to bare-name invocations.

## 4. Pass commands via stdin, not via `-ArgumentList '-c', '<command>'`

PowerShell's `Start-Process -ArgumentList @('-c', '<command-string>')`
flattens the array into a single command line with naive
space-joining. The multi-word command-string is not quoted. Bash's
CRT-style argv parser then re-splits the string at spaces. The first
token becomes the script body for `-c`; the remaining tokens become
positional parameters (`$0`, `$1`, …). Observed failure mode: only
the first whitespace-delimited word of the intended command
executes.

Pass the command to variant bash through redirected stdin instead.
Bash with no `-c` reads its script from stdin until EOF:

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

The stdin-file path is a normal Windows file path. There is no
Windows-side command-line construction; no quoting is required.

## 5. Capture the variant's exit code reliably

When a launcher uses `Start-Process -PassThru` and enforces a timeout
by calling `WaitForExit($timeoutMs)` (in preference to the parameter
`-Wait`, which does not support a timeout), the returned process
object's `.ExitCode` property is empty in `powershell.exe -File`
script context after the process exits, even though `.HasExited`
reports `True`. The observed consequence is that `exit $p.ExitCode`
terminates the launcher with code 0 regardless of the variant's
actual exit. Non-zero exits from the variant are silently lost.

The fix is to set `EnableRaisingEvents` on the process object before
calling `WaitForExit`:

```powershell
$p = Start-Process ... -PassThru
$p.EnableRaisingEvents = $true
$exited = $p.WaitForExit($timeoutMs)
if (-not $exited) { $p.Kill(); exit 124 }
exit $p.ExitCode
```

Setting this flag wires up .NET's internal exit-code capture path in
`System.Diagnostics.Process`. Without it, the property accessor
returns the default value when read after `WaitForExit`.

The parameter `-Wait` on `Start-Process` is an alternative that also
populates `.ExitCode` reliably, but it does not accept a timeout
argument.

## Reference implementation

The repository's `launch-mini-cygroot.sh` is a reference launcher
that honors all five rules: callable from a host Cygwin bash,
producing the variant process under a non-Cygwin parent
(`powershell.exe`) with redirected stdio, sanitized `PATH`,
stdin-based command delivery, and reliable exit-code propagation.

A standalone copy of the same script is also published as a
companion gist:
`https://gist.github.com/phdye/691e93c4db4083b8ed7057ee27246091`
(`launch-mini-cygroot.sh`).
