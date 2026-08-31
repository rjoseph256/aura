# Identity Carriers Map-Layer Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stock Mapbox puck with a two-state Aura puck, upgrade every planned-route line (casing, caps, endpoint markers, traveled-trim on navigate), converge map-chip scrims onto one component, and fix map-ornament collisions.

**Architecture:** Pure metrics/helpers land in AuraCore (macOS-buildable, tested); image rendering and Mapbox wiring land in the app target behind those metrics. The traveled-dim is paint-only: a static dim under-layer beneath a `lineTrimOffset`-trimmed bright layer, driven by the SDK's `fractionTraveled`. No geometry splitting, no SPI imports.

**Tech Stack:** SwiftUI, MapboxMaps 11.x (pinned exactly by Task 1), MapboxNavigationCore, SwiftPM (AuraCore/AuraKit), SwiftLint 0.64.1, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-31-identity-carriers-design.md` (v2, reconciled). The plan argues from the spec; executors read both.

**Board:** ROH-218 (Task 1), ROH-223 (Tasks 2–4), ROH-222 (Tasks 5–6), ROH-219 (Tasks 7–8), ROH-220 (Task 9), ROH-221 (Tasks 10–13), wrap-up (Task 14). Move each issue Todo → In Progress → In Review → Done as its tasks progress.

## Global Constraints

- **Charter:** no gradients anywhere; no pulsing/ambient puck animation; route line is static paint (spec §2).
- **"White = me":** the rider's marker is white-cored with ink outline and mint ring accent — never accent-mint (spec §2).
- **AuraCore purity:** no UIKit/SwiftUI/CoreGraphics imports, no `CGFloat`/`CGPoint` — `Double` only. The package must build in the macOS CI job.
- **The app target has no test bundle.** All testable logic goes in AuraCore/AuraKit. Never instantiate a bare `LocationService()` in a test.
- **SwiftLint runs from the repo root** (`swiftlint --strict`), and the TaskCompleted gate runs lint + package tests automatically.
- **Regenerate the Xcode project (`cd Aura && xcodegen`) after adding/removing app-target files** — the .xcodeproj is gitignored.
- **Builds and sim installs go through the `apple-platform-build-tools` builder agent.**
- **PO gates (spec §7):** the puck (Tasks 8–9) does not merge before the PO approves the visual mockup (gate 1a) and the in-sim renders (gate 1b); Task 9 additionally merge-holds on a device heading check. Tasks 5–6 + 2–4 evidence goes to gate 3; Tasks 12–13 to gate 2 (stills + location-playback recording with one deliberate off-route deviation).
- **Commit style:** `type(roh-NNN): summary`, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Pin the Mapbox SDKs to exact versions (ROH-218)

**Files:**
- Modify: `Aura/project.yml` (packages block, ~lines 8–15)
- Modify: `Aura/Sources/Ride/RideMapView.swift:104`

**Interfaces:**
- Produces: a deterministic dependency graph — every later task's SDK-behavior assumption (verified against 11.28.0) holds in CI.

- [ ] **Step 1: Discover the currently-resolved versions**

Run:
```bash
cat ~/Library/Developer/Xcode/DerivedData/Aura-*/SourcePackages/workspace-state.json 2>/dev/null | python3 -c "
import json,sys,glob
for p in glob.glob('$HOME/Library/Developer/Xcode/DerivedData/Aura-*/SourcePackages/workspace-state.json'):
    st=json.load(open(p))
    for d in st.get('object',{}).get('dependencies',[]):
        n=d.get('packageRef',{}).get('name','')
        if 'mapbox' in n.lower():
            print(p.split('/')[-3], n, d.get('state',{}).get('checkoutState',{}).get('version'))
"
```
Expected: versions for `mapbox-maps-ios` and `mapbox-navigation-ios` (locally 11.28.0-era for maps). If multiple DerivedData folders disagree, prefer the newest folder; the spec's API verifications were made at 11.28.0 — pin no lower than that.

- [ ] **Step 2: Pin both packages in project.yml**

In `Aura/project.yml`, replace the `majorVersion: 11.0.0` (and the navigation SDK's floating requirement) with `exactVersion` entries using the versions from Step 1, e.g.:

```yaml
packages:
  MapboxMaps:
    url: https://github.com/mapbox/mapbox-maps-ios.git
    exactVersion: 11.28.0   # spec-verified APIs: lineBorder*, lineTrimOffset, Puck2D images,
                            # ornamentOptions. NOTE: lineTrimColor is @_spi(Experimental) —
                            # the identity-carriers design avoids it on purpose (dim under-layer).
  MapboxNavigationCore:
    url: https://github.com/mapbox/mapbox-navigation-ios.git
    exactVersion: <resolved version from Step 1>
```
(Keep the existing keys/names — edit requirements only. If the navigation SDK's manifest requires a maps version incompatible with the exact pin, pin navigation only and record the transitive maps version it locks.)

- [ ] **Step 3: Fix the stale comment**

`Aura/Sources/Ride/RideMapView.swift:104` — change `the pinned MapboxMaps 11.27.0` to name the version pinned in Step 2.

- [ ] **Step 4: Regenerate and build**

Run `cd Aura && xcodegen`, then dispatch the builder agent: build the Aura scheme for the iPhone 17 simulator. Expected: BUILD SUCCEEDED, and the resolved graph shows the exact pins.

- [ ] **Step 5: Commit**

```bash
git add Aura/project.yml Aura/Sources/Ride/RideMapView.swift
git commit -m "build(roh-218): pin mapbox-maps-ios and navigation SDK to exact versions"
```

---

### Task 2: MapOrnamentMetrics in AuraCore (ROH-223, TDD)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Theme/MapOrnamentMetrics.swift`
- Test: `AuraCore/Tests/AuraCoreTests/MapOrnamentMetricsTests.swift`

**Interfaces:**
- Consumes: `HUDControlMetrics.standard.size` (existing, `Double` 44).
- Produces: `MapOrnamentMetrics.previewScaleBarTopMargin(safeAreaTop: Double) -> Double` — Task 3 calls it.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AuraCore

struct MapOrnamentMetricsTests {
    @Test func previewMarginClearsTheBackButton() {
        // Margin must clear: safe area + the 44pt control + a breathing gap.
        let m = MapOrnamentMetrics.previewScaleBarTopMargin(safeAreaTop: 59)
        #expect(m >= 59 + HUDControlMetrics.standard.size + 8)
    }

    @Test func previewMarginIsMonotonicInSafeArea() {
        // An SE (20pt) must produce a smaller margin than a notch device (59pt),
        // by exactly the safe-area difference — the constant part is device-free.
        let se = MapOrnamentMetrics.previewScaleBarTopMargin(safeAreaTop: 20)
        let notch = MapOrnamentMetrics.previewScaleBarTopMargin(safeAreaTop: 59)
        #expect(notch - se == 39)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `cd AuraCore && swift test --filter MapOrnamentMetricsTests`. Expected: compile failure, type not defined.

- [ ] **Step 3: Implement**

```swift
/// Ornament placement math for the Mapbox scale bar (ROH-223). Pure and Double-only so the
/// macOS package tests can pin it — a device-tuned literal in a view is wrong on an SE.
public enum MapOrnamentMetrics {
    /// Gap between the back control's bottom edge and the scale bar's top.
    public static let controlClearance: Double = 8

    /// Top margin for the route-preview scale bar: below the safe area, the floating
    /// back control (`HUDControlMetrics.standard`), and the clearance gap.
    public static func previewScaleBarTopMargin(safeAreaTop: Double) -> Double {
        safeAreaTop + HUDControlMetrics.standard.size + controlClearance
    }
}
```

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Theme/MapOrnamentMetrics.swift AuraCore/Tests/AuraCoreTests/MapOrnamentMetricsTests.swift
git commit -m "feat(roh-223): MapOrnamentMetrics for scale-bar placement"
```

---

### Task 3: Ornament options on the four live-map surfaces (ROH-223)

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift` (the `Map` in `body`, ~line 41)
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (the `Map`, ~line 289)
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` (the `Map`, ~line 326)
- Modify: `Aura/Sources/Home/HomeLiveMap.swift` (check-only unless overlap found)

**Interfaces:**
- Consumes: `MapOrnamentMetrics.previewScaleBarTopMargin(safeAreaTop:)` (Task 2); the HUDs' existing follow condition `viewport.followPuck != nil`.
- Produces: nothing later tasks consume; behavior only.

**Constraint (spec §6.6):** `.ornamentOptions(_:)` returns `Map` — it MUST appear before `.ignoresSafeArea()` (same rule the code documents for `.onCameraChanged`). Only `scaleBar` and `compass` fields are ever set; `logo`/`attributionButton` are never touched (they must stay visible — spec §6.3).

- [ ] **Step 1: HUD ornaments — scale bar hidden while following, compass hidden always**

In `RideMapView.swift`, the view already holds `@Binding var viewport: Viewport`. Add a helper and modifier (before `.ignoresSafeArea()`):

```swift
/// Scale bar shows only when the rider has panned off the puck (the wander case);
/// compass never — the recenter cluster owns orientation on a course-up HUD (spec §6.1-2).
private var hudOrnaments: OrnamentOptions {
    var options = OrnamentOptions()
    options.scaleBar.visibility = viewport.followPuck != nil ? .hidden : .adaptive
    options.compass.visibility = .hidden
    return options
}
```
and on the `Map`: `.ornamentOptions(hudOrnaments)`.

In `NavigateHUDView.swift`, the same pattern — the navigate map's viewport state lives in this view (used at `NavigateHUDView+Cockpit.swift:94`); mirror the helper there with its own viewport property.

- [ ] **Step 2: Preview ornaments — margin below the back button**

`RoutePreviewView.swift`: the map fills the top pane. Wrap or read the safe area with the existing environment (the file already handles safe areas for its layout); add:

```swift
private func previewOrnaments(safeAreaTop: CGFloat) -> OrnamentOptions {
    var options = OrnamentOptions()
    options.scaleBar.margins = CGPoint(
        x: 8,
        y: MapOrnamentMetrics.previewScaleBarTopMargin(safeAreaTop: Double(safeAreaTop)))
    options.compass.visibility = .hidden
    return options
}
```
Apply with a `GeometryReader`-free source if one exists in the file; otherwise read `geo.safeAreaInsets.top` from the map pane's existing geometry. NOTE (spec gate finding): the SDK measures ornament margins from the MapView's safe area — if the screenshot in Step 4 shows the margin double-counting the inset, pass `safeAreaTop: 0` and keep the pure function unchanged.

- [ ] **Step 3: Regenerate, build, install** — builder agent, iPhone 17 sim. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Sim-verify all four surfaces**

Drive the sim (grant location, Pittsburgh fix): screenshot (a) route preview — scale bar below the back button, no overlap; (b) Explore HUD while following — no scale bar, no compass; (c) Explore HUD after a pan gesture — scale bar visible; (d) Home `.live` phase (tap the map first) — confirm no ornament under the greeting/wordmark; if the scale bar collides there, apply `options.scaleBar.visibility = .hidden` on `HomeLiveMap` and note it. Confirm the Mapbox logo + attribution ⓘ are visible on every screenshot. Save screenshots for gate 3.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/RideMapView.swift Aura/Sources/Ride/NavigateHUDView.swift Aura/Sources/Plan/RoutePreviewView.swift Aura/Sources/Home/HomeLiveMap.swift
git commit -m "feat(roh-223): scale-bar and compass ornament options per map surface"
```

---

### Task 4: Hide Home's header while searching (ROH-223)

**Files:**
- Modify: `Aura/Sources/Home/HomeView.swift:146-171` (the `populated` ZStack)

**Interfaces:** none produced.

- [ ] **Step 1: Condition the header on search state**

In `HomeView.populated`, the `VStack` currently always renders `header` (greeting + wordmark + controls). Change:

```swift
VStack(spacing: 0) {
    if !searchExpanded {
        header.padding(.top, AuraTheme.Spacing.lg)
        if location.authorization != .authorized {
            HomeLocationHint()
                .padding(.horizontal, AuraTheme.Spacing.xxl)
                .padding(.top, AuraTheme.Spacing.sm)
        }
    }
    Spacer(minLength: 0)
    if !searchExpanded { launchSlot }
}
```
No transition modifier — the search overlay already animates its own presentation, and an animated header exit would fight it (charter: state-conveying only; the overlay's appearance is the state change).

- [ ] **Step 2: Build + sim-verify**

Builder rebuild/install. On Home, tap "Where to?": screenshot must show NO gear, greeting, or "Aura" wordmark ghosting behind the overlay; Cancel must sit alone. Dismiss search: header returns. Save both screenshots for gate 3.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Home/HomeView.swift
git commit -m "fix(roh-223): remove Home header from hierarchy while search overlay is up"
```

---

### Task 5: `.mapChip` modifier and chip migrations (ROH-222)

**Files:**
- Create: `Aura/Sources/Theme/MapChip.swift`
- Modify: `Aura/Sources/Ride/DetourOverlay.swift:84,101,114,127`
- Modify: `Aura/Sources/Home/HomeMapCanvas.swift:45`
- Modify: `Aura/Sources/Ride/ThenChip.swift:28-29`
- Modify: `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift:45,77,104`
- Modify: `Aura/Sources/GroupRide/GroupRideMapOverlay.swift:120`
- Modify: `Aura/Sources/Ride/MarkSpotToast.swift:36` (hairline literal only — fill stays opaque)

**Interfaces:**
- Produces: `View.mapChip(_ shape:stroke:)` with `MapChipStroke { case hairline, none }` — Task 12's marker views may reuse it.

**Do-not-touch list (spec §5):** `TurnCardView` (conditional accent state, keeps 0.92), `MarkSpotToast`'s fill, `HomeGlass`'s accent stroke, `PauseControl`, `GPSSignalChip`, `GroupToastHost`, `GroupLobbyView`, `GroupRosterSheet`, `HUDControlButton`, `MapZoomControl`.

- [ ] **Step 1: Write the component**

```swift
import SwiftUI

/// The flat map-chip treatment (ROH-222). One grammar over the map: frosted material is
/// for CONTROLS (`HUDControlButton`, `MapZoomControl`); flat scrim is for text chips —
/// this modifier. Reads the accessibility environment itself so a call site cannot skip
/// the Increase Contrast / Reduce Transparency branch.
enum MapChipStroke { case hairline, none }

private struct MapChipModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let stroke: MapChipStroke
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(shape.fill(AuraTheme.mapScrim(
                reduceTransparency: reduceTransparency, contrast)))
            .overlay {
                if case .hairline = stroke {
                    shape.strokeBorder(AuraTheme.hairline(contrast), lineWidth: 1)
                }
            }
    }
}

extension View {
    func mapChip(_ shape: some InsettableShape, stroke: MapChipStroke = .hairline) -> some View {
        modifier(MapChipModifier(shape: shape, stroke: stroke))
    }
}
```

- [ ] **Step 2: Migrate the sites**

Replace each listed treatment with `.mapChip(...)`, preserving each site's shape:
- `DetourOverlay` (4 sites): `.background(.ultraThinMaterial, in: Capsule())` → `.mapChip(Capsule())`.
- `HomeMapCanvas:45`: same Capsule swap.
- `ThenChip:28-29`: `surface.opacity(0.85)` fill + `AuraTheme.border` stroke → `.mapChip(Capsule())` (existing shape); delete the now-dead manual stroke.
- `NavigateHUDView+GroupCrew` (3 sites): `surface.opacity(0.9)` → `.mapChip(<existing shape>)`.
- `GroupRideMapOverlay:120`: `surface.opacity(0.85)` → `.mapChip(Capsule(), stroke: .none)` — NO new outline on peer name tags.
- `MarkSpotToast:36`: `.stroke(AuraTheme.hairline(.standard), ...)` → read `@Environment(\.colorSchemeContrast)` in the view and pass it. Fill untouched.

- [ ] **Step 3: Build + lint** — builder build; `swiftlint --strict` from repo root. Expected: green.

- [ ] **Step 4: Sim-verify with accessibility passes**

Screenshots of the navigate HUD (turn card + then-chip + crew pill + controls in one frame) and detour chrome: (a) default; (b) Increase Contrast on (`xcrun simctl ui <udid> increase_contrast enabled` or Settings) — chips must go solid; (c) Reduce Transparency on — same. Save for gate 3.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Theme/MapChip.swift Aura/Sources/Ride/DetourOverlay.swift Aura/Sources/Home/HomeMapCanvas.swift Aura/Sources/Ride/ThenChip.swift Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift Aura/Sources/GroupRide/GroupRideMapOverlay.swift Aura/Sources/Ride/MarkSpotToast.swift
git commit -m "feat(roh-222): mapChip modifier and chip scrim convergence"
```

---

### Task 6: SwiftLint ban on stray `ultraThinMaterial` (ROH-222)

**Files:**
- Modify: `.swiftlint.yml` (the existing `custom_rules:` block)

**Interfaces:** none produced; CI enforcement only.

- [ ] **Step 1: Add the rule**

```yaml
  map_material_outside_theme:
    name: "Bare material outside the Theme layer"
    regex: 'ultraThinMaterial'
    match_kinds:
      - identifier
    excluded:
      - "Aura/Sources/Theme/.*"
      - "Aura/Sources/Home/HomeGlass\\.swift"
      - "Aura/Sources/GroupRide/GroupLobbyView\\.swift"
      - "Aura/Sources/GroupRide/GroupRosterSheet\\.swift"
      - "Aura/Widgets/.*"
    message: "Map-floating chips use .mapChip (ROH-222); frosted material is reserved for Theme controls, HomeGlass, the lobby/roster cards, and widget surfaces."
    severity: error
```
Add a one-line justifying comment above the two lobby/roster exclusions in the YAML: they are sheet/lobby cards with a manual a11y branch, deferred to the Crew slice.

- [ ] **Step 2: Verify the rule fires (negative control)**

Create a probe: add `let x = "\(Material.ultraThinMaterial)"` temporarily to `Aura/Sources/Ride/GPSSignalChip.swift`, run `swiftlint --strict` from the repo root, and confirm the new rule reports it. Then revert the probe. Also confirm a *comment* mentioning ultraThinMaterial (there is one in `HUDControlButton.swift`'s docs and in migrated files' history) does NOT trip it — `match_kinds: identifier` is the guard.

- [ ] **Step 3: Verify the tree is green** — `swiftlint --strict`. Expected: no violations (Task 5 removed every non-exempt site).

- [ ] **Step 4: Commit**

```bash
git add .swiftlint.yml
git commit -m "chore(roh-222): lint rule banning bare ultraThinMaterial outside sanctioned files"
```

---

### Task 7: PuckMetrics in AuraCore (ROH-219, TDD)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Theme/PuckMetrics.swift`
- Test: `AuraCore/Tests/AuraCoreTests/PuckMetricsTests.swift`

**Interfaces:**
- Produces: `BrowsePuckMetrics.standard`, `RidingPuckMetrics.standard` (all fields `Double`); Task 8's `PuckImageRenderer` consumes them. Field names below are the contract.

- [ ] **Step 1: Write the failing tests (the invariants are the point — spec §3)**

```swift
import Testing
@testable import AuraCore

struct PuckMetricsTests {
    // Invariant 2 (spec §3): paint order is shadow → bearing → top, so the wedge
    // (bearingImage) draws UNDER the core. Its tip must clear the core + ring or it
    // is invisible.
    @Test func browseWedgeTipClearsTheCoreAndRing() {
        let m = BrowsePuckMetrics.standard
        #expect(m.wedgeTipRadius > m.coreDiameter / 2 + m.mintRingWidth)
    }

    // The bearing image rotates about the canvas center: everything must fit the
    // inscribed circle or rotation clips it.
    @Test func browseCanvasContainsTheRotatingWedge() {
        let m = BrowsePuckMetrics.standard
        #expect(m.canvasSide >= 2 * m.wedgeTipRadius)
    }

    @Test func ridingArrowSurvivesRotation() {
        let m = RidingPuckMetrics.standard
        let diagonal = (m.arrowLength * m.arrowLength + m.arrowWidth * m.arrowWidth)
            .squareRoot()
        #expect(m.canvasSide >= diagonal)
    }

    @Test func ridingCornersLeaveAFlatBase() {
        // Rounding both base corners must not consume the whole base edge.
        let m = RidingPuckMetrics.standard
        #expect(m.cornerRadius * 2 < m.arrowWidth)
    }

    // Invariant 3: one Puck2D scale feeds every image — relationships are ratios in
    // one type, and both states share one canvas convention so scale math can't fork.
    @Test func bothStatesUseSquareCanvases() {
        #expect(BrowsePuckMetrics.standard.canvasSide > 0)
        #expect(RidingPuckMetrics.standard.canvasSide > 0)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cd AuraCore && swift test --filter PuckMetricsTests`. Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
/// Geometry for the Aura puck bitmaps (ROH-219/220). Pure `Double` so the macOS package
/// job builds it. `PuckImageRenderer` (app target) rasterizes from these — exact values
/// are PO-gate-tunable, but the invariants in `PuckMetricsTests` must keep holding:
/// the wedge tip must out-radius the core (Mapbox paints bearing UNDER top), and every
/// element must fit its canvas's inscribed circle (bearing images rotate about center).
public struct BrowsePuckMetrics {
    public let coreDiameter: Double     // white core, including the ink outline
    public let inkOutlineWidth: Double
    public let mintRingWidth: Double    // accent ring hugging the core
    public let wedgeTipRadius: Double   // canvas center → heading-wedge tip
    public let canvasSide: Double       // square bitmap side (pt, pre-@3x)

    public static let standard = BrowsePuckMetrics(
        coreDiameter: 18, inkOutlineWidth: 1.5, mintRingWidth: 2,
        wedgeTipRadius: 16, canvasSide: 34)
    // wedgeTipRadius 16 (not the invariant-minimum ~11.5): the gate-1a mockup showed a
    // barely-clearing wedge is illegible at map size — the tip needs real protrusion.
}

public struct RidingPuckMetrics {
    public let arrowLength: Double      // triangle height, tip to base
    public let arrowWidth: Double       // base width
    public let cornerRadius: Double     // rounding on all three corners
    public let inkOutlineWidth: Double
    public let mintEdgeWidth: Double    // accent edging — 2.5, PO-bumped at gate 1a

    public let canvasSide: Double

    // Rounded-TRIANGLE silhouette, locked at gate 1a (2026-08-31): the PO rejected
    // the notched dart, picked the rounded triangle, and asked for a heavier mint
    // edge (1.5 → 2.5).
    public static let standard = RidingPuckMetrics(
        arrowLength: 22, arrowWidth: 20, cornerRadius: 3,
        inkOutlineWidth: 1.5, mintEdgeWidth: 2.5, canvasSide: 32)
}
```

- [ ] **Step 4: Run to verify pass** — same filter. Expected: PASS (30 ≥ √(24²+18²) = 30).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Theme/PuckMetrics.swift AuraCore/Tests/AuraCoreTests/PuckMetricsTests.swift
git commit -m "feat(roh-219): PuckMetrics with paint-order and rotation invariants"
```

---

### Task 8: Browse puck on Home's live map (ROH-219) — ⛔ PO gate 1a first

**Do not start implementation until the PO has approved the puck mockup (gate 1a).** The mockup is produced outside this plan and attached to ROH-219.

**Files:**
- Create: `Aura/Sources/Theme/PuckImageRenderer.swift`
- Modify: `Aura/Sources/Home/HomeLiveMap.swift:64`

**Interfaces:**
- Consumes: `BrowsePuckMetrics.standard`, `RidingPuckMetrics.standard` (Task 7), `AuraTheme` colors.
- Produces: `enum AuraPuck { static let browseTop, browseBearing, ridingBearing, clearTop: UIImage }` — Task 9 consumes `ridingBearing` and `clearTop`.

- [ ] **Step 1: Write the renderer**

```swift
import UIKit
import AuraCore

/// Rasterizes the Aura puck bitmaps from `PuckMetrics` + theme tokens (ROH-219/220).
/// `static let` is load-bearing: MapboxMaps diffs Puck2D configurations by UIImage
/// POINTER identity, and the navigate HUD's Map content re-evaluates at 30 Hz — a fresh
/// image per pass re-uploads bitmaps to the style every frame.
enum AuraPuck {
    /// Browse core: white disc, ink outline, mint ring. "White = me" (spec §2).
    static let browseTop: UIImage = {
        let m = BrowsePuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let coreRadius = CGFloat(m.coreDiameter) / 2
            // Mint ring (drawn first, slightly larger).
            c.setFillColor(AuraTheme.routeUIColor.cgColor)
            ring(c, center: center, radius: coreRadius + CGFloat(m.mintRingWidth))
            // Ink outline.
            c.setFillColor(AuraTheme.routeCasingUIColor.cgColor)
            ring(c, center: center, radius: coreRadius)
            // White core.
            c.setFillColor(UIColor.white.cgColor)
            ring(c, center: center, radius: coreRadius - CGFloat(m.inkOutlineWidth))
        }
    }()

    /// Browse heading wedge. Paints UNDER the top image (Mapbox order: shadow →
    /// bearing → top), so only the part beyond the ring shows — PuckMetricsTests
    /// pins that geometry.
    static let browseBearing: UIImage = {
        let m = BrowsePuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let tip = CGPoint(x: center.x, y: center.y - CGFloat(m.wedgeTipRadius))
            let base = CGFloat(m.coreDiameter) / 2
            c.setFillColor(AuraTheme.routeCasingUIColor.cgColor)
            c.move(to: tip)
            c.addLine(to: CGPoint(x: center.x - base * 0.45, y: center.y - base * 0.6))
            c.addLine(to: CGPoint(x: center.x + base * 0.45, y: center.y - base * 0.6))
            c.closePath()
            c.fillPath()
        }
    }()

    /// Riding puck: ROUNDED TRIANGLE, locked at PO gate 1a (2026-08-31) — white body,
    /// ink outline, bumped 2.5pt mint edge. Corner rounding comes from fill+stroke
    /// with a round line join (stroke width = 2 × cornerRadius) — the same pass at
    /// every layer, so the three silhouettes stay concentric.
    static let ridingBearing: UIImage = {
        let m = RidingPuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            c.setLineJoin(.round)
            let layers: [(scale: Double, color: UIColor)] = [
                (1.0, AuraTheme.routeUIColor),                                   // mint edge
                (insetScale(m, by: m.mintEdgeWidth), AuraTheme.routeCasingUIColor), // ink
                (insetScale(m, by: m.mintEdgeWidth + m.inkOutlineWidth), .white),   // body
            ]
            for layer in layers {
                let path = trianglePath(m, center: center, scale: layer.scale)
                c.setFillColor(layer.color.cgColor)
                c.setStrokeColor(layer.color.cgColor)
                c.setLineWidth(2 * CGFloat(m.cornerRadius) * CGFloat(layer.scale))
                c.addPath(path.cgPath)
                c.drawPath(using: .fillStroke)
            }
        }
    }()

    /// The riding triangle, scaled about the canvas center.
    private static func trianglePath(_ m: RidingPuckMetrics, center: CGPoint,
                                     scale: Double) -> UIBezierPath {
        let halfL = CGFloat(m.arrowLength * scale) / 2
        let halfW = CGFloat(m.arrowWidth * scale) / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: center.x, y: center.y - halfL))
        path.addLine(to: CGPoint(x: center.x + halfW, y: center.y + halfL))
        path.addLine(to: CGPoint(x: center.x - halfW, y: center.y + halfL))
        path.close()
        return path
    }

    /// Scale that insets the triangle by `points` all around (height-ratio
    /// approximation — exact enough at these sizes; gate 1b judges the pixels).
    private static func insetScale(_ m: RidingPuckMetrics, by points: Double) -> Double {
        max(0, (m.arrowLength - 2 * points) / m.arrowLength)
    }

    /// Mandatory transparent top for the riding state: a nil topImage falls back to
    /// Mapbox's stock blue dot rendered ON TOP of the bearing arrow (spec §3.1).
    static let clearTop: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    private static func ring(_ c: CGContext, center: CGPoint, radius: CGFloat) {
        c.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2))
    }

}
```
(Gate 1a is LOCKED (2026-08-31): browse dot approved as mocked; riding = rounded
triangle with the 2.5pt mint edge, PO-confirmed "bumped is the way". Gate 1b still
re-checks the real in-app render at cockpit zoom; tune constants there only within
the `PuckMetrics` invariants.)

- [ ] **Step 2: Wire the browse state**

`HomeLiveMap.swift:64`:
```swift
Puck2D(bearing: .heading)
    .topImage(AuraPuck.browseTop)
    .bearingImage(AuraPuck.browseBearing)
    .showsAccuracyRing(true)
    .accuracyRingColor(AuraTheme.routeUIColor.withAlphaComponent(0.12))
    .accuracyRingBorderColor(AuraTheme.routeUIColor.withAlphaComponent(0.35))
```

- [ ] **Step 3: Regenerate (`xcodegen` — new file), build, install** — builder agent. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Sim-verify (gate 1b evidence)**

Home → tap map (`.live` phase): screenshot the puck. Compare against the approved mockup: white core, ink outline, mint ring, no blue anywhere, accuracy ring subtle. Zoom screenshot (`zoom` action on the puck region). Save for PO gate 1b sign-off; **do not proceed to Task 9's merge without it.**

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Theme/PuckImageRenderer.swift Aura/Sources/Home/HomeLiveMap.swift
git commit -m "feat(roh-219): white-core Aura browse puck with real accuracy ring on Home"
```

---

### Task 9: Riding puck on both HUDs (ROH-220) — ⛔ merge-held on device heading check

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift:42`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:291`

**Interfaces:**
- Consumes: `AuraPuck.ridingBearing`, `AuraPuck.clearTop` (Task 8).

- [ ] **Step 1: Wire both HUD sites**

At each site replace `Puck2D(bearing: .heading)` with:

```swift
Puck2D(bearing: .heading)
    .topImage(AuraPuck.clearTop)        // mandatory: nil ships the stock blue dot on top
    .bearingImage(AuraPuck.ridingBearing)
```
No accuracy ring on the HUDs (spec §3).

- [ ] **Step 2: Build + sim-verify statics** — builder; drive an Explore ride and a navigate ride; screenshot both HUDs. The arrow renders white/ink/mint at bearing 0; no blue dot. Confirm the group-ride peer dots' "white = me" grammar reads (see any GroupRide preview if available).

- [ ] **Step 3: Commit, open PR, apply the hold**

```bash
git add Aura/Sources/Ride/RideMapView.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-220): white arrowhead riding puck on both HUDs"
```
The PR body MUST state: *Tier 2 with merge hold — sim delivers no CLHeading; the bearing-image rotation convention (up/right/mirrored) is verifiable only on hardware (VERIFICATION.md Tier-2 class, ROH-213 precedent). Merges after a device heading check.* Mark ROH-220 blocked pending the device pass.

---

### Task 10: `fractionTraveled` plumbing (ROH-221, TDD)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift` (GuidanceUpdate)
- Create: `AuraCore/Sources/AuraCore/Guidance/RouteTrim.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RouteTrimTests.swift`
- Modify: `Aura/Sources/Routing/MapboxGuidanceSession.swift:192` (the update construction)

**Interfaces:**
- Produces: `GuidanceUpdate.fractionTraveled: Double?` (default nil — source-compatible); `RouteTrim.sanitized(_ raw: Double?) -> Double?`; `RouteTrim.quantized(_ fraction: Double, step: Double = 0.005) -> Double`. Task 13 consumes all three.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AuraCore

struct RouteTrimTests {
    @Test func sanitizedClampsToUnitRange() {
        #expect(RouteTrim.sanitized(-0.2) == 0)
        #expect(RouteTrim.sanitized(1.7) == 1)
        #expect(RouteTrim.sanitized(0.42) == 0.42)
    }

    // Spec gate finding: max(0, .nan) is argument-order dependent — non-finite must
    // map to nil (no dim), never to a garbage trim.
    @Test func sanitizedRejectsNonFinite() {
        #expect(RouteTrim.sanitized(.nan) == nil)
        #expect(RouteTrim.sanitized(.infinity) == nil)
        #expect(RouteTrim.sanitized(nil) == nil)
    }

    // Quantization exists so paint updates are rare — ~1 write per 0.5% of route.
    @Test func quantizedSnapsDown() {
        #expect(RouteTrim.quantized(0.4239) == 0.42)
        #expect(RouteTrim.quantized(0.9999) == 0.995)
        #expect(RouteTrim.quantized(1.0) == 1.0)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cd AuraCore && swift test --filter RouteTrimTests`. Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
/// Trim math for the navigate traveled-dim (ROH-221). Pure: the HUD passes the SDK's
/// `fractionTraveled` through `sanitized` then `quantized` before it touches
/// `lineTrimOffset` — a non-finite or out-of-range value means "no dim", never a wrong dim.
public enum RouteTrim {
    public static func sanitized(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        return min(max(raw, 0), 1)
    }

    public static func quantized(_ fraction: Double, step: Double = 0.005) -> Double {
        (fraction / step).rounded(.down) * step
    }
}
```
In `GuidanceUpdate`, add after `durationRemainingSeconds` (and to the init with `= nil`):
```swift
/// How far along the guided route the rider is, 0...1, from the engine's own
/// progress (dimensionless — immune to the cross-geometry subtraction the spec
/// gate refuted). nil until known; only `ScriptedGuidanceSession` stays nil forever.
public var fractionTraveled: Double?
```

- [ ] **Step 4: Run package tests** — full `swift test` (both totals green; the suite prints two). Expected: PASS, no call-site breaks (defaulted parameter).

- [ ] **Step 5: Map it in the session**

`MapboxGuidanceSession.swift:192` region — add to the constructed `GuidanceUpdate`:
```swift
fractionTraveled: RouteTrim.sanitized(progress.fractionTraveled)
```

- [ ] **Step 6: Builder build (app target compiles).** Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift AuraCore/Sources/AuraCore/Guidance/RouteTrim.swift AuraCore/Tests/AuraCoreTests/RouteTrimTests.swift Aura/Sources/Routing/MapboxGuidanceSession.swift
git commit -m "feat(roh-221): carry sanitized fractionTraveled on GuidanceUpdate"
```

---

### Task 11: Guided-route emission on registry fallback (ROH-221)

**Files:**
- Modify: `Aura/Sources/Routing/MapboxGuidanceSession.swift:78-83` (the `isFirst` suppression) and `:138-160` (the fallback paths)

**Interfaces:** none new — uses the existing `.rerouted([Coordinate])` event that `GuidanceViewModel` already consumes into `routeGeometry`.

- [ ] **Step 1: Make the fallback paths self-announcing**

Today `.rerouted` is suppressed for the first `routeId`, on the assumption the drawn route IS the guided route. That assumption fails exactly on the two fallback paths (spec §4, gate blocker): `selectingAlternativeRoute(at:)` returning nil (falls to the main route) and the registry miss (re-fetches its own route). Change: track whether the navigation-session route was resolved through a fallback —

```swift
// In the resolution function (:138-160): return the flag alongside the routes.
// e.g. change the return to (routes: NavigationRoutes, divergedFromSelection: Bool),
// true on BOTH the `?? entry.routes` branch and the registry-miss re-fetch.
```
— and in the event loop's `isFirst` guard: when `divergedFromSelection` is true, do NOT suppress the first `.rerouted`; emit the navigated route's geometry immediately so `NavigateHUDView` draws the guided line. Keep the suppression for the normal path (no behavior change).

- [ ] **Step 2: Build + inspect**

Builder build. Then verify by inspection + a temporary `os_log` on the fallback branch, exercised in the sim by relaunching mid-flow if reachable; if not reachable in-sim, the code path's unit is the boolean plumbing — keep the log permanent at `.debug` level (the session already logs), and note in the PR that this path is registry-miss-only.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Routing/MapboxGuidanceSession.swift
git commit -m "fix(roh-221): emit navigated geometry when guidance diverges from the selected route"
```

---

### Task 12: Casing, caps, and endpoint markers (ROH-221)

**Files:**
- Create: `Aura/Sources/Ride/RouteEndpointMarkers.swift`
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift:331-339`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:296-304`
- Modify: `Aura/Sources/Ride/RideMapView.swift:118-126` (detour polyline)
- Modify: `Aura/Sources/Ride/StaticRouteMap.swift:29-34`

**Interfaces:**
- Consumes: `AuraTheme.routeUIColor`, `AuraTheme.routeCasingUIColor`.
- Produces: `OriginRingView`, `DestinationMarkerView` (SwiftUI views for `MapViewAnnotation`).

- [ ] **Step 1: Marker views**

```swift
import SwiftUI

/// Route endpoint markers (ROH-221). Deliberately NOT in the puck vocabulary: the
/// preview's origin can be the denied-permission fallback coordinate, so a puck-like
/// dot would assert "you are here" falsely (spec §4). Hollow ring = route start.
struct OriginRingView: View {
    var body: some View {
        Circle()
            .strokeBorder(AuraTheme.accent, lineWidth: 3)
            .background(Circle().strokeBorder(AuraTheme.background, lineWidth: 5))
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)   // the preview header already names the route
    }
}

/// Filled destination marker: mint disc, ink flag glyph.
struct DestinationMarkerView: View {
    var body: some View {
        ZStack {
            Circle().fill(AuraTheme.background).frame(width: 26, height: 26)
            Circle().fill(AuraTheme.accent).frame(width: 22, height: 22)
            Image(systemName: "flag.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AuraTheme.onAccent)
        }
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Casing + caps at the four polyline sites**

At each site, on the `PolylineAnnotationGroup` add group-level modifiers, and on the annotation the border:

```swift
PolylineAnnotationGroup {
    PolylineAnnotation(lineCoordinates: coords)
        .lineColor(StyleColor(AuraTheme.routeUIColor))
        .lineWidth(6)                                      // keep each site's width
        .lineBorderColor(StyleColor(AuraTheme.routeCasingUIColor))
        .lineBorderWidth(2)
}
.lineCap(.round)
.lineJoin(.round)
```
Preview keeps width 5; navigate/detour keep 6; `StaticRouteMap` keeps 5. Delete nothing else.

- [ ] **Step 3: Endpoint markers per surface**

- Preview (`RoutePreviewView` map content): `MapViewAnnotation(coordinate: first) { OriginRingView() }` and `MapViewAnnotation(coordinate: last) { DestinationMarkerView() }` for the SELECTED route's endpoints, each `.allowOverlapWithPuck(true)`.
- Navigate (`NavigateHUDView` map content): destination marker only, at the drawn geometry's last coordinate (recomputes with `routeGeometry` on reroute), `.allowOverlapWithPuck(true)`.
- Detour (`RideMapView.detourPolyline`): destination marker at the detour route's last coordinate while a detour is active, `.allowOverlapWithPuck(true)` (spec §4 — the gem pin cannot be relied on).
- Summary (`StaticRouteMap`): no markers (recorded track; casing/caps only).

- [ ] **Step 4: Build + sim-verify (gate 2 stills)**

Builder build/install. Screenshots: (a) route preview — cased mint line, round caps, origin ring at start, flag at destination; (b) navigate HUD — cased line + destination flag, no origin dot; (c) summary after a sim ride — cased line. Save for gate 2.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/RouteEndpointMarkers.swift Aura/Sources/Plan/RoutePreviewView.swift Aura/Sources/Ride/NavigateHUDView.swift Aura/Sources/Ride/RideMapView.swift Aura/Sources/Ride/StaticRouteMap.swift
git commit -m "feat(roh-221): native route casing, round caps, endpoint markers"
```

---

### Task 13: Traveled-dim trim on navigate (ROH-221)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift` (new token)
- Test: `AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift` (extend)
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:287-304` (map content)

**Interfaces:**
- Consumes: `GuidanceUpdate.fractionTraveled` via the HUD's guidance view model; `RouteTrim.quantized`; `guidance.isRerouting` (already consumed at `NavigateHUDView.swift:162`).
- Produces: `AuraPalette.routeDimOpacity`.

- [ ] **Step 1: Token + failing test**

In `WCAGContrastTests.swift` add:
```swift
@Test func dimmedRouteIsVisibleButClearlySubordinate() {
    // The dim trace must stay visible on the near-black basemap…
    let dimmed = WCAGContrast.composite(AuraPalette.mint,
                                        alpha: AuraPalette.routeDimOpacity,
                                        over: AuraPalette.nearBlack)
    #expect(WCAGContrast.ratio(dimmed, AuraPalette.nearBlack) >= 1.4)
    // …and clearly darker than the full line, or "traveled" reads as noise.
    #expect(WCAGContrast.ratio(AuraPalette.mint, dimmed) >= 1.8)
}
```
(Use the file's existing composite/ratio helpers — match their actual names when editing; they compute alpha-composites for the scrim tests in the same file.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter WCAGContrastTests`. Expected: `routeDimOpacity` undefined.

- [ ] **Step 3: Add the token**

In `AuraPalette` (near `mapScrimOpacity`):
```swift
/// Opacity of the ridden portion of the navigate route line (ROH-221). Gate-tunable;
/// the WCAG test pins visible-but-subordinate on the dark basemap.
public static let routeDimOpacity = 0.35
```
Run the filter again. Expected: PASS (adjust 0.35 within the test's bounds if needed — move the token, never the test thresholds).

- [ ] **Step 4: Two-layer trim in the navigate map**

In `NavigateHUDView`'s map content, replace the single route group with (dim group FIRST — separate groups become separate layers; declaration order is the SwiftUI content order, and this stack is validated by the gate-2 playback recording):

```swift
let routeCoords = (guidance.routeGeometry ?? route.geometry).map {
    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
}
// Ridden trace: full-length, revealed as the bright layer above is trimmed away.
PolylineAnnotationGroup {
    PolylineAnnotation(lineCoordinates: routeCoords)
        .lineColor(StyleColor(AuraTheme.routeUIColor
            .withAlphaComponent(CGFloat(AuraPalette.routeDimOpacity))))
        .lineWidth(6)
}
.lineCap(.round)
.lineJoin(.round)

// Route ahead: cased bright line; the trimmed span [0, trimEnd] goes transparent.
PolylineAnnotationGroup {
    PolylineAnnotation(lineCoordinates: routeCoords)
        .lineColor(StyleColor(AuraTheme.routeUIColor))
        .lineWidth(6)
        .lineBorderColor(StyleColor(AuraTheme.routeCasingUIColor))
        .lineBorderWidth(2)
}
.lineCap(.round)
.lineJoin(.round)
.lineTrimOffset(start: 0, end: trimEnd)
```
with, in the view:
```swift
/// Paint-only traveled trim (spec §4). Rerouting renders the full bright line —
/// a brief un-dim beside the "Rerouting" chip, never a wrong dim: during the window
/// the progress stream still describes the OLD route while the geometry may already
/// be the new one (the spec gate's blocker).
private var trimEnd: Double {
    guard !guidance.isRerouting,
          let fraction = guidance.lastUpdate?.fractionTraveled else { return 0 }
    return RouteTrim.quantized(fraction)
}
```
(Adapt property paths to the view's actual guidance model names — `isRerouting` is read at line 162 today; `lastUpdate` is the view model's published update. `.lineTrimOffset(start: 0, end: 0)` must render the full line — verify in Step 5's playback, and if the SDK treats [0,0] oddly, branch to omit the modifier when trimEnd == 0.)

- [ ] **Step 5: Build + gate-2 playback recording**

Builder build/install. Record the sim (`xcrun simctl io <udid> recordVideo`) through a navigate ride driven by location playback (the golden-ride tooling's playback path or `simctl location` scripted along the route): confirm (a) the line starts fully bright; (b) the dim trace grows behind the moving puck; (c) drive one deliberate off-route deviation — during "Rerouting" the whole line is bright, after the new route arrives the dim resumes from the rider's position; (d) no crawling seam (paint boundary only). Save the recording for gate 2. NOTE for the PR: the golden-ride E2E uses `ScriptedGuidanceSession`, which never emits progress — this path is exercised by the playback recording and ROH-224's device pass, not by CI.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraCore/Theme/AuraPalette.swift AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-221): paint-only traveled-dim via lineTrimOffset, frozen while rerouting"
```

---

### Task 14: DESIGN.md, spec sweep, whole-slice evidence (wrap-up)

**Files:**
- Modify: `DESIGN.md`
- Modify: `docs/superpowers/specs/2026-08-31-identity-carriers-design.md` (status line only)

**Interfaces:** none.

- [ ] **Step 1: Correct DESIGN.md**

- Remove the stale `SpeedReadout` entry (line ~41).
- Replace the scrim line (~44/46) with the two-tier grammar: *"Frosted material is for controls (`HUDControlButton`, `MapZoomControl`); map-floating text chips use `.mapChip` (flat `mapScrim` + hairline), which reads the accessibility environment itself. The turn card and `MarkSpotToast` are documented exceptions (conditional accent state; opaque toast)."*
- Document the puck: *"Location puck: two-state, drawn from `PuckMetrics` — browse (white core, ink outline, mint ring, real accuracy ring) on Home; riding (white arrowhead, ink outline, mint edge) on the HUDs. White = me; the accent is never spent on the rider marker."*
- Document the route line: *"Planned routes draw mint over a near-black `lineBorder` casing with round caps; preview shows an origin ring; preview/navigate/detour show the destination flag; navigate dims the ridden span via paint-only trim (`routeDimOpacity`), full-bright while rerouting."*

- [ ] **Step 2: Success-criteria sweep**

Walk spec §10's eight criteria against the built branch; record each as met/not-met with evidence (screenshot path, test name, or PR line). Any not-met item either gets fixed now or is surfaced to the PO explicitly — never silently dropped. Update the spec's Status line to reference the evidence.

- [ ] **Step 3: Whole-slice screenshot set (gate 4)**

Fresh sim pass: Home (idle + live + search), preview, navigate (bright + mid-ride dim), Explore HUD, summary — before/after pairs where the old screenshots exist (the audit set). Deliver to the PO with the whole-branch review.

- [ ] **Step 4: Commit**

```bash
git add DESIGN.md docs/superpowers/specs/2026-08-31-identity-carriers-design.md
git commit -m "docs(roh-45): DESIGN.md puck/route/chip grammar + identity-carriers evidence sweep"
```

- [ ] **Step 5: Whole-branch review + board close-out**

Run the whole-branch review (most capable model) per the repo pipeline; then per-issue: ROH-218/219/221/222/223 → Done as their PRs merge (ROH-220 stays open until the device heading check; ROH-224 stays queued — watch for Linear auto-completing them from PR references and revert if so).
