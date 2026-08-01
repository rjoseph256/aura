#!/usr/bin/env bash
# A `RideInstant` may only be built from parts in one place.
#
# The whole point of the type is that its two halves were read at the same instant on two real
# clocks. Anything under Sources/ that builds one from a `Date` is inventing a monotonic reading
# from a wall clock, which silently reintroduces ROH-130 while the types still line up. Tests do
# exactly that on purpose, which is why this scans Sources/ only.
set -euo pipefail
cd "$(dirname "$0")/.."

SCAN_ROOTS=(AuraCore/Sources Aura/Sources Aura/Widgets)
OWNER='AuraCore/Sources/AuraCore/Ride/RideInstant.swift'

# The tell is the argument label, not the type name: `RideInstant(date:monotonicSeconds:)` and
# `.init(date:monotonicSeconds:)` both carry it. A property read (`instant.monotonicSeconds`) does
# not, and neither does a local named for it.
detect() { sed -E 's|//.*$||' | grep -E 'monotonicSeconds:' || true; }

self_test() {
  local bad='x.swift:1:  let i = RideInstant(date: d, monotonicSeconds: d.timeIntervalSinceReferenceDate)'
  [ -n "$(printf '%s\n' "$bad" | detect)" ] || { echo "SELF-TEST FAIL: missed a fabricated pair"; exit 2; }
  local bad_init='x.swift:1:  let i: RideInstant = .init(date: d, monotonicSeconds: 0)'
  [ -n "$(printf '%s\n' "$bad_init" | detect)" ] || { echo "SELF-TEST FAIL: missed a .init form"; exit 2; }
  local ok='x.swift:1:  // monotonicSeconds: only RideInstant.swift may build one'
  [ -z "$(printf '%s\n' "$ok" | detect)" ] || { echo "SELF-TEST FAIL: flagged a comment"; exit 2; }
  local ok_read='x.swift:1:  let s = instant.monotonicSeconds - start'
  [ -z "$(printf '%s\n' "$ok_read" | detect)" ] || { echo "SELF-TEST FAIL: flagged a property read"; exit 2; }
}

self_test

for root in "${SCAN_ROOTS[@]}"; do
  if [ ! -d "$root" ]; then
    echo "FAIL: scan root '$root' does not exist — check-monotonic-instants.sh is stale"
    exit 1
  fi
done

if [ ! -f "$OWNER" ]; then
  echo "FAIL: '$OWNER' does not exist — check-monotonic-instants.sh is stale"
  exit 1
fi

offenders=$(grep -rn 'monotonicSeconds:' --include='*.swift' "${SCAN_ROOTS[@]}" \
  | grep -v "^${OWNER}:" | detect || true)

if [ -n "$offenders" ]; then
  echo "FAIL: a RideInstant may only be built from parts in ${OWNER}. Built at:"
  echo "$offenders"
  exit 1
fi

echo "PASS: no fabricated RideInstant outside ${OWNER} (self-test OK)."
