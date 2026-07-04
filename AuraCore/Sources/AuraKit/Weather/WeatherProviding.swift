import AuraCore

/// Seam over the weather backend. `Sendable` so the nonisolated app-target provider can run
/// the fetch off the main actor and hand back a `Sendable` `WeatherSnapshot`. AuraKit never
/// imports WeatherKit — only the app-target `WeatherKitProvider` conforms with the real service.
public protocol WeatherProviding: Sendable {
    func currentConditions(for coordinate: Coordinate) async throws -> WeatherSnapshot
}
