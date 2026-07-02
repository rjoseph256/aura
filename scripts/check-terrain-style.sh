#!/usr/bin/env bash
# Validates the bundled Aura terrain style JSON: parses, declares the required sources/layers,
# has glyphs+sprite, and contains NO animated/time-of-day expressions (the static guardrail).
set -euo pipefail
STYLE="${1:-Aura/Resources/AuraTerrainStyle.json}"

validate() {
  local f="$1"
  python3 - "$f" <<'PY'
import json, sys
f = sys.argv[1]
try:
    s = json.load(open(f))
except Exception as e:
    print(f"FAIL: {f} is not valid JSON: {e}"); sys.exit(1)
errs = []
if s.get("version") != 8: errs.append("style version must be 8")
if "glyphs" not in s: errs.append("missing glyphs")
if "sprite" not in s: errs.append("missing sprite")
srcs = s.get("sources", {})
blob = json.dumps(s)
if "mapbox.mapbox-streets-v8" not in blob: errs.append("missing vector source mapbox-streets-v8")
if "mapbox.mapbox-terrain-dem-v1" not in blob: errs.append("missing terrain-dem source")
types = {l.get("type") for l in s.get("layers", [])}
if "hillshade" not in types: errs.append("missing hillshade layer")
# Static guardrail: forbid time-varying / animated properties anywhere in the style.
import re
if re.search(r'"(sky|raster-fade-duration|fill-extrusion-height|line-dasharray-transition)"', blob) \
   or "feature-state" in blob:
    errs.append("style declares an animated/time-varying property")
if errs:
    print("FAIL: " + "; ".join(errs)); sys.exit(1)
print(f"PASS: {f} valid (sources+hillshade+glyphs+sprite, static).")
PY
}

self_test() {
  local tmp; tmp="$(mktemp -d)"
  echo '{ "not": "a style" }' > "$tmp/bad.json"
  if validate "$tmp/bad.json" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: validator passed an invalid style"; rm -rf "$tmp"; exit 1
  fi
  rm -rf "$tmp"
}

self_test
validate "$STYLE"
