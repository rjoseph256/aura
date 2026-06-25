import Foundation
import CoreGraphics
import ImageIO
import AuraCore
import MapboxMaps

/// `AuraCore.ElevationProvider` backed by Mapbox **Terrain-RGB** raster tiles —
/// true per-point elevation (decoded from the RGB-encoded DEM), unlike the contour
/// Tilequery which only returns nearby contour lines. For a route's geometry it
/// samples ~16 evenly-spaced points, decodes each point's elevation from the
/// terrain-rgb tile, and returns them in order so `RouteMetrics.elevationGain` can
/// separate the "Flattest" route.
///
/// BEST-EFFORT: any network/decode/missing-token failure drops the affected sample
/// (or returns []); it never throws. Only a route's relative *deltas* feed elevation
/// gain, so a small absolute offset is harmless.
public struct MapboxTerrainRGBElevationProvider: AuraCore.ElevationProvider {

    private let sampleCount: Int
    private let zoom: Int
    private let tileCache: TerrainTileCache

    public init(sampleCount: Int = 16, zoom: Int = 14, tileCache: TerrainTileCache = .shared) {
        self.sampleCount = sampleCount
        self.zoom = zoom
        self.tileCache = tileCache
    }

    public func elevations(along coordinates: [Coordinate]) async -> [Double] {
        let token = MapboxMaps.MapboxOptions.accessToken
        guard !token.isEmpty else { return [] }

        let indices = ElevationSampling.sampleIndices(total: coordinates.count, count: sampleCount)
        guard !indices.isEmpty else { return [] }
        let sampled = indices.map { coordinates[$0] }

        // Map each sample to its tile + pixel, then warm the cache for all UNIQUE
        // tiles concurrently (a short route usually touches only 1–4 tiles).
        let placements = sampled.map { Self.placement(lat: $0.latitude, lon: $0.longitude, z: zoom) }
        let uniqueTiles = Set(placements.map { TileKey(z: zoom, x: $0.tileX, y: $0.tileY) })

        await withTaskGroup(of: Void.self) { group in
            for tile in uniqueTiles {
                let cache = tileCache
                group.addTask { await cache.warm(tile, token: token) }
            }
            await group.waitForAll()
        }

        // Read each sampled point's elevation from the (now cached) tiles, in order.
        var out: [Double] = []
        out.reserveCapacity(placements.count)
        for p in placements {
            let tile = TileKey(z: zoom, x: p.tileX, y: p.tileY)
            if let e = await tileCache.elevation(tile, px: p.px, py: p.py) {
                out.append(e)
            }
        }
        return out
    }

    // MARK: - Web Mercator tile + pixel placement

    struct Placement { let tileX: Int; let tileY: Int; let px: Int; let py: Int }

    static func placement(lat: Double, lon: Double, z: Int) -> Placement {
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

// `nonisolated` so its (inferred) Hashable conformance is usable from the actor's
// own isolation domain, not only MainActor. It's an immutable Sendable value type,
// so opting out of default MainActor isolation is safe.
nonisolated struct TileKey: Hashable, Sendable { let z: Int; let x: Int; let y: Int }

/// Caches decoded Terrain-RGB tiles (256×256 RGBA byte buffers) so the sampled
/// points of a route — and repeat searches — reuse one fetch+decode per tile.
public actor TerrainTileCache {
    public static let shared = TerrainTileCache()

    /// Decoded RGBA8 pixels (row-major, 4 bytes/px) plus side length, or nil if the
    /// tile failed to load (cached as a negative result to avoid re-fetching).
    ///
    /// Initialized in `init()` rather than via a default literal: under default
    /// MainActor isolation a stored-property default expression is MainActor-isolated,
    /// which can't initialize this actor-isolated storage. Assigning in the actor's
    /// init keeps the initialization inside the actor's isolation domain.
    private var tiles: [TileKey: [UInt8]?]
    private let side = 256

    public init() {
        self.tiles = [:]
    }

    /// Fetches + decodes the tile into the cache if not already present.
    func warm(_ key: TileKey, token: String) async {
        guard tiles[key] == nil else { return }
        tiles[key] = await Self.fetchDecoded(key, token: token, side: side)
    }

    /// The elevation (meters) at a pixel of a cached tile, or nil if unavailable.
    func elevation(_ key: TileKey, px: Int, py: Int) -> Double? {
        guard let entry = tiles[key], let bytes = entry else { return nil }
        let off = (py * side + px) * 4
        guard off + 2 < bytes.count else { return nil }
        let r = Double(bytes[off]), g = Double(bytes[off + 1]), b = Double(bytes[off + 2])
        return -10000.0 + (r * 65536.0 + g * 256.0 + b) * 0.1
    }

    /// Downloads a terrain-rgb tile and decodes it into a deterministic RGBA8 buffer.
    /// Keep this a `nonisolated static func` (it must stay off the main actor): the
    /// CGImage decode is CPU-bound, and under default MainActor isolation an instance
    /// method here would hop onto the main actor and could jank map rendering.
    private static func fetchDecoded(_ key: TileKey, token: String, side: Int) async -> [UInt8]? {
        let urlStr = "https://api.mapbox.com/v4/mapbox.terrain-rgb/\(key.z)/\(key.x)/\(key.y).pngraw?access_token=\(token)"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            // Render into a known RGBA8 buffer so byte order is deterministic across
            // source pixel formats (premultiply by opaque alpha is identity for DEM).
            var buf = [UInt8](repeating: 0, count: side * side * 4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: &buf, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
            return buf
        } catch {
            return nil
        }
    }
}
