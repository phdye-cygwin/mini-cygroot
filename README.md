# Mini-Cygroot: Side-by-Side Cygwin Installations for Testing Alternate `cygwin1.dll` Builds

Canonical source: <https://github.com/phdye-cygwin/mini-cygroot>
Verified-Against: Cygwin 3.6.7 (`upstream-main/winsup/cygwin/`).
Test-Platform: Windows 11.

A mini-cygroot is a self-contained Cygwin installation located at an
arbitrary directory on a Windows host. It operates independently of
the system Cygwin installation. Use cases include A/B testing of
alternate `cygwin1.dll` builds, benchmark variant execution, and
regression bisection.

## Quick start

Three commands to a working mini-cygroot. The full procedure and the
rationale are under [`doc/`](doc/).

Prerequisites: Cygwin 1.7 or later on Windows. `create-mini-cygroot.sh`
and `launch-mini-cygroot.sh` from this repo (or their gist mirrors),
executable, on `PATH` or in the current directory.

```sh
# 1. Build a mini-cygroot skeleton at /tmp/test-cygroot.
#    Hardlinks /usr/bin/* into <inst>/bin/, populates
#    /etc/{passwd,group,nsswitch.conf}.
./create-mini-cygroot.sh /tmp/test-cygroot

# 2. Drop in the variant cygwin1.dll under test.
cp /path/to/variant/cygwin1.dll /tmp/test-cygroot/bin/cygwin1.dll

# 3. Run the default diagnostic inside the variant.
./launch-mini-cygroot.sh /tmp/test-cygroot
```

Expected first line of output:

```
/tmp/test-cygroot/bin on /usr/bin type ntfs (binary,auto)
```

That single line confirms three conditions: the variant DLL loaded,
Cygwin's relocatable-root detection resolved `<instance-root>` to
`/tmp/test-cygroot`, and the variant mount table is active.

### No variant DLL to hand?

Use the host's:

```sh
cp /usr/bin/cygwin1.dll /tmp/test-cygroot/bin/cygwin1.dll
```

The same DLL runs twice. Useful as an end-to-end sanity check of the
procedure on your machine before swapping in a real variant.

### Running a specific command

By default `launch-mini-cygroot.sh` runs the diagnostic
`mount; cygpath -w /; cygpath -w /bin/true`. To run something else,
pass it after `--`:

```sh
./launch-mini-cygroot.sh /tmp/test-cygroot -- 'ps -ef; uname -a'
```

Stdio is captured to temp files and replayed to the launcher's
stdout / stderr after the variant exits. See
[`doc/launcher-constraints.md`](doc/launcher-constraints.md) for why
the launcher routes through PowerShell rather than invoking variant
`bash.exe` directly.

### Cleanup

```sh
rm -rf /tmp/test-cygroot
```

Safe once all variant processes have exited. The mini-cygroot leaves
no filesystem mount, service, or driver behind; see
[`doc/limitations.md`](doc/limitations.md) for the residual registry
entry (benign, self-overwriting).

## Documentation

| File | Contents |
|---|---|
| [`doc/procedure.md`](doc/procedure.md) | The full manual procedure: required layout, configuration file contents, six-command assembly, PowerShell launch sequence. For readers not using the companion scripts, or adapting the procedure to a build system. |
| [`doc/mechanism.md`](doc/mechanism.md) | How it works: relocatable-root detection, Windows loader behaviour, function of each directory in the layout, ABI compatibility between the variant DLL and the user-space binaries. |
| [`doc/launcher-constraints.md`](doc/launcher-constraints.md) | The five rules a PowerShell launcher must honor: non-Cygwin parent, redirected stdio, sanitized `PATH`, stdin-based command delivery, reliable exit-code capture. With failure-mode descriptions for each. |
| [`doc/verification.md`](doc/verification.md) | Three reproducible experiments confirming relocatable-root detection, variant DLL load, and shared-region isolation between host and variant. Outputs reproduced verbatim from runs on Windows 11 with Cygwin 3.6.7. |
| [`doc/limitations.md`](doc/limitations.md) | What the procedure does not handle: path-as-install-key immutability, no-hardlinks-between-cygroots, Cygwin 1.7 version floor, NTFS-vs-FAT filesystem requirement, removal residue. |
| [`doc/source-references.md`](doc/source-references.md) | Requirement-to-rationale cheat sheet, plus line-numbered citations into `winsup/cygwin/` for every Cygwin function referenced in the docs. |

## License

AGPL-3.0. See [`LICENSE`](LICENSE).
