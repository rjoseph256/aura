#!/usr/bin/env bash
# Guards the "Free ride" -> "Explore" rename: fails if any user-facing surface still
# renders "free ride" (case-insensitive). Comment lines (/// or //) are stripped before
# matching, and the frozen identifiers are excluded, so only rendered strings count.
#
# Frozen (must stay): the `.freeRide` enum case, the persisted "freeRide" raw value,
# RideActivityMode.freeRide, AppRoute/DeepLink, and RideMapper's `?? .freeRide`.
set -euo pipefail

matches=$(grep -rniE 'free ride' --include="*.swift" Aura \
  | grep -vE ':[[:space:]]*//' \
  | grep -viE 'freeRide|\.freeRide|RideActivityMode|Ride\.Kind|AppRoute|DeepLink' || true)

if [ -n "$matches" ]; then
  echo "FAIL: user-facing 'free ride' strings remain:"
  echo "$matches"
  exit 1
fi
echo "PASS: no user-facing 'free ride' strings."
