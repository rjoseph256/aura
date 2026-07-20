# Interactive Home Map (ROH-84) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Home's inert terrain image into a movable map — pan/pinch-zoom, centered on the rider, that keeps the authored Aura terrain look — while preserving Home's zero-cost untouched-idle state.

**Architecture:** Approach B (snapshot idle → live map on interaction). AuraCore holds the pure, unit-tested logic (camera constants + reset rule, request zoom/precision, cache bounding, phase reducer). The app target holds the SDK/UIKit surfaces: a device-scale snapshotter, a live `Map`, an `@Observable HomeMapModel` that owns the session camera off the high-frequency render path, and a `HomeMapCanvas` that swaps snapshot↔live and gates on scene/nav lifecycle. Two device spikes (multi-renderer teardown ordering; handoff seam) gate the approach and run first inside Task 8.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, MapboxMaps **v11.26.0** (`Map(viewport:)`, `Viewport`, `@MapContentBuilder`, `Puck2D`, `Snapshotter`, `gestureOptions`, `onCameraChanged`, `cameraBounds`, `withViewportAnimation`), Swift Testing (AuraCore), XCUITest.

## Global Constraints

- **AuraCore is macOS-CI-safe:** no `MapboxMaps`/`UIKit`/`CoreLocation` imports in `AuraCore/Sources`.
- **Coordinate type** is `AuraCore.Coordinate(latitude:longitude:)`.
- **Authored style (intentional, not settings-driven):** the live Home map hardcodes `AuraKit.MapStyle.auraTerrain.mapboxStyle` (bridges the bundled JSON, `.dark` fallback). This deliberately overrides the rider's `settings.mapStyle` because keeping the signature terrain look on Home is a locked product decision. The snapshot uses `TerrainStyle.authoredStyleIdentity`.
- **Gestures:** pan + pinch-zoom only. Rotation/pitch disabled via `GestureOptions`. Zoom bounded by Mapbox `CameraBoundsOptions(minZoom:maxZoom:)` — enforced on the map, not just clamped in state.
- **Camera lifecycle:** persists within an app session; resets to the rider only on cold launch or after a completed ride (the `AppRouter.isRideActive` true→false edge); NO idle-timeout reset.
- **Single-renderer invariant (ROH-7):** never two live Mapbox renderers at once. Home must be `.idle` (snapshot; live `Map` fully removed, no fade) before any route push mounts its map. The idle snapshot renders at a **frozen** camera, never the live camera, so it does not re-render during interaction.
- **Location (ROH-83):** untouched idle holds no renderer and no standing GPS. `Puck2D` runs Mapbox's own location provider; mounting/unmounting it (only in `.live`) is the only lever — verify indicator release on device.
- **Camera observation (MapboxMaps guidance):** `onCameraChanged` fires at high frequency — write it into the `@Observable HomeMapModel`, never straight into SwiftUI `@State`. The model is not read in any `body` that re-executes per frame.
- **Commit** after each task's tests pass. Branch: `claude/home-screen-map-scroll-0dc1da`.
- **AuraCore tests:** `cd AuraCore && swift test`. **App builds/tests** via the `apple-platform-build-tools:builder` agent (`xcodegen` first — the project is gitignored).

---

### Task 1: Home map camera constants + reset rule (AuraCore, pure)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Home/HomeMapCamera.swift`
- Test: `AuraCore/Tests/AuraKitTests/HomeMapCameraTests.swift`

**Interfaces:**
- Consumes: `AuraCore.Coordinate`, `TerrainSnapshotRequest.center(forRider:)`.
- Produces: `HomeMapCamera(center:zoom:)`, `.defaultZoom/.minZoom/.maxZoom`, `.initial(forRider:)`, `.clampedZoom()`, `HomeCameraResetEvent`, `HomeMapCamera.shouldReset(on:)`.

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
        #expect(HomeMapCamera.initial(forRider: nil).center == TerrainSnapshotRequest.curatedDefaultCenter)
    }
    @Test func clampBoundsZoomBothWays() {
        #expect(HomeMapCamera(center: .init(latitude: 0, longitude: 0), zoom: 1).clampedZoom().zoom == HomeMapCamera.minZoom)
        #expect(HomeMapCamera(center: .init(latitude: 0, longitude: 0), zoom: 99).clampedZoom().zoom == HomeMapCamera.maxZoom)
    }
    @Test func resetsOnColdLaunchAndPostRideNotOnReturn() {
        #expect(HomeMapCamera.shouldReset(on: .coldLaunch) == true)
        #expect(HomeMapCamera.shouldReset(on: .rideCompleted) == true)
        #expect(HomeMapCamera.shouldReset(on: .returnedToHome) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails** — `cd AuraCore && swift test --filter HomeMapCameraTests` → FAIL (undefined).

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import AuraCore

/// The Home map's camera (center + zoom), shared by the idle snapshot and the live map so they
/// cannot drift. Pure — the app target maps this onto a MapboxMaps `Viewport`.
public struct HomeMapCamera: Equatable, Sendable {
    public var center: Coordinate
    public var zoom: Double
    public init(center: Coordinate, zoom: Double) { self.center = center; self.zoom = zoom }

    public static let defaultZoom: Double = 12.5   // matches the legacy snapshot zoom
    public static let minZoom: Double = 10.5
    public static let maxZoom: Double = 17.0

    public static func initial(forRider rider: Coordinate?) -> HomeMapCamera {
        HomeMapCamera(center: TerrainSnapshotRequest.center(forRider: rider), zoom: defaultZoom)
    }
    public func clampedZoom() -> HomeMapCamera {
        HomeMapCamera(center: center, zoom: min(max(zoom, Self.minZoom), Self.maxZoom))
    }
}

public enum HomeCameraResetEvent: Sendable, Equatable { case coldLaunch, rideCompleted, returnedToHome }

public extension HomeMapCamera {
    /// Resets to the rider only on cold launch or after a completed ride; a plain return to Home
    /// preserves the rider's panned camera (ROH-84 session persistence).
    static func shouldReset(on event: HomeCameraResetEvent) -> Bool {
        switch event { case .coldLaunch, .rideCompleted: return true; case .returnedToHome: return false }
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — `cd AuraCore && swift test --filter HomeMapCameraTests` → PASS (5).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/HomeMapCamera.swift AuraCore/Tests/AuraKitTests/HomeMapCameraTests.swift
git commit -m "feat(home): pure HomeMapCamera constants + reset rule (ROH-84)"
```

---

### Task 2: TerrainSnapshotRequest gains zoom + precise-center quantization (AuraCore, pure)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift`
- Modify: `AuraCore/Tests/AuraKitTests/TerrainSnapshotRequestTests.swift` (update the pinned literal + add cases)

**Interfaces:**
- Consumes: `HomeMapCamera.defaultZoom`.
- Produces: `init(center:styleURI:width:height:zoom:quantizationDegrees:)` (new params defaulted), `.zoom`, `.preciseQuantizationDegrees`. `cacheKey` now carries a `-z<bucket>` segment.

- [ ] **Step 1: Update the existing pinned-literal test + add new cases**

The existing `TerrainSnapshotRequestTests.swift` contains a determinism test asserting the exact key `"terrain-4044--7999-390x700-s1075307649"`. The new key format inserts `-z125` (zoom 12.5 → bucket 125) after the lng cell. **Change that literal** to:

```swift
// Updated for the -z<bucket> segment (zoom 12.5 → 125). Same coords/size/style as before.
#expect(req.cacheKey == "terrain-4044--7999-z125-390x700-s1075307649")
```

Then append:

```swift
@Test func cacheKeyIncludesZoomBucket() {
    let c = Coordinate(latitude: 40.44, longitude: -79.99)
    let base = TerrainSnapshotRequest(center: c, styleURI: "aura-terrain-v5", width: 390, height: 844)
    let zoomed = TerrainSnapshotRequest(center: c, styleURI: "aura-terrain-v5", width: 390, height: 844, zoom: 15)
    #expect(base.cacheKey != zoomed.cacheKey)
    #expect(base.zoom == HomeMapCamera.defaultZoom)
}

@Test func preciseQuantizationDistinguishesNearbyCenters() {
    let a = Coordinate(latitude: 40.4400, longitude: -79.9959)
    let b = Coordinate(latitude: 40.4413, longitude: -79.9959) // ~150 m north
    #expect(TerrainSnapshotRequest(center: a, styleURI: "s", width: 100, height: 100).cacheKey
         == TerrainSnapshotRequest(center: b, styleURI: "s", width: 100, height: 100).cacheKey)
    let q = TerrainSnapshotRequest.preciseQuantizationDegrees
    #expect(TerrainSnapshotRequest(center: a, styleURI: "s", width: 100, height: 100, quantizationDegrees: q).cacheKey
         != TerrainSnapshotRequest(center: b, styleURI: "s", width: 100, height: 100, quantizationDegrees: q).cacheKey)
}
```

- [ ] **Step 2: Run test to verify it fails** — `cd AuraCore && swift test --filter TerrainSnapshotRequestTests` → FAIL (no `zoom`; old literal mismatch).

- [ ] **Step 3: Write minimal implementation** (replace stored props + init; keep `fnv1a`, the static `quantizationDegrees`, and the `center(forRider:)` extension)

```swift
public struct TerrainSnapshotRequest: Equatable, Sendable {
    public static let quantizationDegrees = 0.01        // ~1.1 km (default: GPS-jitter tolerant)
    public static let preciseQuantizationDegrees = 0.001 // ~110 m (rider-centered on-appear image)

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
    // fnv1a(_:) unchanged.
```

- [ ] **Step 4: Run test to verify it passes** — `cd AuraCore && swift test --filter TerrainSnapshotRequestTests` → PASS (updated literal + 2 new + any other existing).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift AuraCore/Tests/AuraKitTests/TerrainSnapshotRequestTests.swift
git commit -m "feat(home): snapshot request carries zoom + precise-center grid (ROH-84)"
```

---

### Task 3: Bound the snapshot disk cache (AuraCore, pure)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Home/TerrainSnapshotDiskCache.swift`
- Test: `AuraCore/Tests/AuraKitTests/TerrainSnapshotDiskCacheTests.swift` (add case)

**Interfaces:** Produces `.totalBytes() -> Int`, `.prune(toMaxBytes:)`, `.defaultMaxBytes` (25 MB).

- [ ] **Step 1: Write the failing test** (append)

```swift
@Test func pruneEvictsOldestUntilUnderLimit() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("terrain-prune-\(UUID().uuidString)", isDirectory: true)
    let cache = TerrainSnapshotDiskCache(directory: dir)
    for key in ["a", "b", "c"] {
        cache.write(Data(repeating: 0, count: 10), for: key)
        let date = Date(timeIntervalSince1970: Double(["a", "b", "c"].firstIndex(of: key)!))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: cache.url(for: key).path)
    }
    #expect(cache.totalBytes() == 30)
    cache.prune(toMaxBytes: 15)
    #expect(cache.read("a") == nil)   // oldest evicted
    #expect(cache.read("c") != nil)   // newest kept
    #expect(cache.totalBytes() <= 15)
}
```

- [ ] **Step 2: Run test to verify it fails** — `cd AuraCore && swift test --filter TerrainSnapshotDiskCacheTests` → FAIL.

- [ ] **Step 3: Write minimal implementation** (add to the struct)

```swift
public static let defaultMaxBytes = 25 * 1024 * 1024

private func pngFiles() -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]))?
        .filter { $0.pathExtension == "png" } ?? []
}
public func totalBytes() -> Int {
    pngFiles().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}
public func prune(toMaxBytes maxBytes: Int) {
    let files = pngFiles().map { url -> (URL, Int, Date) in
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (url, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
    }
    var total = files.reduce(0) { $0 + $1.1 }
    guard total > maxBytes else { return }
    for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) {
        if total <= maxBytes { break }
        try? FileManager.default.removeItem(at: url); total -= size
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — PASS.

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

**Interfaces:** Produces `HomeMapPhase{.idle,.live}`, `HomeMapTrigger{.activate,.resignedTop,.background,.becameTopActive}`, `HomeMapReducer.next(_:on:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AuraKit

@Suite struct HomeMapPhaseTests {
    @Test func tapActivatesLiveFromIdle() { #expect(HomeMapReducer.next(.idle, on: .activate) == .live) }
    @Test func leavingTopOrBackgroundReturnsToIdle() {
        #expect(HomeMapReducer.next(.live, on: .resignedTop) == .idle)
        #expect(HomeMapReducer.next(.live, on: .background) == .idle)
    }
    @Test func returningToHomeDoesNotAutoActivate() {
        #expect(HomeMapReducer.next(.idle, on: .becameTopActive) == .idle)
        #expect(HomeMapReducer.next(.live, on: .becameTopActive) == .live)
    }
    @Test func idleIgnoresLeaveTriggers() { #expect(HomeMapReducer.next(.idle, on: .resignedTop) == .idle) }
}
```

- [ ] **Step 2: Run test to verify it fails** — FAIL.

- [ ] **Step 3: Write minimal implementation**

```swift
public enum HomeMapPhase: Sendable, Equatable { case idle, live }
public enum HomeMapTrigger: Sendable, Equatable {
    case activate, resignedTop, background, becameTopActive
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

- [ ] **Step 4: Run test to verify it passes** — PASS.

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

**Interfaces:** `TerrainSnapshotRendering.image(for:size:scale:) async -> UIImage?`. (Swift protocol requirements can't carry default arg values; the sole conformer `MapboxTerrainSnapshotter` and sole caller `HomeBackdrop` are both updated here, so every call passes `scale`.)

- [ ] **Step 1: Update the protocol**

```swift
protocol TerrainSnapshotRendering: AnyObject {
    func image(for request: TerrainSnapshotRequest, size: CGSize, scale: CGFloat) async -> UIImage?
}
```

- [ ] **Step 2: Update the snapshotter** — change the signature and the two hardcoded values:

```swift
func image(for request: TerrainSnapshotRequest, size: CGSize, scale: CGFloat) async -> UIImage? {
    // …cache read unchanged…
    let options = MapSnapshotOptions(
        size: size,
        pixelRatio: scale, // device scale so a 2x device's raster matches its live Map
        glyphsRasterizationOptions: GlyphsRasterizationOptions(rasterizationMode: .ideographsRasterizedLocally))
    // …style selection unchanged…
    snapshotter.setCamera(to: CameraOptions(
        center: CLLocationCoordinate2D(latitude: request.center.latitude, longitude: request.center.longitude),
        zoom: request.zoom, // was hardcoded 12.5
        pitch: 0))
    // …gate + render + cache write unchanged…
}
```

- [ ] **Step 3: Update `HomeBackdrop.swift`** — add `@Environment(\.displayScale) private var displayScale` and change `:41`:

```swift
image = await renderer.image(for: req, size: geo.size, scale: displayScale)
```

- [ ] **Step 4: Build** — `xcodegen` then build `Aura` for an iPhone simulator via the builder. Expected: clean. (`FirstRunHomeView` does not call `image(for:)`, so it needs no change here — its `HomeBackdrop` init change happens in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Home/TerrainSnapshotRendering.swift Aura/Sources/Home/MapboxTerrainSnapshotter.swift Aura/Sources/Home/HomeBackdrop.swift
git commit -m "feat(home): snapshot at device scale + request zoom (ROH-84)"
```

---

### Task 6: HomeMapModel + rider-centered idle snapshot + location hint (app target)

**Files:**
- Create: `Aura/Sources/Home/HomeMapModel.swift`
- Create: `Aura/Sources/Home/HomeLocationHint.swift`
- Modify: `Aura/Sources/Home/HomeBackdrop.swift` (take a `HomeMapCamera` + `precise`)
- Modify: `Aura/Sources/Home/FirstRunHomeView.swift:16` (**required** — second `HomeBackdrop` caller)
- Modify: `Aura/Sources/Home/HomeView.swift` (own the model; resolve rider center; denied hint)

**Interfaces:**
- Produces: `@Observable @MainActor final class HomeMapModel` with `phase: HomeMapPhase`, `liveCamera: HomeMapCamera`, `idleCamera: HomeMapCamera`, `movedOffRider: Bool`; `HomeBackdrop(renderer:camera:precise:placeName:)`.

**Why:** the model owns the session camera off SwiftUI's high-frequency `@State` path (MapboxMaps guidance); the idle snapshot renders a **frozen** `idleCamera`, never the live one, so it can't re-render during a pan.

- [ ] **Step 1: Create `HomeMapModel`**

```swift
import Observation
import AuraKit
import AuraCore

/// Owns the Home map's session camera and phase. `liveCamera` is written from the live map's
/// high-frequency `onCameraChanged` (MapboxMaps discourages storing that in SwiftUI @State);
/// `idleCamera` is frozen — the snapshot renders it and it updates only when we enter idle or
/// on a reset, so panning never re-renders the snapshot beneath.
@Observable @MainActor final class HomeMapModel {
    var phase: HomeMapPhase = .idle
    var liveCamera: HomeMapCamera
    var idleCamera: HomeMapCamera
    var movedOffRider = false

    init(initial: HomeMapCamera) { liveCamera = initial; idleCamera = initial }

    /// Freeze the idle snapshot at wherever the live map currently is (called on leave/teardown).
    func freezeIdleFromLive() { idleCamera = liveCamera }

    /// Reset both cameras to the rider (cold launch / post-ride).
    func reset(to camera: HomeMapCamera) {
        liveCamera = camera; idleCamera = camera; movedOffRider = false
    }
}
```

- [ ] **Step 2: Update `HomeBackdrop`** — replace `riderCoordinate` with a camera + precision:

```swift
let camera: HomeMapCamera        // was: let riderCoordinate: Coordinate?
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

- [ ] **Step 3: Fix the first-run caller** (`FirstRunHomeView.swift:16`) — static curated backdrop, no interactivity:

```swift
HomeBackdrop(renderer: renderer, camera: HomeMapCamera.initial(forRider: nil), placeName: "Pittsburgh")
```

- [ ] **Step 4: Add the location hint** (`HomeLocationHint.swift`)

```swift
import SwiftUI
import UIKit

/// Quiet, actionable affordance shown when location is unavailable, so a rider in another city
/// understands why the map isn't on them. Not an error banner.
struct HomeLocationHint: View {
    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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

- [ ] **Step 5: Own the model + resolve center in `HomeView`**

Add: `@Environment(\.scenePhase) private var scenePhase`, `@State private var mapModel = HomeMapModel(initial: .initial(forRider: nil))`, `@State private var didResolveInitialCenter = false`.

```swift
/// One-shot center resolve → rider (authorized) or curated fallback. Writes the model's cameras.
private func resolveCenter(reset: Bool) async {
    let camera: HomeMapCamera
    if location.authorization == .authorized {
        camera = HomeMapCamera.initial(forRider: await location.current())
    } else {
        camera = HomeMapCamera.initial(forRider: nil)
    }
    if reset { mapModel.reset(to: camera) } else { mapModel.idleCamera = camera; mapModel.liveCamera = camera }
}
```

Wire cold-launch resolve: `.task { if !didResolveInitialCenter { didResolveInitialCenter = true; await resolveCenter(reset: false) } }`.
(The post-ride reset trigger is added in Task 8 via `isRideActive`.)

- [ ] **Step 6: Render the rider-centered idle backdrop + hint** (interim until Task 8's canvas replaces it) — in `populated`:

```swift
HomeBackdrop(renderer: renderer, camera: mapModel.idleCamera, precise: true, placeName: nil)
```

And show the hint (e.g. under the header) when `location.authorization != .authorized`:

```swift
if location.authorization != .authorized { HomeLocationHint() }
```

- [ ] **Step 7: Build, device-verify, commit** — build via builder. Verify: authorized launch frames the rider's area; denied shows the hint → Settings.

```bash
git add Aura/Sources/Home/HomeMapModel.swift Aura/Sources/Home/HomeLocationHint.swift Aura/Sources/Home/HomeBackdrop.swift Aura/Sources/Home/FirstRunHomeView.swift Aura/Sources/Home/HomeView.swift
git commit -m "feat(home): HomeMapModel + rider-centered idle snapshot + location hint (ROH-84)"
```

---

### Task 7: The live Home map view (app target)

**Files:**
- Create: `Aura/Sources/Home/HomeLiveMap.swift`

**Interfaces:**
- Consumes: `HomeMapModel`, `HomeMapCamera`, `AuraKit.MapStyle.auraTerrain`.
- Produces: `HomeLiveMap(model: HomeMapModel, savedPlaces:[SavedPlace], onSelectSaved:, flyTo: Coordinate?)` — a live `Map` with pan/zoom-only gestures, **enforced** zoom bounds, `Puck2D`, saved pins, a user-vs-programmatic recenter guard, and external-camera reconciliation.

- [ ] **Step 1: Implement `HomeLiveMap`**

```swift
import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Home's live, movable map: pan + pinch-zoom only (no rotate/pitch), authored Aura terrain
/// style, the rider puck, and Saved pins. Mounted only in `.live`.
struct HomeLiveMap: View {
    @Bindable var model: HomeMapModel
    var savedPlaces: [SavedPlace] = []
    var onSelectSaved: (SavedPlace) -> Void = { _ in }
    var flyTo: Coordinate?

    @Environment(LocationService.self) private var location
    @State private var viewport: Viewport
    /// True while OUR animation (recenter/flyTo) drives the camera, so its `onCameraChanged`
    /// callbacks don't get counted as a user pan (which would re-show the recenter button).
    @State private var programmatic = false

    init(model: HomeMapModel, savedPlaces: [SavedPlace] = [],
         onSelectSaved: @escaping (SavedPlace) -> Void = { _ in }, flyTo: Coordinate? = nil) {
        self.model = model
        self.savedPlaces = savedPlaces
        self.onSelectSaved = onSelectSaved
        self.flyTo = flyTo
        _viewport = State(initialValue: .camera(
            center: CLLocationCoordinate2D(latitude: model.liveCamera.center.latitude,
                                           longitude: model.liveCamera.center.longitude),
            zoom: model.liveCamera.zoom))
    }

    var body: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            ForEvery(savedPlaces, id: \.id) { saved in
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                    latitude: saved.place.coordinate.latitude, longitude: saved.place.coordinate.longitude)) {
                    SavedPinView(name: saved.name) { onSelectSaved(saved) }
                }
                .allowOverlapWithPuck(true)
            }
        }
        .mapStyle(AuraKit.MapStyle.auraTerrain.mapboxStyle)
        .gestureOptions(GestureOptions(rotateEnabled: false, pitchEnabled: false))
        // Enforce zoom bounds on the MAP (not just clamp state) so a pinch can't exceed them.
        .cameraBounds(CameraBoundsOptions(maxZoom: HomeMapCamera.maxZoom, minZoom: HomeMapCamera.minZoom))
        .ignoresSafeArea()
        .onCameraChanged { ctx in
            // Store in the @Observable model, never in @State (MapboxMaps guidance: high-freq).
            model.liveCamera = HomeMapCamera(
                center: Coordinate(latitude: ctx.cameraState.center.latitude,
                                   longitude: ctx.cameraState.center.longitude),
                zoom: Double(ctx.cameraState.zoom)).clampedZoom()
            if !programmatic { model.movedOffRider = true } // user pan only
        }
        // External camera change (post-ride reset) must move an already-mounted map.
        .onChange(of: model.liveCamera) { _, cam in
            guard !model.movedOffRider else { return } // don't fight an active pan
            animate(to: cam)
        }
        .onChange(of: flyTo) { _, target in if let target { animate(to: HomeMapCamera(center: target, zoom: HomeMapCamera.defaultZoom)); model.movedOffRider = true } }
        .overlay(alignment: .trailing) {
            if model.movedOffRider { recenterButton.padding(.trailing, AuraTheme.Spacing.lg) }
        }
    }

    private func animate(to cam: HomeMapCamera) {
        programmatic = true
        withViewportAnimation(.easeOut(duration: 0.4)) {
            viewport = .camera(center: CLLocationCoordinate2D(latitude: cam.center.latitude,
                                                              longitude: cam.center.longitude),
                               zoom: cam.zoom)
        } completion: { _ in programmatic = false }
    }

    private var recenterButton: some View {
        GlassCircleButton {
            Task {
                let rider = await location.current()
                animate(to: HomeMapCamera(center: rider, zoom: HomeMapCamera.defaultZoom))
                model.movedOffRider = false
            }
        } label: { Image(systemName: "location.fill") }
        .accessibilityLabel("Recenter on me")
        .accessibilityIdentifier("home.recenter")
    }
}

/// A small labeled pin for a Saved place. Modeled on GemPinView/PeerDotView in Aura/Sources/Ride/.
struct SavedPinView: View {
    let name: String
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Image(systemName: "star.fill").font(.callout).foregroundStyle(AuraTheme.accent)
                .padding(6).background(AuraTheme.surface, in: Circle())
        }
        .accessibilityLabel("Saved place: \(name)")
    }
}
```

> `withViewportAnimation(_:_:completion:)`, `.gestureOptions`, `.cameraBounds`, `.onCameraChanged`, and `Viewport.camera(center:zoom:)` are all confirmed present in the pinned v11.26.0 SDK. `CameraState.zoom` is `CGFloat` → wrap with `Double(...)`.

- [ ] **Step 2: Build** — regenerate + build via builder. Expected: clean.

- [ ] **Step 3: Device-verify** — a `#Preview` with a `HomeMapModel(initial:)` + one saved place. On device: pan/pinch move the map; rotation/pitch do nothing; pinch cannot exceed min/max zoom (no post-move snap-back); authored dark style; puck shows; recenter appears **only after a user pan** and hides after recentering; a saved pin is tappable.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Home/HomeLiveMap.swift
git commit -m "feat(home): live pan/zoom Home map — bounds, puck, saved pins, guarded recenter (ROH-84)"
```

---

### Task 8: HomeMapCanvas — handoff, lifecycle gating, single-renderer safety (app target) ⚠️ spikes first

**Files:**
- Create: `Aura/Sources/Home/HomeMapCanvas.swift`
- Modify: `Aura/Sources/Home/HomeView.swift` (mount the canvas; drive triggers; deferred push; post-ride reset)

**Interfaces:** `HomeMapCanvas(renderer:model:savedPlaces:onSelectSaved:flyTo:)`.

- [ ] **Step 1: ⚠️ SPIKE — single-renderer teardown ordering (gates the approach; tests the SHIPPED mechanism)**

Instrument `HomeLiveMap` and `RideMapView` bodies with `.onAppear { print("[render] live/ride appear") }` / `.onDisappear { print("[render] … disappear") }`. Implement the **shipped** navigation mechanism now (not a throwaway): a Home-originated push commits `.idle` first, then pushes on the **next runloop tick** so SwiftUI removes `HomeLiveMap` before the ride map mounts:

```swift
private func leaveHome(pushing route: AppRoute) {
    mapModel.freezeIdleFromLive()
    mapModel.phase = .idle                       // live map removed THIS update (no animation on this edge)
    DispatchQueue.main.async { router.push(route) } // ride map mounts NEXT tick
}
```

Wire the launch band to it: `onExplore: { leaveHome(pushing: .freeRide) }`, `onJoin: { leaveHome(pushing: .joinRide) }`.
On device, start a ride from Home's **live** phase and read the logs.
- **PASS:** `live disappear` precedes `ride appear` — never two live maps.
- **FAIL:** overlap → escalate (push strictly from `onChange(of: mapModel.phase)` once `.idle`, or reconsider). Do not proceed until PASS. Record the outcome in the commit body.

- [ ] **Step 2: ⚠️ SPIKE — handoff seam** — with device-scale (Task 5) + precise center (Task 2), mount `HomeLiveMap` over the idle `HomeBackdrop` at the same frozen camera and cross-fade only on the **idle→live** edge. On a 2× and a 3× device, confirm no gross positional jump or style pop. If unacceptable, switch to an intentional quick fade-through-scrim. Record the chosen transition.

- [ ] **Step 3: Implement `HomeMapCanvas`** — animate ONLY idle→live; tear down live→idle instantly (no lingering renderer):

```swift
import SwiftUI
import AuraCore
import AuraKit

/// Swaps Home's backdrop between the frozen idle snapshot and the live map. Idle shows a
/// "tap to explore" affordance; the first tap activates the live map at the same camera. The
/// live→idle edge is INSTANT (no animation) so the live renderer is gone before any route push
/// mounts another map (single-renderer invariant); only idle→live is animated.
struct HomeMapCanvas: View {
    let renderer: TerrainSnapshotRendering
    @Bindable var model: HomeMapModel
    var savedPlaces: [SavedPlace] = []
    var onSelectSaved: (SavedPlace) -> Void = { _ in }
    var flyTo: Coordinate?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HomeBackdrop(renderer: renderer, camera: model.idleCamera, precise: true, placeName: nil)
                .allowsHitTesting(model.phase == .idle)

            if model.phase == .live {
                HomeLiveMap(model: model, savedPlaces: savedPlaces, onSelectSaved: onSelectSaved, flyTo: flyTo)
                    // Animate the APPEARANCE (idle→live) only; removal is instant.
                    .transition(.asymmetric(insertion: reduceMotion ? .identity : .opacity, removal: .identity))
            }

            if model.phase == .idle { tapToExplore }
        }
        // Animate only when going TO live; disappearance is not animated (see removal: .identity).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.phase == .live)
    }

    private var tapToExplore: some View {
        Button { withAnimation { model.phase = HomeMapReducer.next(model.phase, on: .activate) } } label: {
            Label("Tap to explore the map", systemImage: "hand.tap")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityIdentifier("home.tapToExplore")
    }
}
```

- [ ] **Step 4: Wire into `HomeView`** — replace the backdrop in `populated`:

```swift
HomeMapCanvas(renderer: renderer, model: mapModel, savedPlaces: savedPlaces.places,
              flyTo: flyToTarget,
              onSelectSaved: { saved in
                  mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .activate)
                  flyToTarget = saved.place.coordinate
              })
```

Add `@State private var flyToTarget: Coordinate?`. **Merge** the phase triggers into the EXISTING `.onChange(of: router.path)` (do not add a second one):

```swift
.onChange(of: router.path) {
    syncSheet()
    if router.path.isEmpty {
        mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .becameTopActive) // no reset
    } else {
        mapModel.freezeIdleFromLive()
        mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .resignedTop)
    }
}
.onChange(of: scenePhase) {
    if scenePhase != .active { mapModel.freezeIdleFromLive(); mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .background) }
}
// Real post-ride reset: the ride HUD sets router.isRideActive; its true→false edge is a ride ending.
.onChange(of: router.isRideActive) { wasActive, isActive in
    if wasActive && !isActive, HomeMapCamera.shouldReset(on: .rideCompleted) {
        Task { await resolveCenter(reset: true) }
    }
}
```

And the launch-band closures use `leaveHome(pushing:)` from Step 1 (belt-and-suspenders with the path observer). Keep `.onExplore` / `.onJoin` pointed at `leaveHome`.

- [ ] **Step 5: Gesture precedence (explicit — spec requires it, not "in the gaps")**

Document and implement these rules (mostly falls out of existing layering; verify on device):
- The dashboard sheet keeps `presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))` (`HomeSheet.swift:39`), so **vertical drags within the sheet region expand the sheet**, and the map only receives gestures in the area **above** the sheet's current top edge. Above the 0.55 fraction the map is inert by design (matches the spec's `.large`-detent behavior).
- Header cluster, launch band, and search overlay are `Button`s layered above the map; taps hit them. A **pinch that begins on open terrain** zooms the map (Buttons don't claim a magnify gesture), so a pinch spanning a chip and the map still zooms.
- The "tap to explore" affordance covers the idle map area (`contentShape(Rectangle())`) so a tap anywhere on idle terrain activates.

- [ ] **Step 6: Build, device-verify, commit** — idle shows snapshot + "tap to explore"; tap activates at the same frame; leaving to History/Settings returns to snapshot; **starting a ride shows exactly one live map** (Step 1 logs); camera persists across a History round-trip; a completed ride re-centers on the rider.

```bash
git add Aura/Sources/Home/HomeMapCanvas.swift Aura/Sources/Home/HomeView.swift
git commit -m "feat(home): HomeMapCanvas handoff + lifecycle gating, single-renderer safe (ROH-84)

Spikes: <one-map ordering PASS/adjustment>; <handoff transition chosen>."
```

---

### Task 9: Search fly-to wired end-to-end (app target)

**Files:**
- Modify: `Aura/Sources/Home/HomeView.swift` (search-result "show on map" flies the live map)

**Interfaces:** Consumes the `flyTo`/`flyToTarget` path built in Tasks 7–8.

**Why:** completes "check a specific place" — the Saved-pin fly-to is wired in Task 8; this adds the search path.

- [ ] **Step 1: Add a "show on map" affordance to search selection**

The existing `SearchOverlay.onPick` pushes a route preview. Keep that as the default, and add a secondary action so a rider can drop the picked place onto the Home map instead of previewing a route. Simplest wiring that reuses the flyTo path: when a place is picked, set the fly-to target and collapse search rather than only pushing:

```swift
SearchOverlay(
    query: $query,
    onPick: { place in
        router.remember(place)
        searchExpanded = false
        mapModel.phase = HomeMapReducer.next(mapModel.phase, on: .activate)
        flyToTarget = place.coordinate
    },
    onCollapse: { searchExpanded = false })
```

(If the PO wants route-preview to remain the primary pick action, add an explicit "Show on map" button in `SavedPlaceRow`/search results instead; the fly-to wiring is identical. Confirm during execution — either way `flyToTarget` is the single mechanism.)

- [ ] **Step 2: Build, device-verify, commit** — picking a search result flies the Home map to it (activating live if idle); Saved-pin taps (Task 8) fly there too.

```bash
git add Aura/Sources/Home/HomeView.swift
git commit -m "feat(home): fly the Home map to a searched place (ROH-84)"
```

---

### Task 10: Cache prune wiring + verification pass (app target)

**Files:**
- Modify: `Aura/Sources/Home/MapboxTerrainSnapshotter.swift` (prune after write)
- Create: `Aura/Tests/AuraUITests/HomeMapUITests.swift`

- [ ] **Step 1: Prune after each snapshot write** (`MapboxTerrainSnapshotter.swift`)

```swift
if let image, let data = image.pngData() {
    cache.write(data, for: request.cacheKey)
    cache.prune(toMaxBytes: TerrainSnapshotDiskCache.defaultMaxBytes)
}
```

- [ ] **Step 2: XCUITest smoke** (`HomeMapUITests.swift`)

```swift
import XCTest

final class HomeMapUITests: XCTestCase {
    func testTapToExploreActivatesMapAndRecenterAppears() {
        let app = XCUIApplication(); app.launch()
        let hint = app.buttons["home.tapToExplore"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        hint.tap()
        app.otherElements.firstMatch.swipeLeft()
        XCTAssertTrue(app.buttons["home.recenter"].waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 3: Build + run UI test via builder; device verification checklist**

Run app build + `HomeMapUITests` on a simulator. Then on a physical device, record pass/fail:
- Idle Home renderer-free; "tap to explore" visible; tap activates at the same frame; **snapshot does not re-render while panning** (no repeated snapshot logs).
- Pan/zoom smooth; rotation/pitch absent; pinch bounded (no snap-back); authored dark style; legible at close zoom (or file the follow-up).
- Recenter appears only after a user pan and hides after recentering; Saved-pin + search fly-to work.
- Leaving to **History/Settings** turns the iOS location indicator OFF (ROH-83); starting a ride shows exactly one live map (Task 8 Step 1 logs) with location legitimately on.
- Camera persists across a History round-trip; resets to the rider after a completed ride and on cold launch.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Home/MapboxTerrainSnapshotter.swift Aura/Tests/AuraUITests/HomeMapUITests.swift
git commit -m "feat(home): prune snapshot cache + Home map UI smoke test (ROH-84)"
```

---

## Self-Review

**Spec coverage:** pan/zoom + no rotate/pitch + enforced bounds → Task 7 (`gestureOptions`, `cameraBounds`) + Task 1. Authored terrain look (intentional override of settings) → Global Constraints + Task 7. Camera persists; resets on cold launch/post-ride via the `isRideActive` edge; no idle reset → Task 1 + Task 6 (`resolveCenter`) + Task 8 (`isRideActive` onChange; `becameTopActive` doesn't reset). Frozen idle snapshot (no per-pan re-render) → Task 6 model + Task 8 canvas. Snapshot idle→live (Approach B) + tap-to-explore → Task 8. Handoff realism → Tasks 2+5 + Task 8 spike 2. Single-renderer invariant (retain-beneath + no live→idle animation + deferred push) → Task 8 Step 1 spike + Steps 3–4. Puck/ROH-83 → Task 7 (puck only in live) + Task 8 (instant teardown) + Task 10 checklist. Detent/gesture precedence → Task 8 Step 5. Cache bound → Task 3 + Task 10. Location-denied visible state → Task 6.

**Fixes folded from the plan review:** FirstRunHomeView build break → Task 6 Step 3. Phantom post-ride reset → Task 8 `isRideActive` edge (real signal). Two-renderer overlap from animation → Task 8 removal `.identity` + deferred push + aligned spike. Continuous snapshot re-render → frozen `idleCamera`. High-freq `@State` writes + recenter re-trip → Task 7 `@Observable` model + `programmatic` guard. Cosmetic zoom bounds → `cameraBounds`. Missing Task 2 literal → provided. Duplicate `onChange` → merged. `riderCamera` optional inconsistency → replaced by the non-optional model.

**Placeholder scan:** no "TBD"/"add error handling"/"similar to Task N". The one judgment call left to execution (search "show on map" as primary vs secondary action, Task 9 Step 1) is explicitly flagged with both wirings pointing at the same `flyToTarget` mechanism.

**Type consistency:** `HomeMapModel` (`phase`/`liveCamera`/`idleCamera`/`movedOffRider`/`freezeIdleFromLive`/`reset`), `HomeMapCamera(center:zoom:)`, `HomeBackdrop(renderer:camera:precise:placeName:)` (both call sites — HomeView + FirstRunHomeView — updated), `TerrainSnapshotRendering.image(for:size:scale:)`, `HomeLiveMap(model:savedPlaces:onSelectSaved:flyTo:)`, `HomeMapCanvas(renderer:model:savedPlaces:onSelectSaved:flyTo:)`, `SavedPlace.place.coordinate/.name/.id` — consistent across tasks.

**Gaps for execution:** the two Task 8 spikes are approach gates — a hard fail on spike 1 (unavoidable two-renderer overlap even with deferred push) means revisiting the push mechanism (or a hoisted single map) before continuing. `.large`-detent inertness and exact peek-edge gesture feel are device-verified (Task 10), inherent to SDK/sheet interaction.
