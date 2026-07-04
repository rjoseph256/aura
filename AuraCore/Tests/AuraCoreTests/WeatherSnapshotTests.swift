import Testing
import Foundation
@testable import AuraCore

@Test func weatherConditionIncludesUnknownFallback() {
    #expect(AuraWeatherCondition.allCases.contains(.unknown))
    #expect(AuraWeatherCondition.allCases.count == 16)
}

@Test func weatherSnapshotStoresValues() {
    let snap = WeatherSnapshot(
        temperature: Measurement(value: 22, unit: .celsius),
        condition: .clear,
        asOf: Date(timeIntervalSince1970: 1_000),
        coordinate: Coordinate(latitude: 40.44, longitude: -79.99))
    #expect(snap.condition == .clear)
    #expect(snap.temperature.value == 22)
    #expect(snap.coordinate.latitude == 40.44)
}
