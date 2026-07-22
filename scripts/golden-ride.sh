#!/usr/bin/env bash
# scripts/golden-ride.sh — build + run the ROH-92 golden-ride E2E locally.
# Usage: scripts/golden-ride.sh [simulator-name]   (default: iPhone 17)
set -euo pipefail
cd "$(dirname "$0")/.."
SIM_NAME="${1:-iPhone 17}"

if [ ! -s Aura/Resources/MapboxAccessToken ]; then
  echo "error: Aura/Resources/MapboxAccessToken missing — see .mapbox-setup.md" >&2
  exit 1
fi

(cd Aura && xcodegen generate)

UDID=$(xcrun simctl list -j devices available | jq -r --arg name "$SIM_NAME" '
  .devices | to_entries | map(select(.key | contains("iOS"))) | sort_by(.key)
  | map(.value | map(select(.isAvailable and .name == $name))) | flatten
  | last | .udid')
if [ -z "$UDID" ] || [ "$UDID" = "null" ]; then
  echo "error: no available simulator named '$SIM_NAME'" >&2
  exit 1
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" grant location com.rohunjoseph.aura || true

cd Aura
xcodebuild build-for-testing -project Aura.xcodeproj -scheme Aura -configuration Debug \
  -destination "id=$UDID" -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild test-without-building -project Aura.xcodeproj -scheme Aura -configuration Debug \
  -destination "id=$UDID" -derivedDataPath DerivedData \
  -only-testing:AuraUITests/RideE2EUITests CODE_SIGNING_ALLOWED=NO
