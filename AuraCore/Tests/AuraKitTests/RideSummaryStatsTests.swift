import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite("Ride summary stats")
struct RideSummaryStatsTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func duration(elapsed: TimeInterval, paused: TimeInterval) -> RideDuration? {
        RideDuration(startedAt: start, endedAt: start.addingTimeInterval(elapsed),
                     checkpointedAt: nil, pausedSeconds: paused)
    }

    private func stats(_ d: RideDuration?, units: DistanceUnits = .imperial) -> RideSummaryStats {
        RideSummaryStats(duration: d, movingTimeSeconds: 1860,
                         maxSpeedMetersPerSecond: 10.86, units: units)
    }

    @Test("A paused ride shows active with elapsed beneath it")
    func pausedRideShowsThePair() {
        let s = stats(duration(elapsed: 2880, paused: 600))
        #expect(s.activeValue == "38 min")
        #expect(s.elapsedCaption == "48 min elapsed")
        #expect(s.activeAccessibilityLabel == "Active time, 38 min. Elapsed, 48 min.")
    }

    @Test("An unpaused ride shows no elapsed caption")
    func unpausedRideHidesTheCaption() {
        // The majority path. A fixed layout would print the same number twice, permanently.
        let s = stats(duration(elapsed: 2880, paused: 0))
        #expect(s.activeValue == "48 min")
        #expect(s.elapsedCaption == nil)
        #expect(s.activeAccessibilityLabel == "Active time, 48 min.")
    }

    @Test("A pause too short to change the rendered minute shows no caption either")
    func subMinutePauseHidesTheCaption() {
        // `RideStatsFormatter.minutes` truncates, so 2870 s and 2850 s both render "47 min"
        // despite a real 20 s pause. Comparing RENDERED STRINGS rather than `pausedSeconds > 0`
        // is what covers this case.
        let s = stats(duration(elapsed: 2870, paused: 20))
        #expect(s.activeValue == "47 min")
        #expect(s.elapsedCaption == nil)
    }

    @Test("A ride with no trustworthy end shows a dash and no caption")
    func unavailableDurationIsDashed() {
        let s = stats(nil)
        #expect(s.activeValue == "—")
        #expect(s.elapsedCaption == nil)
        #expect(s.activeAccessibilityLabel == "Active time, unavailable.")
    }

    @Test("Moving time and top speed are unchanged by any of this")
    func movingAndTopSpeedAreUntouched() {
        let s = stats(duration(elapsed: 2880, paused: 600))
        #expect(s.movingValue == "31 min")
        #expect(s.topSpeedValue == "24.3")
        #expect(s.topSpeedLabel == "mph top")
        #expect(stats(duration(elapsed: 2880, paused: 600), units: .metric).topSpeedLabel
                == "km/h top")
    }
}
