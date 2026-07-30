# ROH-126 Shareable Ride Card Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the shareable post-ride PNG so the route sits on a real map raster (rider's map style) with nothing covering the map, distance and stats in a readout band below, and a polyline fallback that ships instantly and upgrades in place.

**Architecture:** Pure, package-tested kernels in AuraKit (layout budget, route hygiene, camera validation, raster acceptance, cache key, path building) + an app-target `ShareMapSnapshotter` behind a `ShareMapRasterProviding` seam (single app-lifetime instance, single-flight), a redesigned `ShareCardView`, and a fallback-first upgrade-in-place flow in `RideSummaryView`.

**Tech Stack:** SwiftUI, MapboxMaps v11 `Snapshotter` (`load(mapStyle:)`, capture-only overlay), CoreGraphics, SwiftPM tests (`swift test --no-parallel`), XcodeGen.

**The spec is normative:** `docs/superpowers/specs/2026-07-29-roh126-share-card-redesign-design.md` (revision 4). Every task below implements a spec section; when in doubt, the spec wins. Read it before starting any task.

**Build/test commands used throughout:**
- Package suite: `cd AuraCore && swift test --no-parallel` (filter: `swift test --no-parallel --filter <TestClass>`)
- App build: `cd Aura && xcodegen generate && xcodebuild build -project Aura.xcodeproj -scheme Aura -configuration Debug -destination "id=$UDID" -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -quiet` (DerivedData is pre-warmed; `UDID` = booted iPhone 17 simulator)
- Lint: `scripts/lint.sh`

---

## File structure

**AuraKit (new, all package-tested):**
| File | Responsibility |
|---|---|
| `AuraCore/Sources/AuraKit/Sharing/ShareCardLayout.swift` | Card constants: field sizes, paddings, gaps, font point sizes, chrome strip; budget rows |
| `AuraCore/Sources/AuraKit/Sharing/ShareRouteGeometry.swift` | Coordinate hygiene, decimation (bbox-extremal preserving), route content hash |
| `AuraCore/Sources/AuraKit/Sharing/ShareCameraValidation.swift` | Camera predicate over primitives + zoom clamp |
| `AuraCore/Sources/AuraKit/Sharing/ShareRasterAcceptance.swift` | Interior-variance acceptance over `[UInt8]` with chrome-strip exclusion |
| `AuraCore/Sources/AuraKit/Sharing/ShareMapRequest.swift` | Request value + FNV-1a cache key |
| `AuraCore/Sources/AuraKit/Sharing/ShareRoutePath.swift` | CGPath runs from captured `[[CGPoint]]` |

**App target:**
| File | Responsibility |
|---|---|
| `Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift` (create) | Protocol + `@Observable` provider box for environment injection |
| `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift` (create) | Single-flight coordinator + snapshot pipeline + request handle |
| `Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift` (create) | tmp/ShareCard directory layout, writes, sweep |
| `Aura/Sources/Ride/ShareCard/ShareCardView.swift` (modify) | Redesigned card, three variants |
| `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift` (modify) | `make(content:mapImage:)`, title, per-presentation files, off-main write |
| `Aura/Sources/Ride/RideSummaryView.swift` (modify) | Fallback-first flow, upgrade swap, in-flight hint |
| `Aura/Sources/Theme/StatPair.swift` (modify) | Optional `labelColor` |
| `Aura/Sources/AuraApp.swift` (modify) | Create + inject the app-lifetime provider box |
| `Aura/Sources/Ride/RideHUDView.swift`, `Aura/Sources/Ride/NavigateHUDView.swift` (modify) | Ride-end prefetch |

Environment injection: `ShareMapProviderBox` is `@Observable @MainActor`, injected once at the `WindowGroup` root (`.environment(...)`), read via `@Environment(ShareMapProviderBox.self)` — sheets and pushes inherit it, and a missing injection crashes loudly (no silent bypass; spec §provider). Previews inject a stub box.

---

### Task 1: `ShareCardLayout` + CoreText-measured budget test

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareCardLayout.swift`
- Create: `AuraCore/Tests/AuraKitTests/ShareCardLayoutTests.swift`
- Copy font: `Aura/Resources/Fonts/SairaCondensed-Bold.ttf` and `SairaCondensed-SemiBold.ttf` → `AuraCore/Tests/AuraKitTests/Resources/`
- Modify: `AuraCore/Package.swift` (add `.copy` for the two TTFs to the AuraKitTests resources)

- [ ] **Step 1: Write the failing test.** The test registers the bundled TTF via CoreText and measures real line boxes (spec §Layout: "an actual measurement, not arithmetic over the spec's own constants"):

```swift
import XCTest
import CoreText
@testable import AuraKit

final class ShareCardLayoutTests: XCTestCase {
    private func lineBox(fontResource: String, size: CGFloat) throws -> CGFloat {
        let url = try XCTUnwrap(Bundle.module.url(forResource: fontResource, withExtension: "ttf"))
        let desc = try XCTUnwrap((CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first)
        let font = CTFontCreateWithFontDescriptor(desc, size, nil)
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    func testGeometryInvariants() {
        XCTAssertEqual(ShareCardLayout.cardSize, CGSize(width: 360, height: 450))
        XCTAssertEqual(ShareCardLayout.mapFieldSize, CGSize(width: 360, height: 240))
        XCTAssertEqual(ShareCardLayout.mapFieldSize.height + ShareCardLayout.bandHeight,
                       ShareCardLayout.cardSize.height)
        XCTAssertGreaterThanOrEqual(ShareCardLayout.mapChromeStripHeight, 36) // spec step 6
    }

    func testBandBudgetFitsWithMeasuredSairaLineBoxes() throws {
        let hero = try lineBox(fontResource: "SairaCondensed-Bold", size: ShareCardLayout.heroPointSize)
        let stats = try lineBox(fontResource: "SairaCondensed-SemiBold", size: ShareCardLayout.statsValuePointSize)
        // Context row is SF (system); its measured box is ~14.3 at caption/large. Use a
        // conservative 15 rather than shipping an SF copy into test resources.
        let contextCeiling: CGFloat = 15
        let total = contextCeiling + ShareCardLayout.gapXS + hero + ShareCardLayout.gapSM
            + ShareCardLayout.sparklineHeight + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(total, ShareCardLayout.bandContentHeight,
            "band content \(total) exceeds \(ShareCardLayout.bandContentHeight)")
        // Belt: the Saira ratio the spec quotes. If the font file changes, this moves.
        XCTAssertEqual(hero / ShareCardLayout.heroPointSize, 1.574, accuracy: 0.01)
    }

    func testNoElevationVariantFits() throws {
        let hero = try lineBox(fontResource: "SairaCondensed-Bold", size: ShareCardLayout.heroPointSize)
        let stats = try lineBox(fontResource: "SairaCondensed-SemiBold", size: ShareCardLayout.statsValuePointSize)
        let total = 15 + ShareCardLayout.gapXS + hero + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(total, ShareCardLayout.bandContentHeight)
    }
}
```

- [ ] **Step 2: Run to verify failure.** `cd AuraCore && swift test --no-parallel --filter ShareCardLayoutTests` → FAIL (type doesn't exist). If the TTF copy step was missed the test fails on `XCTUnwrap` — do the copy + `Package.swift` edit first; that's setup, not implementation.

- [ ] **Step 3: Implement.**

```swift
// AuraCore/Sources/AuraKit/Sharing/ShareCardLayout.swift
import Foundation

/// The shareable ride card's fixed geometry (spec ROH-126 rev 4, §Layout). These are
/// card-local constants, deliberately not the app theme's spacing tokens: the card is a
/// fixed 360×450 pt PNG that pins its own numbers, and this package cannot see
/// `AuraTheme`. The package test measures the composed budget against the bundled
/// Saira TTFs so the numbers stay honest.
public enum ShareCardLayout {
    public static let cardSize = CGSize(width: 360, height: 450)
    public static let mapFieldSize = CGSize(width: 360, height: 240)
    public static let rasterScale: CGFloat = 3

    public static let bandHeight: CGFloat = 210
    public static let bandHorizontalPadding: CGFloat = 20
    public static let bandTopPadding: CGFloat = 12
    public static let bandBottomPadding: CGFloat = 16
    public static var bandContentHeight: CGFloat { bandHeight - bandTopPadding - bandBottomPadding }

    public static let gapXS: CGFloat = 4
    public static let gapSM: CGFloat = 8

    public static let heroPointSize: CGFloat = 48
    public static let heroUnitPointSize: CGFloat = 18
    public static let statsValuePointSize: CGFloat = 17
    public static let statsLabelPointSize: CGFloat = 13
    public static let wordmarkPointSize: CGFloat = 16
    public static let sparklineHeight: CGFloat = 40

    /// Route stroke on the raster: dark casing under mint (spec §Route drawing).
    public static let routeCasingWidth: CGFloat = 8
    public static let routeStrokeWidth: CGFloat = 5

    /// Bottom strip of the snapshot excluded from acceptance sampling — covers the SDK's
    /// logo (margin 10 + height 21) and attribution chip with slack (spec step 6).
    public static let mapChromeStripHeight: CGFloat = 36
    /// Camera fit padding; bottom is larger so no stroked pixel (5 pt mint + 8 pt casing
    /// half-width) can enter the chrome band (spec step 4).
    public static let cameraPaddingTop: CGFloat = 24
    public static let cameraPaddingSides: CGFloat = 24
    public static let cameraPaddingBottom: CGFloat = 40
}
```

- [ ] **Step 4: Run to verify pass.** `swift test --no-parallel --filter ShareCardLayoutTests` → PASS.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(roh-126): ShareCardLayout constants with CoreText-measured budget test"`

---

### Task 2: `ShareRouteGeometry` — hygiene, decimation, route hash

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareRouteGeometry.swift`
- Create: `AuraCore/Tests/AuraKitTests/ShareRouteGeometryTests.swift`

- [ ] **Step 1: Failing tests.** Cover (spec step 1): non-finite coords dropped; `< 2` distinct coords → nil; span below epsilon (stationary) → nil; decimation caps points per segment at 600 **and keeps each segment's min/max lat and lon points**; pause gaps preserved (segments never merged); hash stable across runs and sensitive to coordinate changes.

```swift
import XCTest
import AuraCore
@testable import AuraKit

final class ShareRouteGeometryTests: XCTestCase {
    private func line(_ n: Int, lat0: Double = 40.44, lon0: Double = -79.99) -> [Coordinate] {
        (0..<n).map { Coordinate(latitude: lat0 + Double($0) * 0.0005, longitude: lon0 + Double($0) * 0.0006) }
    }

    func testRejectsDegenerateInput() {
        XCTAssertNil(ShareRouteGeometry.prepare(segments: []))
        XCTAssertNil(ShareRouteGeometry.prepare(segments: [[Coordinate(latitude: 40, longitude: -79)]]))
        let stationary = Array(repeating: Coordinate(latitude: 40, longitude: -79), count: 50)
        XCTAssertNil(ShareRouteGeometry.prepare(segments: [stationary]))
    }

    func testDropsNonFiniteAndKeepsRest() {
        var pts = line(20)
        pts.insert(Coordinate(latitude: .nan, longitude: -79.99), at: 5)
        let prepared = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        XCTAssertEqual(prepared.segments[0].count, 20)
        XCTAssertTrue(prepared.segments.allSatisfy { $0.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite } })
    }

    func testDecimationCapsAndKeepsExtremes() {
        let pts = line(5000)
        let prepared = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        XCTAssertLessThanOrEqual(prepared.segments[0].count, ShareRouteGeometry.maxPointsPerSegment)
        let lats = prepared.segments[0].map(\.latitude), lons = prepared.segments[0].map(\.longitude)
        XCTAssertEqual(lats.min(), pts.map(\.latitude).min())
        XCTAssertEqual(lats.max(), pts.map(\.latitude).max())
        XCTAssertEqual(lons.min(), pts.map(\.longitude).min())
        XCTAssertEqual(lons.max(), pts.map(\.longitude).max())
    }

    func testSegmentsStaySeparate() {
        let prepared = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(30), line(30, lat0: 40.5)]))
        XCTAssertEqual(prepared.segments.count, 2)
    }

    func testContentHashStableAndSensitive() {
        let a = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100)]))
        let b = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100)]))
        XCTAssertEqual(a.contentHash, b.contentHash)
        let c = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100, lat0: 40.45)]))
        XCTAssertNotEqual(a.contentHash, c.contentHash)
    }
}
```

- [ ] **Step 2: Verify FAIL.** `swift test --no-parallel --filter ShareRouteGeometryTests`
- [ ] **Step 3: Implement.**

```swift
// AuraCore/Sources/AuraKit/Sharing/ShareRouteGeometry.swift
import Foundation
import AuraCore

/// Input hygiene for the share-card map snapshot (spec ROH-126 rev 4, step 1). This is
/// the real guard for `Snapshotter.camera(for:)`, which is exception-unsafe on
/// degenerate input — garbage must never reach it.
public enum ShareRouteGeometry {
    public static let maxPointsPerSegment = 600
    /// Minimum bounding span (degrees) below which a "route" is treated as stationary.
    public static let minimumSpanDegrees = 0.0002   // ~22 m

    public struct Prepared: Equatable, Sendable {
        public let segments: [[Coordinate]]
        /// FNV-1a over quantized coordinates — the route's content identity for the
        /// cache key (ride rows are upserted/backfilled/merged, so the id alone is not
        /// a route identity; spec step 2).
        public let contentHash: UInt32
    }

    public static func prepare(segments: [[Coordinate]]) -> Prepared? {
        let clean = segments
            .map { $0.filter { $0.latitude.isFinite && $0.longitude.isFinite } }
            .filter { $0.count > 1 }
        let all = clean.flatMap { $0 }
        guard all.count >= 2 else { return nil }
        guard Set(all.map { "\($0.latitude),\($0.longitude)" }).count >= 2 else { return nil }
        let lats = all.map(\.latitude), lons = all.map(\.longitude)
        guard (lats.max()! - lats.min!()) > minimumSpanDegrees
                || (lons.max()! - lons.min!()) > minimumSpanDegrees else { return nil }
        let decimated = clean.map(decimate)
        return Prepared(segments: decimated, contentHash: contentHash(of: decimated))
    }

    /// Stride decimation that force-includes the segment's bbox-extremal points so the
    /// camera fit can't drift from the full track (spec step 1).
    private static func decimate(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > maxPointsPerSegment else { return points }
        var keep = Set<Int>()
        let stride = Double(points.count - 1) / Double(maxPointsPerSegment - 1)
        for i in 0..<maxPointsPerSegment { keep.insert(Int((Double(i) * stride).rounded())) }
        for key in [\Coordinate.latitude, \Coordinate.longitude] {
            keep.insert(points.indices.min { points[$0][keyPath: key] < points[$1][keyPath: key] }!)
            keep.insert(points.indices.max { points[$0][keyPath: key] < points[$1][keyPath: key] }!)
        }
        return keep.sorted().map { points[$0] }
    }

    private static func contentHash(of segments: [[Coordinate]]) -> UInt32 {
        var s = ""
        for seg in segments {
            for c in seg {
                s += "\(Int((c.latitude * 1e5).rounded())),\(Int((c.longitude * 1e5).rounded()));"
            }
            s += "|"
        }
        return TerrainSnapshotRequest.fnv1a(s)
    }
}
```

Note: `TerrainSnapshotRequest.fnv1a` is `internal` today — widen it to `public static` (it is deterministic-by-design; add one doc line). Fix the two force-unwraps' syntax (`lats.max()!` etc.) properly when implementing.

- [ ] **Step 4: Verify PASS**, then run the full package suite once (`swift test --no-parallel`) to confirm no regression from the `fnv1a` access change.
- [ ] **Step 5: Commit.**

---

### Task 3: `ShareCameraValidation`

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareCameraValidation.swift`
- Create: `AuraCore/Tests/AuraKitTests/ShareCameraValidationTests.swift`

- [ ] **Step 1: Failing tests.** The predicate takes primitives (`CameraOptions` is a MapboxMaps type the package can't see; the degenerate SDK path returns nil or NaN — spec step 4):

```swift
final class ShareCameraValidationTests: XCTestCase {
    func testRejectsMissingOrNonFinite() {
        XCTAssertNil(ShareCameraValidation.validated(latitude: nil, longitude: -79, zoom: 12))
        XCTAssertNil(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: nil))
        XCTAssertNil(ShareCameraValidation.validated(latitude: .nan, longitude: -79, zoom: 12))
        XCTAssertNil(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: .infinity))
    }
    func testClampsZoom() {
        XCTAssertEqual(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: 18)?.zoom, 16)
        XCTAssertEqual(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: 12)?.zoom, 12)
    }
}
```

- [ ] **Step 2: FAIL** → **Step 3: Implement** (guard `isFinite` first, then `min(zoom, 16)` — the guard-then-clamp order matters because `min` propagates NaN order-dependently; return a small `(latitude, longitude, zoom)` struct) → **Step 4: PASS** → **Step 5: Commit.**

---

### Task 4: `ShareRasterAcceptance` — interior variance

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareRasterAcceptance.swift`
- Create: `AuraCore/Tests/AuraKitTests/ShareRasterAcceptanceTests.swift`

- [ ] **Step 1: Failing tests.** Pure function over a grayscale `[UInt8]` buffer with width/height and an excluded bottom strip (in buffer rows). Fixtures built in-test: flat buffer → reject; flat buffer with bright "chrome" rows *inside the excluded strip* → still reject (the strip exclusion is the point); buffer with map-like texture (pseudo-random noise from a seeded generator, spread across the interior) → accept; texture only in one quadrant (partial tiles) → reject (spec step 6 backstop). Threshold is a named constant so tuning during device verification is a one-line change.

- [ ] **Step 2: FAIL** → **Step 3: Implement:**

```swift
// AuraCore/Sources/AuraKit/Sharing/ShareRasterAcceptance.swift
import Foundation

/// Acceptance test for a share-card map raster (spec ROH-126 rev 4, step 6): the map
/// demonstrably rendered content, judged only on pixels we did not draw — the caller
/// samples the bare snapshot (route not yet composited) and this excludes the bottom
/// chrome strip (SDK logo + attribution).
public enum ShareRasterAcceptance {
    /// Minimum per-cell luma standard deviation, and minimum fraction of grid cells
    /// that must individually show texture (rejects single-quadrant partial renders).
    public static var varianceThreshold: Double = 4.0
    public static var texturedCellFraction: Double = 0.5
    public static let gridSide = 4

    public static func accepts(gray: [UInt8], width: Int, height: Int, excludedBottomRows: Int) -> Bool {
        let usableHeight = height - excludedBottomRows
        guard width >= gridSide, usableHeight >= gridSide, gray.count == width * height else { return false }
        var textured = 0
        let cellW = width / gridSide, cellH = usableHeight / gridSide
        for cy in 0..<gridSide {
            for cx in 0..<gridSide {
                var sum = 0.0, sumSq = 0.0, n = 0.0
                for y in (cy * cellH)..<((cy + 1) * cellH) {
                    for x in (cx * cellW)..<((cx + 1) * cellW) {
                        let v = Double(gray[y * width + x]); sum += v; sumSq += v * v; n += 1
                    }
                }
                let mean = sum / n
                if (sumSq / n - mean * mean).squareRoot() >= varianceThreshold { textured += 1 }
            }
        }
        return Double(textured) >= texturedCellFraction * Double(gridSide * gridSide)
    }
}
```

- [ ] **Step 4: PASS** → **Step 5: Commit.**

---

### Task 5: `ShareMapRequest` — identity + cache key

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareMapRequest.swift`
- Create: `AuraCore/Tests/AuraKitTests/ShareMapRequestTests.swift`

- [ ] **Step 1: Failing tests.** Key is FNV-1a-hashed and filename-safe (no `/` or `:` — raw StyleURIs would silently break `TerrainSnapshotDiskCache`'s key-as-filename writes); differs across style, route hash, and composite version; stable across construction; style identity derives from the `AuraKit.MapStyle` case (`TerrainStyle.authoredStyleIdentity` for `.auraTerrain`, stable slugs `style-dark` / `style-standard` otherwise).

- [ ] **Step 2: FAIL** → **Step 3: Implement:**

```swift
// AuraCore/Sources/AuraKit/Sharing/ShareMapRequest.swift
import Foundation
import AuraCore

/// Everything the share-map pipeline needs, resolved in the pure layer (spec §provider).
public struct ShareMapRequest: Equatable, Sendable {
    /// Bump when the composited route treatment changes (casing/mint widths, colors) —
    /// the cache stores the *composited* image, so styling changes must invalidate it.
    public static let compositeVersion = 1

    public let rideID: UUID
    public let route: ShareRouteGeometry.Prepared
    public let style: MapStyle
    public let size: CGSize
    public let scale: CGFloat
    public let cacheKey: String

    public init?(rideID: UUID, segments: [[Coordinate]], style: MapStyle,
                 size: CGSize = ShareCardLayout.mapFieldSize,
                 scale: CGFloat = ShareCardLayout.rasterScale) {
        guard let prepared = ShareRouteGeometry.prepare(segments: segments) else { return nil }
        self.rideID = rideID
        self.route = prepared
        self.style = style
        self.size = size
        self.scale = scale
        let styleIdentity: String = switch style {
        case .auraTerrain: TerrainStyle.authoredStyleIdentity
        case .dark: "style-dark"
        case .standard: "style-standard"
        }
        let composed = "\(rideID.uuidString)|r\(prepared.contentHash)|\(styleIdentity)|v\(Self.compositeVersion)|\(Int(size.width))x\(Int(size.height))@\(Int(scale))"
        self.cacheKey = "sharemap-\(TerrainSnapshotRequest.fnv1a(composed))"
    }
}
```

(Verify `TerrainStyle.authoredStyleIdentity` exists in AuraKit — Home uses it; if it lives elsewhere, mirror the constant's accessor, do not duplicate the string.)

- [ ] **Step 4: PASS** → **Step 5: Commit.**

---

### Task 6: `ShareRoutePath` — path building from captured points

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareRoutePath.swift`
- Create: `AuraCore/Tests/AuraKitTests/ShareRoutePathTests.swift`

- [ ] **Step 1: Failing tests.** Builds one `CGPath` containing a subpath per run; runs with `< 2` points dropped; no connection across runs (test via `path.contains` on a midpoint between segment ends, or by counting `moveToPoint` elements via `applyWithBlock`).
- [ ] **Step 2: FAIL** → **Step 3: Implement** (`public static func path(runs: [[CGPoint]]) -> CGPath?` — CoreGraphics is available to the package on Apple platforms) → **Step 4: PASS** → **Step 5: Commit.**

---

### Task 7: `StatPair` label color + card contrast

**Files:**
- Modify: `Aura/Sources/Theme/StatPair.swift`

- [ ] **Step 1:** Add `var labelColor: Color? = nil`; label uses `labelColor ?? AuraTheme.textSecondary`. No behavior change for existing callers.
- [ ] **Step 2:** Build the app target (command above) → succeeds.
- [ ] **Step 3: Commit.**

---

### Task 8: `ShareCardView` redesign

**Files:**
- Modify: `Aura/Sources/Ride/ShareCard/ShareCardView.swift` (full rewrite of layout; keep `ShareCardContent` untouched)

- [ ] **Step 1: Implement per spec §Layout.** Key shape (fill in the straightforward parts; every number comes from `ShareCardLayout` — no literals):

```swift
struct ShareCardView: View {
    let content: ShareCardContent
    let mapImage: UIImage?          // accepted, composited raster — or nil for fallback

    private let scrimText = Color(white: AuraPalette.textSecondaryWhiteHighContrast)
    private var hasRoute: Bool { !content.routeSegments.isEmpty }

    var body: some View {
        Group {
            if hasRoute {
                VStack(spacing: 0) { mapField; readoutBand }
            } else { noRouteBody }   // unchanged composition; StatPair(labelColor: scrimText)
        }
        .frame(width: ShareCardLayout.cardSize.width, height: ShareCardLayout.cardSize.height)
        .background(AuraTheme.background)
    }

    @ViewBuilder private var mapField: some View {
        if let mapImage {
            Image(uiImage: mapImage).resizable()
                .frame(width: ShareCardLayout.mapFieldSize.width,
                       height: ShareCardLayout.mapFieldSize.height)
                .clipped()
        } else {
            RouteThumbnail(segments: content.routeSegments,
                           lineColor: AuraTheme.routeLine, lineWidth: 3)
                .padding(16)
                .frame(width: ShareCardLayout.mapFieldSize.width,
                       height: ShareCardLayout.mapFieldSize.height)
        }
    }

    private var readoutBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextLine                                    // caption rounded semibold, tracked,
                                                           // .lineLimit(1), scrimText
            Spacer().frame(height: ShareCardLayout.gapXS)
            heroRow                                        // speedHero(48) + unit metricCockpit(18)
            Spacer().frame(height: ShareCardLayout.gapSM)
            if !content.elevationSamples.isEmpty {
                ElevationSparkline(elevations: content.elevationSamples,
                                   stroke: AuraTheme.accent,
                                   fill: AuraTheme.accent.opacity(0.18), lineWidth: 2)
                    .frame(height: ShareCardLayout.sparklineHeight)
                Spacer().frame(height: ShareCardLayout.gapSM)
            } else {
                Spacer(minLength: 0)                       // keeps stats row bottom-anchored
            }
            statsRow
        }
        .padding(.horizontal, ShareCardLayout.bandHorizontalPadding)
        .padding(.top, ShareCardLayout.bandTopPadding)
        .padding(.bottom, ShareCardLayout.bandBottomPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Saira numerals + rounded labels (cockpit-numeral rule), wordmark trailing.
    private var statsRow: some View {
        HStack(alignment: .firstTextBaseline) {
            (statText(content.movingTime) + labelText(" min moving".uppercased())
             + labelText("  ·  ")
             + statText(content.climbedValue) + labelText(" \(content.climbedUnit) climbed".uppercased()))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: ShareCardLayout.gapSM)
            Text("AURA")
                .font(AuraTheme.Typography.metricCockpit(ShareCardLayout.wordmarkPointSize,
                                                         face: .semibold, relativeTo: .callout))
                .tracking(4)
                .foregroundStyle(AuraTheme.textPrimary)
                .fixedSize()
                .layoutPriority(1)
        }
    }
    private func statText(_ s: String) -> Text {
        Text(s).font(AuraTheme.Typography.metricCockpit(ShareCardLayout.statsValuePointSize,
                                                        face: .semibold, relativeTo: .body))
            .foregroundStyle(AuraTheme.textPrimary)
    }
    private func labelText(_ s: String) -> Text {
        Text(s).font(.system(size: ShareCardLayout.statsLabelPointSize,
                             design: .rounded).weight(.semibold))
            .foregroundStyle(scrimText)
    }
}
```

Careful notes for the implementer:
- `content.movingTime` is already formatted like "42" + the label carries "min moving" — check `RideStatsFormatter.minutes` output ("42" vs "42 min") and adjust the label strings so nothing doubles.
- Keep the no-route variant's structure; only pass `labelColor: scrimText` to its `StatPair`s.
- **Previews** (spec §Testing): map variant with a fixture image (`UIGraphicsImageRenderer` gradient at exactly 360×240 @3x, built inline in the preview), polyline fallback, no-route, route-without-elevation, long destination, worst-case stats string (`480` min / `12000 ft`), metric + imperial.

- [ ] **Step 2:** Build; open previews if running interactively, otherwise proceed (device verification is Task 14).
- [ ] **Step 3: Commit.**

---

### Task 9: `ShareCardFileStore` + `RideCardRenderer` changes

**Files:**
- Create: `Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift`
- Modify: `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift`
- Modify call site in `Aura/Sources/Ride/RideSummaryView.swift` compiles in Task 11.

- [ ] **Step 1: Implement the file store** (spec §Files):

```swift
// Directory scheme: tmp/ShareCard/<rideID>/<presentationUUID>/<generation>/Aura ride.png
// Leaf name stays clean (user-visible in share targets); uniqueness via directories;
// per-presentation UUID so a second presentation never overwrites a file a lazy
// consumer of the first presentation's URL may still read.
@MainActor struct ShareCardFileStore {
    let rideID: UUID
    let presentationID = UUID()
    private static var root: URL { FileManager.default.temporaryDirectory.appending(path: "ShareCard") }

    func url(generation: Int) -> URL {
        Self.root.appending(path: rideID.uuidString)
            .appending(path: presentationID.uuidString)
            .appending(path: String(generation))
            .appending(path: "Aura ride.png")
    }

    /// Sweep on summary entry only: other rides' subtrees older than one hour. The
    /// current ride's files are structurally out of reach — that is what makes "an open
    /// share sheet keeps its file" hold. Runs off-main.
    func sweepOtherRides() { /* Task.detached; contentsOfDirectory over Self.root,
        skip rideID.uuidString, remove dirs with modification date > 1h old */ }
}
```

- [ ] **Step 2: Rework `RideCardRenderer`:**
  - Signature: `static func make(_ content: ShareCardContent, mapImage: UIImage?, title: String, writeTo url: URL) async -> RideShareImage?`.
  - `ImageRenderer` stays on the main actor; **create the directory, then `pngData()` + atomic write run off-main** (`Task.detached` and `await` its value — an atomic write into a missing directory throws, and a failed initial write means Share stays disabled, so the directory creation is not optional).
  - `RideShareImage` gains `let title: String`; keep `fileURL` + `preview`.
  - Title composed by the caller: `"Aura ride · \(content.distanceValue) \(content.distanceUnit) · \(content.dateText)"`.
- [ ] **Step 3:** Build (RideSummaryView call site will be red until Task 11 — do Task 9 and 11 in one worktree pass if the executor prefers compiling commits; otherwise adjust the old call minimally to the new signature in this task).
- [ ] **Step 4: Commit.**

---

### Task 10: `ShareMapSnapshotter` — seam, handle, pipeline, single-flight

**Files:**
- Create: `Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift`
- Create: `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift`

This is the riskiest task. Implement exactly the spec's §provider + pipeline steps 1–7; the concurrency shapes below are **normative** (each one closes a reviewed defect):

- [ ] **Step 1: The seam + box:**

```swift
@MainActor protocol ShareMapRasterProviding {
    func raster(for request: ShareMapRequest) async -> UIImage?
}

/// App-lifetime holder injected via .environment — instance identity is load-bearing
/// (in-flight dedup state lives on the provider); a missing injection crashes loudly.
@Observable @MainActor final class ShareMapProviderBox {
    let provider: any ShareMapRasterProviding
    init(provider: any ShareMapRasterProviding) { self.provider = provider }
}
```

- [ ] **Step 2: The request handle** (spec step 5 — owns snapshotter, latch, point buffer):

```swift
/// One snapshot attempt. @MainActor class => implicitly Sendable, so the @Sendable
/// onCancel closure may capture IT (capturing the non-Sendable Snapshotter directly —
/// even inside a nested Task — does not compile under Swift 6 + default MainActor).
@MainActor private final class SnapshotAttempt {
    private(set) var snapshotter: Snapshotter?   // held strongly until the latch resolves
    private let done = OSAllocatedUnfairLock(initialState: false)
    var capturedRuns: [[CGPoint]] = []           // per-request buffer (never coordinator-owned)
    private var resolved = false

    /// Resolve-once: first caller wins; late SDK completions and late timeout arms no-op.
    func finishOnce(_ body: () -> Void) {
        done.withLock { flag in
            guard !flag else { return }
            flag = true
            body()
        }
        snapshotter = nil          // release; a cancel() that never calls back can't leak it
    }
    func cancel() { snapshotter?.cancel() }      // main-actor; called via Task { @MainActor in handle.cancel() }
}
```

- [ ] **Step 3: The coordinator** (spec §single-flight): unstructured pipeline task owned by the provider; callers `await task.value`; caller cancellation abandons only the await; in-flight entry removed in `defer`; at most one pipeline alive (a second key queues behind an `AsyncSemaphore`-style gate or simple `while inFlight != nil { await ... }` loop); the pipeline itself never observes caller cancellation.

- [ ] **Step 4: The pipeline**, in spec order. Critical lines:
  - Cache read first: `if let data = cache.read(request.cacheKey) { return UIImage(data: data, scale: request.scale) }` — the cache holds the **composited** image; no re-composite.
  - `let snapshotter = Snapshotter(options: MapSnapshotOptions(size: request.size, pixelRatio: request.scale, glyphsRasterizationOptions: ...))`.
  - Error observer **before** the load, token cancelled in `defer`; **`.style`/`.source` → mark rejected; `.tile` → log only** (edge tiles 404 routinely; variance is the partial-tile gate).
  - Style: `snapshotter.load(mapStyle: mapboxStyle, transition: nil) { completion in ... }` with its **own** resolve-once latch and 4 s belt (a `MapStyleReconciler` completion can fire synchronously; a double resume is a crash). **Never also touch `styleJSON`/`styleURI`** (a second load parks in `pendingCompletions` and can hang). On belt timeout consult `snapshotter.isStyleLoaded` before rejecting. `mapboxStyle` comes from the existing `MapStyle+Mapbox` extension.
  - Camera **after** style resolves (a style's root center/zoom would override the fit): `snapshotter.camera(for: coords, padding: UIEdgeInsets(top: 24, left: 24, bottom: 40, right: 24), bearing: 0, pitch: 0)` → validate via `ShareCameraValidation` → `snapshotter.setCamera(to:)`.
  - Render: `withTaskCancellationHandler(operation: { await withCheckedContinuation { ... snapshotter.start(overlayHandler: { overlay in handle.capturedRuns = runs(from: overlay) }, completion: { [weak snapshotter] result in handle.finishOnce { ... stash + resume ... } }) ... 6s timeout arm → handle.finishOnce { resume nil } + Task { @MainActor in handle.cancel() } } }, onCancel: { Task { @MainActor in handle.cancel() } })`. Completion body does minimal work under the latch — stash and resume; all main-actor work happens after the `await` (the SDK's compositor callback thread is not guaranteed main when attribution text falls to `.none`).
  - Acceptance: downsample the raster to grayscale `[UInt8]` (CoreGraphics, off-main) → `ShareRasterAcceptance.accepts(..., excludedBottomRows: Int(ShareCardLayout.mapChromeStripHeight * downsampleScale))`.
  - Composite: `UIGraphicsImageRenderer(size: request.size, format: .init(scale: 3))` — draw raster, stroke `ShareRoutePath.path(runs:)` casing 8 pt `AuraPalette.nearBlack` then mint 5 pt, round caps/joins.
  - Cache write (create directory implicit in `TerrainSnapshotDiskCache`; it handles its own dir) + `prune(toMaxBytes: 24 * 1024 * 1024)`; encode + write off-main.
- [ ] **Step 5:** Build the app target → succeeds. (This task's correctness is proven on device in Task 14; the pure kernels it calls are already tested.)
- [ ] **Step 6: Commit.**

---

### Task 11: `RideSummaryView` flow + hint

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift`

- [ ] **Step 1:** Per spec §Share flow:
  - `@Environment(ShareMapProviderBox.self) private var shareMap`
  - `@State private var isUpgrading = false`
  - `.task`: keep the existing `Task.yield()`; `let store = ShareCardFileStore(rideID: ride.id)`; `store.sweepOtherRides()`; render fallback → `shareImage = await RideCardRenderer.make(content, mapImage: nil, title: title, writeTo: store.url(generation: 0))`; then if `ShareMapRequest(rideID:segments:style:)` is non-nil: `isUpgrading = true` (behind a ~300 ms show-delay so a warm cache hit doesn't flash it — implement as `.task` child sleeping 0.3 s before setting a `showHint` bool that also requires `isUpgrading`); History path adds the entrance-animation delay before requesting (ride-end path relies on prefetch having warmed the cache); `if let raster = await shareMap.provider.raster(for: request), !Task.isCancelled, let upgraded = await RideCardRenderer.make(content, mapImage: raster, title: title, writeTo: store.url(generation: 1)) { shareImage = upgraded }`; `isUpgrading = false`.
  - Hint view under the Share button: `if showHint { HStack { ProgressView(); Text("Adding your map…") } .font(.caption) ... }` — hidden for no-route rides (request init returns nil → `isUpgrading` never set).
  - The swap is exactly `if let upgraded` — a failed upgrade keeps the fallback (spec: never nil-out an enabled Share).
- [ ] **Step 2:** Build → succeeds.
- [ ] **Step 3: Commit.**

---

### Task 12: App wiring — provider injection + ride-end prefetch

**Files:**
- Modify: `Aura/Sources/AuraApp.swift` (create `@State private var shareMapBox = ShareMapProviderBox(provider: ShareMapSnapshotter())`; add `.environment(shareMapBox)` at the WindowGroup root next to the existing `.environment` injections)
- Modify: `Aura/Sources/Ride/RideHUDView.swift:200` and `Aura/Sources/Ride/NavigateHUDView.swift:244`

- [ ] **Step 1:** At both `router.showRideSummary(...)` call sites, fire the prefetch **after a transition-settling delay** (spec: the push transition transiently has two live Maps and the SDK compositor is main-thread):

```swift
if let request = ShareMapRequest(rideID: ride.id,
                                 segments: ride.segments.map { $0.points.map(\.coordinate) },
                                 style: settings.mapStyle) {
    let provider = shareMapBox.provider
    Task { try? await Task.sleep(for: .seconds(0.7)); _ = await provider.raster(for: request) }
}
router.showRideSummary(ride, saveFailed: coordinator.saveFailed)
```

(Both HUDs already have `settings` in scope; add `@Environment(ShareMapProviderBox.self)`. The summary's own request dedups onto this via the shared instance.)
- [ ] **Step 2:** Build → succeeds. Run `scripts/lint.sh` → clean.
- [ ] **Step 3: Commit.**

---

### Task 13: Full gate

- [ ] `cd AuraCore && swift test --no-parallel` → all pass.
- [ ] App build (command above) → succeeds, no new warnings in the ShareCard files.
- [ ] `scripts/lint.sh` → clean.
- [ ] Commit anything outstanding.

---

### Task 14: Device/simulator verification (spec §Testing — all items)

Launch on the booted simulator with the golden-ride harness:

```bash
xcrun simctl launch $UDID com.rohunjoseph.aura \
  -auraDidCompleteOnboarding YES -auraSimulatedRide golden \
  -auraSimulatedRideMultiplier 30 -auraInMemoryRideStore
```

(Install first via `xcrun simctl install $UDID <path to Aura.app in DerivedData>`. Drive with the iOS-simulator control tool; ride to completion via Explore → wait ~15 s → End.)

- [ ] Ride-end summary: fallback card exists immediately (pull `$(xcrun simctl get_app_container $UDID com.rohunjoseph.aura data)/tmp/ShareCard/<rideID>/<pres>/0/Aura ride.png`); map card replaces it (generation 1 appears); inspect both full-size and at ~130 pt.
- [ ] Tap Share **before** the upgrade lands; complete a share to Photos and to Messages; confirm the sheet survives the swap (or implement the swap latch contingency).
- [ ] Second open from History → cache hit (no re-render; PNG identical, not zoom-cropped, route not double-stroked).
- [ ] All three styles (`auraTerrain`, `dark`, `standard`) — casing keeps the route legible on `standard`; route never touches the SDK chrome band.
- [ ] Offline (`auraTerrain`): simulator can't do airplane mode — use host NLC "100% Loss" or a device; verify the **polyline fallback** renders, never a blank map.
- [ ] Slow network (NLC "Very Bad Network"): partial raster rejected → fallback.
- [ ] Paused multi-segment ride (`-auraSimulatedRide` paused fixture — see `golden-ride-paused.gpx` / its launch hook): no stroke across the gap.
- [ ] No-route variant renders (a zero-track ride from History or a fixture).
- [ ] Entrance animation drops no frames (prefetch delay working); note time-to-upgrade for the PR.
- [ ] Screenshot the map card, fallback card, and `.standard` card for the PR.

---

### Task 15: Wrap-up

- [ ] Update the stale header comment in `ShareCardView.swift` (the "cannot render offscreen" note) — it now explains the Snapshotter pipeline instead.
- [ ] Whole-branch review (repo pipeline step 6) on the most capable model; fix findings.
- [ ] PR to `main` (humanizer-passed body; include screenshots + time-to-upgrade); link ROH-126.
- [ ] Move ROH-126 to **In Review**, comment with the PR link; Rohun reviews.
