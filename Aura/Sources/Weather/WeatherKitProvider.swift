import Foundation
import CoreLocation
import WeatherKit
import AuraCore
import AuraKit

/// The only file that imports WeatherKit. Fetches current conditions and maps WeatherKit's
/// `WeatherCondition` onto Aura's neutral `AuraWeatherCondition` (default `.unknown`), so the
/// package layers stay WeatherKit-free. No stored state → trivially `Sendable`; the fetch runs
/// off the caller's actor.
final class WeatherKitProvider: WeatherProviding {
    func currentConditions(for coordinate: Coordinate) async throws -> WeatherSnapshot {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let current = try await WeatherService.shared.weather(for: location, including: .current)
        return WeatherSnapshot(
            temperature: current.temperature,
            condition: Self.map(current.condition),
            asOf: Date(),
            coordinate: coordinate)
    }

    // Exhaustive WeatherKit→neutral map; cyclomatic complexity is the wrong metric for a flat switch.
    // swiftlint:disable cyclomatic_complexity
    /// Total map from WeatherKit conditions to Aura's neutral set. `@unknown default` catches
    /// any case not listed (including future SDK additions) as `.unknown`.
    static func map(_ c: WeatherCondition) -> AuraWeatherCondition {
        switch c {
        case .clear: return .clear
        case .mostlyClear: return .mostlyClear
        case .partlyCloudy, .mostlyCloudy: return .mostlyCloudy
        case .cloudy: return .cloudy
        case .foggy, .haze, .smoky: return .fog
        case .drizzle, .freezingDrizzle: return .drizzle
        case .rain, .sunShowers, .freezingRain: return .rain
        case .heavyRain: return .heavyRain
        case .thunderstorms, .strongStorms, .isolatedThunderstorms, .scatteredThunderstorms,
             .tropicalStorm, .hurricane: return .thunderstorm
        case .snow, .flurries, .heavySnow, .sunFlurries, .blowingSnow, .blizzard,
             .wintryMix: return .snow
        case .sleet: return .sleet
        case .hail: return .hail
        case .windy, .breezy, .blowingDust: return .windy
        case .hot: return .hot
        case .frigid: return .cold
        @unknown default: return .unknown
        }
    }
    // swiftlint:enable cyclomatic_complexity
}
