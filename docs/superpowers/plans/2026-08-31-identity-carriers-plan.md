# Identity Carriers Map-Layer Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **v2 — reconciled 2026-08-31 after a 2-reviewer adversarial plan review.** The largest
> changes: navigate route rendering moved off `PolylineAnnotationGroup` onto style
> primitives (the annotation path cannot enable `lineMetrics`, without which
> `lineTrimOffset` fails with a shader error, not a no-op); a new Task 10B fixing
> `GuidanceViewModel`'s reroute-window state (one line cleared `isRerouting` on every
> progress tick, making the "full bright while rerouting" promise unimplementable); the
> SDK pin strategy rebuilt around the navigation package's own exact maps pin; ornament
> margins corrected; and a dozen smaller code-block fixes. Line numbers cite HEAD at
> plan time — **locate by symbol/anchor, not line number**, especially in files several
> tasks edit in sequence (`NavigateHUDView.swift`: Tasks 3→9→12→13;
> `RideMapView.swift`: 3→9→12; `RoutePreviewView.swift`: 3→12).

**Goal:** Replace the stock Mapbox puck with the gate-1a-approved two-state Aura puck, upgrade every planned-route line (casing, caps, endpoint markers, traveled-trim on navigate), converge map-chip scrims onto one component, and fix map-ornament collisions.

**Architecture:** Pure metrics/helpers land in AuraCore (macOS-buildable, tested); image rendering and Mapbox wiring land in the app target behind those metrics. The traveled-dim is paint-only, rendered by style primitives (a `lineMetrics` GeoJSON source under two `LineLayer`s) driven by the SDK's `fractionTraveled`, frozen during the whole reroute window by a repaired `isRerouting`.

**Tech Stack:** SwiftUI, MapboxMaps 11.28.0 + MapboxNavigation 3.28.0 (pinned exactly by Task 1), SwiftPM (AuraCore/AuraKit), SwiftLint 0.64.1, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-31-identity-carriers-design.md` (v2 + reconciliation amendments). The plan argues from the spec; executors read both.

**Board:** ROH-218 (Task 1), ROH-223 (Tasks 2–4), ROH-222 (Tasks 5–6), ROH-219 (Tasks 7–8), ROH-220 (Task 9), ROH-221 (Tasks 10, 10B, 11–13), wrap-up (Task 14). Drive statuses per the board flow.

## Global Constraints

- **Charter:** no gradients; no pulsing/ambient puck animation; route line is static paint (spec §2).
- **"White = me":** the rider's marker is never accent-mint (spec §2).
- **Gate 1a is PASSED** (2026-08-31, recorded on ROH-219): browse dot approved as mocked; riding puck = rounded triangle, mint edge 2.5pt. The `PuckMetrics` values in Task 7 ARE the approved design. Gate 1b (in-app render) still applies before the puck work merges.
- **AuraCore purity:** no UIKit/SwiftUI/CoreGraphics imports, `Double` only — the package builds in the macOS CI job.
- **The app target has no test bundle.** Testable logic goes in AuraCore/AuraKit. Never a bare `LocationService()` in tests.
- **SwiftLint runs from the repo root** (`swiftlint --strict`); the TaskCompleted gate lints + runs package tests at every task boundary — code blocks in this plan were screened against default rules (no force casts, etc.); keep it that way.
- **`cd Aura && xcodegen` after ANY app-target file add/remove** (Tasks 5, 8, 12 create files — the step is written into each).
- **Builds/installs via the `apple-platform-build-tools` builder agent.** Sim: iPhone 17, UDID `D221B3C5-13DE-482F-B0FD-017B305EC31B`, bundle `com.rohunjoseph.aura`.
- **PO gates (spec §7):** gate 1b before puck merges; gate 2 (stills + playback recording with an off-route deviation) before Task 13's PR merges; gate 3 for Tasks 2–6; gate 4 whole-slice. While a gate waits: Linear comment + blocked status; rebase on main before merging if it waited.
- **Commit style:** `type(roh-NNN): summary` + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Pin the Mapbox SDKs to exact versions (ROH-218)

**Files:**
- Modify: `Aura/project.yml` (packages block — keys are `MapboxMaps`, `MapboxNavigation`, `MapboxSearch`; `MapboxNavigationCore` is a *product*, not a package key)
- Modify: `Aura/Sources/Ride/RideMapView.swift` (the "pinned MapboxMaps 11.27.0" comment, ~line 104)

**Interfaces:**
- Produces: a deterministic dependency graph resolving MapboxMaps **11.28.0** — the version every SDK-behavior citation in the spec and this plan was verified against.

**Why this shape (plan-review finding):** `mapbox-navigation-ios` pins `mapbox-maps-ios` with `exact:` per release (3.28.0 → 11.28.0; 3.29.1 → 11.29.1), and `search-ios` exact-pins `mapbox-common-ios` per release. Pinning maps independently can produce an unresolvable graph; pinning navigation pins maps transitively and exactly.

- [ ] **Step 1: Pin navigation and search; leave the maps entry as-is**

In `Aura/project.yml`, change ONLY the version requirements (keep every key name):

```yaml
  MapboxNavigation:
    url: https://github.com/mapbox/mapbox-navigation-ios.git
    exactVersion: 3.28.0   # transitively exact-pins mapbox-maps-ios 11.28.0 — the
                           # version the identity-carriers spec's API checks used.
                           # lineTrimColor is @_spi(Experimental) there; the route
                           # design avoids it on purpose (dim under-layer, no SPI).
  MapboxSearch:
    url: https://github.com/mapbox/search-ios.git
    exactVersion: 2.28.0   # its exact mapbox-common pin must match maps 11.28.0's
                           # (both 24.28.0); a floating search can break resolution.
```
`MapboxMaps` keeps its existing entry (the navigation pin constrains it to exactly 11.28.0). If resolution fails on `mapbox-common`, the search minor is the knob — align it with the maps minor (2.x ↔ 11.x share the common line).

- [ ] **Step 2: Fix the stale comment** — `RideMapView.swift` ~104: `11.27.0` → `11.28.0 (via the MapboxNavigation 3.28.0 exact pin — see project.yml)`.

- [ ] **Step 3: Regenerate and build** — `cd Aura && xcodegen`, then builder: build for the sim, and report the resolved versions (`SourcePackages/workspace-state.json` names packages `MapboxMaps`/`MapboxNavigation`/`MapboxSearch`). Expected: BUILD SUCCEEDED, MapboxMaps 11.28.0, MapboxNavigation 3.28.0.

- [ ] **Step 4: Commit**

```bash
git add Aura/project.yml Aura/Sources/Ride/RideMapView.swift
git commit -m "build(roh-218): pin MapboxNavigation and MapboxSearch exactly (maps 11.28.0 transitively)"
```

---

### Task 2: MapOrnamentMetrics in AuraCore (ROH-223, TDD)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Theme/MapOrnamentMetrics.swift`
- Test: `AuraCore/Tests/AuraCoreTests/MapOrnamentMetricsTests.swift`

**Interfaces:**
- Consumes: `HUDControlMetrics.standard.size` (existing, `Double` 44).
- Produces: `MapOrnamentMetrics.belowTopControlMargin: Double` — Task 3 uses it on BOTH the preview and the HUDs.

**Why no `safeAreaTop` parameter (plan-review finding):** Mapbox ornament margins are measured **from the MapView's safe area** (`OrnamentOptions.swift:5-7`), and the colliding controls (preview back button, HUD back/GPS chip) all sit at `.padding(.top, 8)` inside the safe area. So the correct margin is safe-area-relative and device-independent: control top padding + control size + clearance. The v1 design's `safeAreaTop` parameter would have been dead at the call site.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AuraCore

struct MapOrnamentMetricsTests {
    @Test func belowTopControlMarginClearsTheControlRow() {
        // Composition is the contract: the 8pt control top padding, the 44pt
        // HUDControlMetrics control, and a breathing gap — margins are measured
        // from the MapView's safe area, same as the controls' own padding.
        #expect(MapOrnamentMetrics.belowTopControlMargin
                == MapOrnamentMetrics.topControlPadding
                + HUDControlMetrics.standard.size
                + MapOrnamentMetrics.controlClearance)
        #expect(MapOrnamentMetrics.belowTopControlMargin >= 56)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cd AuraCore && swift test --filter MapOrnamentMetricsTests`. Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
/// Ornament placement for the Mapbox scale bar (ROH-223). Margins are relative to the
/// MapView's SAFE AREA (SDK contract), the same frame the floating controls pad from —
/// so this is a device-independent composition, not a tuned literal.
public enum MapOrnamentMetrics {
    /// The `.padding(.top, 8)` every top-row floating control uses.
    public static let topControlPadding: Double = 8
    /// Gap between the control's bottom edge and the scale bar.
    public static let controlClearance: Double = 8
    /// Scale-bar top margin that clears a standard top-row control.
    public static let belowTopControlMargin: Double =
        topControlPadding + HUDControlMetrics.standard.size + controlClearance
}
```

- [ ] **Step 4: Run to verify pass**, then **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Theme/MapOrnamentMetrics.swift AuraCore/Tests/AuraCoreTests/MapOrnamentMetricsTests.swift
git commit -m "feat(roh-223): safe-area-relative scale-bar margin metric"
```

---

### Task 3: Ornament options on the live-map surfaces (ROH-223)

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift` (the `Map` in `body`)
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (the `Map` inside `navigateMapView`)
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` (the `Map` inside `mapPane`)
- Check-only: `Aura/Sources/Home/HomeLiveMap.swift`

**Interfaces:**
- Consumes: `MapOrnamentMetrics.belowTopControlMargin` (Task 2); the HUDs' existing `viewport.followPuck != nil`.

**Constraints:** `.ornamentOptions(_:)` returns `Map` — it MUST precede `.ignoresSafeArea()`. Only `scaleBar` and `compass` are ever set (logo/attribution untouched — they stay visible wherever they are visible today; their pre-existing placement behind the cockpit is out of scope, spec §6.3). **Compass changes on HUDs only — the preview's compass is untouched** (spec §6.2 "untouched elsewhere"; the preview is where a stationary rider may deliberately rotate).

- [ ] **Step 1: HUD ornaments — scale bar margin'd below the control row and hidden while following; compass hidden**

In `RideMapView.swift` (and mirrored in `NavigateHUDView.swift` with its own viewport property):

```swift
/// Scale bar shows only when panned off the puck, and BELOW the top control row —
/// at Mapbox's default topLeading(8,8) it would collide with the back/GPS controls
/// in exactly the panned state that shows it (plan-review finding). Compass never:
/// the recenter cluster owns orientation on a course-up HUD (spec §6.1-2).
private var hudOrnaments: OrnamentOptions {
    var options = OrnamentOptions()
    options.scaleBar.visibility = viewport.followPuck != nil ? .hidden : .adaptive
    options.scaleBar.margins = CGPoint(x: 8, y: MapOrnamentMetrics.belowTopControlMargin)
    options.compass.visibility = .hidden
    return options
}
```
Apply `.ornamentOptions(hudOrnaments)` before `.ignoresSafeArea()`.

- [ ] **Step 2: Preview ornaments — scale bar below the back button; compass untouched**

```swift
/// Scale bar below the floating back control. Margins are safe-area-relative (SDK
/// contract), so no GeometryReader and no device-dependent term.
private var previewOrnaments: OrnamentOptions {
    var options = OrnamentOptions()
    options.scaleBar.margins = CGPoint(x: 8, y: MapOrnamentMetrics.belowTopControlMargin)
    return options
}
```

- [ ] **Step 3: Build** — builder. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Sim-verify (gate 3 evidence)** — screenshots: (a) preview: scale bar clear of the back button; (b) Explore HUD following: no scale bar, no compass; (c) Explore HUD after a pan: scale bar visible **and clear of the back button and GPS chip** — the collision check is the point, not mere visibility; (d) Home `.live` (tap the map): no ornament under the greeting/wordmark — if the scale bar collides there, set `visibility = .hidden` on `HomeLiveMap` and note it. Confirm logo + attribution appear wherever they appear today.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/RideMapView.swift Aura/Sources/Ride/NavigateHUDView.swift Aura/Sources/Plan/RoutePreviewView.swift Aura/Sources/Home/HomeLiveMap.swift
git commit -m "feat(roh-223): scale-bar margins + follow-conditional visibility, compass off HUDs"
```

---

### Task 4: Hide Home's top chrome while searching (ROH-223)

**Files:**
- Modify: `Aura/Sources/Home/HomeView.swift` (the `populated` VStack, ~146-156)

- [ ] **Step 1: Condition the header block AND the location hint on search state**

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
Deliberate widening over spec §6.4 (reconciled): the hint is top-anchored chrome under the same 40%-transparent scrim — ghosting it half-visible during search is worse than absence, and search results carry their own location handling. No transition modifier (the overlay animates its own presentation).

- [ ] **Step 2: Build + sim-verify** — open search: NO gear/greeting/wordmark/hint ghosting; Cancel alone. Dismiss: all return. Save both screenshots (gate 3).

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Home/HomeView.swift
git commit -m "fix(roh-223): remove Home top chrome from hierarchy while search overlay is up"
```

---

### Task 5: `.mapChip` modifier and chip migrations (ROH-222)

**Files:**
- Create: `Aura/Sources/Theme/MapChip.swift`
- Modify: `Aura/Sources/Ride/DetourOverlay.swift` (4 material sites: 84, 101, 114, 127)
- Modify: `Aura/Sources/Home/HomeMapCanvas.swift:45`
- Modify: `Aura/Sources/Ride/ThenChip.swift:28-29`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (~168: the hand-rolled Rerouting chip)
- Modify: `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift` (45, 77, 104)
- Modify: `Aura/Sources/GroupRide/GroupRideMapOverlay.swift:120`
- Modify: `Aura/Sources/Home/HomeGlass.swift` (fallback fill only)
- Modify: `Aura/Sources/Ride/MarkSpotToast.swift` (~37: hairline literal only — fill stays opaque)

**Interfaces:**
- Produces: `View.mapChip(_ shape:stroke:)` with `MapChipStroke { case hairline, none }`.

**Do-not-touch:** `TurnCardView` (conditional accent state, keeps 0.92), `MarkSpotToast`'s fill, `HomeGlass`'s accent stroke and Liquid Glass path, `PauseControl`, `GPSSignalChip`, `GroupToastHost` (already on `mapScrim` via their own shapes), `GroupLobbyView`, `GroupRosterSheet`, `HUDControlButton`, `MapZoomControl`.

- [ ] **Step 1: Write the component** (unchanged from v1 — fill = `AuraTheme.mapScrim(...)`, stroke default `hairline(contrast)` with `.none`, environment read inside the modifier):

```swift
import SwiftUI

/// The flat map-chip treatment (ROH-222). One grammar over the map: frosted material
/// is for CONTROLS (`HUDControlButton`, `MapZoomControl`); flat scrim is for text
/// chips — this modifier. Reads the accessibility environment itself so a call site
/// cannot skip the Increase Contrast / Reduce Transparency branch.
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

- [ ] **Step 2: Migrate the sites — per-site notes matter (plan-review findings):**

- `DetourOverlay` sites 84/114/127: `.background(.ultraThinMaterial, in: Capsule())` → `.mapChip(Capsule())`. **Site :101 is a RoundedRectangle, not a Capsule** → `.mapChip(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))` (16 was the hardcoded value; `Radius.lg` == 16).
- `HomeMapCanvas:45`: Capsule swap.
- `ThenChip`: fill + manual `AuraTheme.border` stroke → `.mapChip(Capsule())`; **delete the manual stroke**.
- `NavigateHUDView` ~168 (Rerouting chip): already `mapScrim` + hairline by hand — converge to `.mapChip(Capsule())` so the DESIGN.md rule has no hand-rolled exception.
- `NavigateHUDView+GroupCrew` ×3: `.background(surface.opacity(0.9), in: Capsule())` + `.overlay(Capsule().strokeBorder(AuraTheme.border))` → `.mapChip(Capsule())`; **delete all three manual stroke overlays** (a kept overlay + the modifier's hairline = double stroke).
- `GroupRideMapOverlay:120`: → `.mapChip(Capsule(), stroke: .none)` — no new outline on peer name tags. NOTE: this view is hosted inside a `MapViewAnnotation` (`UIHostingController`); after Step 4's build, spot-check one group preview render if available — environment plumbing differs there.
- `HomeGlass.swift` fallback branch: route its *fill* through `AuraTheme.mapScrim(...)` (read the two environment values in the view); the accent stroke stays.
- `MarkSpotToast` ~37: `hairline(.standard)` → read `@Environment(\.colorSchemeContrast)` and pass it. Fill untouched.

- [ ] **Step 3: Regenerate + build + lint** — `cd Aura && xcodegen` (new file!), builder build, `swiftlint --strict` from repo root. Expected: green.

- [ ] **Step 4: Sim-verify with accessibility passes (gate 3)** — navigate HUD one-frame composite (turn card + then-chip + crew pill + rerouting chip if triggerable + controls) and detour chrome: default / Increase Contrast (`xcrun simctl ui <udid> increase_contrast enabled`) / Reduce Transparency. Chips must go solid under both settings.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Theme/MapChip.swift Aura/Sources/Ride/DetourOverlay.swift Aura/Sources/Home/HomeMapCanvas.swift Aura/Sources/Ride/ThenChip.swift Aura/Sources/Ride/NavigateHUDView.swift Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift Aura/Sources/GroupRide/GroupRideMapOverlay.swift Aura/Sources/Home/HomeGlass.swift Aura/Sources/Ride/MarkSpotToast.swift
git commit -m "feat(roh-222): mapChip modifier and chip scrim convergence"
```

---

### Task 6: SwiftLint ban on stray `ultraThinMaterial` (ROH-222)

**Files:**
- Modify: `.swiftlint.yml` (existing `custom_rules:` block)

- [ ] **Step 1: Add the rule**

```yaml
  map_material_outside_theme:
    name: "Bare material outside the Theme layer"
    regex: 'ultraThinMaterial'
    match_kinds:
      - identifier
    excluded:
      - "Aura/Sources/Theme/.*"
      - "Aura/Sources/GroupRide/GroupLobbyView\\.swift"   # lobby card, manual a11y branch — Crew slice
      - "Aura/Sources/GroupRide/GroupRosterSheet\\.swift"  # sheet card, manual a11y branch — Crew slice
      - "Aura/Widgets/.*"                                   # pre-emptive: widget surfaces legitimately use system materials
    message: "Map-floating chips use .mapChip (ROH-222); frosted material is reserved for Theme controls, the lobby/roster cards, and widget surfaces."
    severity: error
```
(No `HomeGlass` exclusion — it contains no bare material; the v1 exclusion was inert.)

- [ ] **Step 2: Negative control with a REAL site** — temporarily add `.background(.ultraThinMaterial, in: Capsule())` to a view in `Aura/Sources/Ride/GPSSignalChip.swift`, run `swiftlint --strict`, confirm the rule fires; revert. Also confirm no comment mention trips it (`HUDControlButton.swift` docs mention the API). Do NOT use a string-interpolation probe — syntax kinds inside interpolations are unreliable and a non-firing probe would tempt you to drop `match_kinds`, which is the guard.

- [ ] **Step 3: Tree green** — `swiftlint --strict`: the four surviving sites (`Theme/MapZoomControl`, `Theme/HUDControlButton`, lobby, roster) are all exempt.

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
- Produces: `BrowsePuckMetrics.standard`, `RidingPuckMetrics.standard` (all `Double`); Task 8 consumes them. **These values are the gate-1a-approved design — not proposals.**

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AuraCore

struct PuckMetricsTests {
    // Spec §3 invariant 2: Mapbox paints shadow → bearing → top, so the wedge
    // (bearingImage) draws UNDER the core. Its tip must clear the core + ring.
    @Test func browseWedgeTipClearsTheCoreAndRing() {
        let m = BrowsePuckMetrics.standard
        #expect(m.wedgeTipRadius > m.coreDiameter / 2 + m.mintRingWidth)
    }

    // Bearing images rotate about the canvas center: content must fit the
    // inscribed circle or rotation clips it.
    @Test func browseCanvasContainsTheRotatingWedge() {
        let m = BrowsePuckMetrics.standard
        #expect(m.canvasSide >= 2 * m.wedgeTipRadius)
    }

    @Test func ridingTriangleSurvivesRotation() {
        let m = RidingPuckMetrics.standard
        let diagonal = (m.arrowLength * m.arrowLength + m.arrowWidth * m.arrowWidth)
            .squareRoot()
        #expect(m.canvasSide >= diagonal)
    }

    @Test func ridingCornersLeaveAFlatBase() {
        let m = RidingPuckMetrics.standard
        #expect(m.cornerRadius * 2 < m.arrowWidth)
    }

    // The riding renderer derives its layer insets from these — they must nest.
    @Test func ridingEdgeAndOutlineNestInsideTheTriangle() {
        let m = RidingPuckMetrics.standard
        #expect(2 * (m.mintEdgeWidth + m.inkOutlineWidth) < m.arrowLength)
    }
}
```
(v1's `bothStatesUseSquareCanvases` is gone — both reviewers showed it asserted nothing.)

- [ ] **Step 2: Run to verify failure**, then **Step 3: Implement**

```swift
/// Geometry for the Aura puck bitmaps (ROH-219/220). Pure `Double` so the macOS
/// package job builds it. `PuckImageRenderer` (app target) rasterizes from these.
/// Values are the PO-approved gate-1a design (2026-08-31); tune at gate 1b only
/// within these tests' invariants.
public struct BrowsePuckMetrics {
    public let coreDiameter: Double     // white core, including the ink outline
    public let inkOutlineWidth: Double
    public let mintRingWidth: Double
    public let wedgeTipRadius: Double   // canvas center → heading-wedge tip
    public let canvasSide: Double       // square bitmap side (pt)

    public static let standard = BrowsePuckMetrics(
        coreDiameter: 18, inkOutlineWidth: 1.5, mintRingWidth: 2,
        wedgeTipRadius: 16, canvasSide: 34)
}

public struct RidingPuckMetrics {
    public let arrowLength: Double      // triangle height, tip to base
    public let arrowWidth: Double       // base width
    public let cornerRadius: Double
    public let inkOutlineWidth: Double
    public let mintEdgeWidth: Double    // 2.5 — PO-bumped at gate 1a
    public let canvasSide: Double

    public static let standard = RidingPuckMetrics(
        arrowLength: 22, arrowWidth: 20, cornerRadius: 3,
        inkOutlineWidth: 1.5, mintEdgeWidth: 2.5, canvasSide: 32)
}
```

- [ ] **Step 4: Run to verify pass**, then **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Theme/PuckMetrics.swift AuraCore/Tests/AuraCoreTests/PuckMetricsTests.swift
git commit -m "feat(roh-219): gate-1a PuckMetrics with paint-order and rotation invariants"
```

---

### Task 8: Browse puck on Home's live map (ROH-219)

Gate 1a is PASSED (design locked — see ROH-219's gate comment). Gate 1b (this task's Step 4 evidence) is the remaining approval before merge.

**Files:**
- Create: `Aura/Sources/Theme/PuckImageRenderer.swift`
- Modify: `Aura/Sources/Home/HomeLiveMap.swift` (the `Puck2D` line, ~64)

**Interfaces:**
- Consumes: `BrowsePuckMetrics.standard`, `RidingPuckMetrics.standard` (Task 7), `AuraTheme` colors.
- Produces: `enum AuraPuck { static let browseTop, browseBearing, ridingBearing, clearTop: UIImage }` — Task 9 consumes `ridingBearing`/`clearTop`.

- [ ] **Step 1: Write the renderer**

```swift
import UIKit
import AuraCore

/// Rasterizes the Aura puck bitmaps from `PuckMetrics` + theme tokens (ROH-219/220).
/// `static let` is load-bearing: MapboxMaps diffs Puck2D configurations by UIImage
/// POINTER identity, and the navigate HUD's Map content can re-evaluate at 30 Hz — a
/// fresh image per pass would re-upload bitmaps to the style every frame.
enum AuraPuck {
    /// Browse core: white disc, ink outline, mint ring. "White = me" (spec §2).
    static let browseTop: UIImage = {
        let m = BrowsePuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let coreRadius = CGFloat(m.coreDiameter) / 2
            fillCircle(c, center: center, radius: coreRadius + CGFloat(m.mintRingWidth),
                       color: AuraTheme.routeUIColor)                    // mint ring
            fillCircle(c, center: center, radius: coreRadius,
                       color: AuraTheme.routeCasingUIColor)              // ink outline
            fillCircle(c, center: center, radius: coreRadius - CGFloat(m.inkOutlineWidth),
                       color: .white)                                    // white core
        }
    }()

    /// Browse heading wedge — MINT with an ink backing, so it reads on the dark
    /// terrain (plan-review finding: a near-black wedge on a near-black basemap is
    /// invisible). Paints UNDER the top image; only the part beyond the ring shows,
    /// which PuckMetricsTests pins.
    static let browseBearing: UIImage = {
        let m = BrowsePuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let ringRadius = CGFloat(m.coreDiameter) / 2 + CGFloat(m.mintRingWidth)
            // Ink backing wedge (slightly larger, gives the mint tip a dark seat).
            wedge(c, center: center, tipRadius: CGFloat(m.wedgeTipRadius) + 1.5,
                  halfBase: ringRadius * 0.5, baseRadius: ringRadius * 0.55,
                  color: AuraTheme.routeCasingUIColor)
            // Mint wedge on top.
            wedge(c, center: center, tipRadius: CGFloat(m.wedgeTipRadius),
                  halfBase: ringRadius * 0.4, baseRadius: ringRadius * 0.6,
                  color: AuraTheme.routeUIColor)
        }
    }()

    /// Riding puck: ROUNDED TRIANGLE, locked at PO gate 1a (2026-08-31) — white
    /// body, ink outline, bumped 2.5pt mint edge. Corner rounding comes from
    /// fill+stroke with a round line join (stroke width = 2 × cornerRadius).
    static let ridingBearing: UIImage = {
        let m = RidingPuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            c.setLineJoin(.round)
            let layers: [(scale: Double, color: UIColor)] = [
                (1.0, AuraTheme.routeUIColor),
                (insetScale(m, by: m.mintEdgeWidth), AuraTheme.routeCasingUIColor),
                (insetScale(m, by: m.mintEdgeWidth + m.inkOutlineWidth), .white),
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

    /// Mandatory transparent top for the riding state: a nil topImage falls back to
    /// Mapbox's stock blue dot rendered ON TOP of the bearing arrow (spec §3.1).
    static let clearTop: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    // MARK: - Drawing helpers (no force casts — the TaskCompleted gate lints --strict)

    private static func fillCircle(_ c: CGContext, center: CGPoint, radius: CGFloat,
                                   color: UIColor) {
        c.setFillColor(color.cgColor)
        c.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2))
    }

    private static func wedge(_ c: CGContext, center: CGPoint, tipRadius: CGFloat,
                              halfBase: CGFloat, baseRadius: CGFloat, color: UIColor) {
        c.setFillColor(color.cgColor)
        c.move(to: CGPoint(x: center.x, y: center.y - tipRadius))
        c.addLine(to: CGPoint(x: center.x - halfBase, y: center.y - baseRadius))
        c.addLine(to: CGPoint(x: center.x + halfBase, y: center.y - baseRadius))
        c.closePath()
        c.fillPath()
    }

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
    /// approximation — gate 1b judges the pixels).
    private static func insetScale(_ m: RidingPuckMetrics, by points: Double) -> Double {
        max(0, (m.arrowLength - 2 * points) / m.arrowLength)
    }
}
```

- [ ] **Step 2: Wire the browse state** — `HomeLiveMap.swift`, the `Puck2D` line:

```swift
Puck2D(bearing: .heading)
    .topImage(AuraPuck.browseTop)
    .bearingImage(AuraPuck.browseBearing)
    .showsAccuracyRing(true)
    .accuracyRingColor(AuraTheme.routeUIColor.withAlphaComponent(0.12))
    .accuracyRingBorderColor(AuraTheme.routeUIColor.withAlphaComponent(0.35))
```

- [ ] **Step 3: Regenerate (`cd Aura && xcodegen` — new file), build, install** — builder.

- [ ] **Step 4: Sim-verify (gate 1b evidence)** — Home → tap map: screenshot + zoom on the puck. White core, ink outline, mint ring, MINT wedge visible against the terrain, subtle accuracy ring, zero blue. Deliver for gate 1b sign-off; **Task 9 does not merge without it.**

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Theme/PuckImageRenderer.swift Aura/Sources/Home/HomeLiveMap.swift
git commit -m "feat(roh-219): white-core Aura browse puck with real accuracy ring on Home"
```

---

### Task 9: Riding puck on both HUDs (ROH-220) — ⛔ merge-held on device heading check

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift` (the `Puck2D` line — Task 3 shifted line numbers; find `Puck2D(bearing: .heading)`)
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (same)

**Interfaces:** consumes `AuraPuck.ridingBearing`, `AuraPuck.clearTop` (Task 8).

- [ ] **Step 1: Wire both HUD sites**

```swift
Puck2D(bearing: .heading)
    .topImage(AuraPuck.clearTop)        // mandatory: nil ships the stock blue dot on top
    .bearingImage(AuraPuck.ridingBearing)
```
No accuracy ring on the HUDs.

- [ ] **Step 2: Build + sim-verify statics** — screenshot both HUDs mid-ride: rounded-triangle renders white/ink/mint at bearing 0; no blue anywhere. **Also check the puck draws ABOVE the route line** — the puck does not participate in the SwiftUI layer-ordering chain (`MountedPuck.updateMetadata` is a no-op), so this is an explicit acceptance check now and again at Task 13; if the line covers the puck, the fix belongs in Task 13's layer placement, not here.

- [ ] **Step 3: Commit, open PR, apply the hold structurally**

```bash
git add Aura/Sources/Ride/RideMapView.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-220): white rounded-triangle riding puck on both HUDs"
```
Open the PR **as a draft** (a hold needs a mechanism, not a sentence — this repo has been bitten by holds with no releaser): it converts to ready only after the device heading check. PR body: *Tier 2 merge hold — sim delivers no CLHeading; bearing-image rotation convention is hardware-only (VERIFICATION.md Tier-2 class, ROH-213). Draft until the device pass; releaser = the ROH-220 device check, recorded on the issue.* Mark ROH-220 blocked on the board; watch for Linear auto-completing it from the PR.

---

### Task 10: `fractionTraveled` plumbing (ROH-221, TDD)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift` (GuidanceUpdate)
- Create: `AuraCore/Sources/AuraCore/Guidance/RouteTrim.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RouteTrimTests.swift`
- Modify: `Aura/Sources/Routing/MapboxGuidanceSession.swift` (the `GuidanceUpdate(...)` construction, ~:189)

**Interfaces:**
- Produces: `GuidanceUpdate.fractionTraveled: Double?` (declared AND passed **after `durationRemainingSeconds`, before `currentStreetName`** — Swift requires declaration order at labelled call sites); `RouteTrim.sanitized(_:) -> Double?`; `RouteTrim.quantized(_:step:) -> Double`. Tasks 10B and 13 consume them.

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

    @Test func sanitizedRejectsNonFinite() {
        #expect(RouteTrim.sanitized(.nan) == nil)
        #expect(RouteTrim.sanitized(.infinity) == nil)
        #expect(RouteTrim.sanitized(nil) == nil)
    }

    // Tolerance, not ==: quantized values are computed Doubles and some steps
    // produce representation error (0.3 → 0.30000000000000004).
    @Test func quantizedSnapsDown() {
        #expect(abs(RouteTrim.quantized(0.4239) - 0.42) < 1e-9)
        #expect(abs(RouteTrim.quantized(0.9999) - 0.995) < 1e-9)
        #expect(abs(RouteTrim.quantized(1.0) - 1.0) < 1e-9)
    }
}
```

- [ ] **Step 2: Run to verify failure**, then **Step 3: Implement**

```swift
/// Trim math for the navigate traveled-dim (ROH-221). Pure: the HUD passes the SDK's
/// `fractionTraveled` through `sanitized` then `quantized` before it touches the trim
/// paint property — a non-finite or out-of-range value means "no dim", never a wrong dim.
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
`GuidanceUpdate`: add after `durationRemainingSeconds` (field and init parameter, `= nil`):
```swift
/// How far along the guided route the rider is, 0...1, from the engine's own
/// progress (dimensionless — immune to cross-geometry subtraction). nil until
/// known; `ScriptedGuidanceSession` stays nil forever, so the golden ride never
/// exercises the trim path.
public var fractionTraveled: Double?
```

- [ ] **Step 4: Full `swift test`** (two totals, both green — 15 existing fully-labelled `GuidanceUpdate(` call sites stay valid via the default).

- [ ] **Step 5: Map it in the session** — in the construction at `MapboxGuidanceSession.swift` ~:189, insert **after the `durationRemainingSeconds:` argument**:

```swift
fractionTraveled: RouteTrim.sanitized(progress.fractionTraveled),
```

- [ ] **Step 6: Builder build**, then **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift AuraCore/Sources/AuraCore/Guidance/RouteTrim.swift AuraCore/Tests/AuraCoreTests/RouteTrimTests.swift Aura/Sources/Routing/MapboxGuidanceSession.swift
git commit -m "feat(roh-221): carry sanitized fractionTraveled on GuidanceUpdate"
```

---

### Task 10B: Reroute-window integrity in GuidanceViewModel (ROH-221, TDD) — *new in v2*

Both plan reviewers converged here: `GuidanceViewModel.applyProgress` sets
`isRerouting = false` on EVERY progress tick, and Mapbox keeps publishing progress
against the old route throughout a reroute fetch — so `isRerouting` is true for under
a second of a multi-second reroute, the "full bright while rerouting" behavior is
unimplementable, and a stale `fractionTraveled` survives the geometry swap (wrong dim,
guaranteed, for ~1 tick). The only nearby test scripts `[.rerouting, .rerouted]` with
no intervening progress — the exact production interleaving is never exercised.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift` (`applyProgress` ~:143-146; the `.rerouted` case ~:109-111)
- Test: `AuraCore/Tests/AuraKitTests/GuidanceViewModelTests.swift` (extend)

**Interfaces:**
- Produces: the invariants Task 13 relies on — `isRerouting` stays true from `.rerouting` until `.rerouted`; `lastUpdate.fractionTraveled` is nil from `.rerouted` until the next progress event.

- [ ] **Step 1: Write the failing tests** (follow the file's existing scripted-session test style — it drives the view model with event arrays):

```swift
@Test func progressDuringRerouteDoesNotClearIsRerouting() async {
    // Production interleaving: Mapbox keeps publishing progress against the OLD
    // route while it re-fetches. The rerouting state must survive those ticks.
    // Script: [.progress(a), .rerouting, .progress(b), .progress(c)] →
    // isRerouting == true at the end.
}

@Test func reroutedClearsIsReroutingAndStaleFraction() async {
    // Script: [.progress(a with fractionTraveled 0.4), .rerouting, .rerouted(coords)]
    // → isRerouting == false, lastUpdate != nil, lastUpdate?.fractionTraveled == nil
    // (the 0.4 measured the OLD route; applying it to the new geometry is the
    // wrong-dim the spec forbids).
}

@Test func nextProgressAfterRerouteRestoresFraction() async {
    // Script: [..., .rerouted(coords), .progress(d with fractionTraveled 0.05)]
    // → lastUpdate?.fractionTraveled == 0.05.
}
```
Write them as real tests against the file's existing helpers (it already builds scripted `GuidanceUpdate`s); run and watch the first two FAIL against current behavior.

- [ ] **Step 2: Implement**

In `applyProgress`, **delete `isRerouting = false`** — the flag is cleared by `.rerouted` (already at ~:111) and that is the only honest clear. (If the event stream has a terminal case — arrival/ended — clear there too so a reroute that never completes can't stick the pill; check the enum and mirror `.rerouted`'s clear at the terminal case.)

In the `.rerouted` case, clear the stale fraction alongside the geometry swap:
```swift
case .rerouted(let geometry):
    routeGeometry = geometry
    isRerouting = false
    // The last fraction measured the OLD route; nil it so no frame pairs it with
    // the new geometry (trim renders full-bright until fresh progress arrives).
    if var update = lastUpdate {
        update.fractionTraveled = nil
        lastUpdate = update
    }
```

- [ ] **Step 3: Full `swift test`** — new tests pass; the pre-existing rerouting-pill tests still pass (they assert the pill shows on `.rerouting` and clears on `.rerouted`, which is unchanged; only the progress-tick clear is gone — if one of them scripted a progress-clears-pill expectation, it encoded the bug: update it and say so in the commit).

- [ ] **Step 4: Commit**

```bash
git add AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift AuraCore/Tests/AuraKitTests/GuidanceViewModelTests.swift
git commit -m "fix(roh-221): isRerouting survives progress ticks; stale fraction cleared on reroute"
```

---

### Task 11: Guided-route emission on registry fallback (ROH-221)

**Files:**
- Modify: `Aura/Sources/Routing/MapboxGuidanceSession.swift` (`resolveRoutes` ~:142-173 including the registry-miss `catch` ~:163-172; the `isFirst` suppression ~:77-85)

- [ ] **Step 1: Restructure the resolution so divergence is observable**

The current single-expression fallback cannot report which side fired. Rewrite along:

```swift
// Return the navigated routes AND whether they diverge from the registry's selection.
private func resolveRoutes(...) async -> (routes: NavigationRoutes, divergedFromSelection: Bool) {
    // registry hit path:
    if let entry = ... {
        if let alt = await entry.routes.selectingAlternativeRoute(at: entry.mbRouteIndex - 1) {
            return (alt, false)
        }
        return (entry.routes, true)          // alternative-selection fell to the main route
    }
    // registry miss (relaunch mid-flow): re-fetch — different route by construction
    ...
    return (fetched, true)
}
```
In the event loop, when `divergedFromSelection` is true, do NOT suppress the first `.rerouted` — emit the navigated geometry immediately so `NavigateHUDView` draws the guided line. Normal path unchanged. Keep a permanent `.debug`-level log on the diverged branch.

- [ ] **Step 2: Build + inspect** — builder build; the PR notes this path is registry-fallback-only and not sim-reachable on the happy path.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Routing/MapboxGuidanceSession.swift
git commit -m "fix(roh-221): emit navigated geometry when guidance diverges from the selected route"
```

---

### Task 12: Casing, caps, and endpoint markers (ROH-221)

**Files:**
- Create: `Aura/Sources/Ride/RouteEndpointMarkers.swift`
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` (the `PolylineAnnotationGroup` in the map content, ~:331-339 at HEAD)
- Modify: `Aura/Sources/Ride/RideMapView.swift` (`detourPolyline`, ~:117-126 at HEAD)
- Modify: `Aura/Sources/Ride/StaticRouteMap.swift` (~:29-34)
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (destination flag only — the navigate line itself is rebuilt by Task 13; adding casing here would be churn)

**Interfaces:**
- Produces: `OriginRingView`, `DestinationMarkerView`.

- [ ] **Step 1: Marker views**

```swift
import SwiftUI

/// Route endpoint markers (ROH-221). Deliberately NOT in the puck vocabulary: the
/// preview's origin can be the denied-permission fallback coordinate (spec §4).
/// The ink seat is a LARGER circle UNDER the mint ring (a .background on a same-size
/// ring renders inside it and adds nothing — plan-review finding).
struct OriginRingView: View {
    var body: some View {
        ZStack {
            Circle().fill(AuraTheme.background).frame(width: 20, height: 20)   // ink seat
            Circle().strokeBorder(AuraTheme.accent, lineWidth: 3)
                .frame(width: 16, height: 16)
        }
        .accessibilityHidden(true)
    }
}

/// Filled destination marker: ink seat, mint disc, ink flag glyph.
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

- [ ] **Step 2: Casing + caps — adapt to each site's EXISTING group form**

Add to the existing annotations/groups (do not replace the group construction — `StaticRouteMap` uses the data-driven `PolylineAnnotationGroup(Array(...), id:)` form for pause-split segments, and the detour has its own dim/`lineDash` context):
- per annotation: `.lineBorderColor(StyleColor(AuraTheme.routeCasingUIColor))` + `.lineBorderWidth(2)`
- per group: `.lineCap(.round)` + `.lineJoin(.round)`
Sites: preview (width 5), detour (width 6), `StaticRouteMap` (width 5, every segment piece). Navigate gets its casing in Task 13's layer rebuild.

- [ ] **Step 3: Endpoint markers**

- Preview: `MapViewAnnotation(coordinate: selectedRoute.first) { OriginRingView() }` and `...last { DestinationMarkerView() }`, each `.allowOverlapWithPuck(true)`.
- Navigate: destination flag at the drawn geometry's last coordinate, `.allowOverlapWithPuck(true)`. NOTE: the map content sits in a 30 Hz `TimelineView` during group rides — declare the annotation with stable identity (coordinate-derived) and no per-frame closure work.
- Detour: destination flag at the detour's last coordinate while active, `.allowOverlapWithPuck(true)`.
- Summary: no markers.

- [ ] **Step 4: Regenerate (`cd Aura && xcodegen` — new file), build, sim-verify (gate 2 stills)** — preview (cased line, round caps, origin ring, flag), summary after a sim ride (cased), detour if reachable.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/RouteEndpointMarkers.swift Aura/Sources/Plan/RoutePreviewView.swift Aura/Sources/Ride/RideMapView.swift Aura/Sources/Ride/StaticRouteMap.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-221): route casing, round caps, endpoint markers (non-navigate sites)"
```

---

### Task 13: Traveled-dim on navigate via style layers (ROH-221) — *rebuilt in v2*

**Why not `PolylineAnnotationGroup` (plan-review BLOCKER):** `lineTrimOffset` requires
`lineMetrics: true` on the GeoJSON source; the annotation manager hardcodes a source
without it and exposes no API to set it. The failure mode is not "no dim" — the line
vanishes with a Metal shader error (mapbox-maps-ios#1927), i.e. the navigate route
would render as ONLY the dim under-layer for the whole ride. Mapbox's own vanishing
route line uses raw style primitives for exactly this
(`RouteLineMapFeatures.swift:173-234`: `lineMetrics = true`, stacked `LineLayer`s,
explicit slots). This task follows that pattern.

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift` (new token)
- Test: `AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift` (extend)
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (the route rendering inside the map content — REPLACING the polyline group while **keeping** the `count > 1` emptiness guard (`RideMapView.swift:77-79` documents why: an empty group/source still mounts style objects) and **keeping** Task 12's destination-flag annotation)

**Interfaces:**
- Consumes: `guidance.lastUpdate?.fractionTraveled` + `guidance.isRerouting` (Task 10/10B semantics), `RouteTrim.quantized`, `AuraTheme.routeUIColor`/`routeCasingUIColor`.
- Produces: `AuraPalette.routeDimOpacity`.

- [ ] **Step 1: Token + failing test** — in `WCAGContrastTests.swift`, using the file's REAL helper (signature `composite(_ fg:, over bg:, alpha:)` — fg first, `over:` second, `alpha:` LAST) and its existing bright-basemap convention (`WCAGContrast.white(0.75)`):

```swift
@Test func dimmedRouteIsVisibleButSubordinateOnBothBasemaps() {
    let dimOnDark = WCAGContrast.composite(AuraPalette.mint,
                                           over: AuraPalette.nearBlack,
                                           alpha: AuraPalette.routeDimOpacity)
    #expect(WCAGContrast.ratio(dimOnDark, AuraPalette.nearBlack) >= 2.0)   // visible
    #expect(WCAGContrast.ratio(AuraPalette.mint, dimOnDark) >= 3.0)        // subordinate

    // .standard map style: the dim trace must still separate from a bright basemap.
    let bright = WCAGContrast.white(0.75)
    let dimOnBright = WCAGContrast.composite(AuraPalette.mint, over: bright,
                                             alpha: AuraPalette.routeDimOpacity)
    #expect(WCAGContrast.ratio(AuraPalette.mint, dimOnBright) >= 1.5)
}
```
These are a sanity band, not a pin — the PO tunes the exact value at gate 2; the test
keeps the token out of the invisible (<0.2) and shouting (>0.55) regimes. Move the
token within the band, not the thresholds.

- [ ] **Step 2: Run (fails on missing token), add the token, run again (passes)**

```swift
/// Opacity of the ridden portion of the navigate route line (ROH-221). Gate-2-tunable
/// within WCAGContrastTests' band.
public static let routeDimOpacity = 0.35
```

- [ ] **Step 3: Rebuild the navigate route rendering on style primitives**

Inside the existing `if (guidance.routeGeometry ?? route.geometry).count > 1` guard,
replace the `PolylineAnnotationGroup` with a `lineMetrics` source + two layers,
mirroring the SDK's own vanishing-route pattern (see
`SourcePackages/checkouts/mapbox-navigation-ios/Sources/MapboxNavigationCore/Map/Style/RouteLineMapFeatures.swift`
and the SwiftUI style-content examples in the maps checkout for the exact builder
placement in 11.28.0):

```swift
let routeCoords = ...  // same derivation as today
var source = GeoJSONSource(id: "aura-nav-route")
source.data = .feature(Feature(geometry: .lineString(LineString(routeCoords))))
source.lineMetrics = true   // REQUIRED for line-trim; absent = shader failure, not no-op

var dimLayer = LineLayer(id: "aura-nav-route-dim", source: "aura-nav-route")
dimLayer.lineColor = .constant(StyleColor(AuraTheme.routeUIColor))
dimLayer.lineOpacity = .constant(AuraPalette.routeDimOpacity)
dimLayer.lineWidth = .constant(6)
dimLayer.lineCap = .constant(.round)
dimLayer.lineJoin = .constant(.round)

var brightLayer = LineLayer(id: "aura-nav-route-bright", source: "aura-nav-route")
brightLayer.lineColor = .constant(StyleColor(AuraTheme.routeUIColor))
brightLayer.lineWidth = .constant(6)
brightLayer.lineBorderColor = .constant(StyleColor(AuraTheme.routeCasingUIColor))
brightLayer.lineBorderWidth = .constant(2)
brightLayer.lineCap = .constant(.round)
brightLayer.lineJoin = .constant(.round)
brightLayer.lineTrimOffset = .constant([0, trimEnd])   // trimmed span reveals the dim layer
```
declared dim-then-bright (the SwiftUI content tree re-asserts declaration-order layer
positions every pass — reviewer-traced through `MapContentNodeContext.resolveLayerPosition`),
with the view's trim state:

```swift
/// Paint-only traveled trim (spec §4). While rerouting (which, after Task 10B,
/// spans the WHOLE fetch window), and until a fresh post-reroute fraction arrives
/// (Task 10B nils the stale one), trim is 0 — full bright line, never a wrong dim.
private var trimEnd: Double {
    guard !guidance.isRerouting,
          let fraction = guidance.lastUpdate?.fractionTraveled else { return 0 }
    return RouteTrim.quantized(fraction)
}
```
**Puck z-order (explicit acceptance):** the puck does not participate in the layer
chain; after this change verify the riding puck still draws ABOVE both route layers.
If inverted: put both LineLayers in a slot below the location indicator (the SDK's own
route uses `.slot(...)`; if the authored terrain style JSON defines no slots, add the
standard slot anchors to the style JSON — we own it — rather than relying on implicit
ordering).

- [ ] **Step 4: Build + full package tests** — builder + `swift test` (both totals).

- [ ] **Step 5: Gate-2 playback recording — concrete recipe (the golden-ride harness CANNOT drive this: `SimulatedRideConfig` swaps in `ScriptedGuidanceSession`, which never emits progress):**

1. Non-harness Debug build installed (Task 12's build). Grant location; set the Pittsburgh fix.
2. In-app: search a destination ~2–3 km away (e.g. Point State Park from the audit tour), Start RIDE.
3. Drive the fix along the drawn route with waypoint playback:
   `xcrun simctl location D221B3C5-13DE-482F-B0FD-017B305EC31B start --speed=7 --distance=30 <lat,lon> <lat,lon> ...` using 8–12 waypoints read off the route's streets — plus, mid-route, ONE waypoint a block off-route (the deliberate deviation), then back.
4. Record throughout: `xcrun simctl io <udid> recordVideo --codec h264 trim-playback.mov` (stop with SIGINT).
5. Confirm on the recording: line starts fully bright; dim grows behind the moving puck; during "Rerouting" (after the deviation) the whole line is bright for the fetch window; after the new route arrives dim restarts from the rider; no seam artifacts; puck above the line.
Deliver the recording for gate 2. PR note: CI's golden ride does not exercise this path.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraCore/Theme/AuraPalette.swift AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-221): traveled-dim via lineMetrics style layers, frozen across the reroute window"
```

---

### Task 14: DESIGN.md, spec sweep, whole-slice evidence (wrap-up)

**Files:**
- Modify: `DESIGN.md`
- Modify: `docs/superpowers/specs/2026-08-31-identity-carriers-design.md` (status line only)

- [ ] **Step 1: Correct DESIGN.md** — remove the stale `SpeedReadout` entry; rewrite the scrim rule as the two-tier grammar (*frosted material = controls; map-floating text chips = `.mapChip`; `GPSSignalChip`/`PauseControl`/`GroupToastHost` use the same `mapScrim` fill through their own shapes; turn card and mark-spot toast are documented exceptions*); document the puck (two-state, `PuckMetrics`, white = me) and the route line (cased planned routes, origin ring on preview, destination flags, paint-only traveled trim frozen across reroutes).

- [ ] **Step 2: Success-criteria sweep** — walk spec §10 against the branch with evidence per criterion; not-met items get fixed or surfaced to the PO explicitly. (Reconciliation already softened §10's logo criterion to "visible wherever visible today" and §10.7's bright-basemap case is now Task 13's test.)

- [ ] **Step 3: Whole-slice screenshot set (gate 4)** — fresh sim pass mirroring the audit set; before/after pairs.

- [ ] **Step 4: Rebase check + commit** — if any workstream PR waited on a gate while main moved, rebase before merge (spec §7 wait protocol).

```bash
git add DESIGN.md docs/superpowers/specs/2026-08-31-identity-carriers-design.md
git commit -m "docs(roh-45): DESIGN.md puck/route/chip grammar + identity-carriers evidence sweep"
```

- [ ] **Step 5: Whole-branch review + board close-out** — most-capable-model review per the pipeline; then statuses: 218/219/221/222/223 → Done as PRs merge; 220 stays draft until the device heading check; 224 stays queued. Revert any Linear auto-completions.
