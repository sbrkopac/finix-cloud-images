# Grow the root partition and filesystem to fill the disk.
#
# The image ships a root of about 1.4 GiB so the artifact stays small, and
# every cloud gives it a larger disk. cloud-init would resize the root on first
# boot. finix has no cloud-init, so without this the difference is stranded.
#
# cloud-utils' growpart was rejected: its closure is 267 MiB. sfdisk, partx,
# lsblk and resize2fs are already in the system closure.
#
# Runs every boot and is idempotent. Every failure path exits 0, because a
# machine with no console must boot even if growing goes wrong.
{ pkgs, ... }:
let
  grow-root = pkgs.writeShellScript "grow-root" ''
    set -u

    src=$(findmnt -no SOURCE /) || exit 0
    case "$src" in
      /dev/*) ;;
      *) echo "grow-root: root is $src, not a block device, skipping"; exit 0 ;;
    esac

    part=''${src#/dev/}
    # /sys gives the partition number and geometry directly, which avoids
    # parsing device names (vda2 or nvme0n1p2).
    [ -r "/sys/class/block/$part/partition" ] || {
      echo "grow-root: $src is not a partition, skipping"; exit 0; }
    read -r num   < "/sys/class/block/$part/partition"
    read -r start < "/sys/class/block/$part/start"
    read -r size  < "/sys/class/block/$part/size"

    disk=$(lsblk -no PKNAME "$src") || exit 0
    [ -n "$disk" ] || { echo "grow-root: no parent disk for $src"; exit 0; }

    total=$(blockdev --getsz "/dev/$disk") || exit 0
    slack=$(( total - start - size ))

    # 64 MiB in 512-byte sectors. Below this the partition table is left alone.
    if [ "$slack" -lt 131072 ]; then
      echo "grow-root: $slack sectors free after $src, nothing to do"
      exit 0
    fi

    echo "grow-root: $slack sectors free, growing partition $num on /dev/$disk"

    # ", +" keeps the start and extends the size to the maximum. --no-reread
    # because the disk is in use; partx -u then updates the kernel's view.
    if ! echo ', +' | sfdisk --no-reread --force -N "$num" "/dev/$disk"; then
      echo "grow-root: sfdisk failed, leaving the partition alone"
      exit 0
    fi

    partx -u "/dev/$disk" || echo "grow-root: partx -u failed, continuing anyway"
    resize2fs "$src" || echo "grow-root: resize2fs failed"

    exit 0
  '';
in
{
  # A task, not a service: it runs to completion. `remain` stops it re-running
  # on every runlevel change. It still runs once per boot.
  finit.tasks.grow-root = {
    description = "Grow the root partition and filesystem to fill the disk";
    command = "${grow-root}";
    remain = true;
    log = true;
    path = [
      pkgs.util-linux
      pkgs.e2fsprogs
    ];
  };
}
