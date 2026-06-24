import CoreLocation
import MapboxCommon
import MapboxDirections
import MapboxNavigationCore
import AuraCore
import AuraKit

// NOTE on naming clash:
// MapboxNavigationCore defines its own `RoutingProvider` protocol and a concrete
// class also named `MapboxRoutingProvider`.  Our type conforms to
// `AuraCore.RoutingProvider` and is explicitly module-qualified throughout to
// avoid ambiguity.

/// Concrete `AuraCore.RoutingProvider` backed by the Mapbox Navigation v3 SDK.
///
/// Usage:
/// ```swift
/// let provider = MapboxRoutingProvider()
/// let routes   = try await provider.routes(for: request)
/// ```
public struct MapboxRoutingProvider: AuraCore.RoutingProvider {

    public init() {}

    // MARK: - AuraCore.RoutingProvider

    public func routes(for request: AuraCore.RouteRequest) async throws -> [AuraCore.Route] {

        // 1. Build Mapbox Waypoints (origin → intermediate → destination).
        var allCoords: [AuraCore.Coordinate] = [request.origin]
        allCoords.append(contentsOf: request.waypoints)
        allCoords.append(request.destination)

        let mapboxWaypoints: [MapboxDirections.Waypoint] = allCoords.map { coord in
            MapboxDirections.Waypoint(
                coordinate: CLLocationCoordinate2D(
                    latitude: coord.latitude,
                    longitude: coord.longitude
                )
            )
        }

        // 2. Build cycling route options requesting alternative routes.
        let options = NavigationRouteOptions(
            waypoints: mapboxWaypoints,
            profileIdentifier: .cycling
        )
        options.includesAlternativeRoutes = true
        // Request full-resolution polyline so geometry is detailed.
        options.shapeFormat = .polyline6

        // 3. Obtain the shared navigation provider and calculate routes.
        //
        //    AuraNavigation.provider is the process-level singleton for the Mapbox
        //    v3 stack — constructing a second MapboxNavigationProvider would crash.
        //    We hop to MainActor to call routingProvider() (which is @MainActor-
        //    isolated), then await the FetchTask outside the hop.
        let fetchTask: MapboxNavigationCore.RoutingProvider.FetchTask =
            await MainActor.run {
                AuraNavigation.provider.mapboxNavigation.routingProvider()
                    .calculateRoutes(options: options)
            }

        // 4. Await the result outside the main-actor hop.
        let navigationRoutes: NavigationRoutes = try await fetchTask.value

        // 5. Collect all returned MapboxDirections.Route objects.
        var mbRoutes: [MapboxDirections.Route] = [navigationRoutes.mainRoute.route]
        for alt in navigationRoutes.alternativeRoutes {
            mbRoutes.append(alt.route)
        }

        // 6. Map each Mapbox route → AuraCore.CandidateRoute.
        let candidates: [AuraCore.CandidateRoute] = mbRoutes.map { mbRoute in
            candidateRoute(from: mbRoute)
        }

        guard !candidates.isEmpty else {
            throw RoutingError.noRoutes
        }

        // 7. Rank and label candidates → up to 3 distinct AuraCore.Route values.
        return AuraCore.RouteRanker.label(
            origin: request.origin,
            destination: request.destination,
            candidates: candidates
        )
    }

    // MARK: - Private helpers

    /// Converts a single `MapboxDirections.Route` into an `AuraCore.CandidateRoute`.
    private func candidateRoute(from mbRoute: MapboxDirections.Route) -> AuraCore.CandidateRoute {
        // --- geometry (required; from LineString shape) ---
        let geometry: [AuraCore.Coordinate] = mbRoute.shape?.coordinates.map {
            AuraCore.Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        } ?? []

        // --- distance & duration (reliable; always present in the Directions response) ---
        let distanceMeters = mbRoute.distance
        let durationSeconds = mbRoute.expectedTravelTime

        // --- elevationGainMeters (best-effort) ---
        // The standard Mapbox Directions API does not return an elevation profile
        // via the Swift SDK attributes. Returning 0 here; a future task should
        // integrate a terrain/elevation source (e.g. Mapbox Tilequery or a
        // Valhalla/BRouter engine that natively provides elevation profiles).
        // TODO: wire a real elevation source so RouteRanker can meaningfully
        //       separate "flattest" candidates.
        let elevationGain = RouteMetrics.elevationGain(elevations: [])

        // --- offRoadFraction (best-effort from step transportType) ---
        // Each RouteStep's `.transportType` identifies the travel mode.  For a
        // cycling profile, `.cycling` == on-road/path, `.walking` == pushing the
        // bike (treated as off-road / non-motor path), and anything else is handled
        // conservatively.
        //
        // NOTE: Richer classification (OSM path tags, road classes) requires the
        //       Mapbox Directions annotations extension or an OSM-tag-aware engine.
        //       This v1 proxy gives *some* signal so RouteRanker has something to
        //       differentiate on, but may collapse the "mostPaths" label to
        //       whichever candidate has the most walking steps.
        let offRoad = offRoadFraction(for: mbRoute)

        return AuraCore.CandidateRoute(
            geometry: geometry,
            distanceMeters: distanceMeters,
            estimatedDurationSeconds: durationSeconds,
            elevationGainMeters: elevationGain,
            offRoadFraction: offRoad
        )
    }

    /// Derives a distance-weighted off-road fraction from step transport types.
    private func offRoadFraction(for route: MapboxDirections.Route) -> Double {
        var segments: [(distanceMeters: Double, isOffRoad: Bool)] = []

        for leg in route.legs {
            for step in leg.steps {
                let isOffRoad: Bool
                switch step.transportType {
                case .walking:
                    // "pushing bike" in Directions v5 maps to .walking — treat as off-road.
                    isOffRoad = true
                case .cycling:
                    // On a cycling profile this is normal on-road/path cycling.
                    isOffRoad = false
                default:
                    // Ferry, train, automobile segments — not off-road trails.
                    isOffRoad = false
                }
                segments.append((distanceMeters: step.distance, isOffRoad: isOffRoad))
            }
        }

        return RouteMetrics.offRoadFraction(segments: segments)
    }
}

// MARK: - Errors

enum RoutingError: Error, LocalizedError {
    case noRoutes

    var errorDescription: String? {
        switch self {
        case .noRoutes:
            return "The routing service returned no viable routes for the given request."
        }
    }
}
