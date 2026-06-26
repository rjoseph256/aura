import XCTest
@testable import AuraKit
import AuraCore

/// Boundary tests for `TurnCardPresenter.state` (imperial distance rounding).
final class TurnCardPresenterEdgeTests: XCTestCase {

    private let metersAtNominal1000ft = 1000.0 / 3.280839895013123 // ≈ 304.8 m

    func test_zeroMeters_showsZeroFeet() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 0, instruction: "x", units: .imperial)
        XCTAssertEqual(state.distanceText, "0 ft")
        XCTAssertTrue(state.isExpanded)
    }

    func test_justBelowSwitch_showsFeet() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 300, instruction: "x", units: .imperial)
        XCTAssertEqual(state.distanceText, "980 ft")
    }

    func test_atOrAboveSwitch_showsMiles() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 305, instruction: "x", units: .imperial)
        XCTAssertEqual(state.distanceText, "0.2 mi")
    }

    func test_nominal1000ftBoundary_actuallyStaysInFeet_floatArtifact() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: metersAtNominal1000ft, instruction: "x", units: .imperial)
        XCTAssertEqual(state.distanceText, "1000 ft")
    }

    func test_justAboveSwitch_showsMiles() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: metersAtNominal1000ft + 1, instruction: "x", units: .imperial)
        XCTAssertTrue(state.distanceText.hasSuffix(" mi"),
                      "expected miles formatting just above the switch, got \(state.distanceText)")
    }

    func test_roundsFeetToNearest10() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 30, instruction: "x", units: .imperial).distanceText, "100 ft")
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 8, instruction: "x", units: .imperial).distanceText, "30 ft")
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 1, instruction: "x", units: .imperial).distanceText, "0 ft")
    }
}
