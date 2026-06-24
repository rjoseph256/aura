import XCTest
@testable import AuraKit
import AuraCore

/// Boundary tests for `TurnCardPresenter.state`.
///
/// The feet→miles switch is `feet >= 1000`, where feet = meters * 3.280839895…
/// So 1000 ft corresponds to 1000 / 3.280839895… ≈ 304.8 m. Below that, the card
/// shows feet (rounded to the nearest 10); at/above, it shows miles to one decimal.
final class TurnCardPresenterEdgeTests: XCTestCase {

    // Meters that, in exact arithmetic, map to 1000 ft (the documented switch).
    // NOTE: 1000.0 / 3.280839895… then * 3.280839895… does NOT recover 1000.0 in
    // IEEE-754 doubles — it comes back as 999.9999999999999, which is < 1000. So
    // this value actually lands in the FEET branch, not miles (see test below).
    private let metersAtNominal1000ft = 1000.0 / 3.280839895013123 // ≈ 304.8 m

    func test_zeroMeters_showsZeroFeet() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 0, instruction: "x")
        XCTAssertEqual(state.distanceText, "0 ft")
        // 0 m is within the default 150 m expand window.
        XCTAssertTrue(state.isExpanded)
    }

    func test_justBelowSwitch_showsFeet() {
        // 300 m ≈ 984.25 ft → nearest 10 = 980 ft (clearly in feet territory).
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 300, instruction: "x")
        XCTAssertEqual(state.distanceText, "980 ft")
    }

    func test_atOrAboveSwitch_showsMiles() {
        // 305 m ≈ 1000.66 ft → unambiguously >= 1000 → miles.
        // 305 m ≈ 0.1895 mi → "%.1f mi" = "0.2 mi".
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 305, instruction: "x")
        XCTAssertEqual(state.distanceText, "0.2 mi")
    }

    func test_nominal1000ftBoundary_actuallyStaysInFeet_floatArtifact() {
        // CHARACTERIZATION: the "exact" 1000 ft boundary is unreachable in doubles.
        // 1000/3.2808… → feet == 999.9999999999999 < 1000 → feet branch, and 999.99…
        // rounds to nearest 10 = 1000 → it DISPLAYS "1000 ft" rather than switching
        // to miles. So "1000 ft" is a string the card can actually show, despite
        // 1000 ft nominally being the switch point. Pins the float edge, not endorses it.
        let state = TurnCardPresenter.state(distanceToManeuverMeters: metersAtNominal1000ft, instruction: "x")
        XCTAssertEqual(state.distanceText, "1000 ft")
    }

    func test_justAboveSwitch_showsMiles() {
        // A hair above the nominal boundary clears 1000 ft and switches to miles.
        let state = TurnCardPresenter.state(distanceToManeuverMeters: metersAtNominal1000ft + 1, instruction: "x")
        XCTAssertTrue(state.distanceText.hasSuffix(" mi"),
                      "expected miles formatting just above the switch, got \(state.distanceText)")
    }

    func test_roundsFeetToNearest10() {
        // 30 m ≈ 98.4 ft → nearest 10 = 100 ft.
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 30, instruction: "x").distanceText,
                       "100 ft")
        // 8 m ≈ 26.2 ft → nearest 10 = 30 ft.
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 8, instruction: "x").distanceText,
                       "30 ft")
        // 1 m ≈ 3.28 ft → nearest 10 = 0 ft.
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 1, instruction: "x").distanceText,
                       "0 ft")
    }
}
