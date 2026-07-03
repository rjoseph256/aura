#!/usr/bin/env bash
# Validates the bundled Aura terrain style JSON. Enforces the ROH-6 global constraints so a
# drift-introducing edit (incl. Task 6's on-device colour tuning) fails CI, not silently on-device:
#   - valid JSON, style version 8, glyphs + sprite present
#   - required vector (mapbox-streets-v8) + terrain-DEM (mapbox-terrain-dem-v1) sources, wired right
#   - a hillshade layer that references the DEM source
#   - signal-colour headroom: no reserved signal hue (lime/amber/pink) and no white/near-white in
#     any layer *-color paint (protects the route line + the white "you" peer-dot; no white casings)
#   - fully static: no animated / time-of-day / transition expressions anywhere
set -euo pipefail
STYLE="${1:-Aura/Resources/AuraTerrainStyle.json}"

validate() {
  local f="$1"
  python3 - "$f" <<'PY'
import json, sys, re
f = sys.argv[1]
try:
    s = json.load(open(f))
except Exception as e:
    print(f"FAIL: {f} is not valid JSON: {e}"); sys.exit(1)

errs = []

# --- structure ---
if s.get("version") != 8: errs.append("style version must be 8")
if "glyphs" not in s: errs.append("missing glyphs")
if "sprite" not in s: errs.append("missing sprite")

sources = s.get("sources", {}) if isinstance(s.get("sources"), dict) else {}
def source_by_url(sub):
    for sid, src in sources.items():
        if isinstance(src, dict) and sub in str(src.get("url", "")):
            return sid, src
    return None, None
vec_id, vec = source_by_url("mapbox.mapbox-streets-v8")
if vec is None or vec.get("type") != "vector":
    errs.append("missing/misconfigured vector source mapbox-streets-v8 (must be type 'vector')")
dem_id, dem = source_by_url("mapbox.mapbox-terrain-dem-v1")
if dem is None or dem.get("type") != "raster-dem":
    errs.append("missing/misconfigured terrain-dem source (must be type 'raster-dem')")

layers = s.get("layers", []) if isinstance(s.get("layers"), list) else []
hill = [l for l in layers if isinstance(l, dict) and l.get("type") == "hillshade"]
if not hill:
    errs.append("missing hillshade layer")
elif dem_id is not None and not any(l.get("source") == dem_id for l in hill):
    errs.append("hillshade layer does not reference the terrain-DEM source")

# --- static guardrail: no animated / time-of-day / transition expressions anywhere ---
def walk_keys(node):
    if isinstance(node, dict):
        for k, v in node.items():
            yield k
            yield from walk_keys(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk_keys(v)
FORBIDDEN_KEYS = {"sky", "transition", "raster-fade-duration", "fill-extrusion-height", "feature-state"}
animated = False
for k in walk_keys(s):
    if not isinstance(k, str): continue
    if k in FORBIDDEN_KEYS or k.endswith("-transition"):
        animated = True; break
if not animated:
    for l in layers:
        if isinstance(l, dict) and l.get("type") == "sky":
            animated = True; break
if animated:
    errs.append("style declares an animated/time-varying property (transition/sky/feature-state/etc.)")

# --- signal-colour headroom: no reserved hue and no white/near-white in layer *-color paint ---
RESERVED = {"#c8fa4b": "lime", "#f5c24b": "amber", "#ff4d9d": "pink"}
def expand_hex(h):
    h = h.strip().lower()
    m = re.fullmatch(r"#([0-9a-f]{3,8})", h)
    if not m: return None
    d = m.group(1)
    if len(d) == 3: d = "".join(c*2 for c in d)          # #rgb -> #rrggbb
    if len(d) in (4,):  d = "".join(c*2 for c in d)      # #rgba -> #rrggbbaa
    if len(d) < 6: return None
    return "#" + d[:6]                                    # ignore alpha for hue/luminance
def channels(hex6):
    return int(hex6[1:3],16), int(hex6[3:5],16), int(hex6[5:7],16)
def collect_colors(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(k, str) and k.endswith("-color") and isinstance(v, str):
                yield k, v
            else:
                yield from collect_colors(v)
    elif isinstance(node, list):
        for v in node:
            yield from collect_colors(v)
NEAR_WHITE = 0xC8  # 200: all channels this high reads as white/near-white (forbids white casings)
for l in layers:
    if not isinstance(l, dict): continue
    for k, v in collect_colors(l.get("paint", {})):
        low = v.strip().lower()
        for hue, name in RESERVED.items():
            if hue in low:
                errs.append(f"layer '{l.get('id','?')}' {k} uses reserved signal colour {name} ({v})")
        hx = expand_hex(low)
        if hx:
            r, g, b = channels(hx)
            if r >= NEAR_WHITE and g >= NEAR_WHITE and b >= NEAR_WHITE:
                errs.append(f"layer '{l.get('id','?')}' {k} is white/near-white ({v}) — no white casings")

if errs:
    print("FAIL: " + "; ".join(errs)); sys.exit(1)
print(f"PASS: {f} valid (sources+hillshade+glyphs+sprite, cool-only, static).")
PY
}

# Self-test: fixtures are generated in one python pass (no shell quoting/brace-expansion hazards).
# Each bad fixture exercises a distinct guard branch and must be REJECTED; the good one must PASS.
self_test() {
  local tmp; tmp="$(mktemp -d)"
  python3 - "$tmp" <<'PY'
import json, os, sys, copy
tmp = sys.argv[1]
good = {
    "version": 8, "glyphs": "g", "sprite": "s",
    "sources": {
        "composite": {"type": "vector", "url": "mapbox://mapbox.mapbox-streets-v8"},
        "dem": {"type": "raster-dem", "url": "mapbox://mapbox.mapbox-terrain-dem-v1"}},
    "layers": [
        {"id": "hillshade", "type": "hillshade", "source": "dem",
         "paint": {"hillshade-shadow-color": "#05080A"}},
        {"id": "bg", "type": "background", "paint": {"background-color": "#0D1411"}}]}
def w(name, obj): json.dump(obj, open(os.path.join(tmp, name), "w"))
w("good.json", good)
w("not_a_style.json", {"not": "a style"})
d = copy.deepcopy(good); d["layers"][1]["paint"]["background-color"] = "#C8FA4B"; w("reserved_lime.json", d)
d = copy.deepcopy(good); d["layers"][1]["paint"]["background-color"] = "#FFFFFF"; w("white_casing.json", d)
d = copy.deepcopy(good); d["layers"][1]["paint"]["background-color-transition"] = {"duration": 300}; w("animated_transition.json", d)
d = copy.deepcopy(good); d["layers"].append({"id": "sky", "type": "sky"}); w("sky_layer.json", d)
d = copy.deepcopy(good); d["sources"]["dem"]["type"] = "vector"; w("bad_dem.json", d)
PY
  local bad
  for bad in not_a_style reserved_lime white_casing animated_transition sky_layer bad_dem; do
    if validate "$tmp/$bad.json" >/dev/null 2>&1; then
      echo "SELF-TEST FAIL: validator passed a bad style ($bad)"; rm -rf "$tmp"; exit 1
    fi
  done
  # the known-good minimal style must PASS (guards against over-strict false failures)
  if ! validate "$tmp/good.json" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: validator rejected a valid style"; rm -rf "$tmp"; exit 1
  fi
  rm -rf "$tmp"
}

self_test
validate "$STYLE"
