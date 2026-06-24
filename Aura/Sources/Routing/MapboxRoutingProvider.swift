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

    /// Best-effort terrain elevation source. Defaults to the Mapbox Tilequery
    /// impl; swap for a `NullElevationProvider` (or a future Valhalla/BRouter
    /// engine) without touching callers.
    private let elevationProvider: any AuraCore.ElevationProvider

    public init(elevationProvider: any AuraCore.ElevationProvider = MapboxTerrainRGBElevationProvider()) {
        self.elevationProvider = elevationProvider
    }

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

        // 6. Fetch terrain elevations for all candidates CONCURRENTLY (so the
        //    total added latency ≈ one route's sampling, not the sum), then map
        //    each Mapbox route → AuraCore.CandidateRoute with its real climb.
        let geometries: [[AuraCore.Coordinate]] = mbRoutes.map { mbRoute in
            mbRoute.shape?.coordinates.map {
                AuraCore.Coordinate(latitude: $0.latitude, longitude: $0.longitude)
            } ?? []
        }
        let elevationProvider = self.elevationProvider
        var elevationsByIndex = [[Double]](repeating: [], count: geometries.count)
        await withTaskGroup(of: (Int, [Double]).self) { group in
            for (i, geometry) in geometries.enumerated() {
                group.addTask { (i, await elevationProvider.elevations(along: geometry)) }
            }
            for await (i, elevs) in group {
                elevationsByIndex[i] = elevs
            }
        }

        let candidates: [AuraCore.CandidateRoute] = mbRoutes.enumerated().map { (i, mbRoute) in
            candidateRoute(from: mbRoute, geometry: geometries[i], elevations: elevationsByIndex[i])
        }

        guard !candidates.isEmpty else {
            throw RoutingError.noRoutes
        }

        // 7. Rank and label candidates → up to 3 distinct AuraCore.Route values.
        let labeled = AuraCore.RouteRanker.label(
            origin: request.origin,
            destination: request.destination,
            candidates: candidates
        )

        // 8. Correlate each labeled AuraCore.Route back to its mbRoutes index
        //    (0 = main, k = alternativeRoutes[k-1]) by matching distance AND the
        //    first geometry coordinate (to break ties), then record the mapping so
        //    the ride can navigate THAT exact Mapbox route instead of re-fetching.
        var indexByRouteId: [UUID: Int] = [:]
        for route in labeled {
            if let i = mbRoutes.firstIndex(where: { mb in
                mb.distance == route.distanceMeters &&
                mb.shape?.coordinates.first.map { abs($0.latitude - (route.geometry.first?.latitude ?? .nan)) < 1e-9
                                               && abs($0.longitude - (route.geometry.first?.longitude ?? .nan)) < 1e-9 } ?? false
            }) {
                indexByRouteId[route.id] = i
            }
        }
        let routesToRecord = navigationRoutes
        let indexByRouteIdToRecord = indexByRouteId
        await MainActor.run {
            NavigationRouteRegistry.shared.record(navigationRoutes: routesToRecord, mbRouteIndexByRouteId: indexByRouteIdToRecord)
        }

        return labeled
    }

    // MARK: - Private helpers

    /// Converts a single `MapboxDirections.Route` into an `AuraCore.CandidateRoute`,
    /// using the precomputed `geometry` and best-effort `elevations` sampled along it.
    private func candidateRoute(from mbRoute: MapboxDirections.Route,
                                geometry: [AuraCore.Coordinate],
                                elevations: [Double]) -> AuraCore.CandidateRoute {
        // --- distance & duration (reliable; always present in the Directions response) ---
        let distanceMeters = mbRoute.distance
        let durationSeconds = mbRoute.expectedTravelTime

        // --- elevationGainMeters (best-effort) ---
        // `elevations` is sampled along the geometry by the ElevationProvider (Mapbox
        // Tilequery terrain contours). It may be empty on any network/parse failure or
        // missing token, in which case elevationGain is 0 — the prior behavior — and
        // "Flattest" simply has no signal to separate on. With data, RouteRanker can
        // meaningfully pick the flattest candidate.
        let elevationGain = RouteMetrics.elevationGain(elevations: elevations)

        // --- walkFraction (best-effort from step transportType) ---
        // Each RouteStep's `.transportType` identifies the travel mode. On a cycling
        // profile, `.walking` means you must dismount and push the bike (stairs,
        // pedestrian-only links); `.cycling` is normal riding. A higher walk fraction
        // is a *worse* route to ride, so RouteRanker uses it as a penalty when picking
        // the "Most paths" (most rideable) option, not a reward.
        //
        // NOTE: This is the only path/road signal the Directions response exposes
        //       without the annotations extension or an OSM-tag-aware engine; it can
        //       only penalize forced walking, not reward dedicated bike paths (those
        //       come back as ordinary `.cycling` steps). Richer classification is a
        //       future step (see docs/ROADMAP.md).
        let walk = walkFraction(for: mbRoute)

        return AuraCore.CandidateRoute(
            geometry: geometry,
            distanceMeters: distanceMeters,
            estimatedDurationSeconds: durationSeconds,
            elevationGainMeters: elevationGain,
            walkFraction: walk,
            elevationProfile: elevations
        )
    }

    /// Derives a distance-weighted walk (forced-dismount) fraction from step transport types.
    private func walkFraction(for route: MapboxDirections.Route) -> Double {
        var segments: [(distanceMeters: Double, isWalking: Bool)] = []

        for leg in route.legs {
            for step in leg.steps {
                // On a cycling profile, `.walking` is a forced dismount (pushing the
                // bike); everything else (cycling, and the rare ferry/automobile leg)
                // is ridden, so it does not count toward the walk fraction.
                let isWalking = step.transportType == .walking
                segments.append((distanceMeters: step.distance, isWalking: isWalking))
            }
        }

        return RouteMetrics.walkFraction(segments: segments)
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
