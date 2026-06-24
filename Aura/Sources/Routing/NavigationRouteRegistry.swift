import Foundation
import MapboxNavigationCore
import AuraCore

/// Bridges the pure AuraCore.Route the user selects in preview to the Mapbox
/// NavigationRoutes needed to actually navigate THAT route (instead of re-fetching).
@MainActor
final class NavigationRouteRegistry {
    static let shared = NavigationRouteRegistry()
    private init() {}

    private(set) var navigationRoutes: NavigationRoutes?
    private var mbRouteIndexByRouteId: [UUID: Int] = [:]

    func record(navigationRoutes: NavigationRoutes, mbRouteIndexByRouteId: [UUID: Int]) {
        self.navigationRoutes = navigationRoutes
        self.mbRouteIndexByRouteId = mbRouteIndexByRouteId
    }

    /// The fetched routes plus the mbRoutes index (0 = main) for the given AuraCore.Route, if known.
    func entry(for routeId: UUID) -> (routes: NavigationRoutes, mbRouteIndex: Int)? {
        guard let routes = navigationRoutes, let idx = mbRouteIndexByRouteId[routeId] else { return nil }
        return (routes, idx)
    }
}
