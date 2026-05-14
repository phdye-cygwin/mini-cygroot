# Limitations

What the procedure does not handle, and what state a mini-cygroot
leaves behind after removal.

## Path identity is the install key

The mini-cygroot is identified by its path, not by its contents. The
`install_key` value is `hash_path_name(installation_root)`. Moving
the directory changes the key, which orphans the per-install shared
region and invalidates references stored under the prior path,
including the `Software\Cygwin\Installations\<key>` registry entry
and any paths embedded in `/etc/passwd` home fields or shell startup
scripts. The directory must therefore be treated as immutable once
populated, or the installation must be rebuilt after a move.

`create-mini-cygroot.sh` includes a hardlink-break safety step that
protects against an accidental shared-inode condition. The host's
`/usr/bin/cygwin1.dll` is hardlinked into `<inst>/bin/` by `cp -rl`;
without the break step, a later `cp /path/to/variant/cygwin1.dll
<inst>/bin/cygwin1.dll` would follow the inode and overwrite the
host DLL. The script unconditionally breaks the hardlink before
exiting.

## Single DLL across two cygroots is not supported

A single `cygwin1.dll` file cannot be shared between two cygroots
via hardlink. The Windows loader's `GetModuleFileNameW` returns the
path used to map the module. Each hardlinked path therefore
constitutes a separate installation with a separate `install_key`.

## Version floor: Cygwin 1.7 (2010-12)

Cygwin versions prior to 1.7 are not relocatable. This procedure
applies to versions 1.7 and later. Prior versions determined the
installation root from the registry, not from the loaded DLL path.

## Filesystem requirements

The same-volume hardlink technique (`cp -rl`) requires an NTFS-to-NTFS
copy within a single volume. Cross-volume installation and
installation on FAT filesystems require a recursive copy (`cp -r`).
Disk usage in those configurations scales with the size of the
`bin/` directory.

## Removal residue

`rm -rf <instance-root>` is sufficient to remove the installation
*once all variant processes have exited*. While any process holds
the variant `cygwin1.dll`, the loader prevents unlink and the
operation fails.

After removal, the following residue remains on the host:

- The `HKLM` or `HKCU` `Software\Cygwin\Installations\<key>`
  registry entry persists across reboots. The entry is benign and
  is self-overwriting on the next initialization of any Cygwin
  installation that hashes to the same key (which only happens when
  the same path is reused).
- NT shared-region objects are session-scoped. They are released
  when the last process in the variant cygroot exits.
- No filesystem mount, Windows service, or kernel driver is
  installed by the mini-cygroot itself.
