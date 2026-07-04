import Testing
import Foundation
@testable import AuraCore

@Test func symbolMapIsTotalAndNonEmpty() {
    for c in AuraWeatherCondition.allCases {
        #expect(!WeatherGreeting.symbolName(for: c).isEmpty)
    }
}

@Test func conditionTextIsLowercaseAndUnknownIsBlank() {
    for c in AuraWeatherCondition.allCases {
        let t = WeatherGreeting.text(for: c)
        #expect(t == t.lowercased())
    }
    #expect(WeatherGreeting.text(for: .unknown).isEmpty)
    #expect(WeatherGreeting.text(for: .clear) == "clear")
    #expect(WeatherGreeting.text(for: .heavyRain) == "heavy rain")
}

@Test func temperatureUsesFahrenheitForUSLocaleAndCelsiusOtherwise() {
    let m = Measurement(value: 22, unit: UnitTemperature.celsius) // 71.6°F -> 72
    #expect(WeatherGreeting.temperatureText(m, locale: Locale(identifier: "en_US")) == "72°")
    #expect(WeatherGreeting.temperatureText(m, locale: Locale(identifier: "fr_FR")) == "22°")
}

@Test func accessibilityTextComposesAndFallsBackToGreetingOnly() {
    let snap = WeatherSnapshot(temperature: Measurement(value: 22, unit: .celsius),
                              condition: .clear, asOf: Date(),
                              coordinate: Coordinate(latitude: 0, longitude: 0))
    #expect(WeatherGreeting.accessibilityText(greeting: "Good evening", snapshot: snap,
                                              locale: Locale(identifier: "en_US"))
            == "Good evening, 72 degrees, clear")
    #expect(WeatherGreeting.accessibilityText(greeting: "Good evening", snapshot: nil,
                                              locale: Locale(identifier: "en_US"))
            == "Good evening")
}
