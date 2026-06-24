import XCTest
@testable import AuraCore

final class UnitConverterTests: XCTestCase {
    func test_metersPerSecondToMPH() {
        XCTAssertEqual(UnitConverter.mph(fromMetersPerSecond: 10), 22.369, accuracy: 0.001)
        XCTAssertEqual(UnitConverter.mph(fromMetersPerSecond: 0), 0, accuracy: 0.0001)
    }
    func test_metersToMiles() {
        XCTAssertEqual(UnitConverter.miles(fromMeters: 1609.344), 1.0, accuracy: 0.0001)
    }
    func test_metersToFeet() {
        XCTAssertEqual(UnitConverter.feet(fromMeters: 100), 328.084, accuracy: 0.01)
    }

    func test_metersToKilometers() {
        XCTAssertEqual(UnitConverter.km(fromMeters: 2500), 2.5, accuracy: 1e-9)
    }

    func test_metersPerSecondToKMH() {
        XCTAssertEqual(UnitConverter.kmh(fromMetersPerSecond: 10), 36, accuracy: 1e-9)
    }
}
