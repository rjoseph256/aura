import AuraCore
import AuraKit

/// Single-leg cycling route to a gem, via the shipped `MapboxRoutingProvider`. A throw
/// (offline / no route) drives the controller's `headingOnly` fallback.
public struct MapboxDetourRouting: DetourRouting {
    public init() {}
    public func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route {
        let request = RouteRequest(origin: origin, destination: destination)
        let routes = try await MapboxRoutingProvider().routes(for: request)
        guard let best = routes.first else { throw DetourRoutingError.noRoute }
        return best
    }
}

enum DetourRoutingError: Error { case noRoute }
