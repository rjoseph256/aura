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

# Self-test so the guard's own correctness is proven on every run (the reviewer's
# false-PASS class: a real user string coexisting with a frozen identifier on one line).
self_test() {
  local bad='x.swift:1: kind == .freeRide ? "Navigated" : "Free ride"'
  [ -n "$(printf '%s\n' "$bad" | detect)" ] || { echo "SELF-TEST FAIL: missed a coexisting user string"; exit 2; }
  local ident='x.swift:1: case .freeRide: return mode'
  [ -z "$(printf '%s\n' "$ident" | detect)" ] || { echo "SELF-TEST FAIL: flagged the freeRide identifier"; exit 2; }
  local comment='x.swift:1:    /// "Free ride" — legacy note'
  [ -z "$(printf '%s\n' "$comment" | detect)" ] || { echo "SELF-TEST FAIL: flagged a comment"; exit 2; }
}

self_test
# Scope to the shipping surfaces (app sources + widgets), NOT test code — a UI test may
# legitimately assert the OLD copy is absent (e.g. buttons["Free ride"] does not exist).
matches=$(grep -rniE 'free ride' --include="*.swift" Aura/Sources Aura/Widgets | detect)
if [ -n "$matches" ]; then
  echo "FAIL: user-facing 'free ride' strings remain:"
  echo "$matches"
  exit 1
fi
echo "PASS: no user-facing 'free ride' strings (self-test OK)."
