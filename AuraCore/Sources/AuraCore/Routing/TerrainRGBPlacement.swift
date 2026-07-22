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
