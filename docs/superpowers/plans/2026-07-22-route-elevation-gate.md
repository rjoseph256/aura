# Route-Planning Elevation Gate (ROH-94) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package-level tests that fail if the Terrain-RGB elevation path ever silently goes flat again, by extracting the pure decode/placement/sampling core out of the app target and gating it over a generated fixture tile.

**Architecture:** `TerrainTileID` + `TerrainRGBPlacement` (pure Web Mercator math) go into the Foundation-only `AuraCore` target; `TerrainRGBTile` (hardened CG/ImageIO decode) and `TerrainRGBSampler` (the sampling orchestration, with an injected async tile lookup) go into `AuraKit`. The app's `MapboxTerrainRGBElevationProvider` becomes a thin shell (token guard + URLSession-backed cache) delegating to the extracted core. Tests decode a committed, generated terrain-rgb PNG (synthetic DEM, real Pittsburgh tile coordinates) and run the production sampler end-to-end into `RouteMetrics` + `RouteRanker`.

**Tech Stack:** Swift 6 (SwiftPM package, language mode v6), Swift Testing (`@Test`, `#expect`, `#require`), CoreGraphics/ImageIO (cross-platform iOS/macOS), xcodegen + xcodebuild for the app target.

Spec: `docs/superpowers/specs/2026-07-22-route-elevation-gate-design.md` (read it before starting any task).

## Global Constraints

- Package tests run on macOS CI (`cd AuraCore && swift test --no-parallel`): no network access in any test, no iOS-only API without `#if` guards (CoreGraphics/ImageIO need none).
- Frozen-literal policy: truth literals (pixel elevations, route gains, placement values, tile ID) are recorded once via the `TERRAIN_FIXTURE_RECORD=1` helper (or the independent cross-check commands given below) and pasted as literals. Tests never recompute truth at run time.
- The `AuraCore` *target* stays Foundation-only. CG/ImageIO code goes in `AuraKit` only.
- Public types added to the package need explicit `Sendable` conformance where concurrency requires it (no implicit synthesis for public structs).
- `swiftlint --strict` must stay clean (run from repo root).
- App behavior is unchanged: same provider defaults (spacing 150 m, samples 16–96, zoom 14), same best-effort semantics, same public API.
- Commit after every task (at minimum). Commit messages: `feat(roh-94): …` / `test(roh-94): …` / `refactor(roh-94): …` / `docs(roh-94): …`, each ending with the Claude co-author trailer.
- All package test commands run from the `AuraCore/` directory.

## File Structure

| File | Responsibility |
|---|---|
| `AuraCore/Sources/AuraCore/Routing/TerrainRGBPlacement.swift` (create) | `TerrainTileID`, `Placement`, pure Web Mercator lat/lon→tile/pixel math |
| `AuraCore/Sources/AuraKit/Routing/TerrainRGBTile.swift` (create) | Hardened PNG→RGBA8 decode + RGB→meters formula |
| `AuraCore/Sources/AuraKit/Routing/TerrainRGBSampler.swift` (create) | The single copy of the sampling orchestration (proportional count → indices → placements → dedupe → concurrent lookup → ordered read, drop-on-miss) |
| `AuraCore/Tests/AuraCoreTests/TerrainRGBPlacementTests.swift` (create) | Frozen-literal placement checks |
| `AuraCore/Tests/AuraKitTests/Support/TerrainRGBPNG.swift` (create) | Test-support PNG *encoder* (raw bytes → CGImage → PNG via CGImageDestination; a different path than the decode under test) |
| `AuraCore/Tests/AuraKitTests/Support/TerrainFixture.swift` (create) | Tile ID constant, DEM function, pixel→coordinate route builders, fixture loader |
| `AuraCore/Tests/AuraKitTests/TerrainRGBTileTests.swift` (create) | Decoder gate + rejection tests + record helper |
| `AuraCore/Tests/AuraKitTests/TerrainRGBSamplerTests.swift` (create) | Sampler orchestration unit tests |
| `AuraCore/Tests/AuraKitTests/RoutePlanningElevationGateTests.swift` (create) | End-to-end ranking gate |
| `AuraCore/Tests/AuraKitTests/Resources/terrain-rgb-fixture.png` (generated, committed) | The fixture tile |
| `AuraCore/Package.swift` (modify) | `resources: [.copy(...)]` on `AuraKitTests` |
| `Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift` (modify) | Thin shell: token guard + `TerrainTileCache` (URLSession fetch, negative caching) + sampler call |
| `docs/superpowers/specs/2026-07-22-e2e-ride-harness-design.md`, `...-navigate-golden-ride-design.md`, `docs/ROADMAP.md` (modify) | Append "gated since ROH-94" notes |

### The synthetic DEM (used by Tasks 3–5; defined once in `TerrainFixture`)

- Tile: z14, the Pittsburgh South Side tile containing lat 40.428, lon −79.976. The record helper prints the authoritative x/y; expected ≈ x 4552, y 6177 (verified independently in Task 3).
- `demElevation(px:py:)`: `220.0` for `py` in `100...131` (the flat "riverbank" band); otherwise `240.0 + 0.5·py + 0.8·px`. Every value is an exact multiple of 0.1 m, so terrain-rgb encoding is lossless and literals are exact. Relief ≈ 351 m (> 50 m). Transpose-distinct everywhere off the diagonal (0.8 ≠ 0.5).
- Check pixels (transpose-distinct): (10,200)→348.0, (200,10)→405.0, (50,116)→220.0, (250,250)→565.0.
- Routes (33 vertices each, at pixel centers, so the 16-of-33 downsampling branch executes; in-tile length ≈ 1.6 km so `proportionalCount` min-clamps to 16 — the proportional branch stays covered by `ElevationSamplingTests`):
  - `hillA`: px 16,23,…,240 (step 7), py 40. Monotonic climb 272.8→452.0 m; expected gain **179.2**.
  - `riverbank`: px 16,23,…,240 (step 7), py 116 (in the flat band). Expected gain **0.0**.
  - `hillB`: px 200, py 16,18,…,80 (step 2). Monotonic climb 408.0→440.0 m; expected gain **32.0** (per-sample deltas ≥ 2.0 m, safely above the 1 m noise threshold).

---

### Task 1: `TerrainTileID` + `TerrainRGBPlacement` in AuraCore

**Files:**
- Create: `AuraCore/Sources/AuraCore/Routing/TerrainRGBPlacement.swift`
- Create: `AuraCore/Tests/AuraCoreTests/TerrainRGBPlacementTests.swift`
- Reference (math source, do not modify yet): `Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift:75-84`

**Interfaces:**
- Consumes: nothing new.
- Produces (later tasks import these from `AuraCore`):
  - `public struct TerrainTileID: Hashable, Sendable { public let z: Int; public let x: Int; public let y: Int; public init(z: Int, x: Int, y: Int) }`
  - `public enum TerrainRGBPlacement { public struct Placement: Sendable { public let tileX: Int; public let tileY: Int; public let px: Int; public let py: Int }; public static func placement(lat: Double, lon: Double, z: Int) -> Placement }`

- [ ] **Step 1: Record the frozen placement literals independently**

Run this Python one-liner (standard slippy-map formulas, independent of the Swift code under test):

```bash
python3 -c "
import math
def place(lat, lon, z):
    n = 2.0**z
    xf = (lon + 180.0)/360.0*n
    yf = (1.0 - math.asinh(math.tan(math.radians(lat)))/math.pi)/2.0*n
    return int(xf), int(yf), min(255, max(0, int((xf - int(xf))*256))), min(255, max(0, int((yf - int(yf))*256)))
print('PointStatePark', place(40.4417, -80.0086, 14))
print('SouthSideAnchor', place(40.428, -79.976, 14))
print('CathedralOfLearning', place(40.4443, -79.9532, 14))
"
```

Expected output shape: three lines of `(tileX, tileY, px, py)` tuples. Paste these values into the test in Step 2 as the frozen literals. (SouthSideAnchor's `tileX/tileY` is also the fixture tile ID used in Task 3 — note it down.)

- [ ] **Step 2: Write the failing test**

`AuraCore/Tests/AuraCoreTests/TerrainRGBPlacementTests.swift` — substitute the recorded literals from Step 1 for the `<...>` placeholders; every other character is exact:

```swift
import Testing
@testable import AuraCore

/// Frozen-literal gate on the Web Mercator tile/pixel placement (ROH-94).
/// Literals recorded 2026-07-22 from the independent slippy-map formula
/// (see the plan's Task 1 one-liner) — never recompute at test time.
struct TerrainRGBPlacementTests {

    @Test func pointStateParkPlacement() {
        let p = TerrainRGBPlacement.placement(lat: 40.4417, lon: -80.0086, z: 14)
        #expect(p.tileX == <tileX>)
        #expect(p.tileY == <tileY>)
        #expect(p.px == <px>)
        #expect(p.py == <py>)
    }

    @Test func southSideAnchorPlacement() {
        let p = TerrainRGBPlacement.placement(lat: 40.428, lon: -79.976, z: 14)
        #expect(p.tileX == <tileX>)
        #expect(p.tileY == <tileY>)
        #expect(p.px == <px>)
        #expect(p.py == <py>)
    }

    @Test func cathedralOfLearningPlacement() {
        let p = TerrainRGBPlacement.placement(lat: 40.4443, lon: -79.9532, z: 14)
        #expect(p.tileX == <tileX>)
        #expect(p.tileY == <tileY>)
        #expect(p.px == <px>)
        #expect(p.py == <py>)
    }

    @Test func pixelClampsAtTileEdge() {
        // A longitude exactly on a tile boundary must clamp px into 0...255, never 256.
        let n = 16384.0 // 2^14
        let lonOnBoundary = (Double(9000) / n) * 360.0 - 180.0
        let p = TerrainRGBPlacement.placement(lat: 40.4, lon: lonOnBoundary, z: 14)
        #expect((0...255).contains(p.px))
        #expect((0...255).contains(p.py))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails to compile**

Run: `cd AuraCore && swift test --filter TerrainRGBPlacementTests`
Expected: build FAILURE — `cannot find 'TerrainRGBPlacement' in scope`.

- [ ] **Step 4: Implement**

`AuraCore/Sources/AuraCore/Routing/TerrainRGBPlacement.swift`:

```swift
import Foundation

/// Identifies one Web Mercator raster tile (z/x/y). Extracted from the app's
/// Terrain-RGB provider (ROH-94) so the package-level elevation gate and the
/// app share one tile vocabulary.
public struct TerrainTileID: Hashable, Sendable {
    public let z: Int
    public let x: Int
    public let y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }
}

/// Pure Web Mercator lat/lon → (tile, pixel) placement for 256px raster tiles.
/// Moved verbatim from `MapboxTerrainRGBElevationProvider` (ROH-94) so the
/// math is gated by frozen-literal package tests.
public enum TerrainRGBPlacement {

    public struct Placement: Sendable {
        public let tileX: Int
        public let tileY: Int
        public let px: Int
        public let py: Int
    }

    public static func placement(lat: Double, lon: Double, z: Int) -> Placement {
        let n = pow(2.0, Double(z))
        let xf = (lon + 180.0) / 360.0 * n
        let latRad = lat * .pi / 180.0
        let yf = (1.0 - asinh(tan(latRad)) / .pi) / 2.0 * n
        let tileX = Int(floor(xf)), tileY = Int(floor(yf))
        let px = min(255, max(0, Int((xf - floor(xf)) * 256.0)))
        let py = min(255, max(0, Int((yf - floor(yf)) * 256.0)))
        return Placement(tileX: tileX, tileY: tileY, px: px, py: py)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd AuraCore && swift test --filter TerrainRGBPlacementTests`
Expected: PASS (4 tests). If a placement literal mismatches, the Swift math and the Python formula disagree — investigate before touching literals (they are the independent truth).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraCore/Routing/TerrainRGBPlacement.swift AuraCore/Tests/AuraCoreTests/TerrainRGBPlacementTests.swift
git commit -m "feat(roh-94): extract TerrainTileID + Web Mercator placement into AuraCore

Frozen placement literals recorded from the independent slippy-map formula.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `TerrainRGBTile` hardened decode in AuraKit

**Files:**
- Create: `AuraCore/Sources/AuraKit/Routing/TerrainRGBTile.swift`
- Create: `AuraCore/Tests/AuraKitTests/Support/TerrainRGBPNG.swift`
- Create: `AuraCore/Tests/AuraKitTests/TerrainRGBTileTests.swift`
- Reference (decode source, do not modify yet): `Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift:118-150`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public struct TerrainRGBTile: Sendable { public static let side: Int /* 256 */; public init?(pngData: Data); public func elevation(px: Int, py: Int) -> Double? }` (in `AuraKit`)
  - Test support `enum TerrainRGBPNG { static func encode(side: Int, elevation: (_ px: Int, _ py: Int) -> Double) -> Data? }` (in `AuraKitTests`)

- [ ] **Step 1: Write the test-support PNG encoder**

This is deliberately a *different* CG path (raw bytes → `CGImage` → `CGImageDestination`) than the decode under test (`CGImageSource` → `CGContext.draw`), so encode and decode bugs cannot cancel out.

`AuraCore/Tests/AuraKitTests/Support/TerrainRGBPNG.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Test-support terrain-rgb PNG *encoder* (ROH-94). Encodes a DEM function into
/// the Mapbox terrain-rgb scheme (v = (e + 10000) / 0.1, R = v>>16, G = v>>8,
/// B = v) as an sRGB-tagged PNG. Uses CGImageDestination — a different code
/// path than TerrainRGBTile's CGImageSource/CGContext decode, so a shared bug
/// can't silently cancel.
enum TerrainRGBPNG {

    static func encode(side: Int, elevation: (_ px: Int, _ py: Int) -> Double) -> Data? {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for py in 0..<side {
            for px in 0..<side {
                let v = Int(((elevation(px, py) + 10000.0) * 10.0).rounded())
                let off = (py * side + px) * 4
                bytes[off] = UInt8((v >> 16) & 0xFF)
                bytes[off + 1] = UInt8((v >> 8) & 0xFF)
                bytes[off + 2] = UInt8(v & 0xFF)
                // bytes[off + 3] stays 255 (opaque).
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: side, height: side,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
```

- [ ] **Step 2: Write the failing decoder tests**

`AuraCore/Tests/AuraKitTests/TerrainRGBTileTests.swift` (the fixture-file tests arrive in Task 3; this task covers roundtrip + rejection):

```swift
import Foundation
import Testing
@testable import AuraKit

/// Decoder gate for the Terrain-RGB regression class (ROH-94): the decode must
/// either produce true elevations or fail loudly (nil) — never a silent flat tile.
struct TerrainRGBTileTests {

    // MARK: - Roundtrip over an in-memory synthetic tile

    @Test func decodesEncodedElevationsExactly() throws {
        // Gradient chosen to exercise all three RGB bytes: values are exact
        // multiples of 0.1 m so the terrain-rgb encoding is lossless.
        let png = try #require(TerrainRGBPNG.encode(side: 256) { px, py in
            -50.0 + 0.8 * Double(px) + 0.5 * Double(py)
        })
        let tile = try #require(TerrainRGBTile(pngData: png))
        #expect(abs(try #require(tile.elevation(px: 0, py: 0)) - (-50.0)) < 0.05)
        #expect(abs(try #require(tile.elevation(px: 100, py: 0)) - 30.0) < 0.05)
        #expect(abs(try #require(tile.elevation(px: 0, py: 200)) - 50.0) < 0.05)
        #expect(abs(try #require(tile.elevation(px: 255, py: 255)) - 281.5) < 0.05)
    }

    // MARK: - Rejection: nil, never a fabricated flat tile

    @Test func rejectsRandomBytes() {
        let garbage = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        #expect(TerrainRGBTile(pngData: garbage) == nil)
    }

    @Test func rejectsEmptyData() {
        #expect(TerrainRGBTile(pngData: Data()) == nil)
    }

    @Test func rejectsTruncatedPNG() throws {
        let png = try #require(TerrainRGBPNG.encode(side: 256) { px, _ in Double(px) })
        // A prefix long enough to carry a valid header but not the image data:
        // ImageIO may yield a partial image; the decode must refuse it rather
        // than fabricate undrawn (flat, -10000 m) rows.
        let truncated = png.prefix(png.count / 2)
        #expect(TerrainRGBTile(pngData: Data(truncated)) == nil)
    }

    @Test func rejectsWrongSizePNG() throws {
        // Valid PNG, wrong dimensions: CGContext.draw would silently rescale
        // it into plausible garbage elevations — init must refuse instead.
        let small = try #require(TerrainRGBPNG.encode(side: 64) { px, py in Double(px + py) })
        #expect(TerrainRGBTile(pngData: small) == nil)
    }

    // MARK: - Bounds

    @Test func rejectsOutOfRangePixels() throws {
        let png = try #require(TerrainRGBPNG.encode(side: 256) { _, _ in 100.0 })
        let tile = try #require(TerrainRGBTile(pngData: png))
        #expect(tile.elevation(px: -1, py: 0) == nil)
        #expect(tile.elevation(px: 0, py: -1) == nil)
        #expect(tile.elevation(px: 256, py: 0) == nil)
        #expect(tile.elevation(px: 0, py: 256) == nil)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd AuraCore && swift test --filter TerrainRGBTileTests`
Expected: build FAILURE — `cannot find 'TerrainRGBTile' in scope`.

- [ ] **Step 4: Implement the hardened decode**

`AuraCore/Sources/AuraKit/Routing/TerrainRGBTile.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO

/// A decoded Mapbox Terrain-RGB tile: a 256×256 RGBA8 buffer whose pixels
/// encode elevation as `-10000 + (R·65536 + G·256 + B) · 0.1` meters.
///
/// Extracted from the app's `TerrainTileCache` (ROH-94) and hardened so the
/// decode either produces true elevations or fails (`nil`) — never a silent
/// flat tile, which is the regression class this type exists to prevent:
/// - rejects images that are not exactly 256×256 (CGContext.draw would
///   silently rescale, interpolating R/G/B independently into garbage);
/// - rejects incomplete sources (ImageIO can render a partial image for a
///   truncated PNG, leaving undrawn all-zero rows at −10000 m);
/// - renders into the source image's own RGB colorspace so DEM bytes are
///   never color-matched (a ±1 shift in R alone is ±6553.6 m).
public struct TerrainRGBTile: Sendable {

    public static let side = 256

    /// RGBA8, row-major, 4 bytes per pixel.
    private let pixels: [UInt8]

    public init?(pngData: Data) {
        let side = Self.side
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              CGImageSourceGetStatus(src) == .statusComplete,
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width == side, img.height == side else { return nil }
        // Draw in the source's own colorspace (fall back to sRGB for untagged
        // input) so the draw is a byte-identity transfer, not a color match.
        let space: CGColorSpace
        if let imgSpace = img.colorSpace, imgSpace.model == .rgb {
            space = imgSpace
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            space = srgb
        } else {
            return nil
        }
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        let drew = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        self.pixels = buf
    }

    /// The elevation (meters) at a pixel, or nil for out-of-range coordinates.
    public func elevation(px: Int, py: Int) -> Double? {
        let side = Self.side
        guard (0..<side).contains(px), (0..<side).contains(py) else { return nil }
        let off = (py * side + px) * 4
        let r = Double(pixels[off]), g = Double(pixels[off + 1]), b = Double(pixels[off + 2])
        return -10000.0 + (r * 65536.0 + g * 256.0 + b) * 0.1
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd AuraCore && swift test --filter TerrainRGBTileTests`
Expected: PASS (6 tests). If `rejectsTruncatedPNG` fails because ImageIO reports the truncated source `.statusComplete` with a valid image, increase truncation (`png.prefix(1024)`) — the guard chain (status, then dimensions) must reject it one way or the other; a truncated file must never decode.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Routing/TerrainRGBTile.swift AuraCore/Tests/AuraKitTests/Support/TerrainRGBPNG.swift AuraCore/Tests/AuraKitTests/TerrainRGBTileTests.swift
git commit -m "feat(roh-94): hardened TerrainRGBTile decode in AuraKit

Rejects wrong-size/partial/garbage input instead of fabricating flat tiles;
color-conversion-free render; test-support encoder uses a distinct CG path.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Fixture generation + decoder gate over the committed tile

**Files:**
- Create: `AuraCore/Tests/AuraKitTests/Support/TerrainFixture.swift`
- Create (generated): `AuraCore/Tests/AuraKitTests/Resources/terrain-rgb-fixture.png`
- Modify: `AuraCore/Package.swift` (AuraKitTests `resources:`)
- Modify: `AuraCore/Tests/AuraKitTests/TerrainRGBTileTests.swift` (add fixture suite + record helper)

**Interfaces:**
- Consumes: `TerrainRGBPNG.encode` (Task 2), `TerrainRGBTile` (Task 2), `TerrainTileID` (Task 1).
- Produces (Tasks 4–5 use these):
  - `enum TerrainFixture` with:
    - `static let tileID: TerrainTileID` (z14, the recorded South Side x/y)
    - `static func demElevation(px: Int, py: Int) -> Double`
    - `static func pngData() throws -> Data` (loads the bundled fixture)
    - `static func decodedTile() throws -> TerrainRGBTile`
    - `static func coordinate(px: Double, py: Double) -> Coordinate`
    - `static let hillAPixels: [(px: Double, py: Double)]`, `riverbankPixels`, `hillBPixels` (33 entries each)
    - `static func route(_ pixels: [(px: Double, py: Double)]) -> [Coordinate]`

- [ ] **Step 1: Write `TerrainFixture` support**

`AuraCore/Tests/AuraKitTests/Support/TerrainFixture.swift` — substitute the SouthSideAnchor tile x/y recorded in Task 1 Step 1 for `<tileX>`/`<tileY>`:

```swift
import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// The ROH-94 terrain fixture: a *generated* terrain-rgb tile (nothing
/// Mapbox-owned enters the repo) at the real z14 tile coordinates of
/// Pittsburgh's South Side, so fixture routes use realistic lat/lon.
///
/// The DEM is analytic and exact in 0.1 m quanta:
///   py in 100...131            → 220.0 m   (flat "riverbank" band)
///   otherwise                  → 240 + 0.5·py + 0.8·px
/// Relief ≈ 351 m; transpose-distinct off the diagonal (0.8 ≠ 0.5).
///
/// Truth literals are derived FROM THIS FUNCTION (independent of the decoder
/// and sampler under test) via the TERRAIN_FIXTURE_RECORD=1 helper. Re-record
/// procedure: any intentional change to this DEM, the routes, sampling, or the
/// formula regenerates the PNG and re-pastes every literal in the same commit.
enum TerrainFixture {

    /// Recorded in Task 1 from the independent slippy-map formula.
    static let tileID = TerrainTileID(z: 14, x: <tileX>, y: <tileY>)

    static func demElevation(px: Int, py: Int) -> Double {
        if (100...131).contains(py) { return 220.0 }
        return 240.0 + 0.5 * Double(py) + 0.8 * Double(px)
    }

    // MARK: - Fixture file

    static func pngData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "terrain-rgb-fixture", withExtension: "png"))
        return try Data(contentsOf: url)
    }

    static func decodedTile() throws -> TerrainRGBTile {
        try #require(TerrainRGBTile(pngData: pngData()))
    }

    // MARK: - Routes (pixel-center geometry inside the tile)

    /// Inverse Web Mercator at a pixel center of this tile.
    static func coordinate(px: Double, py: Double) -> Coordinate {
        let n = pow(2.0, Double(tileID.z))
        let xf = (Double(tileID.x) + (px + 0.5) / 256.0) / n
        let lon = xf * 360.0 - 180.0
        let yf = (Double(tileID.y) + (py + 0.5) / 256.0) / n
        let lat = atan(sinh(.pi * (1.0 - 2.0 * yf))) * 180.0 / .pi
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// 33 vertices each — enough that 16-of-33 downsampling actually runs.
    static let hillAPixels: [(px: Double, py: Double)] =
        stride(from: 16, through: 240, by: 7).map { (Double($0), 40.0) }
    static let riverbankPixels: [(px: Double, py: Double)] =
        stride(from: 16, through: 240, by: 7).map { (Double($0), 116.0) }
    static let hillBPixels: [(px: Double, py: Double)] =
        stride(from: 16, through: 80, by: 2).map { (200.0, Double($0)) }

    static func route(_ pixels: [(px: Double, py: Double)]) -> [Coordinate] {
        pixels.map { coordinate(px: $0.px, py: $0.py) }
    }
}
```

- [ ] **Step 2: Add the record helper and fixture-gate tests**

Append to `AuraCore/Tests/AuraKitTests/TerrainRGBTileTests.swift`. The `<...>` literals get pasted from the record run in Step 4; write the tests first with placeholder `-1` values so the suite compiles but fails (that is the TDD "failing test" state):

```swift
import ImageIO   // (top of file, with the existing imports)
import AuraCore

/// Gate over the COMMITTED fixture tile (ROH-94). Literals recorded via
/// TERRAIN_FIXTURE_RECORD=1 from the DEM function — independent of the
/// decode under test. Fixture: z14 tile (<tileX>, <tileY>), generated
/// 2026-07-22 (see TerrainFixture).
struct TerrainFixtureDecodeTests {

    @Test func fixtureDecodesWithFrozenPixelLiterals() throws {
        let tile = try TerrainFixture.decodedTile()
        // Transpose-distinct check pixels; ±0.5 m against 0.1 m quantization.
        #expect(abs(try #require(tile.elevation(px: 10, py: 200)) - <literal>) < 0.5)
        #expect(abs(try #require(tile.elevation(px: 200, py: 10)) - <literal>) < 0.5)
        #expect(abs(try #require(tile.elevation(px: 50, py: 116)) - <literal>) < 0.5)
        #expect(abs(try #require(tile.elevation(px: 250, py: 250)) - <literal>) < 0.5)
    }

    @Test func fixtureIsNotFlat() throws {
        let tile = try TerrainFixture.decodedTile()
        var minE = Double.greatestFiniteMagnitude, maxE = -Double.greatestFiniteMagnitude
        for py in 0..<TerrainRGBTile.side {
            for px in 0..<TerrainRGBTile.side {
                guard let e = tile.elevation(px: px, py: py) else { continue }
                minE = min(minE, e); maxE = max(maxE, e)
            }
        }
        #expect(maxE - minE > 50.0)
    }

    @Test func fixtureColorspaceIsIdentitySafe() throws {
        // The frozen literals depend on the decode being color-conversion-free:
        // pin that the committed fixture is tagged with an RGB colorspace the
        // decoder draws into directly (sRGB), or untagged.
        let data = try TerrainFixture.pngData()
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        if let space = img.colorSpace {
            #expect(space.model == .rgb)
            #expect(space.name == CGColorSpace.sRGB)
        }
    }

    /// Re-record helper (ROH-92 convention): regenerates the fixture PNG from
    /// the DEM function and prints every paste-ready truth literal. Run:
    ///   TERRAIN_FIXTURE_RECORD=1 swift test --filter recordTerrainFixture
    /// then commit the PNG and paste the printed literals in the same commit.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERRAIN_FIXTURE_RECORD"] != nil))
    func recordTerrainFixture() throws {
        let png = try #require(TerrainRGBPNG.encode(side: TerrainRGBTile.side,
                                                    elevation: TerrainFixture.demElevation))
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("terrain-rgb-fixture.png")
        try png.write(to: out)

        var lines = ["TERRAIN_FIXTURE_RECORD →", "wrote \(out.path) (\(png.count) bytes)"]
        for (px, py) in [(10, 200), (200, 10), (50, 116), (250, 250)] {
            lines.append("pixel(\(px),\(py)) = \(TerrainFixture.demElevation(px: px, py: py))")
        }
        for (name, pixels) in [("hillA", TerrainFixture.hillAPixels),
                               ("riverbank", TerrainFixture.riverbankPixels),
                               ("hillB", TerrainFixture.hillBPixels)] {
            let coords = TerrainFixture.route(pixels)
            let count = ElevationSampling.proportionalCount(coordinates: coords, spacingMeters: 150,
                                                            minCount: 16, maxCount: 96)
            let indices = ElevationSampling.sampleIndices(total: pixels.count, count: count)
            let elevations = indices.map { i in
                TerrainFixture.demElevation(px: Int(pixels[i].px), py: Int(pixels[i].py))
            }
            lines.append("\(name): sampleCount=\(count) gain=\(RouteMetrics.elevationGain(elevations: elevations))")
        }
        print(lines.joined(separator: "\n"))
    }
}
```

- [ ] **Step 3: Declare the test resource**

In `AuraCore/Package.swift`, change the `AuraKitTests` target to:

```swift
        .testTarget(name: "AuraKitTests", dependencies: ["AuraKit"],
                    resources: [.copy("Resources/terrain-rgb-fixture.png")]),
```

(`.copy`, not `.process`: the fixture's bytes are the truth; nothing may touch them.)

- [ ] **Step 4: Record the fixture and literals**

Run: `cd AuraCore && TERRAIN_FIXTURE_RECORD=1 swift test --filter recordTerrainFixture`
Expected: PASS, printing the written path plus `pixel(10,200) = 348.0`, `pixel(200,10) = 405.0`, `pixel(50,116) = 220.0`, `pixel(250,250) = 565.0`, and three `gain=` lines (expected: hillA 179.2, riverbank 0.0, hillB 32.0, each with `sampleCount=16`). If a printed value differs from these plan predictions, stop and reconcile (the DEM function or route pixels deviate from the plan) before pasting anything.

Paste the four printed pixel values over the `<literal>` placeholders in `fixtureDecodesWithFrozenPixelLiterals`, and the tile x/y into the suite doc comment. Note the three gains — Task 5 pastes them.

- [ ] **Step 5: Run the fixture gate**

Run: `cd AuraCore && swift test --filter TerrainFixtureDecodeTests`
Expected: PASS (3 tests; the record helper is env-disabled).

- [ ] **Step 6: One-time live cross-check (spec §2 residual-fidelity mitigation — nothing committed)**

Copy the token from the main checkout if not already present, fetch ONE live tile for the fixture's z/x/y, and decode it with the shipped decoder via a scratch test run — confirming the real Mapbox encoder's output decodes to plausible Pittsburgh elevations (roughly 200–450 m):

```bash
TOKEN=$(cat /Users/rohunjoseph/projects/biking-app/Aura/Resources/MapboxAccessToken) && \
curl -sf "https://api.mapbox.com/v4/mapbox.terrain-rgb/14/<tileX>/<tileY>.pngraw?access_token=${TOKEN}" \
  -o /tmp/live-terrain-tile.png && ls -l /tmp/live-terrain-tile.png
```

Then add a TEMPORARY test (delete before commit) in `TerrainRGBTileTests.swift`:

```swift
    @Test func liveTileCrossCheckTEMP() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/live-terrain-tile.png"))
        let tile = try #require(TerrainRGBTile(pngData: data))
        let e = try #require(tile.elevation(px: 128, py: 128))
        print("LIVE CROSS-CHECK: center elevation = \(e) m")
        #expect(e > 150.0 && e < 600.0)
    }
```

Run: `cd AuraCore && swift test --filter liveTileCrossCheckTEMP`
Expected: PASS with a printed plausible elevation. Save the printed line for the PR body, then DELETE the temporary test and `/tmp/live-terrain-tile.png`. Verify deletion: `git diff --stat` must show no live-tile test remaining.

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Tests/AuraKitTests/Support/TerrainFixture.swift AuraCore/Tests/AuraKitTests/TerrainRGBTileTests.swift AuraCore/Tests/AuraKitTests/Resources/terrain-rgb-fixture.png AuraCore/Package.swift
git commit -m "test(roh-94): generated terrain-rgb fixture + decoder gate over committed tile

Synthetic DEM at real South Side z14 tile coordinates; literals recorded from
the DEM function via TERRAIN_FIXTURE_RECORD=1; live-tile cross-check run
once and not committed.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `TerrainRGBSampler` — the extracted orchestration

**Files:**
- Create: `AuraCore/Sources/AuraKit/Routing/TerrainRGBSampler.swift`
- Create: `AuraCore/Tests/AuraKitTests/TerrainRGBSamplerTests.swift`
- Reference (orchestration source, do not modify yet): `Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift:36-68`

**Interfaces:**
- Consumes: `TerrainTileID`, `TerrainRGBPlacement` (Task 1), `TerrainRGBTile` (Task 2), `TerrainFixture` (Task 3), `ElevationSampling` (existing, AuraCore).
- Produces (Task 5 and the app use this exact signature):

```swift
public enum TerrainRGBSampler {
    public static func elevations(along coordinates: [Coordinate], zoom: Int,
                                  spacingMeters: Double, minSamples: Int, maxSamples: Int,
                                  tile: @Sendable (TerrainTileID) async -> TerrainRGBTile?) async -> [Double]
}
```

- [ ] **Step 1: Write the failing tests**

`AuraCore/Tests/AuraKitTests/TerrainRGBSamplerTests.swift`:

```swift
import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// Unit gate on the extracted sampling orchestration (ROH-94): ordered reads,
/// one lookup per unique tile, drop-on-miss. This is the SAME code the app
/// provider runs — that identity is the point of the extraction.
struct TerrainRGBSamplerTests {

    private actor LookupCounter {
        private(set) var requested: [TerrainTileID] = []
        func note(_ id: TerrainTileID) { requested.append(id) }
    }

    @Test func readsElevationsInRouteOrder() async throws {
        let tile = try TerrainFixture.decodedTile()
        // hillA is a monotonic climb: in-order reads are strictly increasing.
        let elevations = await TerrainRGBSampler.elevations(
            along: TerrainFixture.route(TerrainFixture.hillAPixels), zoom: 14,
            spacingMeters: 150, minSamples: 16, maxSamples: 96
        ) { id in id == TerrainFixture.tileID ? tile : nil }
        #expect(elevations.count == 16)
        for i in 1..<elevations.count {
            #expect(elevations[i] > elevations[i - 1])
        }
    }

    @Test func looksUpEachUniqueTileOnce() async throws {
        let tile = try TerrainFixture.decodedTile()
        let counter = LookupCounter()
        _ = await TerrainRGBSampler.elevations(
            along: TerrainFixture.route(TerrainFixture.riverbankPixels), zoom: 14,
            spacingMeters: 150, minSamples: 16, maxSamples: 96
        ) { id in
            await counter.note(id)
            return id == TerrainFixture.tileID ? tile : nil
        }
        // All 33 vertices live in one tile: exactly one lookup.
        #expect(await counter.requested == [TerrainFixture.tileID])
    }

    @Test func dropsSamplesWhoseTileIsUnavailable() async throws {
        // Lookup returns nil for everything: best-effort means empty, not zeros.
        let elevations = await TerrainRGBSampler.elevations(
            along: TerrainFixture.route(TerrainFixture.hillAPixels), zoom: 14,
            spacingMeters: 150, minSamples: 16, maxSamples: 96
        ) { _ in nil }
        #expect(elevations.isEmpty)
    }

    @Test func emptyRouteYieldsEmpty() async {
        let elevations = await TerrainRGBSampler.elevations(
            along: [], zoom: 14, spacingMeters: 150, minSamples: 16, maxSamples: 96
        ) { _ in nil }
        #expect(elevations.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd AuraCore && swift test --filter TerrainRGBSamplerTests`
Expected: build FAILURE — `cannot find 'TerrainRGBSampler' in scope`.

- [ ] **Step 3: Implement**

`AuraCore/Sources/AuraKit/Routing/TerrainRGBSampler.swift`:

```swift
import Foundation
import AuraCore

/// The Terrain-RGB sampling orchestration, extracted from the app provider
/// (ROH-94) so package tests execute the exact pipeline production runs:
/// proportional sample count → evenly-spaced indices → tile/pixel placements →
/// dedupe unique tiles → fetch each once (concurrently, via the injected
/// lookup) → read samples in route order, dropping any unavailable sample.
///
/// BEST-EFFORT like the provider it came from: a missing tile or pixel drops
/// that sample; no elevation is ever fabricated.
public enum TerrainRGBSampler {

    public static func elevations(along coordinates: [Coordinate], zoom: Int,
                                  spacingMeters: Double, minSamples: Int, maxSamples: Int,
                                  tile: @Sendable (TerrainTileID) async -> TerrainRGBTile?) async -> [Double] {
        let count = ElevationSampling.proportionalCount(coordinates: coordinates, spacingMeters: spacingMeters,
                                                        minCount: minSamples, maxCount: maxSamples)
        let indices = ElevationSampling.sampleIndices(total: coordinates.count, count: count)
        guard !indices.isEmpty else { return [] }
        let sampled = indices.map { coordinates[$0] }

        let placements = sampled.map {
            TerrainRGBPlacement.placement(lat: $0.latitude, lon: $0.longitude, z: zoom)
        }
        let uniqueTiles = Set(placements.map { TerrainTileID(z: zoom, x: $0.tileX, y: $0.tileY) })

        // Fetch each unique tile once, concurrently (a short route usually
        // touches only 1–4 tiles).
        var tiles: [TerrainTileID: TerrainRGBTile] = [:]
        await withTaskGroup(of: (TerrainTileID, TerrainRGBTile?).self) { group in
            for id in uniqueTiles {
                group.addTask { (id, await tile(id)) }
            }
            for await (id, decoded) in group {
                if let decoded { tiles[id] = decoded }
            }
        }

        // Read each sampled point's elevation in route order.
        var out: [Double] = []
        out.reserveCapacity(placements.count)
        for p in placements {
            let id = TerrainTileID(z: zoom, x: p.tileX, y: p.tileY)
            if let e = tiles[id]?.elevation(px: p.px, py: p.py) {
                out.append(e)
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter TerrainRGBSamplerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Routing/TerrainRGBSampler.swift AuraCore/Tests/AuraKitTests/TerrainRGBSamplerTests.swift
git commit -m "feat(roh-94): extract Terrain-RGB sampling orchestration into AuraKit

One shared pipeline for app and tests; injected async tile lookup is the
only seam.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: The ranking gate

**Files:**
- Create: `AuraCore/Tests/AuraKitTests/RoutePlanningElevationGateTests.swift`

**Interfaces:**
- Consumes: `TerrainRGBSampler` (Task 4), `TerrainFixture` (Task 3), `RouteMetrics` (AuraKit, existing), `CandidateRoute`/`RouteRanker`/`Route.Profile` (AuraCore, existing — see `AuraCore/Sources/AuraCore/Routing/RouteRanker.swift`).
- Produces: nothing consumed later; this is the flagship gate.

- [ ] **Step 1: Write the failing gate**

Use the three gains recorded in Task 3 Step 4 (expected: hillA 179.2, riverbank 0.0, hillB 32.0) for the `<gain*>` placeholders:

```swift
import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// THE ROH-94 gate: runs the production route-planning elevation pipeline
/// (sampler → RouteMetrics.elevationGain → RouteRanker) over the committed
/// fixture tile and fails if elevation ever silently goes flat — the
/// Terrain-RGB regression class both golden-ride specs list as "not caught".
///
/// Gains are frozen literals from the DEM function (TERRAIN_FIXTURE_RECORD=1),
/// ±0.5 m absolute: sampling and fixture are deterministic; intentional
/// changes are re-record events, not tolerance headroom. Offset/scale decode
/// errors are the decoder gate's job (pixel literals), not this suite's.
struct RoutePlanningElevationGateTests {

    private static let expectedGains: [Double] = [<gainHillA>, <gainRiverbank>, <gainHillB>]

    private func gains() async throws -> [Double] {
        let tile = try TerrainFixture.decodedTile()
        var result: [Double] = []
        for pixels in [TerrainFixture.hillAPixels, TerrainFixture.riverbankPixels, TerrainFixture.hillBPixels] {
            let elevations = await TerrainRGBSampler.elevations(
                along: TerrainFixture.route(pixels), zoom: 14,
                spacingMeters: 150, minSamples: 16, maxSamples: 96
            ) { id in id == TerrainFixture.tileID ? tile : nil }
            #expect(!elevations.isEmpty)
            result.append(RouteMetrics.elevationGain(elevations: elevations))
        }
        return result
    }

    @Test func gainsMatchFrozenLiteralsAndAreNotFlat() async throws {
        let gains = try await gains()
        #expect(gains.count == 3)
        // The flat-regression kill line: a silently flat pipeline makes every
        // gain 0 — both of these plus the literals fail.
        #expect(gains.contains { $0 > 0.0 })
        #expect(Set(gains).count > 1)
        for (gain, expected) in zip(gains, Self.expectedGains) {
            #expect(abs(gain - expected) < 0.5)
        }
    }

    @Test func flattestLabelGoesToTheRiverbankRoute() async throws {
        let gains = try await gains()
        // Choreographed non-elevation fields (spec §4): RouteRanker assigns
        // mostPaths first and dedups winners, so hillA must win mostPaths
        // (lowest walkFraction) and hillB fastest (lowest duration), forcing
        // .flattest onto the minimum-gain candidate.
        let pixelSets = [TerrainFixture.hillAPixels, TerrainFixture.riverbankPixels, TerrainFixture.hillBPixels]
        let walkFractions = [0.0, 0.1, 0.2]
        let durations = [600.0, 500.0, 300.0]
        let candidates = (0..<3).map { i in
            CandidateRoute(geometry: TerrainFixture.route(pixelSets[i]),
                           distanceMeters: 1600,
                           estimatedDurationSeconds: durations[i],
                           elevationGainMeters: gains[i],
                           walkFraction: walkFractions[i])
        }
        let origin = TerrainFixture.coordinate(px: 16, py: 40)
        let destination = TerrainFixture.coordinate(px: 240, py: 40)
        let labeled = RouteRanker.labeled(origin: origin, destination: destination, candidates: candidates)

        let flattest = try #require(labeled.first { $0.route.profile == .flattest })
        #expect(flattest.sourceIndex == 1)  // the riverbank candidate
        // And the choreography itself held (guards against silent re-labeling):
        let mostPaths = try #require(labeled.first { $0.route.profile == .mostPaths })
        #expect(mostPaths.sourceIndex == 0)
        let fastest = try #require(labeled.first { $0.route.profile == .fastest })
        #expect(fastest.sourceIndex == 2)
    }
}
```

- [ ] **Step 2: Run to verify the intended failure mode**

Run: `cd AuraCore && swift test --filter RoutePlanningElevationGateTests`
Expected: PASS immediately if Tasks 1–4 are correct — this suite gates *future* regressions, so its first honest failure demonstration is the drill in Task 8. If it FAILS now, a real defect exists in Tasks 1–4 (or a literal was mispasted); fix that first — do not adjust literals to make it pass.

- [ ] **Step 3: Run the full package suite**

Run: `cd AuraCore && swift test --no-parallel`
Expected: PASS, including all pre-existing suites.

- [ ] **Step 4: Commit**

```bash
git add AuraCore/Tests/AuraKitTests/RoutePlanningElevationGateTests.swift
git commit -m "test(roh-94): route-planning elevation ranking gate over the fixture tile

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: App provider becomes a thin shell

**Files:**
- Modify: `Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift` (full-file replacement below)

**Interfaces:**
- Consumes: `TerrainRGBSampler`, `TerrainRGBTile` (AuraKit), `TerrainTileID` (AuraCore).
- Produces: unchanged public API — `MapboxTerrainRGBElevationProvider(spacingMeters:minSamples:maxSamples:zoom:tileCache:)` conforming to `AuraCore.ElevationProvider`, and `public actor TerrainTileCache` with `static let shared`.

- [ ] **Step 1: Replace the provider implementation**

Replace the entire contents of `Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift` with:

```swift
import Foundation
import AuraCore
import AuraKit
import MapboxMaps

/// `AuraCore.ElevationProvider` backed by Mapbox **Terrain-RGB** raster tiles —
/// true per-point elevation (decoded from the RGB-encoded DEM), unlike the contour
/// Tilequery which only returns nearby contour lines.
///
/// Since ROH-94 this is a thin shell: the pure decode (`TerrainRGBTile`),
/// placement (`TerrainRGBPlacement`), and the sampling orchestration
/// (`TerrainRGBSampler`) live in the package, where regression gates cover
/// them. This file keeps only what CI cannot gate: the access-token guard,
/// the URLSession fetch, and the tile cache.
///
/// BEST-EFFORT: any network/decode/missing-token failure drops the affected sample
/// (or returns []); it never throws. Only a route's relative *deltas* feed elevation
/// gain, so a small absolute offset is harmless.
public struct MapboxTerrainRGBElevationProvider: AuraCore.ElevationProvider {

    private let spacingMeters: Double
    private let minSamples: Int
    private let maxSamples: Int
    private let zoom: Int
    private let tileCache: TerrainTileCache

    public init(spacingMeters: Double = 150, minSamples: Int = 16, maxSamples: Int = 96,
                zoom: Int = 14, tileCache: TerrainTileCache = .shared) {
        self.spacingMeters = spacingMeters
        self.minSamples = minSamples
        self.maxSamples = maxSamples
        self.zoom = zoom
        self.tileCache = tileCache
    }

    public func elevations(along coordinates: [Coordinate]) async -> [Double] {
        let token = MapboxMaps.MapboxOptions.accessToken
        guard !token.isEmpty else { return [] }
        let cache = tileCache
        return await TerrainRGBSampler.elevations(along: coordinates, zoom: zoom,
                                                  spacingMeters: spacingMeters,
                                                  minSamples: minSamples,
                                                  maxSamples: maxSamples) { id in
            await cache.tile(id, token: token)
        }
    }
}

/// Caches decoded Terrain-RGB tiles so the sampled points of a route — and
/// repeat searches — reuse one fetch+decode per tile.
public actor TerrainTileCache {
    public static let shared = TerrainTileCache()

    /// Decoded tile, or nil if the tile failed to load — cached as a negative
    /// result to avoid re-fetching. INVARIANT: the double-optional storage is
    /// what makes negative caching work (`tiles[key] == nil` means "never
    /// tried"; `tiles[key] == .some(nil)` means "tried and failed"). Do not
    /// "simplify" to `[TerrainTileID: TerrainRGBTile]`.
    ///
    /// Initialized in `init()` rather than via a default literal: under default
    /// MainActor isolation a stored-property default expression is MainActor-isolated,
    /// which can't initialize this actor-isolated storage. Assigning in the actor's
    /// init keeps the initialization inside the actor's isolation domain.
    private var tiles: [TerrainTileID: TerrainRGBTile?]

    public init() {
        self.tiles = [:]
    }

    /// The decoded tile for `id`, fetching + decoding on first request.
    func tile(_ id: TerrainTileID, token: String) async -> TerrainRGBTile? {
        if let cached = tiles[id] { return cached }
        let fetched = await Self.fetchDecoded(id, token: token)
        tiles[id] = fetched
        return fetched
    }

    /// Downloads a terrain-rgb tile and decodes it via the package's hardened
    /// `TerrainRGBTile`. Keep this a `nonisolated static func` (it must stay
    /// off the main actor): the decode is CPU-bound, and under the app's
    /// default MainActor isolation an instance method here would hop onto the
    /// main actor and could jank map rendering.
    private static func fetchDecoded(_ id: TerrainTileID, token: String) async -> TerrainRGBTile? {
        let urlStr = "https://api.mapbox.com/v4/mapbox.terrain-rgb/\(id.z)/\(id.x)/\(id.y).pngraw?access_token=\(token)"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return TerrainRGBTile(pngData: data)
        } catch {
            return nil
        }
    }
}
```

Note what disappeared and where it went: `placement`/`Placement` → `TerrainRGBPlacement` (AuraCore, Task 1); `TileKey` → `TerrainTileID` (AuraCore, Task 1); the CGImage decode + RGB formula → `TerrainRGBTile` (AuraKit, Task 2); the sampling body of `elevations(along:)` → `TerrainRGBSampler` (AuraKit, Task 4). `CoreGraphics`/`ImageIO` imports are gone from this file. There is one behavior delta, wanted by the spec: a fetched tile that is wrong-size/partial now decodes to `nil` (negative-cached) instead of a rescaled/partial buffer.

- [ ] **Step 2: Check for other references to the moved symbols**

Run: `grep -rn "TileKey\|\.placement(\|fetchDecoded" Aura/Sources/ Aura/Widgets/ Aura/UITests/`
Expected: no hits outside `MapboxTerrainRGBElevationProvider.swift` (the moved symbols were file-internal). If anything else references them, STOP and reconcile against the spec's "no caller outside the provider changes" claim before proceeding.

- [ ] **Step 3: Ensure the Mapbox token exists in this worktree, then build the app**

```bash
cp -n /Users/rohunjoseph/projects/biking-app/Aura/Resources/MapboxAccessToken Aura/Resources/MapboxAccessToken 2>/dev/null; ls -l Aura/Resources/MapboxAccessToken
```

Then generate and build (delegate to the apple-platform-build-tools builder agent if you are the orchestrator; run directly if you are an implementer subagent):

```bash
cd Aura && xcodegen generate && cd .. && \
xcodebuild build -project Aura/Aura.xcodeproj -scheme Aura \
  -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED` (an empty tail before it is normal with `-quiet`). Any error mentioning `TerrainRGBTile`/`TerrainRGBSampler`/`TerrainTileID` means the package API from Tasks 1/2/4 and this file disagree — fix the app file, not the gated package API.

- [ ] **Step 4: Run the full package suite again (nothing app-side may have leaked in)**

Run: `cd AuraCore && swift test --no-parallel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift
git commit -m "refactor(roh-94): Terrain-RGB provider delegates to the extracted package core

Token guard + URLSession fetch + negative-caching actor stay app-side;
decode/placement/sampling now run the gated package code.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Docs + lint + full verification

**Files:**
- Modify: `docs/superpowers/specs/2026-07-22-e2e-ride-harness-design.md` (line 56 area: the `| Terrain-RGB class in route planning | **Not caught** — ROH-94 |` row)
- Modify: `docs/superpowers/specs/2026-07-22-navigate-golden-ride-design.md` (its equivalent "not caught" row)
- Modify: `docs/ROADMAP.md` (testing section)

**Interfaces:** none — documentation only. Append, don't rewrite: the dated specs stay point-in-time records.

- [ ] **Step 1: Append to the harness spec's row**

In `docs/superpowers/specs/2026-07-22-e2e-ride-harness-design.md`, change the row

```
| Terrain-RGB class in route planning | **Not caught** — ROH-94 |
```

to

```
| Terrain-RGB class in route planning | **Not caught** — ROH-94 (decode/placement/sampling gated since ROH-94, see 2026-07-22-route-elevation-gate-design.md; token guard, fetch, cache, and call-site wiring remain not caught) |
```

- [ ] **Step 2: Append to the navigate spec's equivalent row**

Locate the Terrain-RGB "not caught" row in `docs/superpowers/specs/2026-07-22-navigate-golden-ride-design.md` (`grep -n "ROH-94" docs/superpowers/specs/2026-07-22-navigate-golden-ride-design.md`) and append the same parenthetical.

- [ ] **Step 3: Update ROADMAP**

In `docs/ROADMAP.md`, find the testing section's Terrain-RGB mention (`grep -n -i "terrain" docs/ROADMAP.md`) and append one sentence at the appropriate spot:

```
The route-planning side of the Terrain-RGB lesson is gated as of ROH-94: package tests decode a generated fixture tile and fail if the planning pipeline's elevation ever goes flat (docs/superpowers/specs/2026-07-22-route-elevation-gate-design.md).
```

Match the surrounding prose style; if the section is a table, add a row instead, matching its columns.

- [ ] **Step 4: Lint and full test run**

```bash
swiftlint --strict 2>&1 | tail -5
```
Expected: no violations (exit 0). Fix any new-file violations (likely candidates: line length in comments) without weakening the code.

Run: `cd AuraCore && swift test --no-parallel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-07-22-e2e-ride-harness-design.md docs/superpowers/specs/2026-07-22-navigate-golden-ride-design.md docs/ROADMAP.md
git commit -m "docs(roh-94): close the Terrain-RGB not-caught rows and ROADMAP tale

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Regression drills (spec §7) — prove each gate fires

**Files:**
- Temporarily modify (each reverted): `AuraCore/Sources/AuraKit/Routing/TerrainRGBTile.swift`, `AuraCore/Sources/AuraCore/Routing/TerrainRGBPlacement.swift`

No commits of broken code — each drill is edit → run → capture output → `git checkout` the file.

- [ ] **Step 1: Drill A — all-zero buffer (the historical failure shape)**

In `TerrainRGBTile.init?(pngData:)`, immediately after the `guard drew else { return nil }` line, temporarily add:

```swift
        buf = [UInt8](repeating: 0, count: side * side * 4)  // DRILL A
```

(and move the `self.pixels = buf` assignment after it if needed). Run:

`cd AuraCore && swift test --no-parallel --filter "TerrainFixtureDecodeTests|RoutePlanningElevationGateTests" 2>&1 | tail -15`

Expected: FAILURES in both `fixtureDecodesWithFrozenPixelLiterals` (pixels read −10000) / `fixtureIsNotFlat` AND `gainsMatchFrozenLiteralsAndAreNotFlat` (all gains 0). Save the tail output. Revert: `git checkout AuraCore/Sources/AuraKit/Routing/TerrainRGBTile.swift`

- [ ] **Step 2: Drill B — placement y formula**

In `TerrainRGBPlacement.placement`, temporarily change the `yf` line to:

```swift
        let yf = (1.0 + asinh(tan(latRad)) / .pi) / 2.0 * n  // DRILL B (sign flip)
```

Run: `cd AuraCore && swift test --no-parallel --filter TerrainRGBPlacementTests 2>&1 | tail -10`
Expected: FAILURES in the three landmark placement tests. Save the output. Revert: `git checkout AuraCore/Sources/AuraCore/Routing/TerrainRGBPlacement.swift`

- [ ] **Step 3: Drill C — RGB formula multiplier**

In `TerrainRGBTile.elevation(px:py:)`, temporarily change the return to:

```swift
        return -10000.0 + (r * 65536.0 + g * 256.0 + b) * 0.0  // DRILL C
```

Run: `cd AuraCore && swift test --no-parallel --filter "TerrainRGBTileTests|TerrainFixtureDecodeTests" 2>&1 | tail -10`
Expected: FAILURES in `decodesEncodedElevationsExactly` and the fixture pixel literals. Save the output. Revert: `git checkout AuraCore/Sources/AuraKit/Routing/TerrainRGBTile.swift`

- [ ] **Step 4: Confirm clean tree and green suite**

```bash
git status --porcelain
```
Expected: empty. Then: `cd AuraCore && swift test --no-parallel` → PASS.

- [ ] **Step 5: Record the drill outputs**

Write the three saved failure tails into the scratchpad (`drill-outputs.md`) for the PR body. Do not commit them to the repo.

---

### Task 9: Integrate (PR + merge on green CI)

Follow the repo's default integration flow (memory: push branch + GitHub PR + merge once CI green, then ff local main), and the board flow.

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin claude/route-elevation-gate-terrain-rgb-617af5
```

Then create the PR with `gh pr create` — title `ROH-94: route-planning elevation gate (Terrain-RGB regression class)`, body containing: a summary of the extraction + gates, the three drill output excerpts (Task 8), the live cross-check line (Task 3 Step 6), a link to the spec, and the standard Claude Code attribution footer.

- [ ] **Step 2: Move ROH-94 to In Review** (Linear MCP; the orchestrator does this, not a subagent).

- [ ] **Step 3: Watch CI; merge when green**

```bash
gh pr checks --watch
```
Expected: `AuraCore tests (swift test)` and `App build (xcodebuild)` both pass. Then `gh pr merge --merge`, `git checkout main && git pull` in the main checkout, and ROH-94 → Done.

---

## Self-review notes (performed at plan-writing time)

- Spec coverage: §1 extraction → Tasks 1/2/4/6; §2 fixture + record helper + live cross-check → Task 3; §3 decoder gate + placement checks → Tasks 2/3 + Task 1; §4 ranking gate incl. choreography and honesty note → Task 5; §5 CI/lint → Tasks 5–7; §6 honesty rows → Task 7; §7 drills → Task 8; §8 DoD → Tasks 7–9.
- Type consistency: `TerrainTileID(z:x:y:)`, `TerrainRGBPlacement.placement(lat:lon:z:)`, `TerrainRGBTile(pngData:)`/`elevation(px:py:)`/`side`, `TerrainRGBSampler.elevations(along:zoom:spacingMeters:minSamples:maxSamples:tile:)` are identical in every task that mentions them.
- Known intentional placeholders: the `<literal>`/`<tileX>`-style values are *recorded* values by design (frozen-literal policy) — each has an exact recording step and predicted value; they are not plan gaps.
