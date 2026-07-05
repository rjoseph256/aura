import Foundation
import AuraCore

/// OSM Overpass live feed. Pure URLSession (no Mapbox), so it lives in AuraKit and is
/// unit-testable. Any failure — offline, non-200, decode error — yields `[]`; discovery
/// silently falls back to curated + personal. Live gems are photoless and ≤ Tier 2.
///
/// Region-cached: results for a given cell are reused for `stalenessSeconds` (see
/// `GemRegionCache`) so a ride only pays for one Overpass round trip per region, not one
/// per `gems(near:)` call. Combined with `GemDiscoveryStore.load()` firing once per ride,
/// v1 behavior is "live POIs fetched at ride start, cached for repeat queries" — refetching
/// as the rider moves into a new region within the same ride is a future enhancement.
public struct LiveGemProvider: GemProviding {
    private let session: URLSession
    private let radiusMeters: Double
    private let endpoint: URL
    private let cache: GemRegionCache
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, radiusMeters: Double = 1500,
                endpoint: URL = OSMOverpass.defaultEndpoint,
                cache: GemRegionCache = GemRegionCache(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.radiusMeters = radiusMeters
        self.endpoint = endpoint
        self.cache = cache
        self.now = now
    }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
        await cache.gems(near: coordinate, now: now()) {
            let request = OSMOverpass.request(near: coordinate, radiusMeters: radiusMeters, endpoint: endpoint)
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            return OSMOverpass.elements(from: data).compactMap {
                OSMGemMapping.gem(id: $0.id, name: $0.name, coordinate: $0.coordinate, tags: $0.tags)
            }
        }
    }
}
