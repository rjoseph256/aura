# Interactive Home Map (ROH-84) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Home's inert terrain image into a movable map — pan/pinch-zoom, centered on the rider, that keeps the authored Aura terrain look — while preserving Home's zero-cost untouched-idle state.

**Architecture:** Approach B (snapshot idle → live map on interaction). AuraCore holds the pure, unit-tested logic (camera constants + reset rule, request zoom/precision, cache bounding, phase reducer). The app target holds the SDK/UIKit surfaces (device-scale snapshotter, a live `Map`, and a `HomeMapCanvas` state container that swaps snapshot↔live, gates on scene/nav lifecycle, and persists the session camera). Two device spikes (multi-renderer teardown ordering; handoff seam) gate the approach and run first inside Task 8.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, MapboxMaps v11 (`Map(viewport:)`, `Viewport`, `@MapContentBuilder`, `Puck2D`, `Snapshotter`), Swift Testing (AuraCore), XCUITest.

## Global Constraints

- **AuraCore is macOS-CI-safe:** no `MapboxMaps`/`UIKit`/`CoreLocation` imports in `AuraCore/Sources`. iOS-only APIs stay in the app target. (Existing rule; see `TerrainStyle`/`TerrainSnapshotRequest` — pure today.)
- **Coordinate type** is `AuraCore.Coordinate(latitude:longitude:)`.
- **Authored style:** live map uses `AuraKit.MapStyle.auraTerrain.mapboxStyle` (already bridges the bundled JSON via `AuraTerrainStyleLoader`, `.dark` fallback). Snapshot uses `TerrainStyle.authoredStyleIdentity`.
- **Gestures:** pan + pinch-zoom only. Rotation and pitch disabled. Zoom clamped to `HomeMapCamera.minZoom…maxZoom`.
- **Camera lifecycle:** persists within an app session; resets to the rider only on cold launch or after a completed ride; NO idle-timeout camera reset.
- **Single-renderer invariant (ROH-7):** never two live Mapbox renderers at once. Home must be in `.idle` (snapshot, no renderer) before any route push mounts its map.
- **Location (ROH-83):** untouched idle holds no renderer and no standing GPS. The live map's `Puck2D` runs Mapbox's own location provider — it must start only in `.live` and stop on teardown.
- **Commit** after each task's tests pass. Branch: current worktree branch `claude/home-screen-map-scroll-0dc1da`.
- **AuraCore tests** run with `cd AuraCore && swift test`. **App builds/tests** run via the `apple-platform-build-tools:builder` agent (regenerate the Xcode project with `xcodegen` first — it is gitignored).

---

### Task 1: Home map camera constants + reset rule (AuraCore, pure)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Home/HomeMapCamera.swift`
- Test: `AuraCore/Tests/AuraKitTests/HomeMapCameraTests.swift`

**Interfaces:**
- Consumes: `AuraCore.Coordinate`, `TerrainSnapshotRequest.center(forRider:)`.
- Produces: `HomeMapCamera(center:zoom:)`, `HomeMapCamera.defaultZoom/minZoom/maxZoom`, `HomeMapCamera.initial(forRider:) -> HomeMapCamera`, `HomeMapCamera.clampedZoom() -> HomeMapCamera`, `HomeCameraResetEvent`, `HomeMapCamera.shouldReset(on:) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AuraCore
@testable import AuraKit

@Suite struct HomeMapCameraTests {
    @Test func defaultZoomMatchesLegacySnapshotZoom() {
        #expect(HomeMapCamera.defaultZoom == 12.5)
    }

    @Test func initialCentersOnRiderWhenPresent() {
        let rider = Coordinate(latitude: 37.77, longitude: -122.41)
        let cam = HomeMapCamera.initial(forRider: rider)
        #expect(cam.center == rider)
        #expect(cam.zoom == HomeMapCamera.defaultZoom)
    }

    @Test func initialFallsBackToCuratedCenterWhenRiderNil() {
        let cam = HomeMapCamera.initial(forRider: nil)
        #expect(cam.center == TerrainSnapshotRequest.curatedDefaultCenter)
    }

    @Test func clampBoundsZoomBothWays() {
        let low = HomeMapCamera(center: .init(latitude: 0, longitude: 0), zoom: 1).clampedZoom()
        let high = HomeMapCamera(center: .init(latitude: 0, longitude: 0), zoom: 99).clampedZoom()
        #expect(low.zoom == HomeMapCamera.minZoom)
        #expect(high.zoom == HomeMapCamera.maxZoom)
    }

    @Test func resetsOnColdLaunchAndPostRideNotOnReturn() {
        #expect(HomeMapCamera.shouldReset(on: .coldLaunch) == true)
        #expect(HomeMapCamera.shouldReset(on: .rideCompleted) == true)
        #expect(HomeMapCamera.shouldReset(on: .returnedToHome) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter HomeMapCameraTests`
Expected: FAIL — `HomeMapCamera` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import AuraCore

/// The Home map's camera (center + zoom), shared by the idle snapshot and the live map so
/// they cannot drift. Pure — the app target maps this onto a MapboxMaps `Viewport`.
public struct HomeMapCamera: Equatable, Sendable {
    public var center: Coordinate
    public var zoom: Double

    public init(center: Coordinate, zoom: Double) {
        self.center = center
        self.zoom = zoom
    }

    /// Matches the legacy snapshot zoom so today's framing is preserved.
    public static let defaultZoom: Double = 12.5
    /// Neighborhood-out … street-level-in. Bounds keep Home calm and legible.
    public static let minZoom: Double = 10.5
    public static let maxZoom: Double = 17.0

    public static func initial(forRider rider: Coordinate?) -> HomeMapCamera {
        HomeMapCamera(center: TerrainSnapshotRequest.center(forRider: rider), zoom: defaultZoom)
    }

    public func clampedZoom() -> HomeMapCamera {
        HomeMapCamera(center: center, zoom: min(max(zoom, Self.minZoom), Self.maxZoom))
    }
}

/// Events that may reset the Home camera back to the rider.
public enum HomeCameraResetEvent: Sendable, Equatable {
    case coldLaunch, rideCompleted, returnedToHome
}

public extension HomeMapCamera {
    /// The camera resets to the rider only on a cold launch or after a completed ride; a plain
    /// return to Home preserves the rider's panned camera (ROH-84 session persistence).
    static func shouldReset(on event: HomeCameraResetEvent) -> Bool {
        switch event {
        case .coldLaunch, .rideCompleted: return true
        case .returnedToHome: return false
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter HomeMapCameraTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/HomeMapCamera.swift AuraCore/Tests/AuraKitTests/HomeMapCameraTests.swift
git commit -m "feat(home): pure HomeMapCamera constants + reset rule (ROH-84)"
```

---

### Task 2: TerrainSnapshotRequest gains zoom + precise-center quantization (AuraCore, pure)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift`
- Test: `AuraCore/Tests/AuraKitTests/TerrainSnapshotRequestTests.swift` (add cases)

**Interfaces:**
- Consumes: `HomeMapCamera.defaultZoom`.
- Produces: `TerrainSnapshotRequest.init(center:styleURI:width:height:zoom:quantizationDegrees:)` (new params defaulted), `TerrainSnapshotRequest.zoom`, `TerrainSnapshotRequest.preciseQuantizationDegrees`. `cacheKey` now includes a zoom bucket.

**Why:** the on-appear rider-centered snapshot must render at the rider's true center (the ~1.1 km default grid can offset the idle image up to ~0.8 km from where the live map opens → handoff jump). A finer grid (~110 m) keeps caching useful while making the offset sub-visible at these zooms.

- [ ] **Step 1: Write the failing test** (append to `TerrainSnapshotRequestTests.swift`)

```swift
@Test func cacheKeyIncludesZoomBucket() {
    let base = TerrainSnapshotRequest(center: .init(latitude: 40.44, longitude: -79.99),
                                      styleURI: "aura-terrain-v5", width: 390, height: 844)
    let zoomed = TerrainSnapshotRequest(center: .init(latitude: 40.44, longitude: -79.99),
                                        styleURI: "aura-terrain-v5", width: 390, height: 844, zoom: 15)
    #expect(base.cacheKey != zoomed.cacheKey)
    #expect(base.zoom == HomeMapCamera.defaultZoom)
}

@Test func preciseQuantizationDistinguishesNearbyCenters() {
    // ~150 m apart: default 0.01 grid merges them; precise 0.001 grid must not.
    let a = Coordinate(latitude: 40.4400, longitude: -79.9959)
    let b = Coordinate(latitude: 40.4413, longitude: -79.9959)
    let coarseA = TerrainSnapshotRequest(center: a, styleURI: "s", width: 100, height: 100)
    let coarseB = TerrainSnapshotRequest(center: b, styleURI: "s", width: 100, height: 100)
    #expect(coarseA.cacheKey == coarseB.cacheKey)
    let fineA = TerrainSnapshotRequest(center: a, styleURI: "s", width: 100, height: 100,
        quantizationDegrees: TerrainSnapshotRequest.preciseQuantizationDegrees)
    let fineB = TerrainSnapshotRequest(center: b, styleURI: "s", width: 100, height: 100,
        quantizationDegrees: TerrainSnapshotRequest.preciseQuantizationDegrees)
    #expect(fineA.cacheKey != fineB.cacheKey)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter TerrainSnapshotRequestTests`
Expected: FAIL — no `zoom` param / member.

- [ ] **Step 3: Write minimal implementation** (replace the struct body's stored props + init; keep `fnv1a`, quantization constant, and the `center(forRider:)` extension unchanged)

```swift
public struct TerrainSnapshotRequest: Equatable, Sendable {
    public static let quantizationDegrees = 0.01 // ~1.1 km per grid cell (default: GPS-jitter tolerant).
    public static let preciseQuantizationDegrees = 0.001 // ~110 m: rider-centered on-appear image.

    public let center: Coordinate
    public let styleURI: String
    public let zoom: Double
    public let widthBucket: Int
    public let heightBucket: Int
    public let cacheKey: String

    public init(center: Coordinate, styleURI: String, width: Double, height: Double,
                zoom: Double = HomeMapCamera.defaultZoom,
                quantizationDegrees: Double = TerrainSnapshotRequest.quantizationDegrees) {
        self.center = center
        self.styleURI = styleURI
        self.zoom = zoom
        let q = quantizationDegrees
        let latCell = Int((center.latitude / q).rounded())
        let lngCell = Int((center.longitude / q).rounded())
        self.widthBucket = Int((width / 10).rounded()) * 10
        self.heightBucket = Int((height / 10).rounded()) * 10
        let zoomBucket = Int((zoom * 10).rounded())
        let styleHash = Self.fnv1a(styleURI)
        self.cacheKey = "terrain-\(latCell)-\(lngCell)-z\(zoomBucket)-\(widthBucket)x\(heightBucket)-s\(styleHash)"
    }
    // fnv1a(_:) unchanged below.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter TerrainSnapshotRequestTests`
Expected: PASS (existing + 2 new). Existing cache-key-string assertions that hardcode the old format must be updated to the new `-z…` format if present.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift AuraCore/Tests/AuraKitTests/TerrainSnapshotRequestTests.swift
git commit -m "feat(home): snapshot request carries zoom + precise-center grid (ROH-84)"
```

---

### Task 3: Bound the snapshot disk cache (AuraCore, pure)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Home/TerrainSnapshotDiskCache.swift`
- Test: `AuraCore/Tests/AuraKitTests/TerrainSnapshotDiskCacheTests.swift` (add cases)

**Interfaces:**
- Produces: `TerrainSnapshotDiskCache.totalBytes() -> Int`, `TerrainSnapshotDiskCache.prune(toMaxBytes:)`, `TerrainSnapshotDiskCache.defaultMaxBytes` (= 25 MB).

**Why:** once snapshots follow the rider, the coordinate-keyed cache grows without bound; `Caches/` OS eviction is unpredictable and can stall a re-render mid-session.

- [ ] **Step 1: Write the failing test** (append)

```swift
@Test func pruneEvictsOldestUntilUnderLimit() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("terrain-prune-\(UUID().uuidString)", isDirectory: true)
    let cache = TerrainSnapshotDiskCache(directory: dir)
    // Three 10-byte entries, written oldest-first with distinct mod dates.
    for key in ["a", "b", "c"] {
        cache.write(Data(repeating: 0, count: 10), for: key)
        let url = cache.url(for: key)
        // Force ascending modification dates so LRU order is deterministic.
        let date = Date(timeIntervalSince1970: Double(["a", "b", "c"].firstIndex(of: key)!))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    #expect(cache.totalBytes() == 30)
    cache.prune(toMaxBytes: 15) // keep newest ~1 entry
    #expect(cache.read("a") == nil)      // oldest evicted
    #expect(cache.read("c") != nil)      // newest kept
    #expect(cache.totalBytes() <= 15)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter TerrainSnapshotDiskCacheTests`
Expected: FAIL — `totalBytes`/`prune` undefined.

- [ ] **Step 3: Write minimal implementation** (add to the struct)

```swift
public static let defaultMaxBytes = 25 * 1024 * 1024 // 25 MB of terrain snapshots.

private func pngFiles() -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]))?
        .filter { $0.pathExtension == "png" } ?? []
}

public func totalBytes() -> Int {
    pngFiles().reduce(0) { sum, url in
        sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

/// LRU prune by modification date: delete oldest files until total ≤ maxBytes.
public func prune(toMaxBytes maxBytes: Int) {
    var files = pngFiles().map { url -> (URL, Int, Date) in
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (url, vals?.fileSize ?? 0, vals?.contentModificationDate ?? .distantPast)
    }
    var total = files.reduce(0) { $0 + $1.1 }
    guard total > maxBytes else { return }
    files.sort { $0.2 < $1.2 } // oldest first
    for (url, size, _) in files {
        if total <= maxBytes { break }
        try? FileManager.default.removeItem(at: url)
        total -= size
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter TerrainSnapshotDiskCacheTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/TerrainSnapshotDiskCache.swift AuraCore/Tests/AuraKitTests/TerrainSnapshotDiskCacheTests.swift
git commit -m "feat(home): bound terrain snapshot cache with LRU prune (ROH-84)"
```

---

### Task 4: Pure Home map phase reducer (AuraCore, pure)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Home/HomeMapPhase.swift`
- Test: `AuraCore/Tests/AuraKitTests/HomeMapPhaseTests.swift`

**Interfaces:**
- Produces: `HomeMapPhase{.idle,.live}`, `HomeMapTrigger{.activate,.resignedTop,.background,.becameTopActive}`, `HomeMapReducer.next(_:on:) -> HomeMapPhase`.

**Why:** isolates the idle↔live decision from Mapbox/CoreLocation so it is unit-tested; the app maps SDK/scene/nav events onto these abstract triggers.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AuraKit

@Suite struct HomeMapPhaseTests {
    @Test func tapActivatesLiveFromIdle() {
        #expect(HomeMapReducer.next(.idle, on: .activate) == .live)
    }
    @Test func leavingTopOrBackgroundReturnsToIdle() {
        #expect(HomeMapReducer.next(.live, on: .resignedTop) == .idle)
        #expect(HomeMapReducer.next(.live, on: .background) == .idle)
    }
    @Test func returningToHomeDoesNotAutoActivate() {
        // Coming back to Home stays idle until the rider taps again (snapshot resting state).
        #expect(HomeMapReducer.next(.idle, on: .becameTopActive) == .idle)
        #expect(HomeMapReducer.next(.live, on: .becameTopActive) == .live)
    }
    @Test func idleIgnoresLeaveTriggers() {
        #expect(HomeMapReducer.next(.idle, on: .resignedTop) == .idle)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter HomeMapPhaseTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
/// Whether Home's backdrop is the static snapshot (`idle`, no renderer) or the live map (`live`).
public enum HomeMapPhase: Sendable, Equatable { case idle, live }

/// Abstract events the app maps from taps, nav-path changes, and scene phase.
public enum HomeMapTrigger: Sendable, Equatable {
    case activate         // rider tapped "tap to explore", or a fly-to was requested
    case resignedTop      // Home is no longer top-of-stack (a route was pushed)
    case background       // scene left .active
    case becameTopActive  // Home is top-of-stack and the scene is active again
}

public enum HomeMapReducer {
    public static func next(_ phase: HomeMapPhase, on trigger: HomeMapTrigger) -> HomeMapPhase {
        switch trigger {
        case .activate: return .live
        case .resignedTop, .background: return .idle
        case .becameTopActive: return phase // returning to Home never auto-activates
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter HomeMapPhaseTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/HomeMapPhase.swift AuraCore/Tests/AuraKitTests/HomeMapPhaseTests.swift
git commit -m "feat(home): pure Home map phase reducer (ROH-84)"
```

---

### Task 5: Snapshotter renders at device scale + request zoom (app target)

**Files:**
- Modify: `Aura/Sources/Home/TerrainSnapshotRendering.swift` (protocol)
- Modify: `Aura/Sources/Home/MapboxTerrainSnapshotter.swift`
- Modify: `Aura/Sources/Home/HomeBackdrop.swift:41` (pass scale)
- Modify: `Aura/Sources/Home/FirstRunHomeView.swift` (only if it calls `image(for:size:)` directly — else no change; the added param is defaulted)

**Interfaces:**
- Produces: `TerrainSnapshotRendering.image(for:size:scale:) async -> UIImage?` (scale defaulted to `3` for back-compat). Snapshotter uses `request.zoom` (not the `12.5` literal) and `pixelRatio: scale`.

**Why:** fixes the handoff pixel-ratio mismatch (snapshot hardcoded `pixelRatio: 3` vs a live map at device scale) and lets the snapshot match the live camera zoom.

- [ ] **Step 1: Update the protocol**

```swift
protocol TerrainSnapshotRendering: AnyObject {
    func image(for request: TerrainSnapshotRequest, size: CGSize, scale: CGFloat) async -> UIImage?
}
```

- [ ] **Step 2: Update the snapshotter** (`MapboxTerrainSnapshotter.swift`)

Change the signature and the two hardcoded values:

```swift
func image(for request: TerrainSnapshotRequest, size: CGSize, scale: CGFloat) async -> UIImage? {
    if let data = cache.read(request.cacheKey), let img = UIImage(data: data) { return img }
    guard size.width > 0, size.height > 0 else { return nil }

    let options = MapSnapshotOptions(
        size: size,
        pixelRatio: scale, // device scale, so a 2x device's raster matches its live Map
        glyphsRasterizationOptions: GlyphsRasterizationOptions(rasterizationMode: .ideographsRasterizedLocally))
    // …unchanged style selection…
    snapshotter.setCamera(to: CameraOptions(
        center: CLLocationCoordinate2D(latitude: request.center.latitude,
                                        longitude: request.center.longitude),
        zoom: request.zoom, // was hardcoded 12.5
        pitch: 0))
    // …unchanged gate + render + cache write…
}
```

- [ ] **Step 3: Update `HomeBackdrop.swift`** to pass the environment display scale

Add near the other `@Environment` lines:

```swift
@Environment(\.displayScale) private var displayScale
```

Change the render call (`:41`):

```swift
image = await renderer.image(for: req, size: geo.size, scale: displayScale)
```

- [ ] **Step 4: Build**

Regenerate + build via the builder agent:
Run: `xcodegen` then build the `Aura` scheme for an iPhone simulator.
Expected: builds clean. If `FirstRunHomeView` calls `image(for:size:)` directly, update that call to add `scale: displayScale` (add the `@Environment(\.displayScale)` there too).

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Home/TerrainSnapshotRendering.swift Aura/Sources/Home/MapboxTerrainSnapshotter.swift Aura/Sources/Home/HomeBackdrop.swift Aura/Sources/Home/FirstRunHomeView.swift
git commit -m "feat(home): snapshot at device scale + request zoom (ROH-84)"
```

---

### Task 6: Rider-centered idle snapshot + location-denied state (app target)

**Files:**
- Modify: `Aura/Sources/Home/HomeView.swift` (resolve rider coordinate; pass to backdrop/canvas; denied affordance)
- Modify: `Aura/Sources/Home/HomeBackdrop.swift` (accept a `HomeMapCamera` + `precise` so it renders at the true rider center/zoom)
- Create: `Aura/Sources/Home/HomeLocationHint.swift` (the "Location off · Enable" affordance)

**Interfaces:**
- Consumes: `HomeMapCamera`, `LocationService.current() async -> Coordinate`, `location.authorization`.
- Produces: `HomeView` state `@State private var riderCamera: HomeMapCamera?`; `HomeBackdrop(renderer:camera:precise:placeName:)`.

**Why:** today the backdrop is fed `nil` → always Pittsburgh. Center it on the rider; and replace the silent wrong-city fallback with a visible, actionable hint.

- [ ] **Step 1: Update `HomeBackdrop` to render a given camera**

Replace `riderCoordinate: Coordinate?` with a camera + precision, and use them in `request(for:)`:

```swift
let camera: HomeMapCamera          // was: let riderCoordinate: Coordinate?
var precise: Bool = false

private func request(for size: CGSize) -> TerrainSnapshotRequest? {
    guard size.width > 0, size.height > 0 else { return nil }
    return TerrainSnapshotRequest(
        center: camera.center,
        styleURI: TerrainStyle.authoredStyleIdentity,
        width: size.width, height: size.height,
        zoom: camera.zoom,
        quantizationDegrees: precise ? TerrainSnapshotRequest.preciseQuantizationDegrees
                                     : TerrainSnapshotRequest.quantizationDegrees)
}
```

- [ ] **Step 2: Resolve the rider coordinate in `HomeView`**

Add state + a resolver, and call it on appear and after a completed ride (reuse the existing ride-completion signal — the `rideStore.syncRevision`/summary reload path; center reset piggybacks the `loadRides` post-ride refresh). Add:

```swift
@Environment(\.scenePhase) private var scenePhase
@State private var riderCamera: HomeMapCamera = HomeMapCamera.initial(forRider: nil)
@State private var didResolveInitialCenter = false

/// One-shot center resolve. Only calls `current()` when authorized (matches weather gating);
/// otherwise leaves the curated fallback and lets the location hint explain why.
private func resolveCenterIfNeeded(force: Bool) async {
    guard force || !didResolveInitialCenter else { return }
    didResolveInitialCenter = true
    guard location.authorization == .authorized else {
        riderCamera = HomeMapCamera.initial(forRider: nil); return
    }
    riderCamera = HomeMapCamera.initial(forRider: await location.current())
}
```

Wire it: `.task { await resolveCenterIfNeeded(force: false) }` and on the post-ride reload (inside `loadRides()` completion or its `onChange`) call `await resolveCenterIfNeeded(force: true)` when `HomeMapCamera.shouldReset(on: .rideCompleted)`.

- [ ] **Step 3: Add the location hint view** (`HomeLocationHint.swift`)

```swift
import SwiftUI
import UIKit

/// Small, quiet affordance shown when location is unavailable, so a rider in another city
/// understands why the map isn't centered on them and can act. Not an error banner.
struct HomeLocationHint: View {
    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            Label("Location off — showing a default area", systemImage: "location.slash")
                .font(.footnote.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AuraTheme.textSecondary)
        .accessibilityHint("Opens Settings to enable location")
        .accessibilityIdentifier("home.locationHint")
    }
}
```

Show it in `populated` (e.g. under the header) when `location.authorization != .authorized`.

- [ ] **Step 4: Update the backdrop call site** in `populated` (temporary until Task 8 replaces it with the canvas):

```swift
HomeBackdrop(renderer: renderer, camera: riderCamera, precise: true, placeName: nil)
```

- [ ] **Step 5: Build + device-verify + commit**

Build via builder (regenerate project first). Device-verify: on a fresh launch with location authorized, Home frames the rider's area (not Pittsburgh); with location denied, the hint appears and tapping opens Settings.

```bash
git add Aura/Sources/Home/HomeView.swift Aura/Sources/Home/HomeBackdrop.swift Aura/Sources/Home/HomeLocationHint.swift
git commit -m "feat(home): center idle snapshot on rider + location-off hint (ROH-84)"
```

---

### Task 7: The live Home map view (app target)

**Files:**
- Create: `Aura/Sources/Home/HomeLiveMap.swift`
- Test: `Aura/Tests/AuraUITests/HomeMapUITests.swift` (new XCUITest, minimal)

**Interfaces:**
- Consumes: `HomeMapCamera`, `AuraKit.MapStyle.auraTerrain`.
- Produces: `HomeLiveMap(camera: Binding<HomeMapCamera>, savedPlaces: [SavedPlace], onSelectSaved: (SavedPlace)->Void)` — a live `Map` with pan/zoom-only gestures, zoom bounds, `Puck2D`, saved pins, and a recenter control that returns to the rider.

**Why:** the interactive surface. Built to reuse `RideMapView`'s `Map(viewport:)` + `Puck2D` + `MapViewAnnotation` patterns and the `MapStyle.auraTerrain` bridge.

- [ ] **Step 1: Implement `HomeLiveMap`**

```swift
import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Home's live, movable map: pan + pinch-zoom only (no rotate/pitch), authored Aura terrain
/// style, the rider puck, and Saved-place pins. Mounted only in the `.live` phase.
struct HomeLiveMap: View {
    @Binding var camera: HomeMapCamera
    var savedPlaces: [SavedPlace] = []
    var onSelectSaved: (SavedPlace) -> Void = { _ in }

    @Environment(LocationService.self) private var location
    @State private var viewport: Viewport
    @State private var movedOffRider = false

    init(camera: Binding<HomeMapCamera>, savedPlaces: [SavedPlace] = [],
         onSelectSaved: @escaping (SavedPlace) -> Void = { _ in }) {
        _camera = camera
        self.savedPlaces = savedPlaces
        self.onSelectSaved = onSelectSaved
        _viewport = State(initialValue: .camera(
            center: CLLocationCoordinate2D(latitude: camera.wrappedValue.center.latitude,
                                           longitude: camera.wrappedValue.center.longitude),
            zoom: camera.wrappedValue.zoom))
    }

    var body: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            ForEvery(savedPlaces, id: \.id) { saved in
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                    latitude: saved.place.coordinate.latitude,
                    longitude: saved.place.coordinate.longitude)) {
                    SavedPinView(name: saved.name) { onSelectSaved(saved) }
                }
                .allowOverlapWithPuck(true)
            }
        }
        .mapStyle(AuraKit.MapStyle.auraTerrain.mapboxStyle)
        // Pan + zoom only; kill rotate & pitch for a calm north-up look-around.
        .gestureOptions(GestureOptions(rotateEnabled: false, pitchEnabled: false))
        .ignoresSafeArea()
        .onCameraChanged { ctx in
            let c = ctx.cameraState
            camera = HomeMapCamera(center: Coordinate(latitude: c.center.latitude,
                                                      longitude: c.center.longitude),
                                   zoom: c.zoom).clampedZoom()
            movedOffRider = true
        }
        .overlay(alignment: .trailing) {
            if movedOffRider { recenterButton.padding(.trailing, AuraTheme.Spacing.lg) }
        }
    }

    private var recenterButton: some View {
        GlassCircleButton {
            Task {
                let rider = await location.current()
                withViewportAnimation(.easeOut(duration: 0.4)) {
                    viewport = .camera(center: CLLocationCoordinate2D(latitude: rider.latitude,
                                                                      longitude: rider.longitude),
                                       zoom: HomeMapCamera.defaultZoom)
                }
                movedOffRider = false
            }
        } label: {
            Image(systemName: "location.fill")
        }
        .accessibilityLabel("Recenter on me")
        .accessibilityIdentifier("home.recenter")
    }
}
```

> Note: confirm exact MapboxMaps v11 names during implementation — `.gestureOptions(GestureOptions(...))`, `.onCameraChanged { }`, `withViewportAnimation`, and `Viewport.camera(center:zoom:)`. If a modifier name differs in the pinned SDK, use the SDK's equivalent; the behavior (disable rotate/pitch, observe camera, animate to a fixed camera) is the contract. Also add `SavedPinView` (a small labeled pin) — model it on `GemPinView`/`PeerDotView` in `Aura/Sources/Ride/`.

- [ ] **Step 2: Add `SavedPinView`** (same file or a sibling) — a minimal pin:

```swift
struct SavedPinView: View {
    let name: String
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Image(systemName: "star.fill")
                .font(.callout)
                .foregroundStyle(AuraTheme.accent)
                .padding(6)
                .background(AuraTheme.surface, in: Circle())
        }
        .accessibilityLabel("Saved place: \(name)")
    }
}
```

- [ ] **Step 3: Build**

Regenerate + build via builder. Expected: clean compile (resolve any SDK modifier-name differences here).

- [ ] **Step 4: Device-verify**

Temporarily preview `HomeLiveMap` (a `#Preview` with a constant camera + one saved place). On device: pan and pinch move the map; rotation/pitch do nothing; the terrain shows the authored dark style; the puck shows; the recenter button appears after moving and returns to the rider; a saved pin is tappable.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Home/HomeLiveMap.swift
git commit -m "feat(home): live pan/zoom Home map with puck, saved pins, recenter (ROH-84)"
```

---

### Task 8: HomeMapCanvas — phase container, handoff, lifecycle gating (app target) ⚠️ spikes first

**Files:**
- Create: `Aura/Sources/Home/HomeMapCanvas.swift`
- Modify: `Aura/Sources/Home/HomeView.swift` (replace `HomeBackdrop(...)` in `populated` with `HomeMapCanvas(...)`; drive triggers from `scenePhase` + `router.path`)

**Interfaces:**
- Consumes: `HomeMapPhase`, `HomeMapReducer`, `HomeMapTrigger`, `HomeMapCamera`, `HomeBackdrop`, `HomeLiveMap`.
- Produces: `HomeMapCanvas(renderer:camera:phase:savedPlaces:onSelectSaved:)` where `camera` and `phase` are bindings owned by `HomeView` (so they persist across the retained Home's lifetime).

- [ ] **Step 1: ⚠️ SPIKE — multi-renderer teardown ordering (gates the approach)**

Before building the container, prove the invariant on device. Temporarily instrument `HomeLiveMap` and `RideMapView` bodies with `print("[render] <name> onAppear/onDisappear")` on `.onAppear`/`.onDisappear`. Wire a throwaway version where tapping "Explore" first sets `phase = .idle` (drop the live map), then `router.push(.freeRide)` on the next runloop tick (`Task { @MainActor in router.push(...) }` or `DispatchQueue.main.async`). On device, start a ride from Home's live phase and read the logs.
- **Pass:** `HomeLiveMap onDisappear` precedes `RideMapView onAppear` — never two live maps.
- **Fail:** overlap logged → escalate: gate the live map behind the push differently (e.g., present the ride via a path change only after `phase == .idle` is committed, using `onChange(of: phase)`), or reconsider. Do not proceed to Step 2 until this passes. Record the result in the task's commit message.

- [ ] **Step 2: ⚠️ SPIKE — handoff seam**

With Task 5 (device scale) + Task 2 (precise center) in, mount `HomeLiveMap` over the idle `HomeBackdrop` at the same `camera` and cross-fade. On device, verify there is no gross positional jump or style pop at the moment of activation across a 2x and a 3x device. If the seam is unacceptable, switch the transition from a "seamless" cross-fade to an intentional quick fade-through-scrim (still acceptable per spec). Record the chosen transition.

- [ ] **Step 3: Implement `HomeMapCanvas`**

```swift
import SwiftUI
import AuraCore
import AuraKit

/// Swaps Home's backdrop between the idle snapshot and the live map. Idle shows a "tap to
/// explore" affordance; the first tap activates the live map at the same camera. Owns nothing
/// persistent itself — `camera` and `phase` are bindings held by the retained HomeView.
struct HomeMapCanvas: View {
    let renderer: TerrainSnapshotRendering
    @Binding var camera: HomeMapCamera
    @Binding var phase: HomeMapPhase
    var savedPlaces: [SavedPlace] = []
    var onSelectSaved: (SavedPlace) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Snapshot stays mounted beneath the live map so the live style can load behind it.
            HomeBackdrop(renderer: renderer, camera: camera, precise: true, placeName: nil)
                .allowsHitTesting(phase == .idle)

            if phase == .live {
                HomeLiveMap(camera: $camera, savedPlaces: savedPlaces, onSelectSaved: onSelectSaved)
                    .transition(reduceMotion ? .identity : .opacity)
            }

            if phase == .idle {
                tapToExplore
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: phase)
    }

    /// Discoverability + the deliberate first-touch activation (a fresh live map can't receive
    /// an in-flight touch, so activation is an explicit tap, not a stolen drag).
    private var tapToExplore: some View {
        Button { phase = HomeMapReducer.next(phase, on: .activate) } label: {
            Label("Tap to explore the map", systemImage: "hand.tap")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle()) // whole idle area activates
        .accessibilityIdentifier("home.tapToExplore")
    }
}
```

- [ ] **Step 4: Wire it into `HomeView`**

Add `@State private var mapPhase: HomeMapPhase = .idle`. Replace the backdrop line in `populated`:

```swift
HomeMapCanvas(renderer: renderer, camera: $riderCamera, phase: $mapPhase,
              savedPlaces: savedPlaces.places,
              onSelectSaved: { saved in router.push(.preview(saved.place)) })
```

Drive triggers (add to the existing `.onChange`/`.task` cluster in `body`):

```swift
.onChange(of: router.path) {
    syncSheet()
    if !router.path.isEmpty { mapPhase = HomeMapReducer.next(mapPhase, on: .resignedTop) }
    else { mapPhase = HomeMapReducer.next(mapPhase, on: .becameTopActive) }
}
.onChange(of: scenePhase) {
    if scenePhase != .active { mapPhase = HomeMapReducer.next(mapPhase, on: .background) }
}
```

Because pushing a route flips `mapPhase` to `.idle` in the same `onChange(of: router.path)` that already runs, and the push itself happens in the launch-band closures, ensure the spike-verified ordering: the `HomeLaunchBand` `onExplore`/`onJoin` closures set `mapPhase = .idle` **before** `router.push(...)` (belt-and-suspenders with the path observer):

```swift
onExplore: { mapPhase = .idle; router.push(.freeRide) },
onJoin:    { mapPhase = .idle; router.push(.joinRide) },
```

- [ ] **Step 5: Build, device-verify, commit**

Build via builder. Device-verify: idle Home shows the snapshot + "tap to explore"; tapping activates the live map at the same frame; leaving to History/Settings returns Home to the snapshot; starting a ride shows exactly one live map (per Step 1 logs). Include the spike outcomes in the commit body.

```bash
git add Aura/Sources/Home/HomeMapCanvas.swift Aura/Sources/Home/HomeView.swift
git commit -m "feat(home): HomeMapCanvas idle↔live handoff + lifecycle gating (ROH-84)

Spike results: <one-map ordering PASS/adjustment>; <handoff transition chosen>."
```

---

### Task 9: Search fly-to + Saved pins wired end-to-end (app target)

**Files:**
- Modify: `Aura/Sources/Home/HomeView.swift` (search-result selection also flies the live map)
- Modify: `Aura/Sources/Home/HomeLiveMap.swift` (accept an external fly-to target)

**Interfaces:**
- Produces: `HomeLiveMap(camera:savedPlaces:onSelectSaved:flyTo:)` where `flyTo: Coordinate?` animates the viewport to a coordinate when set; Saved pins already wired in Task 7/8.

**Why:** makes "check a specific place" real — selecting a search result / Saved place moves the map there rather than a pan-by-eye hunt.

- [ ] **Step 1: Add a fly-to input to `HomeLiveMap`**

```swift
var flyTo: Coordinate?

// in body, after .onCameraChanged:
.onChange(of: flyTo) { _, target in
    guard let target else { return }
    withViewportAnimation(.easeOut(duration: 0.5)) {
        viewport = .camera(center: CLLocationCoordinate2D(latitude: target.latitude,
                                                          longitude: target.longitude),
                           zoom: HomeMapCamera.defaultZoom)
    }
    movedOffRider = true
}
```

- [ ] **Step 2: Wire search selection in `HomeView`**

Add `@State private var flyToTarget: Coordinate?`. In the `SearchOverlay` `onPick`, in addition to remembering + previewing, offer a map fly-to when the rider chose "show on map" — simplest: keep the existing preview push for a picked search result, and additionally, when a Saved pin is tapped on the live map (`onSelectSaved`), fly to it instead of pushing preview:

```swift
HomeMapCanvas(renderer: renderer, camera: $riderCamera, phase: $mapPhase,
              savedPlaces: savedPlaces.places,
              onSelectSaved: { saved in
                  mapPhase = HomeMapReducer.next(mapPhase, on: .activate) // ensure live
                  flyToTarget = saved.place.coordinate
              })
```

Pass `flyTo: flyToTarget` through `HomeMapCanvas` into `HomeLiveMap`. (Add `var flyTo: Coordinate?` to `HomeMapCanvas` and forward it.)

- [ ] **Step 3: Build, device-verify, commit**

Device-verify: tapping a Saved pin on the live map flies to it; if idle, it activates first then flies. Saved pins render at the correct coordinates.

```bash
git add Aura/Sources/Home/HomeView.swift Aura/Sources/Home/HomeLiveMap.swift Aura/Sources/Home/HomeMapCanvas.swift
git commit -m "feat(home): fly-to a saved place on the live Home map (ROH-84)"
```

---

### Task 10: Cache prune wiring + verification pass (app target)

**Files:**
- Modify: `Aura/Sources/Home/MapboxTerrainSnapshotter.swift` (prune after write)
- Create/modify: `Aura/Tests/AuraUITests/HomeMapUITests.swift` (XCUITest smoke where feasible)

**Interfaces:**
- Consumes: `TerrainSnapshotDiskCache.prune(toMaxBytes:)`, `.defaultMaxBytes`.

- [ ] **Step 1: Prune the cache after each snapshot write** (`MapboxTerrainSnapshotter.swift`)

```swift
if let image, let data = image.pngData() {
    cache.write(data, for: request.cacheKey)
    cache.prune(toMaxBytes: TerrainSnapshotDiskCache.defaultMaxBytes)
}
```

- [ ] **Step 2: XCUITest smoke** (`HomeMapUITests.swift`) — assert the interactive affordances exist

```swift
import XCTest

final class HomeMapUITests: XCTestCase {
    func testTapToExploreActivatesMapAndRecenterAppears() {
        let app = XCUIApplication()
        app.launch()
        let hint = app.buttons["home.tapToExplore"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        hint.tap()
        // After a pan, the recenter control should appear.
        let map = app.otherElements.firstMatch
        map.swipeLeft()
        XCTAssertTrue(app.buttons["home.recenter"].waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 3: Build + run the UI test via builder; device verification checklist**

Run the app build + `HomeMapUITests` on a simulator via the builder agent. Then, on a physical device, walk the acceptance checklist from the spec and record pass/fail:
- Idle Home renderer-free; "tap to explore" visible; tap activates at the same frame.
- Pan/zoom smooth; rotation/pitch absent; authored dark style; legible at close zoom (or note the follow-up).
- Recenter returns to the rider; Saved pins fly-to.
- Leaving to **History/Settings** turns the iOS location indicator OFF (ROH-83); starting a ride shows exactly one live map (Task 8 Step 1 logs) and location stays legitimately on.
- Camera persists across a History round-trip; resets to the rider after a completed ride and on cold launch.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Home/MapboxTerrainSnapshotter.swift Aura/Tests/AuraUITests/HomeMapUITests.swift
git commit -m "feat(home): prune snapshot cache + Home map UI smoke test (ROH-84)"
```

---

## Self-Review

**Spec coverage:**
- Pan/pinch-zoom, no rotate/pitch, zoom bounds → Task 7 (`gestureOptions`, `clampedZoom`) + Task 1.
- Authored Aura terrain look → Task 7 (`MapStyle.auraTerrain`) + Task 5 (snapshot parity).
- Camera persists within session; reset on cold launch/post-ride; no idle reset → Task 1 (`shouldReset`) + Task 6 (post-ride resolve) + Task 8 (bindings on retained Home; `becameTopActive` doesn't reset).
- Light "check a place": search/saved fly-to + saved pins → Tasks 7 (pins) + 9 (fly-to).
- Snapshot idle → live on interaction (Approach B) → Task 8 (`HomeMapCanvas`).
- Tap-to-explore (first-touch + discoverability) → Task 8.
- Handoff realism (device scale + true center) → Tasks 5 + 2 + Task 8 spike 2.
- Multi-renderer invariant (retain-beneath) → Task 8 spike 1 + phase gating.
- Puck provider lifecycle / ROH-83 → Task 7 (puck only in live) + Task 8 (teardown to idle) + Task 10 (indicator checklist, correct transition).
- Detent/gesture behavior → represented via `allowsHitTesting(phase == .idle)` and the live map living above the peek; the `.large`-detent-inert behavior is inherited from the existing sheet's `presentationBackgroundInteraction` (unchanged) and verified in Task 10.
- Cache bound → Task 3 + Task 10 wiring.
- Location-denied visible state → Task 6.

**Placeholder scan:** SDK modifier names in Task 7 are flagged with an explicit "confirm exact v11 name" note and a behavioral contract, not left as a vague TODO. No "TBD"/"add error handling"/"similar to Task N".

**Type consistency:** `HomeMapCamera(center:zoom:)`, `HomeMapPhase`, `HomeMapReducer.next(_:on:)`, `TerrainSnapshotRequest(... zoom: quantizationDegrees:)`, `TerrainSnapshotRendering.image(for:size:scale:)`, `HomeBackdrop(renderer:camera:precise:placeName:)`, `HomeLiveMap(camera:savedPlaces:onSelectSaved:flyTo:)`, `HomeMapCanvas(renderer:camera:phase:savedPlaces:onSelectSaved:flyTo:)` — used consistently across tasks. `SavedPlace.place.coordinate`/`.name`/`.id` per `SavedPlacesStore`.

**Gaps / notes for execution:** the `.large`-detent inert behavior and exact gesture precedence at the peek edge are verified on device (Task 10), not unit-tested — inherent to SDK/sheet interaction. The two device spikes in Task 8 are approach gates: a hard fail on spike 1 (unavoidable two-renderer overlap) means revisiting the push mechanism before continuing.
