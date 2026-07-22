import Foundation
import Testing
import ImageIO
import CoreGraphics
import AuraCore
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

/// Gate over the COMMITTED fixture tile (ROH-94). Literals recorded via
/// TERRAIN_FIXTURE_RECORD=1 from the DEM function — independent of the
/// decode under test. Fixture: z14 tile (4552, 6177), generated
/// 2026-07-22 (see TerrainFixture).
struct TerrainFixtureDecodeTests {

    @Test func fixtureDecodesWithFrozenPixelLiterals() throws {
        let tile = try TerrainFixture.decodedTile()
        // Transpose-distinct check pixels; ±0.5 m against 0.1 m quantization.
        #expect(abs(try #require(tile.elevation(px: 10, py: 200)) - 348.0) < 0.5)
        #expect(abs(try #require(tile.elevation(px: 200, py: 10)) - 405.0) < 0.5)
        #expect(abs(try #require(tile.elevation(px: 50, py: 116)) - 220.0) < 0.5)
        #expect(abs(try #require(tile.elevation(px: 250, py: 250)) - 565.0) < 0.5)
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
