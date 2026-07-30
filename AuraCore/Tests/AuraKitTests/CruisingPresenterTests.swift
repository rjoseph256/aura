import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite struct CruisingPresenterTests {
    private func calendar(_ localeID: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: localeID)
        return cal
    }
    private func now(_ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 16, minute: 20))!
    }
    private func update(distance: Double? = nil, duration: Double? = nil,
                        street: String? = nil) -> GuidanceUpdate {
        GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "x",
                       distanceRemainingMeters: distance,
                       durationRemainingSeconds: duration, currentStreetName: street)
    }

    @Test func distanceRemainingImperial() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380), units: .imperial,
                                        now: now(cal), calendar: cal)
        #expect(s.distanceRemaining == "2.1 mi")
    }

    @Test func distanceRemainingMetric() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380), units: .metric,
                                        now: now(cal), calendar: cal)
        #expect(s.distanceRemaining == "3.4 km")
    }

    @Test func etaTwelveHour() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(duration: 1080), units: .imperial,
                                        now: now(cal), calendar: cal)
        // 16:20 UTC + 18 min = 16:38, which a 12-hour locale renders as "4:38 PM".
        // Assert it contains "4:38" rather than the exact "4:38 PM" string: recent
        // Apple OSes put a narrow no-break space (U+202F) before "PM", so an exact
        // equality check is OS-fragile. "4:38" (not "16:38") proves the 12-hour split.
        #expect(s.eta?.contains("4:38") == true)
    }

    @Test func etaTwentyFourHour() {
        let cal = calendar("en_GB")
        let s = CruisingPresenter.state(for: update(duration: 1080), units: .metric,
                                        now: now(cal), calendar: cal)
        // A 24-hour locale has no AM/PM glyph, so the exact string is stable.
        #expect(s.eta == "16:38")
    }

    @Test func nilFieldsYieldStarting() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(), units: .imperial,
                                        now: now(cal), calendar: cal)
        #expect(s.streetName == nil)
        #expect(s.distanceRemaining == nil)
        #expect(s.eta == nil)
        #expect(s == .starting)
    }

    @Test func emptyOrWhitespaceStreetYieldsNil() {
        let cal = calendar("en_US")
        let empty = CruisingPresenter.state(for: update(street: ""), units: .imperial,
                                            now: now(cal), calendar: cal)
        let spaces = CruisingPresenter.state(for: update(street: "   "), units: .imperial,
                                             now: now(cal), calendar: cal)
        #expect(empty.streetName == nil)
        #expect(spaces.streetName == nil)
    }

    @Test func streetPassesThrough() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(street: "Penn Ave"), units: .imperial,
                                        now: now(cal), calendar: cal)
        #expect(s.streetName == "Penn Ave")
    }

    @Test func accessibilityLabel_full() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, duration: 1080, street: "Penn Ave"),
                                        units: .imperial, now: now(cal), calendar: cal)
        // 3380 m -> "2.1 miles"; 16:20 + 18 min -> "4:38 PM" (assert the stable parts).
        #expect(s.accessibilityLabel.hasPrefix("On Penn Ave, 2.1 miles to go, arriving "))
        #expect(s.accessibilityLabel.contains("4:38"))
    }

    @Test func accessibilityLabel_noStreet() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, duration: 1080),
                                        units: .imperial, now: now(cal), calendar: cal)
        #expect(s.accessibilityLabel.hasPrefix("2.1 miles to go, arriving "))
    }

    @Test func accessibilityLabel_missingDistance() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(duration: 1080, street: "Penn Ave"),
                                        units: .imperial, now: now(cal), calendar: cal)
        #expect(s.accessibilityLabel.hasPrefix("On Penn Ave, arriving "))
    }

    @Test func accessibilityLabel_missingEta() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, street: "Penn Ave"),
                                        units: .imperial, now: now(cal), calendar: cal)
        #expect(s.accessibilityLabel == "On Penn Ave, 2.1 miles to go")
    }

    @Test func accessibilityLabel_metricDistance() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, street: "Penn Ave"),
                                        units: .metric, now: now(cal), calendar: cal)
        #expect(s.accessibilityLabel == "On Penn Ave, 3.4 kilometers to go")
    }

    @Test func accessibilityLabel_startingState() {
        #expect(CruisingState.starting.accessibilityLabel == "Starting navigation.")
    }

    @Test func pausedAccessibilityLabel_dropsArrival() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, duration: 1080, street: "Penn Ave"),
                                        units: .imperial, now: now(cal), calendar: cal)
        #expect(s.pausedAccessibilityLabel == "On Penn Ave, 2.1 miles to go")
        #expect(!s.pausedAccessibilityLabel.contains("arriving"))
    }

    @Test func pausedAccessibilityLabel_startingState() {
        #expect(CruisingState.starting.pausedAccessibilityLabel == "Starting navigation.")
    }
}
