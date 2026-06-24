import XCTest
import AuraCore
@testable import AuraKit

final class RideStatsFormatterTests: XCTestCase {
    func test_imperial_valuesAndUnits() {
        let f = RideStatsFormatter(units: .imperial)
        XCTAssertEqual(f.distanceValue(1609.344), "1.0")   // 1 mile
        XCTAssertEqual(f.distanceUnit, "mi")
        XCTAssertEqual(f.elevationValue(30.48), "100")     // 100 ft
        XCTAssertEqual(f.elevationUnit, "ft")
        XCTAssertEqual(f.speedValue(4.4704), "10")         // 10 mph
        XCTAssertEqual(f.speedUnit, "mph")
    }

    func test_metric_valuesAndUnits() {
        let f = RideStatsFormatter(units: .metric)
        XCTAssertEqual(f.distanceValue(2500), "2.5")       // 2.5 km
        XCTAssertEqual(f.distanceUnit, "km")
        XCTAssertEqual(f.elevationValue(240.4), "240")     // 240 m
        XCTAssertEqual(f.elevationUnit, "m")
        XCTAssertEqual(f.speedValue(10), "36")             // 36 km/h
        XCTAssertEqual(f.speedUnit, "km/h")
    }

    func test_speedValue_honorsDecimals() {
        XCTAssertEqual(RideStatsFormatter(units: .imperial).speedValue(4.4704, decimals: 1), "10.0")
    }

    func test_minutesAndClock() {
        let f = RideStatsFormatter(units: .imperial)
        XCTAssertEqual(f.minutes(630), "10 min")
        XCTAssertEqual(RideStatsFormatter.clock(125), "2:05")
        XCTAssertEqual(RideStatsFormatter.clock(5), "0:05")
    }

    func test_maneuverDistance_imperial() {
        let f = RideStatsFormatter(units: .imperial)
        XCTAssertEqual(f.maneuverDistance(120), "390 ft")    // 120 m → nearest 10 ft
        XCTAssertEqual(f.maneuverDistance(8), "30 ft")       // rounds to nearest 10 ft
        XCTAssertEqual(f.maneuverDistance(1609.344), "1.0 mi") // ≥1000 ft rolls up to miles
    }

    func test_maneuverDistance_metric() {
        let f = RideStatsFormatter(units: .metric)
        XCTAssertEqual(f.maneuverDistance(120), "120 m")     // nearest 10 m
        XCTAssertEqual(f.maneuverDistance(8), "10 m")        // rounds to nearest 10 m
        XCTAssertEqual(f.maneuverDistance(2500), "2.5 km")   // ≥1000 m rolls up to km
    }
}
