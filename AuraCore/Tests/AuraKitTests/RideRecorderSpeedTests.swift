import Testing
import Foundation
@testable import AuraKit
@testable import AuraCore

@MainActor
struct RideRecorderSpeedTests {
    private func pt(_ lat: Double, _ t: TimeInterval, speed: Double?) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80.0),
                   elevation: nil, timestamp: Date(timeIntervalSince1970: t),
                   speedMetersPerSecond: speed)
    }

    @Test func tracksDopplerSpeed() {
        let r = RideRecorder()
        r.start(at: Date(timeIntervalSince1970: 0))
        r.record(pt(40.000, 0, speed: 9))
        r.record(pt(40.001, 1, speed: 9))
        r.record(pt(40.002, 2, speed: 9))
        #expect(r.currentSpeedMetersPerSecond > 5)   // converging toward 9
        #expect(r.currentSpeedMetersPerSecond <= 9)
    }

    @Test func decaysTowardZeroWhenStopped() {
        let r = RideRecorder()
        r.start(at: Date(timeIntervalSince1970: 0))
        for i in 0...4 { r.record(pt(40.0 + Double(i) * 0.001, Double(i), speed: 10)) }
        let moving = r.currentSpeedMetersPerSecond
        for i in 5...12 { r.record(pt(40.005, Double(i), speed: 0)) } // parked: speed 0
        #expect(r.currentSpeedMetersPerSecond < moving)
        #expect(r.currentSpeedMetersPerSecond < 2)
    }

    @Test func startResetsSpeed() {
        let r = RideRecorder()
        r.start(at: Date(timeIntervalSince1970: 0))
        r.record(pt(40.0, 0, speed: 8))
        r.record(pt(40.001, 1, speed: 8))
        #expect(r.currentSpeedMetersPerSecond > 0)
        r.start(at: Date(timeIntervalSince1970: 100))
        #expect(r.currentSpeedMetersPerSecond == 0)
    }
}
