#!/usr/bin/env bash
# Stage 3: activate the copied system in a chroot and install limine.
#
# Three steps, in this order:
#   1. `activate` populates /etc and writes /etc/os-release.
#   2. `switch-to-configuration boot` writes limine.conf and limine-bios.sys to
#      /boot. The config sets biosDevice = "nodev", so it writes no boot code.
#   3. `limine bios-install` writes stage 1 to the image's MBR and stage 2 to
#      the gap before partition 1.
#
# TMPDIR=/tmp on every chroot call: setup-etc.sh calls `mktemp -d`, and an
# inherited TMPDIR that does not exist inside the chroot makes every write
# fail. The result is an /etc with about 11 entries instead of about 47 and no
# /etc/ssh at all, and activation reports success either way.
#
# Safe to re-run. Not safe to run before stage 2, which the guards enforce.
set -euo pipefail
cd "$(dirname "$0")"
. ./common.sh

preflight
guard_uuids
guard_mounted
[ -e "$MNT/etc/NIXOS" ] || fail "$MNT/etc/NIXOS missing, run 2-install.sh"
[ -L "$MNT$PROFILE" ] || fail "$MNT$PROFILE is not a symlink, run 2-install.sh"

# The profile must resolve to a toplevel inside the target store, not to a
# dangling link into the build host's store.
TOPLEVEL=$(readlink -f "$MNT$PROFILE")
echo "profile -> $TOPLEVEL"
[ -x "$MNT${TOPLEVEL}/activate" ] || fail "$MNT${TOPLEVEL}/activate not found or not executable"
[ -x "$MNT${TOPLEVEL}/bin/switch-to-configuration" ] || fail "switch-to-configuration not found in the target"
echo "all guards passed"
echo

cleanup() {
  # Lazy, because the chroot may still hold references.
  for d in dev proc sys; do
    mountpoint -q "$MNT/$d" && umount -l "$MNT/$d" || true
  done
}
trap cleanup EXIT

in_target() { TMPDIR=/tmp chroot "$MNT" "$@"; }

echo "=== bind mounts ==="
mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/tmp"
chmod 1777 "$MNT/tmp"
for d in dev proc sys; do
  mountpoint -q "$MNT/$d" || mount --bind "/$d" "$MNT/$d"
done
echo "$MNT/etc entries before: $(ls "$MNT/etc" | wc -l)"
echo

echo "=== 1/3 activate ==="
in_target "$PROFILE/activate"
echo "$MNT/etc entries after: $(ls "$MNT/etc" | wc -l)"
echo

# limine's installer lists generations by running nix-env against the profile
# symlinks stage 2 made by hand. If that fails it fails inside python with a
# wrapped error, so probe it here where the message is legible.
echo "=== can nix-env see the generation? ==="
NIX_ENV=$PROFILE/sw/bin/nix-env
if [ -x "$MNT$NIX_ENV" ]; then
  in_target "$NIX_ENV" --list-generations -p "$PROFILE" --option build-users-group '' \
    || echo "WARNING: nix-env --list-generations failed, limine's installer will too" >&2
else
  echo "(no nix-env at $NIX_ENV, skipping the probe)"
fi
echo

echo "=== 2/3 switch-to-configuration boot ==="
in_target "$PROFILE/bin/switch-to-configuration" boot
echo

echo "=== 3/3 install limine boot code into $TARGET ==="
# Take limine from the system closure. Its stage 1 and stage 2 must match the
# limine-bios.sys that step 2 copied, or it refuses at boot.
LIMINE_BIN=""
while read -r p; do
  if [ -n "$p" ] && [ -x "$MNT$p/bin/limine" ]; then
    LIMINE_BIN=$p/bin/limine
    break
  fi
done <<< "$(nix path-info -r "$TOPLEVEL" | grep -E -- '-limine-' || true)"
[ -n "$LIMINE_BIN" ] || fail "no limine binary in the closure of $TOPLEVEL"
echo "limine: $LIMINE_BIN"

# Zero the boot code first, so 4-verify.sh cannot pass on bytes a previous run
# wrote. 446 bytes only: 446 to 509 are the partition table and 510 to 511 are
# the boot signature.
dd if=/dev/zero of="$TARGET" bs=446 count=1 conv=notrunc status=none
sync

in_target "$LIMINE_BIN" bios-install "$TARGET"
