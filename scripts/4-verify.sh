#!/usr/bin/env bash
# Stage 4: verify the built image.
#
# These are image-file checks only. They inspect /etc, /boot, the store and the
# MBR of a target that has been activated and never booted. They cannot prove
# that it boots, that sshd accepts a key, that the metadata fetch works, that
# the root grows, or that DHCP comes up. A green run here is not a boot test.
#
# Every check records a verdict and the script exits non-zero at the end, so
# one run prints the complete picture instead of stopping at the first fault.
set -euo pipefail
cd "$(dirname "$0")"
. ./common.sh

VERIFY_FAILURES=0
# Assignment form, not (( ++ )): an arithmetic command that evaluates to 0
# returns status 1 and would trip `set -e` on the first failure recorded.
vfail() { echo "FAIL: $*"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
vok()   { echo "OK: $*"; }
check() { # description, command...
  local what=$1; shift
  if "$@"; then vok "$what"; else vfail "$what"; fi
}

# One trap for every temp file. A second `trap ... EXIT` would replace this one.
TMPFILES=()
cleanup_tmp() { if [ "${#TMPFILES[@]}" -gt 0 ]; then rm -f "${TMPFILES[@]}"; fi; return 0; }
trap cleanup_tmp EXIT
# Sets a named variable. `X=$(newtmp)` would run in a subshell and lose the
# registration.
newtmp() {
  local t; t=$(mktemp)
  TMPFILES+=("$t")
  printf -v "$1" '%s' "$t"
}

# Entries in /etc are symlinks with absolute targets such as /etc/static/...,
# which resolve against the build host's root when followed from outside. Read
# them from inside the image instead.
target_read() { # path inside the image, file to write it to
  chroot "$MNT" "$PROFILE/sw/bin/cat" "$1" > "$2" 2>/dev/null
}

preflight
guard_mounted
guard_uuids
TOPLEVEL=$(readlink -f "$MNT$PROFILE")
echo

echo "############ VERIFICATION (image-file checks) ############"

echo "--- toplevel ---"
echo "want: $EXPECT_TOPLEVEL"
echo "got:  $TOPLEVEL"
check "the profile is the system this flake builds" [ "$TOPLEVEL" = "$EXPECT_TOPLEVEL" ]
echo

# A broken activation leaves about 11 entries here instead of about 47, with no
# /etc/ssh. A floor, not an equality test: the named files below are the real
# checks.
echo "--- /etc populated? ---"
ETC_COUNT=$(ls "$MNT/etc" | wc -l)
check "/etc has $ETC_COUNT entries (want 20 or more)" [ "$ETC_COUNT" -ge 20 ]
check "/etc/ssh exists" [ -d "$MNT/etc/ssh" ]
echo

echo "--- SSH keys: fetched at boot ---"
newtmp TASK
if target_read /etc/finit.d/cloud-ssh-keys.conf "$TASK"; then
  cat "$TASK"; echo
  check "the cloud-ssh-keys task is registered" grep -q 'name:cloud-ssh-keys' "$TASK"
else
  vfail "/etc/finit.d/cloud-ssh-keys.conf missing, nothing will fetch a key at boot"
fi
echo

echo "--- SSH keys: baked in ---"
WANT_KEYS=$FLAKE/finix/authorized_keys
KEYFILE=$MNT/etc/ssh/authorized_keys.d/$LOGIN_USER
if grep -q '[^[:space:]]' "$WANT_KEYS" 2>/dev/null; then
  # Must be a real file with mode 0444. A symlink into /nix/store is rejected
  # by sshd's StrictModes, because the store is group-writable.
  if [ -L "$KEYFILE" ]; then
    vfail "$KEYFILE is a symlink, sshd StrictModes will reject it"
  elif [ -f "$KEYFILE" ]; then
    check "$KEYFILE has mode 0444" [ "$(stat -c %a "$KEYFILE")" = 444 ]
    # Compare content, not shape: a valid key that is the wrong key passes any
    # "starts with ssh-" test and produces a machine nobody can log into.
    newtmp WANT_NORM; newtmp GOT_NORM
    grep '[^[:space:]]' "$WANT_KEYS" | sed 's/[[:space:]]*$//' > "$WANT_NORM"
    grep '[^[:space:]]' "$KEYFILE"   | sed 's/[[:space:]]*$//' > "$GOT_NORM"
    check "the baked keys are the ones in $WANT_KEYS" cmp -s "$WANT_NORM" "$GOT_NORM"
  else
    vfail "$KEYFILE does not exist, but $WANT_KEYS has keys"
  fi
else
  echo "none requested: $WANT_KEYS is empty, so the metadata fetch is the only way in"
  check "no key file was baked in" [ ! -e "$KEYFILE" ]
fi
echo

# The account must exist, be uid 1000 and be in wheel. Otherwise the key has no
# user to authenticate and passwordless sudo has no group to match.
echo "--- account $LOGIN_USER ---"
if passwd_line=$(grep "^${LOGIN_USER}:" "$MNT/etc/passwd" 2>/dev/null); then
  echo "$passwd_line"
  check "uid is 1000" [ "$(echo "$passwd_line" | cut -d: -f3)" = 1000 ]
  check "$LOGIN_USER is in wheel" grep -q "^wheel:.*[:,]${LOGIN_USER}\(,\|$\)" "$MNT/etc/group"
  # Three states must not be confused: a missing entry, an empty field (which
  # permits passwordless login) and a locked field. Only locked passes.
  if shadow_line=$(grep "^${LOGIN_USER}:" "$MNT/etc/shadow" 2>/dev/null); then
    shadow=$(printf '%s' "$shadow_line" | cut -d: -f2)
    case "$shadow" in
      '!'*|'*') vok "password field is locked" ;;
      '')       vfail "password field is empty, which permits passwordless login" ;;
      \$*)      vfail "password field carries a hash" ;;
      *)        vfail "unrecognised password field, cannot confirm the account is locked" ;;
    esac
  else
    vfail "no $LOGIN_USER entry in $MNT/etc/shadow"
  fi
else
  vfail "no $LOGIN_USER account in $MNT/etc/passwd"
fi
echo

# sudoers is last-match-wins and the sudo module ships its own %wheel rule
# earlier in the file, so NOPASSWD must be on the last one. `Defaults` lines
# mention %wheel and are not rules.
echo "--- passwordless sudo for wheel ---"
SUDOERS=$MNT/etc/sudoers
if [ -e "$SUDOERS" ]; then
  LAST_WHEEL=$(grep -n '^[^#]*%wheel' "$SUDOERS" | grep -v '^[0-9]*:[[:space:]]*Defaults' | tail -1 || true)
  echo "last %wheel rule: $LAST_WHEEL"
  check "the last %wheel rule carries NOPASSWD" grep -q NOPASSWD <<< "$LAST_WHEEL"
else
  vfail "$SUDOERS missing"
fi
echo

# sshd is first-match-wins per keyword, the opposite of sudoers, so assert on
# the first occurrence.
echo "--- sshd auth policy ---"
newtmp SSHD
sshd_first() { # keyword -> the rest of its first line
  awk -v k="$1" 'tolower($1) == tolower(k) { $1 = ""; sub(/^ /, ""); print; exit }' "$SSHD"
}
sshd_assert() { # keyword, expected value
  local got; got=$(sshd_first "$1")
  check "sshd $1 is '$2' (got '${got:-unset}')" [ "$got" = "$2" ]
}
if target_read /etc/ssh/sshd_config "$SSHD"; then
  sshd_assert PasswordAuthentication no
  sshd_assert PermitRootLogin no
  # AuthorizedKeysFile replaces sshd's default list, so these paths are the only
  # places a key is read from.
  sshd_assert AuthorizedKeysFile "/etc/ssh/authorized_keys.d/%u /var/lib/cloud-ssh-keys/%u"
else
  vfail "/etc/ssh/sshd_config does not exist"
fi
echo

echo "--- MBR: limine stage 1, the boot signature, and stage 2 in the gap ---"
# Read sector 0 once, into a file. Piping dd into a reader that exits at its
# first match can SIGPIPE dd and, under pipefail, report a find as a failure.
newtmp MBRFILE
dd if="$TARGET" bs=512 count=1 of="$MBRFILE" status=none
od -An -tx1 -N16 "$MBRFILE"
check "LIMINE found in the MBR" grep -aq LIMINE "$MBRFILE"
# Without 55 aa at offset 510 the BIOS does not consider the disk bootable.
MBR_SIG=$(od -An -tx1 -j510 -N2 "$MBRFILE" | tr -d ' \n')
check "boot signature 55 aa at offset 510 (got '$MBR_SIG')" [ "$MBR_SIG" = 55aa ]
# Stage 2 lives in the gap before partition 1. A stage 1 that jumps into an
# empty gap hangs with no message. 3-bootloader.sh zeroes the boot code before
# installing, so these bytes are what this run wrote.
GAP_BYTES=$(dd if="$TARGET" bs=512 skip=1 count=2047 status=none | tr -d '\0' | wc -c)
check "stage 2 present in the MBR gap ($GAP_BYTES non-zero bytes)" [ "${GAP_BYTES:-0}" -gt 0 ]
echo

echo "--- /boot ---"
ls -la "$MNT/boot" "$MNT/boot/limine" 2>/dev/null || true
CONF=$MNT/boot/limine/limine.conf
check "limine-bios.sys is on /boot" [ -s "$MNT/boot/limine/limine-bios.sys" ]
if [ -f "$CONF" ]; then
  # Present is not enough. A limine.conf left by an earlier generation still
  # parses and boots the wrong system. It carries `init=<toplevel>/init`.
  check "limine.conf references the current toplevel" grep -qF -- "$TOPLEVEL" "$CONF"
else
  vfail "no $CONF"
fi
echo

# finix puts no root= on the kernel command line. Root is mounted from inside
# the initrd by a finit task, by UUID. The initrd is zstd-compressed, so the
# raw file cannot be grepped. grep -c, not -q: -q exits at its first match,
# which SIGPIPEs zstd and fails the pipeline.
echo "--- root UUID in the initrd ---"
INITRD=$(readlink -f "$MNT$PROFILE/initrd")
if [ -f "$INITRD" ]; then
  UUID_HITS=$(zstd -dc "$INITRD" 2>/dev/null | grep -ac "$EXPECT_ROOT_UUID" || true)
  check "the initrd mounts /dev/disk/by-uuid/$EXPECT_ROOT_UUID" [ "${UUID_HITS:-0}" -gt 0 ]
else
  vfail "no initrd at $INITRD"
fi
echo

echo "--- grow-root task ---"
newtmp GROW
if target_read /etc/finit.d/grow-root.conf "$GROW"; then
  check "the grow-root task is registered" grep -q 'name:grow-root' "$GROW"
else
  vfail "/etc/finit.d/grow-root.conf missing"
fi
echo

# Compares store path names only, not their contents.
echo "--- the store is exactly the runtime closure ---"
du -sh "$MNT/nix/store"
newtmp WANT; newtmp GOT
nix path-info -r "$TOPLEVEL" | sed 's|.*/||' | sort -u > "$WANT"
ls "$MNT/nix/store" | grep -v '^\.links$' | sort -u    > "$GOT"
echo "in closure: $(wc -l < "$WANT")   on target: $(wc -l < "$GOT")"
EXTRA=$(comm -13 "$WANT" "$GOT" || true)
MISSING=$(comm -23 "$WANT" "$GOT" || true)
check "no extra paths on the target" [ -z "$EXTRA" ]
check "no closure paths missing from the target" [ -z "$MISSING" ]
[ -z "$EXTRA$MISSING" ] || printf 'extra:\n%s\nmissing:\n%s\n' "$EXTRA" "$MISSING"
echo

echo "--- space ---"
df -h "$MNT" "$MNT/boot"
df -i "$MNT"
echo

echo "############ RESULT ############"
if [ "$VERIFY_FAILURES" -ne 0 ]; then
  echo "VERIFICATION FAILED: $VERIFY_FAILURES check(s) reported FAIL."
  exit 1
fi
echo "All image-file checks passed. Not proven here: that it boots."
