#!/usr/bin/env bash
# Stage 1: partition and format the target.
#
# Layout:
#   MBR (dos label), 1 MiB gap for limine stage 2
#   p1  128 MiB FAT32-LBA (type c), bootable   -> /boot
#   p2  remainder, Linux (type 83)             -> /
#
# The FAT partition is not an ESP. limine's installer only accepts a /boot whose
# filesystem type starts with "vfat", on BIOS as well.
#
# mkfs.ext4 options:
#   -i 8192  doubles the inode count. The default ratio gives about 90k inodes
#            on a partition this size and the closure needs about 45k.
#   -m 1     instead of the default 5% reserved, which on a grown root would
#            hold back hundreds of megabytes for nothing.
#   -U, -i   the UUIDs are pinned, so hardware-configuration.nix can name them
#            before the disk exists.
set -euo pipefail
cd "$(dirname "$0")"
. ./common.sh

preflight
echo "all guards passed"
echo

echo "=== unmount anything on the target ==="
mountpoint -q "$MNT/boot" && umount "$MNT/boot" || true
mountpoint -q "$MNT"      && umount -R "$MNT"   || true
findmnt | grep -E "$TARGET" || echo "nothing from $TARGET is mounted"
echo

echo "=== partitioning ==="
sfdisk --wipe always "$TARGET" <<PARTS
label: dos
start=2048, size=${BOOT_SECTORS}, type=c, bootable
type=83
PARTS

# With `losetup --partscan` the kernel creates the partition nodes during the
# re-read that sfdisk issues. The wait is a margin; the check is the gate.
sleep 2
for p in "$BOOT_PART" "$ROOT_PART"; do
  [ -b "$p" ] || fail "$p did not appear after partitioning"
done
echo "partition nodes present: $BOOT_PART $ROOT_PART"
echo

echo "=== filesystems ==="
mkfs.vfat -F32 -n BOOT -i "$PIN_BOOT_ID" "$BOOT_PART"
mkfs.ext4 -F -m 1 -i 8192 -U "$EXPECT_ROOT_UUID" -L finix "$ROOT_PART"
echo

echo "=== result ==="
sfdisk -l "$TARGET"
echo
guard_uuids
echo "UUID pins confirmed"
