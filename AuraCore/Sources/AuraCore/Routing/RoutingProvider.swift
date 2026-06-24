/// The swappable routing interface. v1 ships a Mapbox-backed implementation (Plan 3);
/// a self-hosted Valhalla/BRouter implementation can replace it without touching callers.
public protocol RoutingProvider: Sendable {
    func routes(for request: RouteRequest) async throws -> [Route]
}

/// Test/dev double.
public struct MockRoutingProvider: RoutingProvider {
    public var result: [Route]
    public var error: Error?

    public init(result: [Route] = [], error: Error? = nil) {
        self.result = result; self.error = error
    }

    public func routes(for request: RouteRequest) async throws -> [Route] {
        if let error { throw error }
        return result
    }
}
