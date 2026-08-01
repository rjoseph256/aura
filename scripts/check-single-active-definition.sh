#!/usr/bin/env bash
# Active time has exactly one definition: `RideDuration.activeSeconds`.
#
# Three clocks compute it — the HUD's, both branches of the Live Activity's, and the finished
# ride's — and parent spec D5 requires that they agree, because the rider must see the same clock
# after the ride that they watched during it. Two of them were separately-written subtractions
# until ROH-112, and the rendered one was nearly missed. A comment asking future authors not to
# re-derive it is the kind of request this repo has watched get ignored, so this is a build gate.
set -euo pipefail
cd "$(dirname "$0")/.."

offenders=$(grep -rnE \
  '(-[[:space:]]*[A-Za-z_.]*[Pp]ausedSeconds)|(addingTimeInterval\([A-Za-z_.]*[Pp]ausedSeconds)' \
  --include='*.swift' AuraCore/Sources Aura/Sources Aura/Widgets \
  | grep -vE ':[[:space:]]*//' \
  | grep -v 'AuraCore/Sources/AuraCore/Ride/RideDuration.swift' || true)

if [ -n "$offenders" ]; then
  echo "Active time must come from RideDuration.activeSeconds. Re-derived at:"
  echo "$offenders"
  exit 1
fi
