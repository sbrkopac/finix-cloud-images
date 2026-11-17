#!/usr/bin/env bash
# Stage 2: install the system by copying its runtime closure.
#
# Not nixos-install: that realises derivations inside the target store and
# drags the build closure in with them (compilers, source tarballs), which does
# not fit on a root this small. `nix copy` transfers exactly the runtime closure
# of the toplevel, so the target store needs no garbage collection afterwards.
set -euo pipefail
cd "$(dirname "$0")"
. ./common.sh

preflight
guard_uuids
echo "all guards passed"
echo

echo "=== mount ==="
mount_target
mkdir -p "$MNT/tmp" "$MNT/etc" "$MNT/var"
chmod 1777 "$MNT/tmp"
guard_mounted
echo

echo "=== build the system on this machine, never in the target ==="
TOPLEVEL=$(nix build --no-link --print-out-paths "$FLAKE_REF")
echo "toplevel: $TOPLEVEL"
[ "$TOPLEVEL" = "$EXPECT_TOPLEVEL" ] || fail "built $TOPLEVEL, expected $EXPECT_TOPLEVEL"
echo -n "runtime closure size: "
nix path-info -Sh "$TOPLEVEL" | awk '{print $2}'
echo

echo "=== copy only the runtime closure into the target ==="
nix copy --no-check-sigs --to "$MNT" "$TOPLEVEL"
echo

echo "=== set up the system profile ==="
mkdir -p "$MNT/nix/var/nix/profiles"
ln -sfn "$TOPLEVEL" "$MNT/nix/var/nix/profiles/system-1-link"
ln -sfn system-1-link "$MNT/nix/var/nix/profiles/system"
ls -l "$MNT/nix/var/nix/profiles/"
echo

# switch-to-configuration refuses to run unless it can tell this is a nix
# system, which it decides from this file.
touch "$MNT/etc/NIXOS"

echo "=== stage the flake for rebuilds on the machine ==="
mkdir -p "$MNT/etc/nixos"
cp -r "$FLAKE"/. "$MNT/etc/nixos/"
find "$MNT/etc/nixos" -type f | sort
echo

echo "=== space after copy ==="
df -h "$MNT" "$MNT/boot"
df -i "$MNT"
