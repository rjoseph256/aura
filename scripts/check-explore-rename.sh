#!/usr/bin/env bash
# Guards the "Free ride" -> "Explore" rename: fails if any user-facing surface still
# renders the phrase "free ride" (case-insensitive).
#
# Why this is safe for the frozen identifiers: the phrase match requires a SPACE
# ("free ride"), while every frozen identifier is camelCase with no space
# (`.freeRide`, `"freeRide"`, `RideActivityMode.freeRide`, etc.), so they can never
# match — no fragile whole-line exclusion is needed. Comments (`//`, `///`, and inline
# trailing comments) are stripped per line before matching, so doc/MARK comments that
# still mention the old term don't trip the guard while a real rendered string does.
set -euo pipefail

# Detector: reads `path:line:content` (or raw) lines on stdin, strips from the first
# `//` to end of line, and prints any line that still contains the phrase "free ride".
detect() {
  sed -E 's|//.*$||' | grep -iE 'free ride' || true
}

# Corpus scan: greps the given directories and runs the detector. grep's exit 1
# means "no match", which for this guard is the SUCCESS end-state the rename is
# aiming for — under `set -euo pipefail` a bare pipeline turned that into a
# silent fatal (ROH-158: the guard died at this line with empty output the
# moment the last stale comment disappeared). Only exit >1 is a real error
# (unreadable/missing directory), and that must stay loud, not be swallowed.
scan() {
  # A missing scan root is checked explicitly: grep flavors disagree on the
  # exit code for a nonexistent path (GNU/BSD say 2, ugrep warns and says 1),
  # so an exit-code test alone is not portable. The rc>1 branch stays as a
  # backstop for other grep errors.
  #
  # Error text goes to STDERR: scan is only ever called inside a command
  # substitution, and a message on stdout is captured into the variable and
  # discarded when the substitution's exit kills the script — the silent-death
  # shape ROH-158 was filed about, reintroduced for a different input (both
  # round-2 reviewers reproduced it through the real gate).
  local d
  for d in "$@"; do
    [ -d "$d" ] || { echo "FAIL: scan directory missing: $d" >&2; exit 2; }
  done
  local raw rc=0
  raw="$(grep -rniE 'free ride' --include="*.swift" "$@")" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "FAIL: grep error (exit $rc) while scanning: $*" >&2
    exit 2
  fi
  printf '%s\n' "$raw" | detect
}

# Self-test so the guard's own correctness is proven on every run (the reviewer's
# false-PASS class: a real user string coexisting with a frozen identifier on one line).
self_test() {
  local bad='x.swift:1: kind == .freeRide ? "Navigated" : "Free ride"'
  [ -n "$(printf '%s\n' "$bad" | detect)" ] || { echo "SELF-TEST FAIL: missed a coexisting user string"; exit 2; }
  local ident='x.swift:1: case .freeRide: return mode'
  [ -z "$(printf '%s\n' "$ident" | detect)" ] || { echo "SELF-TEST FAIL: flagged the freeRide identifier"; exit 2; }
  local comment='x.swift:1:    /// "Free ride" — legacy note'
  [ -z "$(printf '%s\n' "$comment" | detect)" ] || { echo "SELF-TEST FAIL: flagged a comment"; exit 2; }
  # The empty-corpus path is the one that actually broke (ROH-158): a tree with
  # no mention of the phrase at all must scan to empty output and survive, not
  # die inside scan. Run the REAL scan function against a real clean directory.
  local lab
  lab="$(mktemp -d)" && [ -d "$lab" ] || { echo "SELF-TEST FAIL: mktemp -d failed"; exit 2; }
  printf 'struct Clean {}\n' >"$lab/Clean.swift"
  local out rc=0
  out="$(scan "$lab")" || rc=$?
  rm -rf "$lab"
  [ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "SELF-TEST FAIL: clean corpus should scan empty (exit $rc, out: $out)"; exit 2; }
  # And a scan of a missing directory is a real error that must be LOUD — the
  # || true class of fix would swallow it into a false PASS. The capture takes
  # ONLY stderr (2>&1 >/dev/null): the production call site discards scan's
  # stdout into a substitution, so a message there is a message nowhere, and a
  # self-test that folded the streams together could not tell the difference.
  local missing_rc=0 err
  err="$(scan "$lab/does-not-exist" 2>&1 >/dev/null)" || missing_rc=$?
  [ "$missing_rc" -ne 0 ] && [ -n "$err" ] || { echo "SELF-TEST FAIL: missing directory must fail loudly on stderr (exit $missing_rc)"; exit 2; }
}

self_test
# Scope to the shipping surfaces (app sources + widgets), NOT test code — a UI test may
# legitimately assert the OLD copy is absent (e.g. buttons["Free ride"] does not exist).
# The if-guard keeps a scan error LOUD at this call site: a bare `matches=$(scan ...)`
# under set -e dies inside the substitution with scan's stdout captured and unread.
if ! matches=$(scan Aura/Sources Aura/Widgets); then
  echo "FAIL: explore-rename scan errored; see the message above." >&2
  exit 2
fi
if [ -n "$matches" ]; then
  echo "FAIL: user-facing 'free ride' strings remain:"
  echo "$matches"
  exit 1
fi
echo "PASS: no user-facing 'free ride' strings (self-test OK)."
