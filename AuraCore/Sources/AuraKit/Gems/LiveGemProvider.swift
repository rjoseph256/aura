import Foundation
import AuraCore

/// OSM Overpass live feed. Pure URLSession (no Mapbox), so it lives in AuraKit and is
/// unit-testable. Any failure — offline, non-200, decode error — yields `[]`; discovery
/// silently falls back to curated + personal. Live gems are photoless and ≤ Tier 2.
public struct LiveGemProvider: GemProviding {
    private let session: URLSession
    private let radiusMeters: Double
    private let endpoint: URL

    public init(session: URLSession = .shared, radiusMeters: Double = 1500,
                endpoint: URL = OSMOverpass.defaultEndpoint) {
        self.session = session
        self.radiusMeters = radiusMeters
        self.endpoint = endpoint
    }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
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
