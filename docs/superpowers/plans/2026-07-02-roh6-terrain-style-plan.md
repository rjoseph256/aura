# ROH-6 — Aura Custom Terrain Style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship Aura's own charcoal-green, hill-shaded terrain style as a bundled JSON that the Home backdrop snapshotter renders via `styleJSON`, replacing the generic dark preset.

**Architecture:** The authored style is a version-controlled JSON resource in the app target, composed from Mapbox's vector + terrain-DEM sources with hosted glyphs/sprite. `MapboxTerrainSnapshotter` loads it, gates the capture on `onStyleLoaded`, and falls back to the dark preset on any failure. `TerrainStyle` (pure AuraKit) gains a `styleVersion` + a version-bearing `authoredStyleIdentity` used both to signal "render the authored style" and to key the snapshot cache so a restyle invalidates old images. A CI script validates the JSON (pure AuraKit can't read an app resource, and there's no app unit-test bundle).

**Tech Stack:** Swift 6, SwiftUI, MapboxMaps v11 (`Snapshotter`, `styleJSON`, `onStyleLoaded`), Swift Testing (AuraKit), bash (CI validator), xcodegen.

## Global Constraints

- **Bundled JSON, no Studio / no `styles:write`.** The style is `Aura/Resources/AuraTerrainStyle.json`, rendered via `Snapshotter.styleJSON`. Token reads (styles/fonts/sprite/tiles/DEM) are confirmed `200`.
- **Palette (verbatim):** base `nearBlack #07080C` shifts to a deep charcoal-green; `lime #C8FA4B`, `amber #F5C24B`, `pink #FF4D9D` are unchanged and **reserved for signals — never used by the base map**.
- **Signal-colour headroom:** the base style uses only cool/neutral/dark tones. No lime/amber/warm/white in map layers; **no light/white road casings** (protects the white "you" peer-dot). Chunk 3 pins peer-dot values against this style.
- **Fully static:** the JSON declares no animated or time-of-day-driven expressions. Must stay static even if reused for the live map.
- **Explicit paint:** every paint property used is set explicitly; no reliance on omitted Mapbox defaults.
- **ROH-7:** no live map — the backdrop stays an off-map `Snapshotter` raster.
- **Purity:** `TerrainStyle` imports only Foundation (no MapboxMaps); the JSON load + SDK bridge live in the app target.
- **Fallback:** on missing/unparseable JSON or a load error/timeout, render `TerrainStyle.fallbackStyleURI` (dark preset) so Home never breaks.
- **Device-first:** final relief-intensity + label-density are chosen from 2–3 on-device variants; the style must read at a sub-second glance in bright sun (Chunk 0 bar).

## File Structure

- `AuraCore/Sources/AuraKit/Home/TerrainStyle.swift` (modify) — add `styleVersion`, `authoredStyleIdentity`, `authoredStyleResource`; rework `isCustom` to an identity check; drop unused `customStyleURI`.
- `AuraCore/Tests/AuraKitTests/TerrainStyleTests.swift` (modify) — update `isCustom` test; add version/identity tests.
- `Aura/Resources/AuraTerrainStyle.json` (create) — the authored style (auto-bundled by the existing `- path: Resources` glob; `.json` is a recognized resource type).
- `scripts/check-terrain-style.sh` (create) — CI validator (required sources/layers/glyphs/sprite; forbids animated expressions; self-test). Wired into the `lint` job in `.github/workflows/ci.yml`.
- `Aura/Sources/Home/AuraTerrainStyleLoader.swift` (create) — reads the bundled JSON string from `Bundle.main`.
- `Aura/Sources/Home/MapboxTerrainSnapshotter.swift` (modify) — load JSON via the loader, set `styleJSON`, gate on `onStyleLoaded` + timeout, fall back to `fallbackStyleURI`.
- `Aura/Sources/Home/HomeBackdrop.swift` (modify) — pass `TerrainStyle.authoredStyleIdentity` as the request's style identity.

---

### Task 1: TerrainStyle — style version + authored identity + isCustom rework (pure, TDD)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Home/TerrainStyle.swift`
- Test: `AuraCore/Tests/AuraKitTests/TerrainStyleTests.swift`

**Interfaces:**
- Produces: `TerrainStyle.styleVersion: String`, `TerrainStyle.authoredStyleIdentity: String` (`"aura-terrain-v<version>"`), `TerrainStyle.authoredStyleResource: String` (`"AuraTerrainStyle"`), `TerrainStyle.isCustom(_ identity: String) -> Bool` (true iff the authored style), plus existing `fallbackStyleURI`, `resolve(custom:)`, `styleURI`.

- [ ] **Step 1: Update the failing tests**

Replace the `isCustomTrueOnlyForAuraAuthoredStyles` test and add version/identity tests in `TerrainStyleTests.swift`:

```swift
@Test func isCustomTrueOnlyForTheAuthoredIdentity() {
    #expect(TerrainStyle.isCustom(TerrainStyle.authoredStyleIdentity) == true)
    #expect(TerrainStyle.isCustom(TerrainStyle.fallbackStyleURI) == false)
    #expect(TerrainStyle.isCustom("mapbox://styles/mapbox/outdoors-v12") == false)
}

@Test func authoredIdentityCarriesTheVersion() {
    #expect(TerrainStyle.authoredStyleIdentity == "aura-terrain-v\(TerrainStyle.styleVersion)")
    #expect(TerrainStyle.authoredStyleIdentity != TerrainStyle.fallbackStyleURI)
}

@Test func authoredResourceIsTheBundledBaseName() {
    #expect(TerrainStyle.authoredStyleResource == "AuraTerrainStyle")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AuraCore && swift test --filter TerrainStyleTests`
Expected: FAIL (no `authoredStyleIdentity` / `styleVersion` / `authoredStyleResource`; `isCustom` still prefix-based).

- [ ] **Step 3: Implement**

Replace `TerrainStyle.swift` body with:

```swift
import Foundation

/// Resolves the Home terrain backdrop style. Pure (no MapboxMaps import) so it tests on the
/// macOS CI host; the app target bridges the authored JSON and the fallback URI to the SDK.
public enum TerrainStyle {
    /// Safe dark fallback, used only when the authored style fails to load.
    public static let fallbackStyleURI = "mapbox://styles/mapbox/dark-v11"

    /// Bump when `AuraTerrainStyle.json`'s look changes, to invalidate cached snapshots.
    public static let styleVersion = "1"

    /// Resource base name of the bundled authored style (`Aura/Resources/AuraTerrainStyle.json`).
    public static let authoredStyleResource = "AuraTerrainStyle"

    /// Cache-key identity for the authored style. Version-bearing so a restyle invalidates
    /// snapshots; also the signal the snapshotter uses to load the bundled JSON (vs a URI).
    public static var authoredStyleIdentity: String { "aura-terrain-v\(styleVersion)" }

    /// Pure selection kept for the fallback path. Tested directly.
    public static func resolve(custom: String?) -> String { custom ?? fallbackStyleURI }

    /// The fallback style URI the snapshotter uses when the authored style is unavailable.
    public static var styleURI: String { fallbackStyleURI }

    /// Whether `identity` is Aura's authored terrain style (not the fallback preset). Defined
    /// against the authored identity, so a stock Mapbox style never reads as the authored one.
    public static func isCustom(_ identity: String) -> Bool { identity.hasPrefix("aura-terrain") }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter TerrainStyleTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/TerrainStyle.swift AuraCore/Tests/AuraKitTests/TerrainStyleTests.swift
git commit -m "feat(roh6): TerrainStyle style version + authored identity; identity-based isCustom"
```

---

### Task 2: Authored style JSON asset (create + validator + CI)

This task delivers the style asset **and** its CI guard together (the guard is meaningless without the asset, and the asset must not ship unvalidated).

**Files:**
- Create: `Aura/Resources/AuraTerrainStyle.json`
- Create: `scripts/check-terrain-style.sh`
- Modify: `.github/workflows/ci.yml` (add a step to the `lint` job)

- [ ] **Step 1: Author the starting style JSON**

Create `Aura/Resources/AuraTerrainStyle.json`. This is the **starting** style (device-tuned in Task 6). It composes Mapbox vector + terrain-DEM sources with hosted glyphs/sprite (all token-verified), charcoal-green land, subtle cool hillshade, cool-grey roads with **no casings**, and muted labels. Colours are cool/neutral only — no lime/amber/white:

```json
{
  "version": 8,
  "name": "Aura Terrain",
  "metadata": { "aura:version": "1" },
  "glyphs": "mapbox://fonts/mapbox/{fontstack}/{range}.pbf",
  "sprite": "mapbox://sprites/mapbox/dark-v11",
  "sources": {
    "composite": { "type": "vector", "url": "mapbox://mapbox.mapbox-streets-v8" },
    "dem": { "type": "raster-dem", "url": "mapbox://mapbox.mapbox-terrain-dem-v1", "tileSize": 512 }
  },
  "layers": [
    { "id": "background", "type": "background",
      "paint": { "background-color": "#0D1411" } },
    { "id": "landuse-park", "type": "fill", "source": "composite", "source-layer": "landuse",
      "filter": ["match", ["get", "class"], ["park", "grass", "pitch"], true, false],
      "paint": { "fill-color": "#101A14", "fill-opacity": 1.0 } },
    { "id": "water", "type": "fill", "source": "composite", "source-layer": "water",
      "paint": { "fill-color": "#0A1418", "fill-opacity": 1.0 } },
    { "id": "hillshade", "type": "hillshade", "source": "dem",
      "paint": {
        "hillshade-exaggeration": 0.45,
        "hillshade-shadow-color": "#05080A",
        "hillshade-highlight-color": "#5A6470",
        "hillshade-accent-color": "#0D1411" } },
    { "id": "road-minor", "type": "line", "source": "composite", "source-layer": "road",
      "filter": ["match", ["get", "class"],
        ["street", "street_limited", "service", "track"], true, false],
      "paint": { "line-color": "#252C33",
        "line-width": ["interpolate", ["linear"], ["zoom"], 12, 0.4, 16, 2.0] } },
    { "id": "road-major", "type": "line", "source": "composite", "source-layer": "road",
      "filter": ["match", ["get", "class"],
        ["motorway", "trunk", "primary", "secondary", "tertiary"], true, false],
      "paint": { "line-color": "#3A434C",
        "line-width": ["interpolate", ["linear"], ["zoom"], 12, 0.8, 16, 3.5] } },
    { "id": "place-label", "type": "symbol", "source": "composite", "source-layer": "place_label",
      "filter": ["match", ["get", "class"],
        ["settlement", "settlement_subdivision"], true, false],
      "layout": {
        "text-field": ["get", "name_en"],
        "text-font": ["DIN Pro Medium", "Arial Unicode MS Regular"],
        "text-size": ["interpolate", ["linear"], ["zoom"], 10, 11, 14, 15],
        "text-max-width": 7 },
      "paint": { "text-color": "#8A94A0", "text-halo-color": "#07080C",
        "text-halo-width": 1.2, "text-opacity": 0.9 } }
  ]
}
```

- [ ] **Step 2: Write the CI validator with a self-test**

Create `scripts/check-terrain-style.sh` (mirrors `check-explore-rename.sh`: embedded self-test, non-zero exit on failure):

```bash
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
```

- [ ] **Step 3: Run the validator (fails first if the JSON is malformed, passes on the real asset)**

Run: `chmod +x scripts/check-terrain-style.sh && bash scripts/check-terrain-style.sh`
Expected: `PASS: Aura/Resources/AuraTerrainStyle.json valid (...)` and the self-test does not abort.

- [ ] **Step 4: Wire it into CI**

In `.github/workflows/ci.yml`, under the `lint` job, after the "Explore rename guard" step, add:

```yaml
      - name: Terrain style guard
        run: bash scripts/check-terrain-style.sh
```

- [ ] **Step 5: Commit**

```bash
git add Aura/Resources/AuraTerrainStyle.json scripts/check-terrain-style.sh .github/workflows/ci.yml
git commit -m "feat(roh6): authored terrain style JSON + CI validator"
```

---

### Task 3: AuraTerrainStyleLoader — load the bundled JSON (app target)

**Files:**
- Create: `Aura/Sources/Home/AuraTerrainStyleLoader.swift`

**Interfaces:**
- Consumes: `TerrainStyle.authoredStyleResource` (Task 1).
- Produces: `enum AuraTerrainStyleLoader { static func json(bundle: Bundle = .main) -> String? }` — the bundled style JSON string, or `nil` if the resource is missing/unreadable.

- [ ] **Step 1: Implement**

```swift
import Foundation
import AuraKit

/// Loads the bundled authored terrain style JSON. Returns nil (→ snapshotter falls back to the
/// dark preset) if the resource is absent or unreadable, so Home never breaks on a bad asset.
enum AuraTerrainStyleLoader {
    static func json(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: TerrainStyle.authoredStyleResource, withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }
}
```

- [ ] **Step 2: Build the app to confirm it compiles**

Delegate to the builder: regenerate the project (`cd Aura && xcodegen generate`) and `build-for-testing` for an iPhone simulator. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Home/AuraTerrainStyleLoader.swift
git commit -m "feat(roh6): bundled terrain-style JSON loader"
```

---

### Task 4: Snapshotter — render styleJSON, gate on load, fall back

**Files:**
- Modify: `Aura/Sources/Home/MapboxTerrainSnapshotter.swift`

**Interfaces:**
- Consumes: `AuraTerrainStyleLoader.json()` (Task 3), `TerrainStyle.isCustom(_:)`, `TerrainStyle.fallbackStyleURI` (Task 1), `request.styleURI` (now the style identity), `request.cacheKey`.

- [ ] **Step 1: Implement the JSON + gate + fallback path**

Replace the body of `image(for:size:)`. Key changes: when `request.styleURI` is the authored identity, load the bundled JSON and set `snapshotter.styleJSON`; otherwise set `styleURI` from the string. Gate `start()` on `onStyleLoaded` with a timeout; on any failure render the fallback preset.

```swift
func image(for request: TerrainSnapshotRequest, size: CGSize) async -> UIImage? {
    if let data = cache.read(request.cacheKey), let img = UIImage(data: data) { return img }
    guard size.width > 0, size.height > 0 else { return nil }

    let options = MapSnapshotOptions(
        size: size,
        pixelRatio: 3,
        glyphsRasterizationOptions: GlyphsRasterizationOptions(rasterizationMode: .ideographsRasterizedLocally))
    let snapshotter = Snapshotter(options: options)

    // Authored style → load the bundled JSON; anything else (or a missing JSON) → fallback URI.
    let authoredJSON = TerrainStyle.isCustom(request.styleURI) ? AuraTerrainStyleLoader.json() : nil
    if let authoredJSON {
        snapshotter.styleJSON = authoredJSON
    } else {
        guard let uri = StyleURI(rawValue: TerrainStyle.fallbackStyleURI) else { return nil }
        snapshotter.styleURI = uri
    }
    snapshotter.setCamera(to: CameraOptions(
        center: CLLocationCoordinate2D(latitude: request.center.latitude,
                                        longitude: request.center.longitude),
        zoom: 12.5, pitch: 0))
    snapshotter.onMapLoadingError.observe { error in
        print("[TerrainSnapshotter] style load error: \(error)")
    }.store(in: &tokens)

    // Setting styleJSON is a non-blocking assignment; wait for the style + its remote sources
    // to report loaded before capturing, or the raster can come back blank. Timeout so a stall
    // still resolves (start() will render whatever loaded — worst case the fallback).
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let done = OSAllocatedUnfairLock(initialState: false)
        func finishOnce() { done.withLock { if !$0 { $0 = true; cont.resume() } } }
        snapshotter.onStyleLoaded.observe { _ in finishOnce() }.store(in: &tokens)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finishOnce() }
    }

    let image: UIImage? = await withCheckedContinuation { continuation in
        snapshotter.start(overlayHandler: nil) { [snapshotter] result in
            _ = snapshotter
            switch result {
            case .success(let img): continuation.resume(returning: img)
            case .failure: continuation.resume(returning: nil)
            }
        }
    }
    if let image, let data = image.pngData() { cache.write(data, for: request.cacheKey) }
    return image
}
```

Add `import os` at the top of the file (for `OSAllocatedUnfairLock`).

- [ ] **Step 2: Build (device + sim) to confirm it compiles**

Delegate to the builder: `xcodegen generate`, then build for the device and `build-for-testing` for the simulator. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Home/MapboxTerrainSnapshotter.swift
git commit -m "feat(roh6): snapshotter renders bundled styleJSON, gated on load with fallback"
```

---

### Task 5: HomeBackdrop — request the authored style identity

**Files:**
- Modify: `Aura/Sources/Home/HomeBackdrop.swift`

**Interfaces:**
- Consumes: `TerrainStyle.authoredStyleIdentity` (Task 1).

- [ ] **Step 1: Implement**

In `request(for:)`, change the `styleURI:` argument from `TerrainStyle.styleURI` to the authored identity, so the snapshotter loads the authored JSON and the cache key reflects the style version:

```swift
    private func request(for size: CGSize) -> TerrainSnapshotRequest? {
        guard size.width > 0, size.height > 0 else { return nil }
        return TerrainSnapshotRequest(
            center: TerrainSnapshotRequest.center(forRider: riderCoordinate),
            styleURI: TerrainStyle.authoredStyleIdentity,
            width: size.width,
            height: size.height)
    }
```

- [ ] **Step 2: Build + confirm the whole AuraKit suite still passes**

Run: `cd AuraCore && swift test` (expected: all pass — the pinned cache-key literal test is unaffected, since it uses an explicit input string, not the production identity). Then delegate an app build to the builder. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Home/HomeBackdrop.swift
git commit -m "feat(roh6): Home backdrop renders the authored terrain style"
```

---

### Task 6: Device verification + variant tuning (device-first)

**Files:**
- Modify: `Aura/Resources/AuraTerrainStyle.json` (final tuned values)
- Modify: `AuraCore/Sources/AuraKit/Home/TerrainStyle.swift` (bump `styleVersion` if the look changed after images were cached)

- [ ] **Step 1: Render on the real device**

Build + install to the iPhone, launch, screenshot Home. Confirm: the authored style renders (charcoal-green land, visible hills, cool roads, muted labels), NOT the dark preset; the lime "Where to?" and route headroom read clearly over it.

- [ ] **Step 1a: Sunlight legibility gate (enforces the spec's legibility floor)**

Capture Home in direct sunlight (outdoors, or screen brightness ≥ 80%). At a 1–2 second glance, is the hillshade relief visually distinct from the land base, and is land distinct from water? If relief reads as flat/muddy, raise `hillshade-highlight-color` (toward a lighter cool grey, e.g. `#6A7A8C`) and/or `hillshade-exaggeration` **before** tuning variants. Legibility beats atmosphere (Chunk 0) — the floor is non-negotiable; the exact values are not.

- [ ] **Step 2: Produce 2–3 variants and pick**

Vary `hillshade-exaggeration` (e.g. 0.35 / 0.45 / 0.6) and label density (place-only vs place + neighborhood). Capture each on-device; pick the one that reads at a sub-second glance in bright sun without going muddy **and keeps the backdrop aesthetic** — the terrain is a supporting, partly-occluded backdrop, not the hero (the hero is Chunk 3's summary medal / the navigate cockpit). Prefer the subtler relief that stays distinct over pronounced relief that dominates the visible band. Apply the chosen values to the JSON.

- [ ] **Step 3: Bump the version if needed and verify the fallback**

If the JSON look changed after any snapshot was cached, bump `TerrainStyle.styleVersion` to `"2"` so stale cached images are invalidated. Temporarily rename the bundled JSON and confirm Home still renders (fallback path), then restore it.

- [ ] **Step 4: Re-run guards + commit**

```bash
bash scripts/check-terrain-style.sh
git add Aura/Resources/AuraTerrainStyle.json AuraCore/Sources/AuraKit/Home/TerrainStyle.swift
git commit -m "feat(roh6): tune terrain style on-device; final relief + labels"
```

## Verification Gates

- `cd AuraCore && swift test` green (TerrainStyle + unchanged cache-key literal).
- `bash scripts/check-terrain-style.sh` passes; CI `lint` job runs it.
- App + AuraWidgets build; SwiftLint `--strict` clean.
- On device: authored style renders (not fallback); sub-second bright-sun legibility; lime/route headroom intact; fallback renders Home when the JSON is absent.
