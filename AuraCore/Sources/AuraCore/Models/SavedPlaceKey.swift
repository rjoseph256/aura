import Foundation

/// Identity for "is this spot already saved": coordinates bucketed at 5
/// decimal places (~1.1 m). Never compare raw Doubles across Mapbox code
/// paths — the RouteRanker sourceIndex fix is the precedent.
public struct SavedPlaceKey: Hashable, Sendable {
    public let latE5: Int
    public let lonE5: Int

    public init(_ coordinate: Coordinate) {
        latE5 = Int((coordinate.latitude * 100_000).rounded())
        lonE5 = Int((coordinate.longitude * 100_000).rounded())
    }
}
