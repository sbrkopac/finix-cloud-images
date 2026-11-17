#!/usr/bin/env bash
# Build the finix cloud image into a file, through a loop device.
#
#   ./build.sh              run every stage against a freshly created image
#   ./build.sh 3 4          re-attach the existing image and run only stages 3, 4
#   IMG=/var/tmp/x.img ./build.sh
#
# Run as root on a Linux host with Nix. Stages:
#   1 partition   2 install   3 bootloader   4 verify
#
# The stages are separate scripts so one can be re-run without repeating the
# closure copy.
set -euo pipefail
cd "$(dirname "$0")"
. ./common.sh

[ "$(id -u)" = 0 ] || fail "must run as root"

STAGES=${*:-1 2 3 4}
runs() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# An unrecognised stage would otherwise run nothing and print BUILD COMPLETE.
for s in $STAGES; do
  case "$s" in
    1|2|3|4) ;;
    *) fail "unknown stage '$s', valid stages are 1 2 3 4 (space separated)" ;;
  esac
done

LOOP=""
cleanup() {
  mountpoint -q "$MNT/boot" && umount "$MNT/boot" || true
  mountpoint -q "$MNT"      && umount -R "$MNT"   || true
  if [ -n "$LOOP" ]; then
    losetup -d "$LOOP" 2>/dev/null || true
    echo "detached $LOOP"
  fi
}
trap cleanup EXIT

echo "########## stages: $STAGES ##########"
echo "image: $IMG"
echo "flake: $FLAKE"
echo

echo "=== build the system ==="
[ -f "$FLAKE/flake.lock" ] || fail "$FLAKE has no flake.lock, the pin is what makes the build repeatable"
if [ -z "$EXPECT_TOPLEVEL" ]; then
  EXPECT_TOPLEVEL=$(nix build --no-link --print-out-paths "$FLAKE_REF")
fi
export EXPECT_TOPLEVEL
echo "toplevel: $EXPECT_TOPLEVEL"
echo

if runs 1; then
  # Stage 1 is destructive, so creating the backing file belongs to it.
  if [ -e "$IMG" ] && [ "${FORCE:-0}" != 1 ]; then
    fail "$IMG already exists. Move it aside, or re-run with FORCE=1 to overwrite."
  fi
  echo "=== create the backing file ($EXPECT_BYTES bytes, sparse) ==="
  rm -f "$IMG"
  truncate -s "$EXPECT_BYTES" "$IMG"
  ls -l "$IMG"
  echo
else
  [ -f "$IMG" ] || fail "$IMG does not exist, run stage 1 first"
fi

echo "=== attach ==="
# --partscan makes the kernel create loopNp1 and loopNp2.
LOOP=$(losetup --find --show --partscan "$IMG")
export TARGET=$LOOP
echo "TARGET=$TARGET  <- $(losetup -n -O BACK-FILE "$LOOP")"

# Stages 2, 3 and 4 work on a mounted target. Stage 1 must not have it mounted,
# because it repartitions, and stage 2 then mounts for itself. So mount here
# only when stage 1 is not selected.
if ! runs 1; then
  derive_parts
  mount_target
  echo "mounted: $ROOT_PART -> $MNT, $BOOT_PART -> $MNT/boot"
fi
echo

for s in 1 2 3 4; do
  runs "$s" || continue
  case $s in
    1) script=1-partition.sh  ;;
    2) script=2-install.sh    ;;
    3) script=3-bootloader.sh ;;
    4) script=4-verify.sh     ;;
  esac
  echo
  echo "################ stage $s: $script ################"
  bash "./$script"
  echo "################ stage $s OK ################"
done

echo
echo "########## BUILD COMPLETE ##########"
echo "image: $IMG"
