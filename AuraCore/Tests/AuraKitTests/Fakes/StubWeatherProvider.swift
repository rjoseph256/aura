import Foundation
@testable import AuraKit
import AuraCore

/// Test double for `WeatherProviding`. `@MainActor` (so it is `Sendable` without an
/// `@unchecked` escape hatch); `result` is a mutable `var` so a test can flip success→failure
/// between refreshes. All access is from `@MainActor` test methods, so `callCount` is race-free.
@MainActor final class StubWeatherProvider: WeatherProviding {
    var result: Result<WeatherSnapshot, Error>
    private(set) var callCount = 0

    init(_ result: Result<WeatherSnapshot, Error>) { self.result = result }

    func currentConditions(for coordinate: Coordinate) async throws -> WeatherSnapshot {
        callCount += 1
        return try result.get()
    }
}

struct StubError: Error {}
