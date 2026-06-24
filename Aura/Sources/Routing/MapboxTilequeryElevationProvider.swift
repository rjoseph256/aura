import Foundation
import AuraCore
import MapboxMaps

/// `AuraCore.ElevationProvider` backed by the Mapbox Tilequery API against the
/// `mapbox.mapbox-terrain-v2` tileset. For a route's geometry it samples ~12
/// evenly-spaced points and reads the terrain contour elevation at each, feeding
/// `RouteMetrics.elevationGain` so `RouteRanker` can separate the "Flattest" route.
///
/// BEST-EFFORT by contract: any network/decode/missing-token failure is swallowed
/// and the affected sample is dropped. The method never throws and returns whatever
/// elevations it managed to fetch (possibly `[]`, which callers treat as "flat").
public struct MapboxTilequeryElevationProvider: AuraCore.ElevationProvider {

    /// How many points to sample along a route before querying.
    private let sampleCount: Int
    /// Max in-flight Tilequery requests (bounds latency without hammering the API).
    private let maxConcurrent: Int
    /// Process-wide cache so the 3 candidate routes (and repeat searches) dedupe
    /// overlapping sample points instead of re-fetching.
    private let cache: ElevationCache

    public init(sampleCount: Int = 12,
                maxConcurrent: Int = 6,
                cache: ElevationCache = .shared) {
        self.sampleCount = sampleCount
        self.maxConcurrent = maxConcurrent
        self.cache = cache
    }

    public func elevations(along coordinates: [Coordinate]) async -> [Double] {
        // Token is configured at launch (AuraApp.configureMapbox). If missing, bail.
        let token = MapboxMaps.MapboxOptions.accessToken
        guard !token.isEmpty else { return [] }

        // Downsample to a bounded set of evenly-spaced points.
        let indices = ElevationSampling.sampleIndices(total: coordinates.count, count: sampleCount)
        guard !indices.isEmpty else { return [] }
        let sampled: [Coordinate] = indices.map { coordinates[$0] }

        // Fetch each sample's elevation concurrently with a small in-flight cap,
        // tagging each result with its sample position so we can re-order. Failed
        // samples are dropped (nil) rather than zero-filled.
        var results = [Double?](repeating: nil, count: sampled.count)

        await withTaskGroup(of: (Int, Double?).self) { group in
            var nextIndex = 0
            let inFlightCap = max(1, maxConcurrent)

            // Seed the group up to the cap.
            while nextIndex < sampled.count && nextIndex < inFlightCap {
                let i = nextIndex
                let coord = sampled[i]
                group.addTask { (i, await Self.elevation(at: coord, token: token, cache: cache)) }
                nextIndex += 1
            }

            // As each finishes, record it and enqueue the next pending sample.
            while let (i, value) = await group.next() {
                results[i] = value
                if nextIndex < sampled.count {
                    let j = nextIndex
                    let coord = sampled[j]
                    group.addTask { (j, await Self.elevation(at: coord, token: token, cache: cache)) }
                    nextIndex += 1
                }
            }
        }

        // Preserve sample ORDER; drop the points that failed.
        return results.compactMap { $0 }
    }

    // MARK: - Single-point Tilequery

    /// Resolves the contour elevation (meters) at a single coordinate, using the
    /// shared cache. Returns nil on any error (network, decode, no feature / no `ele`).
    private static func elevation(at coordinate: Coordinate,
                                  token: String,
                                  cache: ElevationCache) async -> Double? {
        let key = ElevationCache.key(for: coordinate)
        if let cached = await cache.value(for: key) {
            return cached
        }

        guard let url = tilequeryURL(for: coordinate, token: token) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let elevation = parseElevation(from: data) else { return nil }
            await cache.set(elevation, for: key)
            return elevation
        } catch {
            // Best-effort: any failure means "no data for this sample".
            return nil
        }
    }

    /// Builds the Tilequery URL for a single coordinate against the terrain
    /// contour layer. Coordinates are encoded `lon,lat` with high precision.
    private static func tilequeryURL(for coordinate: Coordinate, token: String) -> URL? {
        // ~6 decimals (≈ 0.1 m) is plenty of precision for terrain sampling.
        let lon = String(format: "%.6f", coordinate.longitude)
        let lat = String(format: "%.6f", coordinate.latitude)

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.mapbox.com"
        components.path = "/v4/mapbox.mapbox-terrain-v2/tilequery/\(lon),\(lat).json"
        components.queryItems = [
            URLQueryItem(name: "layers", value: "contour"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "access_token", value: token),
        ]
        return components.url
    }

    /// Parses the GeoJSON FeatureCollection and reads `features[0].properties.ele`
    /// (meters). Returns nil if there is no feature or no numeric `ele`.
    private static func parseElevation(from data: Data) -> Double? {
        struct FeatureCollection: Decodable {
            struct Feature: Decodable {
                struct Properties: Decodable { let ele: Double? }
                let properties: Properties
            }
            let features: [Feature]
        }

        guard let decoded = try? JSONDecoder().decode(FeatureCollection.self, from: data),
              let first = decoded.features.first,
              let ele = first.properties.ele else {
            return nil
        }
        return ele
    }
}

/// In-process, Sendable elevation cache keyed by coordinate rounded to ~5 decimals
/// (≈ 1 m), so overlapping samples across the 3 candidate routes and repeated
/// searches reuse a single Tilequery call. An `actor` gives us Sendable-correct,
/// data-race-free access without a manual lock.
public actor ElevationCache {
    public static let shared = ElevationCache()

    private var storage: [String: Double] = [:]

    public init() {}

    func value(for key: String) -> Double? { storage[key] }

    func set(_ value: Double, for key: String) { storage[key] = value }

    /// Rounds to 5 decimals (~1.1 m at the equator) so near-identical sample
    /// points collapse to the same cache entry.
    static func key(for coordinate: Coordinate) -> String {
        let lat = (coordinate.latitude * 100_000).rounded() / 100_000
        let lon = (coordinate.longitude * 100_000).rounded() / 100_000
        return "\(lat),\(lon)"
    }
}
