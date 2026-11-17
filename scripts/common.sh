#!/usr/bin/env bash
# Shared configuration and guards for the image build. Sourced by every stage.
#
# The image is built into a plain file attached with `losetup --partscan`. Each
# stage re-checks that it is pointed at that file and nothing else, because the
# stages format and write boot code to whatever TARGET names.

# Directory and file modes in the image must not depend on the caller's umask:
# sshd's StrictModes rejects a key under a group-writable directory.
umask 022

# Overridable per run:  IMG=/var/tmp/other.img ./build.sh
IMG=${IMG:-/var/tmp/finix.img}
FLAKE=${FLAKE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../flake" && pwd)}
LOGIN_USER=${LOGIN_USER:-finix}
MNT=${MNT:-/mnt}
PROFILE=${PROFILE:-/nix/var/nix/profiles/system}

# `path:` makes Nix read the flake directory as it is on disk, including an
# authorized_keys file filled in for this build, instead of through git.
FLAKE_REF="path:${FLAKE}#nixosConfigurations.finixos.config.system.build.toplevel"

# The store path the image must contain. build.sh sets it by building FLAKE, so
# a stale image or a profile pointing somewhere else fails verification.
EXPECT_TOPLEVEL=${EXPECT_TOPLEVEL:-}

# Constants, deliberately not overridable. They must match
# flake/finix/hardware-configuration.nix. A wrong UUID is not caught by the
# build: it shows up as a hang at first boot, waiting for a root device.
EXPECT_BYTES=1610612736                    # 1536 MiB
BOOT_SECTORS=262144                        # 128 MiB
PIN_BOOT_ID=5A1F09D8                       # surfaces as UUID 5A1F-09D8
EXPECT_BOOT_UUID=5A1F-09D8
EXPECT_ROOT_UUID=7c4e1a9d-2b3f-4c58-9e6a-0d1f2a3b4c5d

# The whole-disk node, set by build.sh from `losetup --show`.
TARGET=${TARGET:-}

# Exported so an override given once to build.sh reaches every stage.
export IMG FLAKE LOGIN_USER MNT PROFILE TARGET EXPECT_TOPLEVEL

fail() { echo "REFUSING: $*" >&2; exit 1; }

# /dev/sdb -> sdb1, but /dev/loop0 -> loop0p1.
part_suffix() {
  case "$1" in
    *loop*|*nvme*|*mmcblk*) printf 'p' ;;
    *)                      printf ''  ;;
  esac
}

# TARGET is authoritative and the partitions are derived from it, so the device
# that gets mounted and the device whose MBR is written can never disagree.
derive_parts() {
  local suf; suf=$(part_suffix "$TARGET")
  BOOT_PART=${TARGET}${suf}1
  ROOT_PART=${TARGET}${suf}2
}

# ---------------------------------------------------------------------- guards

guard_not_live_root() {
  local rootdev; rootdev=$(findmnt -no SOURCE /)
  echo "live root: $rootdev"
  case "$rootdev" in
    "$TARGET"*) fail "live root is on the target $TARGET" ;;
  esac
}

# Catches a truncated or stale image file, and a loop device backed by
# something else entirely.
guard_size() {
  local size; size=$(blockdev --getsize64 "$TARGET")
  [ "$size" = "$EXPECT_BYTES" ] || fail "$TARGET is $size bytes, expected $EXPECT_BYTES"
  echo "size: $size bytes"
}

# Proves TARGET is a loop device backed by IMG. Mandatory: a physical disk of
# the right size must not pass.
guard_backing_file() {
  case "$TARGET" in
    *loop*) ;;
    *) fail "$TARGET is not a loop device" ;;
  esac
  local back got want
  back=$(losetup -n -O BACK-FILE "$TARGET" 2>/dev/null || true)
  [ -n "$back" ] || fail "$TARGET is not an attached loop device"
  got=$(readlink -f "$back" || true)
  want=$(readlink -f "$IMG" || true)
  [ -n "$want" ] || fail "cannot canonicalise IMG '$IMG'"
  [ "$got" = "$want" ] || fail "$TARGET is backed by '$back' ($got), not '$IMG' ($want)"
  echo "backing file: $back"
}

guard_uuids() {
  local pair part want got
  for pair in "$BOOT_PART:$EXPECT_BOOT_UUID" "$ROOT_PART:$EXPECT_ROOT_UUID"; do
    part=${pair%%:*}; want=${pair##*:}
    got=$(blkid -s UUID -o value "$part" 2>/dev/null || true)
    echo "$part UUID=$got (expect $want)"
    [ "$got" = "$want" ] || fail "UUID mismatch on $part"
  done
}

guard_mounted() {
  local got_root got_boot
  got_root=$(findmnt -no SOURCE "$MNT"      2>/dev/null || true)
  got_boot=$(findmnt -no SOURCE "$MNT/boot" 2>/dev/null || true)
  echo "$MNT      <- ${got_root:-(nothing)}"
  echo "$MNT/boot <- ${got_boot:-(nothing)}"
  [ "$got_root" = "$ROOT_PART" ] || fail "$MNT is not $ROOT_PART, run 2-install.sh first"
  [ "$got_boot" = "$BOOT_PART" ] || fail "$MNT/boot is not $BOOT_PART, run 2-install.sh first"
}

mount_target() {
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || mount "$ROOT_PART" "$MNT"
  mkdir -p "$MNT/boot"
  mountpoint -q "$MNT/boot" || mount "$BOOT_PART" "$MNT/boot"
}

# Every stage calls this first.
preflight() {
  [ -n "$TARGET" ] || fail "TARGET is not set, run via build.sh"
  [ -b "$TARGET" ] || fail "$TARGET is not a block device"
  # An empty expectation would turn the toplevel check in 4-verify.sh into a
  # no-op.
  [ -n "$EXPECT_TOPLEVEL" ] || fail "EXPECT_TOPLEVEL is empty, run via build.sh"
  derive_parts
  echo "=== guards ==="
  echo "target: $TARGET   boot: $BOOT_PART   root: $ROOT_PART"
  guard_not_live_root
  guard_size
  guard_backing_file
}
