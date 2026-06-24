import Foundation

/// A raw routing alternative before it has been labeled with a user-facing profile.
public struct CandidateRoute: Equatable, Sendable {
    public var geometry: [Coordinate]
    public var distanceMeters: Double
    public var estimatedDurationSeconds: Double
    public var elevationGainMeters: Double
    public var offRoadFraction: Double   // 0...1 — share of the route on paths/trails

    public init(geometry: [Coordinate], distanceMeters: Double, estimatedDurationSeconds: Double,
                elevationGainMeters: Double, offRoadFraction: Double) {
        self.geometry = geometry; self.distanceMeters = distanceMeters
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.elevationGainMeters = elevationGainMeters; self.offRoadFraction = offRoadFraction
    }
}

public enum RouteRanker {
    /// Picks the best candidate for each profile and returns up to 3 distinct labeled Routes.
    /// Label priority when one candidate wins multiple criteria: mostPaths > flattest > fastest.
    public static func label(origin: Coordinate, destination: Coordinate,
                             candidates: [CandidateRoute]) -> [Route] {
        guard !candidates.isEmpty else { return [] }

        // (profile, winning index) in priority order.
        let winners: [(Route.Profile, Int)] = [
            (.mostPaths, indexOfMax(candidates) { $0.offRoadFraction }),
            (.flattest, indexOfMin(candidates) { $0.elevationGainMeters }),
            (.fastest, indexOfMin(candidates) { $0.estimatedDurationSeconds }),
        ]

        var usedIndices = Set<Int>()
        var routes: [Route] = []
        for (profile, idx) in winners where !usedIndices.contains(idx) {
            usedIndices.insert(idx)
            let c = candidates[idx]
            routes.append(Route(origin: origin, destination: destination, waypoints: [],
                                geometry: c.geometry, profile: profile,
                                distanceMeters: c.distanceMeters,
                                estimatedDurationSeconds: c.estimatedDurationSeconds,
                                elevationGainMeters: c.elevationGainMeters))
        }
        return routes
    }

    private static func indexOfMin(_ items: [CandidateRoute], _ key: (CandidateRoute) -> Double) -> Int {
        var best = 0
        for i in items.indices where key(items[i]) < key(items[best]) { best = i }
        return best
    }
    private static func indexOfMax(_ items: [CandidateRoute], _ key: (CandidateRoute) -> Double) -> Int {
        var best = 0
        for i in items.indices where key(items[i]) > key(items[best]) { best = i }
        return best
    }
}
