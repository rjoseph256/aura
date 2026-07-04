import Foundation

/// Pure formatting for the inline greeting weather. No `MeasurementFormatter` (not Sendable);
/// temperature unit is chosen from the passed `Locale`. Condition text is lowercase (the Home
/// slop gate forbids uppercase "eyebrow" copy).
public enum WeatherGreeting {

    /// SF Symbol for each condition. Total over `AuraWeatherCondition` — every case returns
    /// a non-empty name so the greeting never renders a blank glyph.
    public static func symbolName(for c: AuraWeatherCondition) -> String {
        switch c {
        case .clear: "sun.max"
        case .mostlyClear: "sun.max"
        case .cloudy: "cloud"
        case .mostlyCloudy: "cloud.sun"
        case .fog: "cloud.fog"
        case .drizzle: "cloud.drizzle"
        case .rain: "cloud.rain"
        case .heavyRain: "cloud.heavyrain"
        case .thunderstorm: "cloud.bolt.rain"
        case .snow: "snowflake"
        case .sleet: "cloud.sleet"
        case .hail: "cloud.hail"
        case .windy: "wind"
        case .hot: "thermometer.sun"
        case .cold: "thermometer.snowflake"
        case .unknown: "cloud"
        }
    }

    /// Short, lowercase condition word. `.unknown` returns "" so no condition word is shown.
    public static func text(for c: AuraWeatherCondition) -> String {
        switch c {
        case .clear: "clear"
        case .mostlyClear: "mostly clear"
        case .cloudy: "cloudy"
        case .mostlyCloudy: "mostly cloudy"
        case .fog: "fog"
        case .drizzle: "drizzle"
        case .rain: "rain"
        case .heavyRain: "heavy rain"
        case .thunderstorm: "thunderstorms"
        case .snow: "snow"
        case .sleet: "sleet"
        case .hail: "hail"
        case .windy: "windy"
        case .hot: "hot"
        case .cold: "cold"
        case .unknown: ""
        }
    }

    /// Locale-based °F/°C, rounded to a whole degree. US locale → Fahrenheit, else Celsius.
    public static func temperatureText(_ measurement: Measurement<UnitTemperature>,
                                       locale: Locale) -> String {
        let unit: UnitTemperature = locale.measurementSystem == .us ? .fahrenheit : .celsius
        let value = measurement.converted(to: unit).value
        return "\(Int(value.rounded()))°"
    }

    /// One composed VoiceOver string, e.g. "Good evening, 72 degrees, clear". Greeting-only
    /// when there is no snapshot.
    public static func accessibilityText(greeting: String,
                                         snapshot: WeatherSnapshot?,
                                         locale: Locale) -> String {
        guard let snapshot else { return greeting }
        let unit: UnitTemperature = locale.measurementSystem == .us ? .fahrenheit : .celsius
        let degrees = Int(snapshot.temperature.converted(to: unit).value.rounded())
        let word = text(for: snapshot.condition)
        let tail = word.isEmpty ? "" : ", \(word)"
        return "\(greeting), \(degrees) degrees\(tail)"
    }
}
