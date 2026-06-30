import Testing
import Foundation
@testable import AuraCore

struct InstantaneousSpeedTests {
    private func pt(_ lat: Double, _ lon: Double, _ t: TimeInterval, speed: Double? = nil) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: nil, timestamp: Date(timeIntervalSince1970: t),
                   speedMetersPerSecond: speed)
    }

    @Test func prefersDopplerWhenPresent() {
        let prev = pt(40.0, -80.0, 0)
        let curr = pt(40.001, -80.0, 1, speed: 6.0)   // delta would be ~111 m/s
        #expect(InstantaneousSpeed.between(previous: prev, current: curr) == 6.0)
    }

    @Test func fallsBackToPositionDelta() {
        let prev = pt(40.0, -80.0, 0)
        let curr = pt(40.0001, -80.0, 5)              // ~11.1 m over 5 s ≈ 2.2 m/s
        let v = InstantaneousSpeed.between(previous: prev, current: curr)
        #expect(v > 1.8 && v < 2.6)
    }

    @Test func firstPointIsZero() {
        #expect(InstantaneousSpeed.between(previous: nil, current: pt(40, -80, 0)) == 0)
    }

    @Test func zeroDtIsZeroWhenNoDoppler() {
        let prev = pt(40.0, -80.0, 3)
        let curr = pt(40.0001, -80.0, 3)              // dt == 0, no Doppler
        #expect(InstantaneousSpeed.between(previous: prev, current: curr) == 0)
    }
}
