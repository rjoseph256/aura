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
/// Truth literals are derived FROM THIS FUNCTION — independent of
/// `TerrainRGBTile` and `TerrainRGBSampler`, the components under test (they
/// do pass through the separately unit-tested `ElevationSampling` and
/// `RouteMetrics`) — via the TERRAIN_FIXTURE_RECORD=1 helper. Re-record
/// procedure: any intentional change to this DEM, the routes, sampling, or the
/// formula regenerates the PNG and re-pastes every literal in the same commit.
enum TerrainFixture {

    /// Recorded in Task 1 from the independent slippy-map formula.
    static let tileID = TerrainTileID(z: 14, x: 4552, y: 6177)

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
