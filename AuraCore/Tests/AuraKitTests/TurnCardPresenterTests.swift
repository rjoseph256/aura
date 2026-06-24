import XCTest
@testable import AuraKit

final class TurnCardPresenterTests: XCTestCase {
    func test_distanceFormatting_feetThenMiles() {
        // 120 m ≈ 394 ft → rounded to nearest 10 ft = "390 ft"
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "x").distanceText, "390 ft")
        // 400 m ≈ 1312 ft → switches to miles ≈ "0.2 mi"
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 400, instruction: "x").distanceText, "0.2 mi")
    }

    func test_isExpanded_whenWithinThreshold() {
        XCTAssertTrue(TurnCardPresenter.state(distanceToManeuverMeters: 100, instruction: "x", expandWithinMeters: 150).isExpanded)
        XCTAssertFalse(TurnCardPresenter.state(distanceToManeuverMeters: 200, instruction: "x", expandWithinMeters: 150).isExpanded)
    }

    func test_passesInstructionThrough() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 50, instruction: "Right onto Penn Ave").primaryText,
                       "Right onto Penn Ave")
    }
}
