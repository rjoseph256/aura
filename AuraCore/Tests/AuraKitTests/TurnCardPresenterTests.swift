import XCTest
@testable import AuraKit

final class TurnCardPresenterTests: XCTestCase {
    func test_distanceFormatting_feetThenMiles_imperial() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "x", units: .imperial).distanceText, "390 ft")
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 400, instruction: "x", units: .imperial).distanceText, "0.2 mi")
    }

    func test_distanceFormatting_metric() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "x", units: .metric).distanceText, "120 m")
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 2500, instruction: "x", units: .metric).distanceText, "2.5 km")
    }

    func test_isExpanded_whenWithinThreshold() {
        XCTAssertTrue(
            TurnCardPresenter.state(distanceToManeuverMeters: 100, instruction: "x", units: .imperial, expandWithinMeters: 150).isExpanded)
        XCTAssertFalse(
            TurnCardPresenter.state(distanceToManeuverMeters: 200, instruction: "x", units: .imperial, expandWithinMeters: 150).isExpanded)
    }

    func test_passesInstructionThrough() {
        XCTAssertEqual(
            TurnCardPresenter.state(distanceToManeuverMeters: 50, instruction: "Right onto Penn Ave", units: .imperial).primaryText,
            "Right onto Penn Ave")
    }

    func test_accessibilityLabel_composed_imperial() {
        let s = TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave", units: .imperial)
        XCTAssertEqual(s.accessibilityLabel, "In 390 feet, Right onto Penn Ave")
    }

    func test_accessibilityLabel_composed_metric() {
        let s = TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave", units: .metric)
        XCTAssertEqual(s.accessibilityLabel, "In 120 meters, Right onto Penn Ave")
    }

    func test_staticStates_accessibilityLabel() {
        XCTAssertEqual(TurnCardState.starting.accessibilityLabel, "Starting navigation.")
        XCTAssertEqual(TurnCardState.unavailable.accessibilityLabel, "Navigate to destination.")
    }
}
