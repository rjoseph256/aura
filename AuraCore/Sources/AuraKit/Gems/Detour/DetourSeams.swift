import AuraCore

/// Fetches a single-leg cycling route to a gem. App concrete wraps `MapboxRoutingProvider`;
/// a throw (offline / no route) drives the machine's `routeFailedOffline`.
public protocol DetourRouting: Sendable {
    func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route
}

/// Streams the device compass heading in degrees (true north). App concrete wraps CLHeading
/// (`#if os(iOS)`); a non-iOS stub yields nothing. Protocol stays CoreLocation-free (macOS CI).
public protocol HeadingProviding: Sendable {
    func headings() -> AsyncStream<Double>
}

/// The narrow face the coordinator sees — keeps `RideSessionCoordinator` free of the concrete
/// controller and testable with a fake.
public protocol GuidanceControlling: AnyObject {
    @MainActor var isDetouring: Bool { get }
    @MainActor var isGuiding: Bool { get }
    @MainActor func riderDidUpdate(_ point: TrackPoint)
    @MainActor func detach()
}
