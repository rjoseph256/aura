#!/usr/bin/env bash
# Active time has exactly one definition: `RideDuration.activeSeconds`.
#
# Three sites compute it — the HUD's, the Live Activity's running branch, and the finished
# ride's — and parent spec D5 requires that they agree, because the rider must see the same clock
# after the ride that they watched during it. The Live Activity's paused branch is no longer a
# fourth: it carries a value `RideRecorder.pause(at:)` froze at the tap rather than computing one.
# Two of them were separately-written subtractions until ROH-112, and the rendered one was nearly
# missed. A comment asking future authors not to re-derive it is the kind of request this repo has
# watched get ignored, so this is a build gate.
#
# The second detector — `betweenStamps` — is a different failure: a live caller can derive elapsed
# from a pair of `Date`s and still call the one definition, which reintroduces ROH-130 while
# passing every check above. `RideElapsed.betweenStamps` is legal for a finished ride's two stamps
# and nothing else. It is matched as a bare token on purpose: a regex over the whole call could be
# walked past by a line wrapped at the 140-column limit, and a single token cannot be.
set -euo pipefail
cd "$(dirname "$0")/.."

SCAN_ROOTS=(AuraCore/Sources Aura/Sources Aura/Widgets)

# Detector: reads `path:line:content` (or raw) lines on stdin, strips from the first `//` to end
# of line (so a doc comment or a trailing-comment mention doesn't trip the guard), and prints any
# line that still re-derives active time by subtracting or adding pausedSeconds by hand.
detect() {
  sed -E 's|//.*$||' | grep -E \
    '(-[[:space:]]*[A-Za-z_.]*[Pp]ausedSeconds)|(addingTimeInterval\([A-Za-z_.]*[Pp]ausedSeconds)|(betweenStamps)' \
    || true
}

# Self-test so the guard's own correctness is proven on every run, not assumed. Covers the
# reviewer's two false-negative classes: an unanchored comment filter that drops any line
# containing "://" (a real derivation could sit on a line with a URL), and a comment-only mention
# that must NOT trip the guard.
self_test() {
  local bad='x.swift:1:        let x = now.timeIntervalSince(startedAt) - pausedSeconds'
  [ -n "$(printf '%s\n' "$bad" | detect)" ] || { echo "SELF-TEST FAIL: missed a real re-derivation"; exit 2; }
  local bad_url='x.swift:1:        let x = now.timeIntervalSince(startedAt) - pausedSeconds // see https://example.com/pausedSeconds'
  [ -n "$(printf '%s\n' "$bad_url" | detect)" ] || { echo "SELF-TEST FAIL: missed a re-derivation on a line containing a URL"; exit 2; }
  local bad_wall='x.swift:1:      elapsed: .betweenStamps(startedAt: startedAt, endedAt: now),'
  [ -n "$(printf '%s\n' "$bad_wall" | detect)" ] || { echo "SELF-TEST FAIL: missed a wall-derived elapsed"; exit 2; }
  local ok_mono='x.swift:1:      elapsed: .measured(r.elapsedSeconds(asOf: now)),'
  [ -z "$(printf '%s\n' "$ok_mono" | detect)" ] || { echo "SELF-TEST FAIL: flagged a monotonic elapsed"; exit 2; }
  local ok='x.swift:1:        // pausedSeconds is subtracted inside RideDuration.activeSeconds'
  [ -z "$(printf '%s\n' "$ok" | detect)" ] || { echo "SELF-TEST FAIL: flagged a comment-only mention"; exit 2; }
}

self_test

# Each scan root must exist: `grep -r` on a missing directory exits 2 ("no such file or
# directory"), which the old `|| true` swallowed right along with "no matches", so a renamed or
# moved root made this guard pass vacuously forever while scanning nothing.
for root in "${SCAN_ROOTS[@]}"; do
  if [ ! -d "$root" ]; then
    echo "FAIL: scan root '$root' does not exist — check-single-active-definition.sh is stale"
    exit 1
  fi
done

offenders=$(grep -rn \
  -E '(-[[:space:]]*[A-Za-z_.]*[Pp]ausedSeconds)|(addingTimeInterval\([A-Za-z_.]*[Pp]ausedSeconds)|(betweenStamps)' \
  --include='*.swift' "${SCAN_ROOTS[@]}" \
  | grep -v 'AuraCore/Sources/AuraCore/Ride/RideDuration.swift' \
  | detect || true)

if [ -n "$offenders" ]; then
  echo "FAIL: active time must come from RideDuration.activeSeconds. Re-derived at:"
  echo "$offenders"
  exit 1
fi

echo "PASS: no re-derivation of active time outside RideDuration.activeSeconds (self-test OK)."
