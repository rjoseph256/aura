#!/usr/bin/env bash
# Validates the bundled Aura terrain style JSON. Enforces the ROH-6 global constraints so a
# drift-introducing edit (incl. Task 6's on-device colour tuning) fails CI, not silently on-device:
#   - valid JSON, style version 8, glyphs + sprite present
#   - required vector (mapbox-streets-v8) + terrain-DEM (mapbox-terrain-dem-v1) sources, wired right
#   - a hillshade layer that references the DEM source
#   - signal-colour headroom: no reserved signal hue (mint/amber/pink) and no white/near-white in
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

# --- street labels (ROH-86): an interactive, pan/pinch-zoomable map must label streets when
# zoomed in, but stay label-free at the far-out Home framing. Require a road-label symbol layer
# (source-layer 'road') that is zoom-gated (a minzoom, or a zoom-interpolated text-opacity), so a
# future edit can't silently drop street labels OR splash them across the calm far-out snapshot.
road_labels = [l for l in layers if isinstance(l, dict)
               and l.get("type") == "symbol" and l.get("source-layer") == "road"]
if not road_labels:
    errs.append("missing a road-label symbol layer (source-layer 'road') — streets unlabeled at close zoom")
else:
    def zoom_gated(l):
        # Home's far-out snapshot renders at zoom 12.5 (HomeMapCamera.defaultZoom); a minzoom
        # gate only keeps that framing calm if it sits strictly above 12.5.
        mz = l.get("minzoom")
        if isinstance(mz, (int, float)) and mz > 12.5:
            return True
        return "\"zoom\"" in json.dumps(l.get("paint", {}).get("text-opacity"))
    if not any(zoom_gated(l) for l in road_labels):
        errs.append("road-label layer is not zoom-gated (needs minzoom>12.5 or a zoom-based text-opacity) — would clutter far-out Home")

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
RESERVED = {"#7cf0a8": "mint", "#f5c24b": "amber", "#ff4d9d": "pink"}
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
def strings_in(node):
    # every string anywhere under `node` (a plain colour string OR a colour stop buried in a
    # Mapbox expression array like ["interpolate",["linear"],["zoom"],10,"#FFF",14,"#5A6470"]).
    if isinstance(node, str):
        yield node
    elif isinstance(node, list):
        for v in node:
            yield from strings_in(v)
    elif isinstance(node, dict):
        for v in node.values():
            yield from strings_in(v)
def collect_colors(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(k, str) and k.endswith("-color"):
                for s in strings_in(v):   # catches expression-valued paint, not just plain strings
                    yield k, s
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
        {"id": "bg", "type": "background", "paint": {"background-color": "#0D1411"}},
        {"id": "road-label", "type": "symbol", "source": "composite", "source-layer": "road",
         "minzoom": 13,
         "layout": {"symbol-placement": "line", "text-field": ["get", "name"]},
         "paint": {"text-color": "#A7B0BB",
                   "text-opacity": ["interpolate", ["linear"], ["zoom"], 13, 0, 15, 1]}}]}
def w(name, obj): json.dump(obj, open(os.path.join(tmp, name), "w"))
w("good.json", good)
w("not_a_style.json", {"not": "a style"})
# a style with no road-label symbol layer must be rejected (the ROH-86 regression)
d = copy.deepcopy(good); d["layers"] = [l for l in d["layers"] if l["id"] != "road-label"]; w("no_road_label.json", d)
# a road-label present but ungated (labels at every zoom, incl. far-out Home) must be rejected
d = copy.deepcopy(good)
for l in d["layers"]:
    if l["id"] == "road-label":
        del l["minzoom"]; l["paint"]["text-opacity"] = 1
w("ungated_road_label.json", d)
# a minzoom that still shows at the 12.5 Home framing (<= 12.5) with flat opacity must be rejected
d = copy.deepcopy(good)
for l in d["layers"]:
    if l["id"] == "road-label":
        l["minzoom"] = 12; l["paint"]["text-opacity"] = 1
w("low_minzoom_road_label.json", d)
d = copy.deepcopy(good); d["layers"][1]["paint"]["background-color"] = "#7CF0A8"; w("reserved_mint.json", d)
d = copy.deepcopy(good); d["layers"][1]["paint"]["background-color"] = "#FFFFFF"; w("white_casing.json", d)
# a reserved hue hidden inside a zoom-interpolated expression must also be rejected
d = copy.deepcopy(good)
d["layers"][0]["paint"]["hillshade-highlight-color"] = ["interpolate", ["linear"], ["zoom"], 10, "#5A6470", 16, "#7CF0A8"]
w("expr_mint.json", d)
d = copy.deepcopy(good); d["layers"][1]["paint"]["background-color-transition"] = {"duration": 300}; w("animated_transition.json", d)
d = copy.deepcopy(good); d["layers"].append({"id": "sky", "type": "sky"}); w("sky_layer.json", d)
d = copy.deepcopy(good); d["sources"]["dem"]["type"] = "vector"; w("bad_dem.json", d)
PY
  local bad
  for bad in not_a_style reserved_mint white_casing expr_mint animated_transition sky_layer bad_dem no_road_label ungated_road_label low_minzoom_road_label; do
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
