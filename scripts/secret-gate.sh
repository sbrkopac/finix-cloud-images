#!/usr/bin/env bash
# Fails if the tree holds a crypt hash, an email address or a credential.
# Run it before every commit; CI runs it too.
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERNS=(
  '\$(6|y|2b)\$[A-Za-z0-9./]{8,}\$[A-Za-z0-9./]{8,}'
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[a-z]{2,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY'
  'dop_v1_[a-f0-9]{16,}'
  'AKIA[0-9A-Z]{16}'
)

# user@<placeholder> and user@host in command examples are not addresses, and
# neither is an action reference such as actions/checkout@v4.
ALLOW='@<|@example\.com|uses: [A-Za-z0-9._/-]+@'

status=0
for pattern in "${PATTERNS[@]}"; do
  hits=$(grep -rnIE --exclude-dir=.git --exclude=secret-gate.sh -e "$pattern" . | grep -vE "$ALLOW" || true)
  if [ -n "$hits" ]; then
    echo "GATE FAILED: $pattern"
    echo "$hits"
    status=1
  fi
done

[ "$status" = 0 ] && echo "secret gate: clean"
exit "$status"
