import Foundation

/// A raw routing alternative before it has been labeled with a user-facing profile.
public struct CandidateRoute: Equatable, Sendable {
    public var geometry: [Coordinate]
    public var distanceMeters: Double
    public var estimatedDurationSeconds: Double
    public var elevationGainMeters: Double
    public var walkFraction: Double   // 0...1 — distance-weighted share you must walk (push the bike)
    public var elevationProfile: [Double]  // sampled elevations along geometry (for the sparkline)

    public init(geometry: [Coordinate], distanceMeters: Double, estimatedDurationSeconds: Double,
                elevationGainMeters: Double, walkFraction: Double, elevationProfile: [Double] = []) {
        self.geometry = geometry; self.distanceMeters = distanceMeters
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.elevationGainMeters = elevationGainMeters; self.walkFraction = walkFraction
        self.elevationProfile = elevationProfile
    }
}

/// A labeled `Route` paired with the index of the `candidates` entry it was chosen from.
/// Lets a caller (e.g. the Mapbox provider) map a labeled route back to its source route
/// by identity instead of by fragile value matching on distance/coordinates.
public struct LabeledRoute: Equatable, Sendable {
    public let route: Route
    public let sourceIndex: Int

    public init(route: Route, sourceIndex: Int) {
        self.route = route
        self.sourceIndex = sourceIndex
    }
}

public enum RouteRanker {
    /// Picks the best candidate for each profile and returns up to 3 distinct labeled
    /// routes, each carrying the index of the `candidates` entry it came from.
    /// Label priority when one candidate wins multiple criteria: mostPaths > flattest > fastest.
    public static func labeled(origin: Coordinate, destination: Coordinate,
                               candidates: [CandidateRoute]) -> [LabeledRoute] {
        guard !candidates.isEmpty else { return [] }

        // (profile, winning index) in priority order. "Most paths" goes to the most
        // rideable candidate — the one with the least forced walking — since a
        // dismount-and-push segment is a negative signal, not a positive one.
        let winners: [(Route.Profile, Int)] = [
            (.mostPaths, indexOfMin(candidates) { $0.walkFraction }),
            (.flattest, indexOfMin(candidates) { $0.elevationGainMeters }),
            (.fastest, indexOfMin(candidates) { $0.estimatedDurationSeconds })
        ]

        var usedIndices = Set<Int>()
        var result: [LabeledRoute] = []
        for (profile, idx) in winners where !usedIndices.contains(idx) {
            usedIndices.insert(idx)
            let c = candidates[idx]
            let route = Route(origin: origin, destination: destination, waypoints: [],
                              geometry: c.geometry, profile: profile,
                              distanceMeters: c.distanceMeters,
                              estimatedDurationSeconds: c.estimatedDurationSeconds,
                              elevationGainMeters: c.elevationGainMeters,
                              elevationProfile: c.elevationProfile)
            result.append(LabeledRoute(route: route, sourceIndex: idx))
        }
        return result
    }

    /// Picks the best candidate for each profile and returns up to 3 distinct labeled Routes.
    /// Label priority when one candidate wins multiple criteria: mostPaths > flattest > fastest.
    public static func label(origin: Coordinate, destination: Coordinate,
                             candidates: [CandidateRoute]) -> [Route] {
        labeled(origin: origin, destination: destination, candidates: candidates).map(\.route)
    }

    private static func indexOfMin(_ items: [CandidateRoute], _ key: (CandidateRoute) -> Double) -> Int {
        var best = 0
        for i in items.indices where key(items[i]) < key(items[best]) { best = i }
        return best
    }
}
