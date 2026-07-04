import Foundation

/// A neutral, Aura-owned weather condition set. Deliberately independent of WeatherKit
/// (which is iOS-only) so this and its symbol/text map stay in AuraCore and build on the
/// macOS CI host. `.unknown` is the fallback the provider maps any unrecognized case to.
public enum AuraWeatherCondition: String, Sendable, CaseIterable {
    case clear, mostlyClear, cloudy, mostlyCloudy, fog, drizzle, rain, heavyRain
    case thunderstorm, snow, sleet, hail, windy, hot, cold, unknown
}

/// An immutable snapshot of current conditions for one coordinate. Sendable so it can cross
/// the `WeatherProviding` seam back to the main-actor store.
public struct WeatherSnapshot: Sendable {
    public let temperature: Measurement<UnitTemperature>
    public let condition: AuraWeatherCondition
    public let asOf: Date
    public let coordinate: Coordinate

    public init(temperature: Measurement<UnitTemperature>,
                condition: AuraWeatherCondition,
                asOf: Date,
                coordinate: Coordinate) {
        self.temperature = temperature
        self.condition = condition
        self.asOf = asOf
        self.coordinate = coordinate
    }
}
