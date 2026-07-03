# Home Terrain-Hero Reinvention (Chunk 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Aura's Home into the "Terrain hero canvas" — a cached, non-interactive terrain backdrop; one dominant "Where to?" launch action with demoted Explore/Join secondaries; an always-visible motivation hook and a detented pull-up dashboard sheet — and rename "Free ride" to "Explore" app-wide, all carrying the locked Chunk 0 direction.

**Architecture:** All decision logic (style resolution, snapshot cache-key + curated region, the disk cache, the motivation-hook sentence, the first-run predicate) lives in `AuraKit` as pure value functions with Swift Testing unit tests, so it builds and tests on the macOS CI host and the behavioral gates are actually covered. Everything importing `MapboxMaps`/SwiftUI (the `Snapshotter` renderer, `HomeBackdrop`, the sheet, the launch band, the search overlay, the assembled `HomeView`) lives in the app target behind a `@MainActor` protocol seam — matching the shipped `WorkoutWriting` / `HapticPlaying` pattern — and is build- + device-verified. The single-hoisted live map (ROH-7) is preserved because the backdrop is a rendered `UIImage`, not a `Map`. The dashboard uses a **system `.presentationDetents` sheet with background interaction**, not a hand-rolled drag, so SwiftUI arbitrates scroll-vs-drag.

**Tech Stack:** Swift 6, SwiftUI, MapboxMaps v11 (`Snapshotter`), SwiftData-backed stores (unchanged), Swift Testing (new pure tests) + XCTest/XCUITest (existing), SwiftLint (strict), xcodegen (`project.yml`).

## Revision history

- **R1 (2026-07-02):** reconciled after a 3-reviewer adversarial plan review (engineering/Mapbox, product/spec-fidelity, architecture/test-quality). Fixes folded in: Snapshotter deallocation-race retain; deterministic (non-`hashValue`) cache key with a literal-pinned test; disk cache extracted to a pure `Data` cache in AuraKit with a round-trip test; `TerrainStyle` refactored to a pure `resolve(custom:)`; system `.presentationDetents` sheet replacing the custom drag; one composed launch band (primary + demoted secondaries); peek shows the last-ride card; subtle terrain foreshadow on `LastRideCard` (signature-moment gate); `DestinationSearchView` gains a `FocusState` binding + a11y id; seam is `@MainActor …: AnyObject`; robust CI-wired rename grep incl. `HistoryView:104` empty-state and the `WidgetSupport:12` comment; first-run via a persisted onboarding flag + a pure `HomeMode.resolve`; UI tests seed via the built-in `NSArgumentDomain` (`-auraDidCompleteOnboarding YES`), not a nonexistent `-uiTestSeed`; deterministic locale for the weekday; motivation hook = distance-to-goal (PO decision); Task 10 split into 14a/14b/14c.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the two specs.

- **ROH-6 is a hard predecessor.** Home cannot hit its "real styled terrain" acceptance gate until the custom Mapbox terrain style ships and is device-verified. Downstream code lands against a fallback style URI in the meantime.
- **One live map only (ROH-7).** The Home backdrop is a rendered terrain **image** (`Snapshotter` → cached `UIImage`), never a live `Map`. It never pans and never adds a persistent second Metal renderer.
- **Frozen internal identifiers — never change:** `Ride.Kind.freeRide`, its persisted raw value `"freeRide"`, `RideMapper`'s `?? .freeRide`, `AppRoute.freeRide`, `DeepLink.freeRide`, the `aura://ride` deep-link host, and `RideActivityMode.freeRide`.
- **User-facing copy:** every rendered "Free ride" string becomes **"Explore"**; the pre-start HUD button becomes **"Start ride"**; History's row label AND empty-state copy follow suit. The acceptance test greps that no user-facing surface renders "free ride" (case-insensitive), excluding frozen-identifier lines and comments.
- **Signal accent is electric lime `#C8FA4B`** (`AuraTheme.accent`), reserved for the ONE dominant launch action, the weekly-goal ring, and the route line. Secondaries carry no lime fill.
- **Text is never directly on terrain.** Every floating text element sits on an opaque/near-opaque plate meeting ≥ 4.5:1; frosted surfaces degrade via `AuraTheme.prefersOpaqueSurface(reduceTransparency:_:)` / `AuraTheme.mapScrim(reduceTransparency:_:)` under Reduce Transparency / Increase Contrast.
- **Reduce Motion is fully static** — zero residual drift on the backdrop, not merely reduced.
- **Design tokens only:** views use `AuraTheme` roles and the `AuraTheme.Spacing` / `AuraTheme.Radius` scales; no raw colors or magic numbers. Any fixed layout height that must scale uses `@ScaledMetric`.
- **New pure tests use Swift Testing** (`import Testing`, `@Test`, `#expect`) in `AuraCore/Tests/AuraKitTests/`. `import AuraCore` resolves there transitively (24 existing files do it). Existing XCTest files stay as-is.
- **State ownership stays intact:** `.task { loadRides() }` and `.onChange(of: rideStore.syncRevision)` live on the always-mounted Home container, never on a detent-conditional subview. All `@State` is hoisted to the container. The Join flow and rename alert are anchored on the container.
- **Verification is device-first** on the real iPhone through the tunnel. CI verifies: package tests green, app builds, SwiftLint strict, and the rename grep.

## Product decisions (PO-confirmed, 2026-07-02)

- **Motivation hook framing = distance-to-goal.** Mid-week under goal → "12 mi to your weekly goal"; no rides yet this week → "18.4 mi last ride, Tue" (last-ride fallback). Not an estimated ride-count.
- **Signature card = subtle foreshadow now.** `LastRideCard` gets a restrained terrain tint / faint contour behind the route thumbnail on an opaque plate (satisfies the "foreshadows the medal" gate); the full terrain-carved emboss stays Chunk 3.

---

## File structure

New AuraKit (pure, CI-tested):
- `AuraCore/Sources/AuraKit/Home/TerrainStyle.swift` (Task 1)
- `AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift` (Task 2)
- `AuraCore/Sources/AuraKit/Home/TerrainSnapshotDiskCache.swift` (Task 3)
- `AuraCore/Sources/AuraKit/Home/WeeklyGlance.swift` (Task 7)
- `AuraCore/Sources/AuraKit/Home/HomeMode.swift` (Task 8)

New app target (MapboxMaps/SwiftUI, build/device-verified):
- `Aura/Sources/Home/TerrainSnapshotRendering.swift` (Task 4)
- `Aura/Sources/Home/MapboxTerrainSnapshotter.swift` (Task 4)
- `Aura/Sources/Home/HomeBackdrop.swift` (Task 5)
- `Aura/Sources/Home/WeeklyGlanceView.swift` (Task 9)
- `Aura/Sources/Home/HomeSheet.swift` (Task 11)
- `Aura/Sources/Home/HomeLaunchBand.swift` (Task 12)
- `Aura/Sources/Home/SearchOverlay.swift` (Task 12)
- `Aura/Sources/Home/FirstRunHomeView.swift` (Task 13)
- `Aura/Sources/Home/HomeView.swift` + `HomeRows.swift` (Task 14a–14c)

New tests:
- `AuraCore/Tests/AuraKitTests/TerrainStyleTests.swift` (1), `TerrainSnapshotRequestTests.swift` (2), `TerrainSnapshotDiskCacheTests.swift` (3), `WeeklyGlanceTests.swift` (7), `HomeModeTests.swift` (8)
- `Aura/UITests/HomeUITests.swift` (12, 14b)
- `scripts/check-explore-rename.sh` + a CI step (6)

Modified:
- Rename sites (Task 6): `Aura/Sources/Ride/RideHUDView.swift:70`, `Aura/Sources/History/HistoryView.swift:104,150`, `Aura/Sources/Plan/LastRideCard.swift:81`, `Aura/Sources/Plan/PlanView.swift:253`, `Aura/Widgets/RideLockScreenView.swift:42,58`, `Aura/Widgets/RideLiveActivity.swift:73`, `Aura/Widgets/WidgetSupport.swift:12,14`.
- `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift` — add device-local `didCompleteOnboarding` (Task 8).
- `Aura/Sources/Plan/DestinationSearchView.swift` — add `isFocused` binding + a11y id (Task 12).
- `Aura/Sources/Plan/LastRideCard.swift` — subtle terrain foreshadow (Task 10).
- `Aura/Sources/AuraApp.swift` — RootView `PlanView()` → `HomeView()` (Task 14b).
- `.github/workflows/ci.yml` — run the rename grep (Task 6).
- Delete `Aura/Sources/Plan/PlanView.swift` after `HomeView` ships (Task 14c); rehost `RecentRow`; keep `SavedPlaceRow`, `WeeklyRing`, `DestinationSearchView`, `LastRideCard`.

---

## Task 1: ROH-6 — pure terrain style resolver (+ Studio authoring brief)

Lands the style-selection logic as a pure function, TDD-first, with a safe fallback so downstream builds before the Studio style is published. The Studio authoring is a collaborative, device-verified deliverable (brief below); it does not block Tasks 2–15.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Home/TerrainStyle.swift`
- Test: `AuraCore/Tests/AuraKitTests/TerrainStyleTests.swift`

**Interfaces:**
- Produces: `public enum TerrainStyle` with `public static let fallbackStyleURI = "mapbox://styles/mapbox/dark-v11"`, `static let customStyleURI: String?` (paste-in point), `public static func resolve(custom: String?) -> String`, `public static var styleURI: String { resolve(custom: customStyleURI) }`, `public static func isCustom(_ uri: String) -> Bool`.

### Mapbox Studio authoring brief (collaborative deliverable — Linear ROH-6)

Author a custom style in Mapbox Studio tuned to the Chunk 0 palette; publish; paste its `mapbox://styles/<account>/<id>` URI into `TerrainStyle.customStyleURI`. Brief: deep charcoal-green/slate land (near `#07080C` shifted green, not pure black); hillshade + readable relief tuned low-contrast (tactile, not busy); muted water/parks; quiet, recessive labels; **no route line in the style** (the lime line is drawn on top by the app). Device gate (Chunk 0 exit spike): static export read in bright sun at a sub-second glance while moving. Run when the tunnel is open.

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/TerrainStyleTests.swift
import Testing
@testable import AuraKit

@Suite struct TerrainStyleTests {
    @Test func fallbackIsAWellFormedMapboxStyleURI() {
        #expect(TerrainStyle.fallbackStyleURI.hasPrefix("mapbox://styles/"))
    }

    @Test func resolvePrefersCustomWhenPresent() {
        #expect(TerrainStyle.resolve(custom: "mapbox://styles/aura/terrain123") == "mapbox://styles/aura/terrain123")
    }

    @Test func resolveFallsBackWhenNil() {
        #expect(TerrainStyle.resolve(custom: nil) == TerrainStyle.fallbackStyleURI)
    }

    @Test func isCustomTrueOnlyForAuraAuthoredStyles() {
        #expect(TerrainStyle.isCustom("mapbox://styles/aura/terrain123") == true)
        #expect(TerrainStyle.isCustom(TerrainStyle.fallbackStyleURI) == false)
        // A stock non-fallback Mapbox style must NOT read as the authored terrain.
        #expect(TerrainStyle.isCustom("mapbox://styles/mapbox/outdoors-v12") == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Delegate to the builder agent (see Task-runner note). Run the AuraKit test target. Expected: FAIL — `TerrainStyle` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// AuraCore/Sources/AuraKit/Home/TerrainStyle.swift
import Foundation

/// Resolves which Mapbox style the Home terrain backdrop renders. Pure (no MapboxMaps import)
/// so it tests on the macOS CI host; the app target bridges the URI to a `StyleURI`. The
/// custom Studio style is ROH-6's authored deliverable — until it is published the resolver
/// degrades to a dark fallback so the snapshotter always has a valid style.
public enum TerrainStyle {
    /// Safe dark fallback used until the authored terrain style is pasted in.
    public static let fallbackStyleURI = "mapbox://styles/mapbox/dark-v11"

    /// Authored custom terrain style URI (ROH-6). Set to the published
    /// `mapbox://styles/aura/<id>` once the Studio style ships. `nil` → fallback.
    static let customStyleURI: String? = nil

    /// Pure selection: custom when present, else fallback. Tested directly.
    public static func resolve(custom: String?) -> String { custom ?? fallbackStyleURI }

    /// The style the backdrop should render right now.
    public static var styleURI: String { resolve(custom: customStyleURI) }

    /// Whether `uri` is an Aura-authored terrain style (feeds the "real terrain" gate).
    /// Defined against the authored namespace, not "not the fallback", so a stock Mapbox
    /// style never passes the gate.
    public static func isCustom(_ uri: String) -> Bool { uri.hasPrefix("mapbox://styles/aura/") }
}
```

- [ ] **Step 4: Run test to verify it passes** — Expected: PASS (4 tests).
- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/TerrainStyle.swift AuraCore/Tests/AuraKitTests/TerrainStyleTests.swift
git commit -m "feat(home): pure terrain style resolver with dark fallback (ROH-6 seam)"
```

> The authored-style paste-in (`customStyleURI`) + its device gate are ROH-6's remaining acceptance; they land as a follow-up once the Studio style ships. Do not block Tasks 2–15.

---

## Task 2: TerrainSnapshotRequest — deterministic cache key + curated region

The pure request value the snapshotter renders. The cache key is **deterministic across launches** (FNV-1a over the style URI, not `String.hashValue`) and includes a quantized size bucket so a re-layout re-renders at the right resolution. Answers spec open question #2 (a ~1 km coordinate grid). Curated default region for the locationless case.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift`
- Test: `AuraCore/Tests/AuraKitTests/TerrainSnapshotRequestTests.swift`

**Interfaces:**
- Consumes: `AuraCore.Coordinate` (`latitude`/`longitude: Double`).
- Produces: `public struct TerrainSnapshotRequest: Equatable, Sendable` with `let center: Coordinate`, `let styleURI: String`, `let widthBucket: Int`, `let heightBucket: Int`, `let cacheKey: String`; `public init(center:styleURI:width:height:)`; `public static let quantizationDegrees = 0.01`; `public static let curatedDefaultCenter = Coordinate(latitude: 40.4406, longitude: -79.9959)`; `public static func center(forRider: Coordinate?) -> Coordinate`.

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/TerrainSnapshotRequestTests.swift
import Testing
import AuraCore
@testable import AuraKit

@Suite struct TerrainSnapshotRequestTests {
    private func req(_ lat: Double, _ lng: Double, _ style: String = "mapbox://styles/aura/t",
                     w: Double = 390, h: Double = 700) -> TerrainSnapshotRequest {
        TerrainSnapshotRequest(center: .init(latitude: lat, longitude: lng), styleURI: style, width: w, height: h)
    }

    @Test func jitterWithinGridReusesCacheKey() {
        #expect(req(40.4406, -79.9959).cacheKey == req(40.4409, -79.9961).cacheKey)
    }
    @Test func movingPastGridChangesCacheKey() {
        #expect(req(40.44, -79.99).cacheKey != req(40.46, -79.99).cacheKey)
    }
    @Test func styleIsPartOfCacheKey() {
        #expect(req(40.44, -79.99).cacheKey != req(40.44, -79.99, "mapbox://styles/mapbox/dark-v11").cacheKey)
    }
    @Test func sizeBucketIsPartOfCacheKey() {
        #expect(req(40.44, -79.99, w: 390, h: 700).cacheKey != req(40.44, -79.99, w: 800, h: 700).cacheKey)
    }
    // The load-bearing test: a cross-launch guarantee can't be unit-tested in one process,
    // so pin an EXACT literal key for a known input. If someone reintroduces String.hashValue
    // this literal changes and the test fails.
    @Test func cacheKeyIsDeterministicLiteral() {
        #expect(req(40.44, -79.99, "mapbox://styles/aura/t", w: 390, h: 700).cacheKey
                == "terrain-4044--7999-390x700-s2851307223")
    }
    @Test func usesRiderCoordinateWhenAvailable() {
        let rider = Coordinate(latitude: 37.77, longitude: -122.41)
        #expect(TerrainSnapshotRequest.center(forRider: rider) == rider)
    }
    @Test func fallsBackToCuratedDefault() {
        #expect(TerrainSnapshotRequest.center(forRider: nil) == TerrainSnapshotRequest.curatedDefaultCenter)
    }
}
```

> The literal `-s2851307223` is the FNV-1a value for `"mapbox://styles/aura/t"`. During Step 3, compute the actual value the implementation produces (the builder will report the mismatch on first run) and set the literal to that; the test's purpose is to lock whatever deterministic value ships, not to guess it. The lat/lng/size portions are deterministic by construction.

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — `TerrainSnapshotRequest` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift
import Foundation
import AuraCore

/// A pure description of a terrain backdrop to render. `cacheKey` is stable across process
/// launches (FNV-1a over the style URI — NOT `String.hashValue`, which is per-process
/// seeded) so the disk cache actually hits on relaunch. The coordinate is quantized to a
/// ~1 km grid so GPS jitter reuses the cached image and only a real move re-renders (spec
/// open question #2); the size is bucketed to 10 pt so minor layout changes don't thrash.
public struct TerrainSnapshotRequest: Equatable, Sendable {
    public static let quantizationDegrees = 0.01 // ~1.1 km of latitude per grid cell.

    public let center: Coordinate
    public let styleURI: String
    public let widthBucket: Int
    public let heightBucket: Int
    public let cacheKey: String

    public init(center: Coordinate, styleURI: String, width: Double, height: Double) {
        self.center = center
        self.styleURI = styleURI
        let q = Self.quantizationDegrees
        let latCell = Int((center.latitude / q).rounded())
        let lngCell = Int((center.longitude / q).rounded())
        self.widthBucket = Int((width / 10).rounded()) * 10
        self.heightBucket = Int((height / 10).rounded()) * 10
        let styleHash = Self.fnv1a(styleURI)
        self.cacheKey = "terrain-\(latCell)-\(lngCell)-\(widthBucket)x\(heightBucket)-s\(styleHash)"
    }

    /// Stable 32-bit FNV-1a hash as a string. Deterministic across launches and platforms.
    static func fnv1a(_ s: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in s.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash
    }
}

public extension TerrainSnapshotRequest {
    /// Downtown Pittsburgh — Aura's home terrain, genuinely hilly, so the locationless default
    /// reads as an intentional sample, not an empty map.
    static let curatedDefaultCenter = Coordinate(latitude: 40.4406, longitude: -79.9959)
    static func center(forRider rider: Coordinate?) -> Coordinate { rider ?? curatedDefaultCenter }
}
```

- [ ] **Step 4: Run test to verify it passes** — set the literal in the test to the value the builder reports, then re-run. Expected: PASS (7 tests).
- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift AuraCore/Tests/AuraKitTests/TerrainSnapshotRequestTests.swift
git commit -m "feat(home): TerrainSnapshotRequest with deterministic cache key + curated region"
```

---

## Task 3: TerrainSnapshotDiskCache — pure Data round-trip

Extract the disk cache so it is unit-testable on CI: a pure Foundation `Data` store keyed by `cacheKey`. The app target wraps it with UIImage↔pngData (Task 4).

**Files:**
- Create: `AuraCore/Sources/AuraKit/Home/TerrainSnapshotDiskCache.swift`
- Test: `AuraCore/Tests/AuraKitTests/TerrainSnapshotDiskCacheTests.swift`

**Interfaces:**
- Produces: `public struct TerrainSnapshotDiskCache: Sendable` with `public init(directory: URL)`, `public func url(for key: String) -> URL`, `public func read(_ key: String) -> Data?`, `public func write(_ data: Data, for key: String)`, and `public static func defaultDirectory(fileManager:) -> URL` (Caches/TerrainSnapshots).

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/TerrainSnapshotDiskCacheTests.swift
import Testing
import Foundation
@testable import AuraKit

@Suite struct TerrainSnapshotDiskCacheTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachetest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func writeThenReadRoundTrips() {
        let cache = TerrainSnapshotDiskCache(directory: tmpDir())
        let payload = Data([0x1, 0x2, 0x3, 0x4])
        cache.write(payload, for: "k1")
        #expect(cache.read("k1") == payload)
    }
    @Test func missReturnsNil() {
        #expect(TerrainSnapshotDiskCache(directory: tmpDir()).read("absent") == nil)
    }
    @Test func keysAreIsolated() {
        let cache = TerrainSnapshotDiskCache(directory: tmpDir())
        cache.write(Data([0xAA]), for: "a")
        #expect(cache.read("b") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — `TerrainSnapshotDiskCache` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// AuraCore/Sources/AuraKit/Home/TerrainSnapshotDiskCache.swift
import Foundation

/// Pure Foundation disk cache for rendered terrain images, stored as `Data` keyed by a
/// stable `cacheKey`. Kept in AuraKit (no UIKit) so the round-trip is unit-tested on CI; the
/// app target wraps it with UIImage↔pngData. Files live in Caches/ (OS-evictable).
public struct TerrainSnapshotDiskCache: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for key: String) -> URL { directory.appendingPathComponent("\(key).png") }

    public func read(_ key: String) -> Data? { try? Data(contentsOf: url(for: key)) }

    public func write(_ data: Data, for key: String) {
        try? data.write(to: url(for: key), options: .atomic)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TerrainSnapshots", isDirectory: true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — Expected: PASS (3 tests).
- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/TerrainSnapshotDiskCache.swift AuraCore/Tests/AuraKitTests/TerrainSnapshotDiskCacheTests.swift
git commit -m "feat(home): pure Data disk cache for terrain snapshots (CI round-trip test)"
```

---

## Task 4: Snapshot render seam + Mapbox implementation

The app-target renderer. `MapboxMaps.Snapshotter` renders terrain to a `UIImage` off the live map (no persistent second renderer), cached via `TerrainSnapshotDiskCache`. Seam matches the codebase (`@MainActor protocol …: AnyObject`). **Critical:** the snapshotter is retained through the async render (deallocation-race fix).

**Files:**
- Create: `Aura/Sources/Home/TerrainSnapshotRendering.swift`
- Create: `Aura/Sources/Home/MapboxTerrainSnapshotter.swift`

**Interfaces:**
- Consumes: `TerrainSnapshotRequest`, `TerrainStyle`, `TerrainSnapshotDiskCache`.
- Produces: `@MainActor protocol TerrainSnapshotRendering: AnyObject { func image(for request: TerrainSnapshotRequest, size: CGSize) async -> UIImage? }`; `@MainActor final class MapboxTerrainSnapshotter: TerrainSnapshotRendering`.

- [ ] **Step 1: Write the seam**

```swift
// Aura/Sources/Home/TerrainSnapshotRendering.swift
import UIKit
import AuraKit

/// Renders a terrain backdrop image for a request. A `@MainActor` class protocol (matching
/// the WorkoutWriting / HapticPlaying seams) so `HomeBackdrop` can be driven by a stub in
/// previews and by Mapbox at runtime.
@MainActor
protocol TerrainSnapshotRendering: AnyObject {
    func image(for request: TerrainSnapshotRequest, size: CGSize) async -> UIImage?
}
```

- [ ] **Step 2: Write the Mapbox implementation**

```swift
// Aura/Sources/Home/MapboxTerrainSnapshotter.swift
import UIKit
import MapboxMaps
import AuraKit

/// Renders the Home terrain backdrop via `MapboxMaps.Snapshotter` — an off-map raster, so it
/// adds no persistent live renderer and preserves the single-hoisted-map invariant (ROH-7).
/// Disk-cached (as PNG Data) by `request.cacheKey`.
@MainActor
final class MapboxTerrainSnapshotter: TerrainSnapshotRendering {
    private let cache = TerrainSnapshotDiskCache(directory: TerrainSnapshotDiskCache.defaultDirectory())

    func image(for request: TerrainSnapshotRequest, size: CGSize) async -> UIImage? {
        if let data = cache.read(request.cacheKey), let img = UIImage(data: data) { return img }
        guard size.width > 0, size.height > 0,
              let styleURI = StyleURI(rawValue: request.styleURI) else { return nil }

        let options = MapSnapshotOptions(
            size: size,
            pixelRatio: 3, // fixed @3x; UIScreen.main.scale is deprecated / multi-scene-unsafe
            glyphsRasterizationOptions: GlyphsRasterizationOptions(rasterizationMode: .ideographsRasterizedLocally))
        let snapshotter = Snapshotter(options: options)
        snapshotter.styleURI = styleURI
        snapshotter.setCamera(to: CameraOptions(
            center: CLLocationCoordinate2D(latitude: request.center.latitude,
                                           longitude: request.center.longitude),
            zoom: 12.5, pitch: 0))
        // Surface a bad custom URI (ROH-6 typo) instead of a silent permanent placeholder.
        snapshotter.onMapLoadingError.observe { error in
            print("[TerrainSnapshotter] style load error: \(error)")
        }.store(in: &tokens)

        let image: UIImage? = await withCheckedContinuation { continuation in
            // Retain `snapshotter` for the render's lifetime — the SDK callback captures
            // [weak self] and returns early if the Snapshotter has been deallocated, which
            // would leak the continuation and hang the await. Capturing it here keeps it alive.
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

    private var tokens: Set<AnyCancelable> = []
}
```

> Verify the exact v11 event-observation API (`onMapLoadingError.observe {…}.store(in:)` / `AnyCancelable`) against the checked-out SDK; the builder reports the precise shape if it differs. The retain-through-`start` and the `pixelRatio: 3` are non-negotiable fixes from review.

- [ ] **Step 3: Build to verify it compiles** — delegate to the builder (app scheme, simulator). Expected: BUILD SUCCEEDED. (Snapshotter can't be unit-tested on CI; the *cache* round-trip already is, Task 3.)
- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Home/TerrainSnapshotRendering.swift Aura/Sources/Home/MapboxTerrainSnapshotter.swift
git commit -m "feat(home): Mapbox Snapshotter terrain renderer (retained render, disk cache, no 2nd renderer)"
```

---

## Task 5: HomeBackdrop view

Non-interactive backdrop: placeholder → rendered image without a flash, top/bottom scrims, Reduce Transparency/Motion honored, one ignored VoiceOver element under a labeled wrapper. The render `.task` id includes the quantized size so a real layout change re-renders at the right resolution (no stretched `scaledToFill`).

**Files:** Create: `Aura/Sources/Home/HomeBackdrop.swift`

**Interfaces:**
- Consumes: `TerrainSnapshotRendering`, `TerrainSnapshotRequest`, `TerrainStyle`, `AuraTheme`, `AuraCore.Coordinate`.
- Produces: `struct HomeBackdrop: View` taking `let renderer: TerrainSnapshotRendering`, `let riderCoordinate: Coordinate?`, `let placeName: String?`.

- [ ] **Step 1: Write the view**

```swift
// Aura/Sources/Home/HomeBackdrop.swift
import SwiftUI
import AuraCore
import AuraKit

/// The Home terrain backdrop: a cached, non-interactive rendered image (never a live Map),
/// framed with top/bottom scrims. One ignored VoiceOver element under a labeled wrapper.
struct HomeBackdrop: View {
    let renderer: TerrainSnapshotRendering
    let riderCoordinate: Coordinate?
    let placeName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var image: UIImage?
    @State private var settled = false

    var body: some View {
        GeometryReader { geo in
            let req = request(for: geo.size)
            ZStack {
                AuraTheme.background // placeholder while rendering — no flash
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .scaleEffect(settled || reduceMotion ? 1.0 : 1.04)
                        .opacity(settled || reduceMotion ? 1.0 : 0.0)
                }
                scrims
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: req?.cacheKey) {
                guard let req else { return }
                settled = false
                image = await renderer.image(for: req, size: geo.size)
                if reduceMotion { settled = true }
                else { withAnimation(.easeOut(duration: 0.6)) { settled = true } }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placeName.map { "Map of your area, \($0)" } ?? "Map of your area")
    }

    private func request(for size: CGSize) -> TerrainSnapshotRequest? {
        guard size.width > 0, size.height > 0 else { return nil }
        return TerrainSnapshotRequest(
            center: TerrainSnapshotRequest.center(forRider: riderCoordinate),
            styleURI: TerrainStyle.styleURI, width: size.width, height: size.height)
    }

    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [AuraTheme.background.opacity(reduceTransparency ? 0.95 : 0.7), .clear],
                           startPoint: .top, endPoint: .bottom).frame(height: 180)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, AuraTheme.background.opacity(reduceTransparency ? 0.98 : 0.85)],
                           startPoint: .top, endPoint: .bottom).frame(height: 320)
        }
        .ignoresSafeArea()
    }
}
```

- [ ] **Step 2: Build to verify + commit** — delegate a build. Expected: BUILD SUCCEEDED.

```bash
git add Aura/Sources/Home/HomeBackdrop.swift
git commit -m "feat(home): HomeBackdrop — cached terrain image, scrims, size-aware re-render, VoiceOver wrapper"
```

- [ ] **Step 3: Device gate (deferred):** terrain legible in bright sun; one-shot settle intentional; Reduce Motion fully static.

---

## Task 6: The Explore rename (atomic, robust grep, CI-wired)

Rename every user-facing "free ride" to "Explore" and the pre-start HUD to "Start ride"; leave all frozen identifiers untouched. The grep is case-insensitive, ignores comments, excludes frozen-identifier lines, and runs in CI.

**Files (exact edits):**
- `Aura/Sources/Ride/RideHUDView.swift:70` — `"Start free ride"` → `"Start ride"`.
- `Aura/Sources/History/HistoryView.swift:150` — `"Free ride"` → `"Explore"`.
- `Aura/Sources/History/HistoryView.swift:104` — `"Start a free ride or navigate somewhere — your rides land here."` → `"Start an Explore ride or navigate somewhere — your rides land here."` (reword for humanized copy if preferred, but remove "free ride").
- `Aura/Sources/Plan/LastRideCard.swift:81` — fallback `"Free ride"` → `"Explore"`.
- `Aura/Sources/Plan/PlanView.swift:253` — `Button("Free ride")` → `Button("Explore")` (required — PlanView still exists at rename time; deleted later in Task 14c).
- `Aura/Widgets/RideLockScreenView.swift:42` — header `"Free ride"` → `"Explore"`; `:58` — `"Free ride in progress"` → `"Explore in progress"`.
- `Aura/Widgets/RideLiveActivity.swift:73` — `"Free ride"` → `"Explore"`.
- `Aura/Widgets/WidgetSupport.swift:14` — string `"Free ride"` → `"Explore"`; `:12` — reword the doc comment so it no longer contains the quoted token (e.g. `/// "Explore" or the navigated destination name.`).
- Audit (read, don't just grep): every rendered label **derived** from `RideActivityMode.freeRide` / `Ride.Kind.freeRide` (share card included) — confirm none interpolate the word "Free ride" at runtime. Fix any that do.
- Create: `scripts/check-explore-rename.sh`. Modify: `.github/workflows/ci.yml` to run it.

- [ ] **Step 1: Write the failing acceptance check**

```bash
#!/usr/bin/env bash
# Fails if any user-facing surface still renders "free ride" (case-insensitive), excluding
# code comments and the frozen identifiers. Comments (/// or //) are stripped before matching.
set -euo pipefail
matches=$(grep -rniE 'free ride' --include="*.swift" Aura \
  | grep -vE ':[[:space:]]*//' \
  | grep -viE 'freeRide|\.freeRide|RideActivityMode|Ride\.Kind|AppRoute|DeepLink' || true)
if [ -n "$matches" ]; then
  echo "FAIL: user-facing 'free ride' strings remain:"; echo "$matches"; exit 1
fi
echo "PASS: no user-facing 'free ride' strings."
```

- [ ] **Step 2: Run it to verify it fails** — `bash scripts/check-explore-rename.sh`. Expected: FAIL, listing the sites above.
- [ ] **Step 3: Apply the edits** listed under **Files**. Do NOT touch `.freeRide`, `RideActivityMode.freeRide`, the `"freeRide"` raw value, `aura://ride`, `AppRoute`, `DeepLink`, or `RideMapper`.
- [ ] **Step 4: Run the check + build** — `bash scripts/check-explore-rename.sh` → PASS. Delegate a build → BUILD SUCCEEDED.
- [ ] **Step 5: Wire into CI** — add a step to the lint/build job in `.github/workflows/ci.yml`:

```yaml
      - name: Explore rename guard
        run: bash scripts/check-explore-rename.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/check-explore-rename.sh .github/workflows/ci.yml Aura/Sources/Ride/RideHUDView.swift Aura/Sources/History/HistoryView.swift Aura/Sources/Plan/LastRideCard.swift Aura/Sources/Plan/PlanView.swift Aura/Widgets/RideLockScreenView.swift Aura/Widgets/RideLiveActivity.swift Aura/Widgets/WidgetSupport.swift
git commit -m "refactor(copy): rename user-facing 'free ride' to 'Explore'; HUD 'Start ride'; CI-guarded (identifiers frozen)"
```

---

## Task 7: WeeklyGlance motivation model

The pure motivation-hook sentence: distance-to-goal when riding this week, last-ride fallback otherwise. Deterministic (injected calendar + `en_US_POSIX` locale). Exact-string tests.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Home/WeeklyGlance.swift`
- Test: `AuraCore/Tests/AuraKitTests/WeeklyGlanceTests.swift`

**Interfaces:**
- Consumes: `WeeklyRideStats`, `RideSummary`, `DistanceUnits`, `RideStatsFormatter` (public in AuraKit), `RideAggregator`.
- Produces: `public enum WeeklyGlance` with `public static func headline(week: WeeklyRideStats, goalMeters: Double, lastRide: RideSummary?, units: DistanceUnits, now: Date, calendar: Calendar = .current) -> String` and `public static func ringFraction(week: WeeklyRideStats, goalMeters: Double) -> Double`.

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/WeeklyGlanceTests.swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite struct WeeklyGlanceTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000) // fixed
    private func summary(_ meters: Double, daysAgo: Int) -> RideSummary {
        RideSummary(id: UUID(), kind: .freeRide,
                    startedAt: now.addingTimeInterval(Double(-daysAgo) * 86_400),
                    endedAt: now, hasStats: true, distanceMeters: meters,
                    movingTimeSeconds: 1800, elevationGainMeters: 50,
                    destinationName: nil, thumbnailCoordinates: [])
    }

    @Test func noRidesNoLast_promptsFirstRide() {
        let s = WeeklyGlance.headline(week: .zero, goalMeters: 40_000, lastRide: nil,
                                      units: .imperial, now: now)
        #expect(s == "Plan your first ride to start your weekly goal")
    }

    @Test func noRidesThisWeek_showsLastRideDistanceAndDay() {
        let last = summary(29_600, daysAgo: 1) // ~18.4 mi, yesterday
        let s = WeeklyGlance.headline(week: .zero, goalMeters: 40_000, lastRide: last,
                                      units: .imperial, now: now)
        #expect(s == "18.4 mi last ride, yesterday")
    }

    @Test func underGoalMidWeek_showsDistanceRemaining() {
        let week = WeeklyRideStats(distanceMeters: 29_600, rideCount: 1,
                                   elevationGainMeters: 50, movingTimeSeconds: 1800)
        let s = WeeklyGlance.headline(week: week, goalMeters: 40_000, lastRide: summary(29_600, daysAgo: 1),
                                      units: .imperial, now: now)
        #expect(s == "6.5 mi to your weekly goal") // (40000-29600)m = 10400m ≈ 6.5 mi
    }

    @Test func atOrOverGoal_showsComplete() {
        let week = WeeklyRideStats(distanceMeters: 80_000, rideCount: 5,
                                   elevationGainMeters: 0, movingTimeSeconds: 0)
        let s = WeeklyGlance.headline(week: week, goalMeters: 40_000, lastRide: nil,
                                      units: .imperial, now: now)
        #expect(s == "Weekly goal complete — 200%")
    }

    @Test func ringFractionClampsToOne() {
        let week = WeeklyRideStats(distanceMeters: 80_000, rideCount: 5,
                                   elevationGainMeters: 0, movingTimeSeconds: 0)
        #expect(WeeklyGlance.ringFraction(week: week, goalMeters: 40_000) == 1.0)
    }
}
```

> Confirm `RideStatsFormatter.distanceValue(29_600)` renders `"18.4"` and `distanceValue(10_400)` renders `"6.5"` for `.imperial` (it uses `%.1f` mi). If the formatter rounds differently, set the expected literals to the real output; keep them exact, not `contains`.

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — `WeeklyGlance` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// AuraCore/Sources/AuraKit/Home/WeeklyGlance.swift
import Foundation
import AuraCore

/// The always-visible Home motivation hook — a specific sentence with a number. Pure and
/// deterministic (injected calendar, fixed POSIX locale) so it is unit-tested on CI. Framing
/// is distance-to-goal (PO decision), with a last-ride fallback when there's no weekly story.
public enum WeeklyGlance {
    public static func headline(week: WeeklyRideStats, goalMeters: Double, lastRide: RideSummary?,
                                units: DistanceUnits, now: Date, calendar: Calendar = .current) -> String {
        if week.rideCount == 0 {
            guard let last = lastRide else { return "Plan your first ride to start your weekly goal" }
            return "\(distanceText(last.distanceMeters, units)) last ride, \(dayText(last.startedAt, now: now, calendar: calendar))"
        }
        let percent = week.goalPercent(goalMeters: goalMeters)
        if percent >= 100 { return "Weekly goal complete — \(percent)%" }
        let remaining = max(0, goalMeters - week.distanceMeters)
        return "\(distanceText(remaining, units)) to your weekly goal"
    }

    public static func ringFraction(week: WeeklyRideStats, goalMeters: Double) -> Double {
        week.goalFraction(goalMeters: goalMeters)
    }

    private static func distanceText(_ meters: Double, _ units: DistanceUnits) -> String {
        let fmt = RideStatsFormatter(units: units)
        return "\(fmt.distanceValue(meters)) \(fmt.distanceUnit)"
    }

    private static func dayText(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: y) { return "yesterday" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"
        return f.string(from: date) // e.g. "Tue"
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — Expected: PASS (5 tests).
- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/WeeklyGlance.swift AuraCore/Tests/AuraKitTests/WeeklyGlanceTests.swift
git commit -m "feat(home): WeeklyGlance motivation model (distance-to-goal, deterministic, exact-string tests)"
```

---

## Task 8: HomeMode first-run predicate + onboarding flag

The first-run vs populated decision, extracted to a pure function and tested against the full `(hasRides, authState)` matrix, so the returning-user-who-denied-location reliably gets the populated layout with the curated default. Backed by a device-local persisted onboarding flag.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Home/HomeMode.swift`
- Modify: `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift` — add device-local `didCompleteOnboarding`.
- Test: `AuraCore/Tests/AuraKitTests/HomeModeTests.swift`

**Interfaces:**
- Produces: `public enum LocationAuthState: Sendable { case notDetermined, denied, authorized }`; `public enum HomeMode: Sendable { case firstRun, populated }`; `public extension HomeMode { static func resolve(hasCompletedOnboarding: Bool, hasRides: Bool, auth: LocationAuthState) -> HomeMode }`.
- Modifies: `SettingsStore` gains `public var didCompleteOnboarding: Bool` (device-local, not synced — like `saveToHealth`).

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/HomeModeTests.swift
import Testing
@testable import AuraKit

@Suite struct HomeModeTests {
    @Test func trueFirstRun_notOnboardedNoRidesUndetermined() {
        #expect(HomeMode.resolve(hasCompletedOnboarding: false, hasRides: false, auth: .notDetermined) == .firstRun)
    }
    @Test func returningUserDeniedLocationNoRides_isPopulated() {
        // The spec's "no location permission (returning user)" case must NOT get first-run.
        #expect(HomeMode.resolve(hasCompletedOnboarding: true, hasRides: false, auth: .denied) == .populated)
    }
    @Test func anyRides_isPopulated() {
        #expect(HomeMode.resolve(hasCompletedOnboarding: false, hasRides: true, auth: .notDetermined) == .populated)
    }
    @Test func onboardedNoRidesUndetermined_isPopulated() {
        #expect(HomeMode.resolve(hasCompletedOnboarding: true, hasRides: false, auth: .notDetermined) == .populated)
    }
}
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — `HomeMode` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// AuraCore/Sources/AuraKit/Home/HomeMode.swift
import Foundation

/// A CoreLocation-free authorization projection so the predicate stays pure/testable on CI;
/// the app maps `CLAuthorizationStatus` onto it.
public enum LocationAuthState: Sendable { case notDetermined, denied, authorized }

/// Which Home composition to show. First-run is its own composition; everything else is the
/// populated layout (which itself handles the no-permission case via the curated default).
public enum HomeMode: Sendable { case firstRun, populated }

public extension HomeMode {
    /// First-run only when the user has never completed onboarding AND has no rides AND has
    /// not yet answered the location prompt. Any ride, or a determined auth state, means a
    /// returning user → populated (with the curated default when location is unavailable).
    static func resolve(hasCompletedOnboarding: Bool, hasRides: Bool, auth: LocationAuthState) -> HomeMode {
        if hasRides || hasCompletedOnboarding { return .populated }
        return auth == .notDetermined ? .firstRun : .populated
    }
}
```

- [ ] **Step 4: Add `didCompleteOnboarding` to SettingsStore** — mirror the device-local `saveToHealth` pattern exactly:

```swift
    /// Device-local: whether the rider has completed the first-run composition. Not synced.
    public var didCompleteOnboarding: Bool { didSet { defaults.set(didCompleteOnboarding, forKey: Key.didCompleteOnboarding) } }
```
Initialize in `init`: `didCompleteOnboarding = defaults.object(forKey: Key.didCompleteOnboarding) as? Bool ?? false`, and add `static let didCompleteOnboarding = "didCompleteOnboarding"` to the `Key` enum. Add an XCTest to `SettingsStoreTests.swift` mirroring `test_turnHaptics_defaultsOnAndPersists`: defaults false, persists true.

- [ ] **Step 5: Run tests to verify they pass** — Expected: PASS (4 HomeMode + 1 SettingsStore).
- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/HomeMode.swift AuraCore/Sources/AuraKit/Settings/SettingsStore.swift AuraCore/Tests/AuraKitTests/HomeModeTests.swift AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift
git commit -m "feat(home): pure HomeMode first-run predicate + device-local onboarding flag"
```

---

## Task 9: WeeklyGlanceView

The always-visible hook: the `WeeklyGlance` sentence plus a compact ring. Renders with no gesture.

**Files:** Create: `Aura/Sources/Home/WeeklyGlanceView.swift`

**Interfaces:** Consumes `WeeklyGlance`, `WeeklyRideStats`, `RideSummary`, `DistanceUnits`, `AuraTheme`. Produces `struct WeeklyGlanceView: View` taking `week`, `goalMeters`, `lastRide`, `units`.

- [ ] **Step 1: Write the view**

```swift
// Aura/Sources/Home/WeeklyGlanceView.swift
import SwiftUI
import AuraCore
import AuraKit

/// The always-visible motivation hook in the sheet's peek header: a sentence with a number
/// plus a compact progress ring. Renders with no gesture (explicit spec gate).
struct WeeklyGlanceView: View {
    let week: WeeklyRideStats
    let goalMeters: Double
    let lastRide: RideSummary?
    let units: DistanceUnits

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedFraction: Double = 0

    private var fraction: Double { WeeklyGlance.ringFraction(week: week, goalMeters: goalMeters) }
    private var headline: String {
        WeeklyGlance.headline(week: week, goalMeters: goalMeters, lastRide: lastRide, units: units, now: Date())
    }

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.lg) {
            ZStack {
                Circle().stroke(AuraTheme.border, lineWidth: 5)
                Circle().trim(from: 0, to: animatedFraction)
                    .stroke(AuraTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 36, height: 36)
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("home.glance")
        .onAppear { animate(to: fraction) }
        .onChange(of: fraction) { _, new in animate(to: new) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    private func animate(to target: Double) {
        guard !reduceMotion else { animatedFraction = target; return }
        withAnimation(.easeOut(duration: 0.9)) { animatedFraction = target }
    }
}
```

- [ ] **Step 2: Build + commit** — delegate a build. Expected: BUILD SUCCEEDED.

```bash
git add Aura/Sources/Home/WeeklyGlanceView.swift
git commit -m "feat(home): WeeklyGlanceView — always-visible motivation hook (sentence + compact ring)"
```

---

## Task 10: LastRideCard subtle terrain foreshadow (signature-moment thread)

Restyle `LastRideCard`'s thumbnail area with a restrained terrain tint / faint contour behind the route line on an opaque plate, so it visibly foreshadows the Chunk 3 terrain-carved medal (a named acceptance gate). PO decision: subtle now, full emboss deferred.

**Files:** Modify: `Aura/Sources/Plan/LastRideCard.swift` (the `thumbnail` view, lines 53–75).

- [ ] **Step 1: Restyle the thumbnail backdrop** — replace the flat `AuraTheme.background` behind the `RouteThumbnail` with a layered terrain hint: a subtle radial/linear charcoal-green tint plus a faint contour motif at capped low opacity (Chunk 0 Rule 4: texture behind an opaque plate, bounded delta-luminance), keeping the lime `RouteThumbnail` on top. Concretely, inside `thumbnail`'s `ZStack`, replace `AuraTheme.background` with:

```swift
            ZStack {
                AuraTheme.surface
                // Faint contour foreshadow — bounded, decorative, never behind text (text is
                // outside this thumbnail). Reads as tactile relief, not busy.
                ContourForeshadow().opacity(0.10)
            }
```

and add a small private `ContourForeshadow: View` in the same file drawing a few nested rounded strokes with `Canvas` in `AuraTheme.accent.opacity(low)` / a green tint (no text underneath). Keep the existing `RouteThumbnail`/glyph on top unchanged. Under `accessibilityReduceTransparency`/Increase Contrast, drop the foreshadow to a plain `AuraTheme.surface` (reuse the env value).

- [ ] **Step 2: Build + device-eyeball + commit** — delegate a build. Expected: BUILD SUCCEEDED. Device gate (deferred): the card reads as terrain-flavored and foreshadows the medal without competing with the route line.

```bash
git add Aura/Sources/Plan/LastRideCard.swift
git commit -m "feat(home): subtle terrain foreshadow on LastRideCard (signature-moment thread)"
```

---

## Task 11: HomeSheet — system detented dashboard

A **system `.presentationDetents` sheet** with background interaction, always presented (never dismissed). SwiftUI arbitrates scroll-vs-drag (no hand-rolled gesture). Peek shows the glance **and** the last-ride card; half/full reveal recents + saved in a scroll.

**Files:** Create: `Aura/Sources/Home/HomeSheet.swift`

**Interfaces:**
- Produces: a view modifier `func homeDashboardSheet<PeekHeader: View, Body: View>(isPresented: Binding<Bool>, peekHeight: CGFloat, @ViewBuilder peek: () -> PeekHeader, @ViewBuilder body: () -> Body) -> some View`. (Applied by `HomeView` to its content; the sheet content is peek + scroll body.)

- [ ] **Step 1: Write the sheet modifier**

```swift
// Aura/Sources/Home/HomeSheet.swift
import SwiftUI
import AuraCore

/// The Home dashboard as a system sheet with three detents, always presented and
/// non-dismissable, with background interaction so the terrain + launch band stay live
/// beneath it. Using `.presentationDetents` means SwiftUI arbitrates the drag vs the inner
/// ScrollView — no custom gesture. Peek shows the peek header (glance + last ride); dragging
/// up scrolls the body (recents, saved).
private struct HomeDashboardSheet<PeekHeader: View, Body: View>: ViewModifier {
    @Binding var isPresented: Bool
    let peekHeight: CGFloat
    @ViewBuilder let peek: () -> PeekHeader
    @ViewBuilder let body: () -> Body

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            VStack(spacing: AuraTheme.Spacing.md) {
                peek().padding(.horizontal, AuraTheme.Spacing.xxl).padding(.top, AuraTheme.Spacing.lg)
                ScrollView { body().padding(.horizontal, AuraTheme.Spacing.xxl) }
                    .scrollIndicators(.hidden)
            }
            .presentationDetents([.height(peekHeight), .fraction(0.55), .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
            .presentationBackground(AuraTheme.surface)
        }
    }
}

extension View {
    func homeDashboardSheet<PeekHeader: View, Body: View>(
        isPresented: Binding<Bool>, peekHeight: CGFloat,
        @ViewBuilder peek: @escaping () -> PeekHeader,
        @ViewBuilder body: @escaping () -> Body) -> some View {
        modifier(HomeDashboardSheet(isPresented: isPresented, peekHeight: peekHeight, peek: peek, body: body))
    }
}
```

- [ ] **Step 2: Build + commit** — delegate a build. Expected: BUILD SUCCEEDED.

```bash
git add Aura/Sources/Home/HomeSheet.swift
git commit -m "feat(home): system detented dashboard sheet (peek/half/large, background interaction)"
```

- [ ] **Step 3: Device gate (deferred):** peek shows glance + last-ride card; drag to half/large reveals recents+saved and scrolls cleanly; the launch band beneath stays tappable at peek/half; Reduce Motion respected by the system.

---

## Task 12: HomeLaunchBand + SearchOverlay (one dominant band)

One composed lower band: the dominant lime "Where to?" primary on top, the demoted Explore + Join secondaries beneath. Tapping the primary expands `SearchOverlay` (scrim + focused field + results). `DestinationSearchView` gains a `FocusState` binding + a11y id so the field actually focuses and is findable.

**Files:**
- Create: `Aura/Sources/Home/HomeLaunchBand.swift`
- Create: `Aura/Sources/Home/SearchOverlay.swift`
- Modify: `Aura/Sources/Plan/DestinationSearchView.swift` (add `isFocused: FocusState<Bool>.Binding` param, apply `.focused` to its own TextField, add `.accessibilityIdentifier("home.searchField")`).
- Test: create `Aura/UITests/HomeUITests.swift` with `test_searchExpandsAndCollapses`.

- [ ] **Step 1: Write the failing UI test**

```swift
// Aura/UITests/HomeUITests.swift
import XCTest

final class HomeUITests: XCTestCase {
    // Seed "onboarded" via the built-in NSArgumentDomain so Home shows the populated layout
    // (not first-run) without any custom test-seeding code in the app.
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES"]
        app.launch()
        return app
    }

    func test_searchExpandsAndCollapses() {
        let app = launchedApp()
        let whereTo = app.buttons["home.whereTo"]
        XCTAssertTrue(whereTo.waitForExistence(timeout: 5))
        whereTo.tap()
        XCTAssertTrue(app.textFields["home.searchField"].waitForExistence(timeout: 3))
        app.buttons["home.searchCancel"].tap()
        XCTAssertTrue(whereTo.waitForExistence(timeout: 3))
    }
}
```

> `SettingsStore` reads `UserDefaults.standard`; the `-auraDidCompleteOnboarding YES` launch arg lands in `NSArgumentDomain`, so `defaults.object(forKey: "auraDidCompleteOnboarding") as? Bool == true` at launch, with no app-side seeding seam. Confirm the `Key.didCompleteOnboarding` string is exactly `"auraDidCompleteOnboarding"` — set it so in Task 8's `Key` enum (adjust Task 8 if it used a shorter key).

- [ ] **Step 2: Run to verify it fails** — delegate the UI test. Expected: FAIL (band/overlay absent).

- [ ] **Step 3: Modify DestinationSearchView** — change its signature to `init(query: Binding<String>, isFocused: FocusState<Bool>.Binding, onPick: @escaping (Place) -> Void)`, store the binding, apply `.focused(isFocused)` to its internal `TextField`, and add `.accessibilityIdentifier("home.searchField")` to that field. Update its one existing call site (the retired PlanView — or leave until Task 14). Keep all search/debounce behavior unchanged.

- [ ] **Step 4: Write HomeLaunchBand**

```swift
// Aura/Sources/Home/HomeLaunchBand.swift
import SwiftUI
import AuraCore

/// The one dominant launch band, pinned in the reachable lower area: a full-width lime
/// "Where to?" primary on top, with Explore + Join as a demoted secondary row beneath. Lime
/// lives only on the primary. Tapping the primary expands search.
struct HomeLaunchBand: View {
    let onWhereTo: () -> Void
    let onExplore: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            Button(action: onWhereTo) {
                Label("Where to?", systemImage: "magnifyingglass")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ctaPrimary)
            .accessibilityIdentifier("home.whereTo")
            .accessibilitySortPriority(3)

            HStack(spacing: AuraTheme.Spacing.sm) {
                Button("Explore", action: onExplore)
                    .buttonStyle(.ctaSecondary).frame(maxWidth: .infinity)
                    .accessibilitySortPriority(1)
                Button(action: onJoin) {
                    Label("Join a ride", systemImage: "person.2.badge.plus")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ctaSecondary)
                .accessibilitySortPriority(1)
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }
}
```

- [ ] **Step 5: Write SearchOverlay**

```swift
// Aura/Sources/Home/SearchOverlay.swift
import SwiftUI
import AuraCore

/// The expanded search state only: a dimming scrim, the focused field (DestinationSearchView),
/// and results above everything. The container hides the sheet + band while this is up, so
/// nothing stacks. On pick/cancel it clears + collapses.
struct SearchOverlay: View {
    @Binding var query: String
    let onPick: (Place) -> Void
    let onCollapse: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            AuraTheme.background.opacity(0.6).ignoresSafeArea().onTapGesture { collapse() }
            VStack(spacing: AuraTheme.Spacing.md) {
                HStack(spacing: AuraTheme.Spacing.sm) {
                    DestinationSearchView(query: $query, isFocused: $fieldFocused) { place in
                        onPick(place); collapse()
                    }
                    Button("Cancel") { collapse() }.accessibilityIdentifier("home.searchCancel")
                }
                Spacer(minLength: 0)
            }
            .padding(AuraTheme.Spacing.xxl)
        }
        .task { fieldFocused = true }
    }

    private func collapse() { query = ""; fieldFocused = false; onCollapse() }
}
```

- [ ] **Step 6: Run the UI test to verify it passes** — this requires `HomeView` (Task 14) to mount the band + overlay. If executing strictly in order, defer running `test_searchExpandsAndCollapses` to Task 14b and here only build-verify the three files compile. Delegate a build. Expected: BUILD SUCCEEDED.
- [ ] **Step 7: Commit**

```bash
git add Aura/Sources/Home/HomeLaunchBand.swift Aura/Sources/Home/SearchOverlay.swift Aura/Sources/Plan/DestinationSearchView.swift Aura/UITests/HomeUITests.swift
git commit -m "feat(home): one dominant launch band + expandable SearchOverlay (focus + a11y id wired)"
```

---

## Task 13: FirstRunHomeView (one primary)

First run is its own composition: a purpose-framed location ask over a curated sample terrain, and ONE unmistakable primary. Tapping the primary marks onboarding complete and routes into planning (the location prompt is triggered by the app's existing location entry point, not a competing second CTA).

**Files:** Create: `Aura/Sources/Home/FirstRunHomeView.swift`

**Interfaces:** Consumes `HomeBackdrop`, `AuraTheme`. Produces `struct FirstRunHomeView: View` taking `let renderer: TerrainSnapshotRendering`, `let onStart: () -> Void`.

- [ ] **Step 1: Write the view**

```swift
// Aura/Sources/Home/FirstRunHomeView.swift
import SwiftUI
import AuraCore
import AuraKit

/// First-run Home: a purpose-framed ask over a curated sample terrain, one primary. Its own
/// composition, not the populated layout with empty strings.
struct FirstRunHomeView: View {
    let renderer: TerrainSnapshotRendering
    let onStart: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            HomeBackdrop(renderer: renderer, riderCoordinate: nil, placeName: "Pittsburgh")
            VStack(spacing: AuraTheme.Spacing.md) {
                Text("Aura needs your location to map your hills")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AuraTheme.textPrimary)
                Text("Sample terrain shown — your first ride maps your own.")
                    .font(.footnote).foregroundStyle(AuraTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Plan your first ride", action: onStart)
                    .buttonStyle(.ctaPrimary)
                    .accessibilityIdentifier("home.planFirstRide")
            }
            .padding(.horizontal, AuraTheme.Spacing.xxl)
            .padding(.bottom, AuraTheme.Spacing.xxl)
        }
    }
}
```

- [ ] **Step 2: Build + commit** — delegate a build. Expected: BUILD SUCCEEDED.

```bash
git add Aura/Sources/Home/FirstRunHomeView.swift
git commit -m "feat(home): first-run composition with a single primary over sample terrain"
```

- [ ] **Step 3: Device screenshot gate (deferred):** the ask, sample terrain, and single primary read clearly on the real iPhone.

---

## Task 14a: HomeView — assemble the container (PlanView still present)

Create the always-mounted container wiring backdrop + band + glance/sheet + overlay + first-run branch + loading state, with all `@State` hoisted and the data wiring intact. Do NOT touch RootView or delete PlanView yet (keeps this reviewable and revertible).

**Files:**
- Create: `Aura/Sources/Home/HomeView.swift`
- Create: `Aura/Sources/Home/HomeRows.swift` (move `RecentRow` here from PlanView — copy now; PlanView's copy is removed in 14c).

**Interfaces:** Produces `struct HomeView: View` (reads the environment like PlanView). Consumes everything from Tasks 4–13, `RideAggregator`, `WeeklyGlance`, `HomeMode`.

- [ ] **Step 1: Write HomeView**

```swift
// Aura/Sources/Home/HomeView.swift
import SwiftUI
import CoreLocation
import AuraCore
import AuraKit

/// Home — the "Terrain hero canvas". Always-mounted container: owns the backdrop, the launch
/// band, the search overlay, the dashboard sheet, and all state + data subscriptions.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(SavedPlacesStore.self) private var savedPlaces

    @State private var query = ""
    @State private var summaries: [RideSummary] = []
    @State private var didLoad = false
    @State private var showJoinRide = false
    @State private var renameTarget: SavedPlace?
    @State private var renameText = ""
    @State private var searchExpanded = false
    @State private var sheetPresented = true
    @State private var authState: LocationAuthState = .notDetermined
    @ScaledMetric(relativeTo: .title) private var brandSize: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var peekHeight: CGFloat = 250

    private let renderer: TerrainSnapshotRendering = MapboxTerrainSnapshotter()

    private var weekStats: WeeklyRideStats { RideAggregator.weekToDate(summaries, now: Date()) }
    private var lastRide: RideSummary? { RideAggregator.mostRecent(summaries) }
    private var mode: HomeMode {
        HomeMode.resolve(hasCompletedOnboarding: settings.didCompleteOnboarding,
                         hasRides: !summaries.isEmpty, auth: authState)
    }

    var body: some View {
        Group {
            if mode == .firstRun {
                FirstRunHomeView(renderer: renderer) {
                    settings.didCompleteOnboarding = true
                    searchExpanded = true
                }
            } else {
                populated
            }
        }
        .task { await loadRides() }
        .onChange(of: rideStore.syncRevision) { Task { await loadRides() } }
        .sheet(isPresented: $showJoinRide) { NavigationStack { GroupRideJoinView() } }
        .alert("Rename saved place", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let t = renameTarget { savedPlaces.rename(id: t.id, to: renameText) }; renameTarget = nil }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var populated: some View {
        ZStack {
            HomeBackdrop(renderer: renderer, riderCoordinate: nil, placeName: nil)
            VStack(spacing: 0) {
                header.padding(.top, AuraTheme.Spacing.lg)
                Spacer(minLength: 0)
                if !searchExpanded {
                    HomeLaunchBand(
                        onWhereTo: { searchExpanded = true; sheetPresented = false },
                        onExplore: { router.push(.freeRide) },
                        onJoin: { showJoinRide = true })
                        .padding(.bottom, peekHeight + AuraTheme.Spacing.md) // sit above the peek sheet
                }
            }
            if searchExpanded {
                SearchOverlay(query: $query,
                              onPick: { place in router.remember(place); router.push(.preview(place)) },
                              onCollapse: { searchExpanded = false; sheetPresented = true })
            }
        }
        .homeDashboardSheet(isPresented: $sheetPresented, peekHeight: peekHeight) {
            VStack(spacing: AuraTheme.Spacing.lg) {
                WeeklyGlanceView(week: weekStats, goalMeters: settings.weeklyGoalMeters,
                                 lastRide: lastRide, units: settings.units)
                if let lastRide {
                    LastRideCard(summary: lastRide, units: settings.units) { router.selectedTab = .history }
                } else if !didLoad {
                    RoundedRectangle(cornerRadius: AuraTheme.Radius.lg).fill(AuraTheme.surface).frame(height: 88)
                }
            }
        } body: {
            sheetBody
        }
    }

    private func loadRides() async {
        summaries = (try? rideStore.summaries()) ?? []
        didLoad = true
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting).font(.footnote.weight(.medium)).foregroundStyle(AuraTheme.textSecondary)
                Text("Aura").font(AuraTheme.Typography.metricBrand(brandSize)).foregroundStyle(AuraTheme.textPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late ride?"
        }
    }

    private var visibleRecents: [Place] { router.recents.filter { !savedPlaces.isSaved($0) } }

    @ViewBuilder private var sheetBody: some View {
        VStack(spacing: AuraTheme.Spacing.xxxl) {
            if !savedPlaces.places.isEmpty { savedSection }
            if !visibleRecents.isEmpty { recentsSection }
        }
        .padding(.vertical, AuraTheme.Spacing.lg)
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            sectionHeader("Saved")
            listCard { ForEach(savedPlaces.places) { saved in
                SavedPlaceRow(saved: saved,
                              onTap: { router.push(.preview(saved.place)) },
                              onRename: { renameText = saved.name; renameTarget = saved },
                              onSetHome: { savedPlaces.setHome(id: saved.id) },
                              onRemoveHome: { savedPlaces.removeHome(id: saved.id) },
                              onDelete: { savedPlaces.delete(id: saved.id) })
                if saved.id != savedPlaces.places.last?.id { rowDivider }
            } }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            sectionHeader("Recents")
            listCard { ForEach(visibleRecents) { place in
                RecentRow(place: place) { router.push(.preview(place)) }
                if place.id != visibleRecents.last?.id { rowDivider }
            } }
        }
    }

    private func listCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
    }
    private var rowDivider: some View { Divider().background(AuraTheme.border).padding(.leading, 58) }

    // Sentence-case section header (not an uppercase "eyebrow" — the slop gate forbids those).
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AuraTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

`HomeRows.swift`: move the `private struct RecentRow` verbatim from `PlanView.swift` (make it `struct RecentRow` file-scoped in `HomeRows.swift`).

- [ ] **Step 2: Build to verify + commit** (PlanView still the RootView root; HomeView unreferenced but compiling). Delegate a build. Expected: BUILD SUCCEEDED.

```bash
git add Aura/Sources/Home/HomeView.swift Aura/Sources/Home/HomeRows.swift
git commit -m "feat(home): assemble HomeView container (first-run branch, hoisted state, loading placeholder)"
```

---

## Task 14b: Swap RootView to HomeView + UI tests

**Files:**
- Modify: `Aura/Sources/AuraApp.swift` — Ride-tab root `PlanView()` → `HomeView()`.
- Test: `Aura/UITests/HomeUITests.swift` (add `test_ctaShowsWhereToAndExplore` and `test_glanceVisibleAtPeek`).

- [ ] **Step 1: Write the failing UI tests** (append to `HomeUITests.swift`)

```swift
    func test_ctaShowsWhereToAndExplore_notFreeRide() {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["home.whereTo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Explore"].exists)
        XCTAssertFalse(app.buttons["Free ride"].exists)
    }

    func test_glanceVisibleAtPeek() {
        let app = launchedApp()
        // The motivation hook renders with no gesture — visible at the peek detent.
        XCTAssertTrue(app.staticTexts["home.glance"].waitForExistence(timeout: 5))
    }
```

- [ ] **Step 2: Run to verify they fail** — delegate. Expected: FAIL (RootView still shows PlanView).
- [ ] **Step 3: Swap RootView** — in `Aura/Sources/AuraApp.swift`, change the Ride-tab `NavigationStack` root from `PlanView()` to `HomeView()`. Leave `PlanView.swift` on disk for now.
- [ ] **Step 4: Run tests + package tests + build** — delegate: the three `HomeUITests`, the AuraKit/AuraCore package tests, and a build. Expected: all PASS, BUILD SUCCEEDED.
- [ ] **Step 5: Verify the syncRevision refetch** — on device or via a targeted test: with the sheet at peek, a `rideStore.syncRevision` bump refreshes the glance + last-ride (the `.onChange` is on the container). Confirm by reading `HomeView` that `.task`/`.onChange` are on the outer `Group`, not a subview.
- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/AuraApp.swift Aura/UITests/HomeUITests.swift
git commit -m "feat(home): make HomeView the Ride-tab root; Home UI tests (rename, glance-at-peek, search)"
```

---

## Task 14c: Retire PlanView

**Files:** Delete `Aura/Sources/Plan/PlanView.swift`. Confirm `SavedPlaceRow`, `WeeklyRing`, `LastRideCard`, `DestinationSearchView` live in their own files (they do) and still compile; `RecentRow` now lives in `HomeRows.swift`.

- [ ] **Step 1: Delete + build** — `git rm Aura/Sources/Plan/PlanView.swift`; delegate a build + the full UI suite. Expected: BUILD SUCCEEDED, tests green (nothing references `PlanView`).
- [ ] **Step 2: Commit**

```bash
git rm Aura/Sources/Plan/PlanView.swift
git commit -m "refactor(home): retire PlanView (superseded by HomeView)"
```

---

## Task 15: Accessibility, motion, loading polish

Close the spec's accessibility matrix and motion language on the assembled Home.

**Files:** Modify the `Aura/Sources/Home/*` views. Test: `Aura/UITests/HomeUITests.swift` (AX5 detent smoke test).

- [ ] **Step 1: VoiceOver order** — confirm traversal: primary "Where to?" (sortPriority 3) → glance (add sortPriority 2 in `WeeklyGlanceView`) → secondaries (1) → backdrop (ignored). Verify the backdrop reads as one element.
- [ ] **Step 2: Dynamic Type AX5** — add a UI test launching with `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge` + `-auraDidCompleteOnboarding YES`; at peek and large detents assert `home.whereTo` and `home.glance` are hittable and unclipped. The `peekHeight` is already `@ScaledMetric`; raise its base or let the peek content scroll if AX5 clips.
- [ ] **Step 3: Reduce Transparency / Increase Contrast** — the launch band + sheet already sit on opaque `AuraTheme.surface`; ensure `LastRideCard`'s foreshadow drops to plain surface (Task 10) and scrims strengthen (Task 5). Route any translucency through `AuraTheme.prefersOpaqueSurface(reduceTransparency:_:)`.
- [ ] **Step 4: Reduce Motion** — confirm zero residual drift: backdrop settle skipped, glance ring instant, system sheet handles its own motion. Add a staggered content reveal on first appear, disabled under Reduce Motion.
- [ ] **Step 5: Loading** — verify the glance shows a real sentence and the last-ride slot shows the quiet placeholder (Task 14a `!didLoad`) rather than a spinner or empty-state flash before the first `loadRides()`.
- [ ] **Step 6: Run the AX5 test + build + commit**

```bash
git add Aura/Sources/Home Aura/UITests/HomeUITests.swift
git commit -m "feat(home): a11y matrix (VoiceOver order, AX5, RT/RM) + staggered reveal + loading placeholders"
```

---

## Verification & acceptance (run before finishing the branch)

The finishing gates from both specs. In order:

1. **CI-equivalent green** (delegate to the builder): AuraCore + AuraKit package tests pass; the app builds for the simulator; SwiftLint strict clean; `bash scripts/check-explore-rename.sh` passes; the `HomeUITests` pass.
2. **`impeccable`-judgment critique pass** on the assembled Home (native judgment; its taste applies even though `impeccable`'s web tooling is optional for native).
3. **`emil-design-eng` motion review** of the settle, sheet detents, glance fill, staggered reveal; `review-animations` if a second pass is needed.
4. **Device-first verification** on the real iPhone through the tunnel, in real light:
   - Terrain legible + primary findable in under one second, in sunlight.
   - Search expand/collapse, both secondaries, and the three sheet detents work; scroll-vs-drag clean.
   - The glance renders with no gesture at peek; peek also shows the last-ride card.
   - `syncRevision` refetch updates glance + last-ride at peek.
   - Dynamic Type AX5 at each detent; VoiceOver order; Reduce Motion static; Reduce Transparency opaque.
   - First-run composition (its own screenshot); returning-user-no-permission shows the populated layout with the curated default.
   - **ROH-6 gate:** the real styled terrain (once `TerrainStyle.customStyleURI` is set), not the dark fallback.
   - **Signature thread:** the last-ride card reads as terrain-flavored / foreshadows the medal.
   - **Slop test:** no hero-metric template, no decorative-only glass, no card grid, no eyebrows.
5. **Whole-branch review on the most capable model** before merge.

---

## Self-review (spec-coverage, post-R1)

- Backdrop = rendered image, not live map → Tasks 4–5; ROH-7 constraint. ✅
- One dominant "Where to?", demoted Explore/Join in ONE band → Task 12 `HomeLaunchBand`. ✅ (fixed R1-product-#1)
- Motivation always visible + peek shows last-ride card → Tasks 9, 11, 14a peek. ✅ (fixed R1-product-#2)
- Hook = distance-to-goal + last-ride fallback, exact-string tested → Task 7. ✅ (PO decision)
- Detented sheet via system detents (scroll-vs-drag safe) → Task 11. ✅ (fixed R1-eng-#8)
- Search overlay expand/collapse, focus wired, a11y id → Task 12. ✅ (fixed R1-eng-#6)
- State ownership intact (`.task`/`.onChange(syncRevision)` on container) → Task 14a/14b. ✅
- Explore rename, robust CI-wired grep, History empty-state, frozen ids → Task 6. ✅ (fixed R1-#5/#7/#9/#10)
- First-run its own composition, one primary, pure predicate + onboarding flag → Tasks 8, 13, 14a. ✅ (fixed R1-product-#5/#6)
- States: no-permission (curated default via HomeMode.populated), searching, loading (didLoad placeholder) → Tasks 2, 8, 12, 14a. ✅ (fixed R1-product-#9)
- Signature-moment thread (subtle foreshadow) → Task 10. ✅ (fixed R1-product-#7; PO decision)
- Cache key deterministic + literal-pinned; disk cache round-trip tested; Snapshotter retained → Tasks 2–4. ✅ (fixed R1-eng-#1/#2)
- Motion + Reduce Motion static; a11y matrix; sentence-case headers → Tasks 5, 15. ✅ (fixed R1-product-#11/#12)
- Open question #1 (glance ring form) → compact 36 pt ring beside the sentence (Task 9). Open question #2 (cache invalidation) → 0.01° grid + size bucket (Task 2). ✅

---

## Task-runner note

Delegate all builds, package tests, and UI tests to the **`apple-platform-build-tools:builder`** agent (it absorbs verbose logs, returns pass/fail + the error). Do not run `xcodebuild`/`swift test` inline. Simulator is iPhone 17. Copy the gitignored `pk` token file into this worktree's `Aura/Resources/MapboxAccessToken` before an app build (see the aura-build-and-gaps memory).
