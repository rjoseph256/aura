import Foundation

/// Pure, timestamp-driven discovery logic. This slice implements only the ambient
/// layer: which gems are visible as pins near a location, capped to the nearest N.
public struct GemDiscoveryEngine: Sendable {
    public let proximityRadiusMeters: Double
    public let pinCap: Int

    public init(proximityRadiusMeters: Double = 1500, pinCap: Int = 10) {
        self.proximityRadiusMeters = proximityRadiusMeters
        self.pinCap = pinCap
    }

    /// Gems within `proximityRadiusMeters` of `location`, nearest first, capped to `pinCap`.
    public func visiblePins(from candidates: [Gem], at location: Coordinate) -> [Gem] {
        candidates
            .map { ($0, Geo.distance($0.coordinate, location)) }
            .filter { $0.1 <= proximityRadiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(pinCap)
            .map(\.0)
    }
}
