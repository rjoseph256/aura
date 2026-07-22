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
    /// `TerrainRGBTile`. Explicitly `nonisolated` (it must stay off the main
    /// actor): the decode is CPU-bound, and under the app's default MainActor
    /// isolation a member here could otherwise hop onto the main actor and
    /// jank map rendering.
    nonisolated private static func fetchDecoded(_ id: TerrainTileID, token: String) async -> TerrainRGBTile? {
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
