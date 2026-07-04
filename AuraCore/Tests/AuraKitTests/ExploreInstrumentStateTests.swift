import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ExploreInstrumentStateTests {
    private func stats(distance: Double, elevation: Double) -> RideStats {
        RideStats(distanceMeters: distance, movingTimeSeconds: 0,
                  averageSpeedMetersPerSecond: 0, maxSpeedMetersPerSecond: 0,
                  elevationGainMeters: elevation)
    }

    @Test func imperialValues() {
        let s = ExploreInstrumentState(stats: stats(distance: 8046.72, elevation: 103.6),
                                       elapsed: 1440, units: .imperial)
        #expect(s.distance == "5.0 mi")
        #expect(s.time == "24:00")
        #expect(s.elevationGain == "340 ft")
    }

    @Test func metricValues() {
        let s = ExploreInstrumentState(stats: stats(distance: 5000, elevation: 120),
                                       elapsed: 90, units: .metric)
        #expect(s.distance == "5.0 km")
        #expect(s.time == "1:30")
        #expect(s.elevationGain == "120 m")
    }

    @Test func zeroValues() {
        let s = ExploreInstrumentState(stats: .zero, elapsed: 0, units: .imperial)
        #expect(s.distance == "0.0 mi")
        #expect(s.time == "0:00")
        #expect(s.elevationGain == "0 ft")
    }

    @Test func accessibilityLabelReusesSpeedRailVoice() {
        let st = stats(distance: 8046.72, elevation: 103.6)
        let s = ExploreInstrumentState(stats: st, elapsed: 1440, units: .imperial)
        #expect(s.accessibilityLabel == SpeedRailVoice.statsLabel(st, elapsed: 1440, units: .imperial))
    }
}
