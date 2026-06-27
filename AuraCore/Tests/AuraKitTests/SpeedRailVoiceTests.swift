import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite struct SpeedRailVoiceTests {
    /// 24 mph average, 5.0 mi, 340 ft climb (imperial) or 24 km/h, 8.0 km, 104 m (metric).
    private func stats(speed: Double, distance: Double, elevation: Double) -> RideStats {
        RideStats(distanceMeters: distance, movingTimeSeconds: 0,
                  averageSpeedMetersPerSecond: speed, maxSpeedMetersPerSecond: 0,
                  elevationGainMeters: elevation)
    }

    @Test func speedValue_imperial() {
        // 10.728 m/s ≈ 24 mph
        let s = SpeedRailVoice.speedValue(stats(speed: 10.728, distance: 0, elevation: 0), units: .imperial)
        #expect(s == "24 miles per hour")
    }

    @Test func speedValue_metric() {
        // 6.6667 m/s = 24 km/h
        let s = SpeedRailVoice.speedValue(stats(speed: 6.6667, distance: 0, elevation: 0), units: .metric)
        #expect(s == "24 kilometers per hour")
    }

    @Test func statsLabel_imperial() {
        // 8046.72 m = 5.0 mi; 103.632 m = 340 ft
        let s = SpeedRailVoice.statsLabel(stats(speed: 0, distance: 8046.72, elevation: 103.632),
                                          elapsed: 750, units: .imperial)
        #expect(s == "Distance 5.0 miles, time 12 minutes 30 seconds, elevation gain 340 feet")
    }

    @Test func statsLabel_metric() {
        let s = SpeedRailVoice.statsLabel(stats(speed: 0, distance: 8000, elevation: 104),
                                          elapsed: 750, units: .metric)
        #expect(s == "Distance 8.0 kilometers, time 12 minutes 30 seconds, elevation gain 104 meters")
    }

    @Test func elapsedSpoken_edgeCases() {
        let z = stats(speed: 0, distance: 0, elevation: 0)
        #expect(SpeedRailVoice.statsLabel(z, elapsed: 0, units: .imperial).contains("time 0 seconds"))
        #expect(SpeedRailVoice.statsLabel(z, elapsed: 45, units: .imperial).contains("time 45 seconds"))
        #expect(SpeedRailVoice.statsLabel(z, elapsed: 720, units: .imperial).contains("time 12 minutes,"))
        #expect(SpeedRailVoice.statsLabel(z, elapsed: 61, units: .imperial).contains("time 1 minute 1 second"))
    }
}
