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
