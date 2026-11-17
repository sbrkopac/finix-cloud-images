# Design

Why the image is built the way it is. Each point was learned by getting it wrong first.

## The disk

- **MBR, BIOS boot.** BIOS with an MBR disk is the strictest common denominator across KVM clouds.
  limine's stage 1 is in the MBR and stage 2 is in the 1 MiB gap before the first partition.
- **`/boot` is FAT32 even on BIOS.** limine's installer accepts only a `/boot` whose filesystem
  type starts with `vfat`. It is a plain FAT partition, not an ESP.
- **Mount by UUID.** finix's `mdevd` populates `/dev/disk/by-uuid`, so one image boots whether the
  disk is `/dev/sda` or `/dev/vda`. The UUIDs are pinned in `scripts/common.sh` and in
  `hardware-configuration.nix`, so the config is correct before the disk exists. finix puts no
  `root=` on the kernel command line; a task in the initrd mounts root by UUID.
- **Small root, grown at boot.** The root partition is about 1.4 GiB so the artifact is small. The
  `grow-root` task extends the partition and filesystem on every boot and does nothing when there
  is no free space. It always exits 0: a machine with no console must boot even if growing fails.

## The build

- **A loop device, not a second disk.** The image is a file attached with `losetup --partscan`.
  The file that is verified is the file that is shipped. Every stage checks that its target is a
  loop device backed by that file before it writes.
- **`nix copy`, not `nixos-install`.** `nixos-install` realises derivations inside the target
  store and leaves the build closure behind, which does not fit a root this small. `nix copy`
  transfers exactly the runtime closure.
- **`TMPDIR=/tmp` for every chroot call.** Activation calls `mktemp -d`. With a `TMPDIR` that does
  not exist inside the chroot, activation writes about 11 entries to `/etc` instead of about 47,
  creates no `/etc/ssh`, and reports success.
- **`biosDevice = "nodev"`, and boot code written by the build.** With a device name in the
  config, `switch-to-configuration` writes boot code to that name wherever it runs, which on a
  build host is the builder's own disk. `nodev` makes it manage only `limine.conf` and
  `limine-bios.sys`. The build then runs `limine bios-install` against the image, using the limine
  binary from the system closure so stage 1, stage 2 and `limine-bios.sys` match.
- **The boot code is zeroed before it is installed.** Otherwise a re-run could pass the MBR check
  on the bytes an earlier run wrote.

## Logging in

- **No password.** The account's password field is locked, root login is off and sshd accepts
  keys only. `sudo` is passwordless for `wheel` through `providers.privileges`, because there is no
  password to ask for.
- **Keys from the metadata service.** finix has no cloud-init and no `authorizedKeys` option, so
  nothing consumes the key chosen when a machine is created. The `cloud-ssh-keys` task asks
  `169.254.169.254` for it once there is a default route, trying DigitalOcean's path, then
  OpenStack's, then the EC2-style path. It writes to `/var/lib/cloud-ssh-keys/`, because `/etc` is
  rebuilt by activation. A failed fetch leaves the previous file in place.
- **Keys baked in.** `flake/finix/authorized_keys` is installed as a real file with mode 0444.
  Without an explicit mode it would be a symlink into `/nix/store`, which is group-writable, and
  sshd's `StrictModes` would reject it.
- **sshd reads exactly two files**, in that order. `AuthorizedKeysFile` replaces sshd's default
  list.

## What verification covers

`scripts/4-verify.sh` checks the image file: the toplevel, `/etc`, the key sources, the account,
sudoers, the sshd policy, the MBR, `/boot`, the root UUID inside the initrd, and that the store is
exactly the runtime closure. It cannot check anything that needs a running system. A boot test in
CI is not implemented.
