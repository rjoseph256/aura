import Testing
import Foundation
import CoreLocation
@testable import AuraKit

@MainActor
struct LocationServiceIngestTests {
    @Test func capturesValidDopplerSpeed() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -80.0),
                             altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 0, speed: 8.0, timestamp: Date())
        let point = svc.ingest(loc, now: Date())
        #expect(point?.speedMetersPerSecond == 8.0)
    }

    @Test func dropsInvalidSpeedToNil() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -80.0),
                             altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 0, speed: -1, timestamp: Date())
        let point = svc.ingest(loc, now: Date())
        #expect(point != nil)
        #expect(point?.speedMetersPerSecond == nil)
    }

    // A stopped rider reports speed 0 (valid) — it must be captured as 0.0, NOT dropped
    // to nil. This pins the `>= 0` guard so a later refactor to `> 0` can't silently
    // break stopped-rider decay-to-zero on the dial.
    @Test func capturesZeroSpeed() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -80.0),
                             altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 0, speed: 0, timestamp: Date())
        #expect(svc.ingest(loc, now: Date())?.speedMetersPerSecond == 0.0)
    }
}
