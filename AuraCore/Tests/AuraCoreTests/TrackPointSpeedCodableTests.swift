import Testing
import Foundation
@testable import AuraCore

struct TrackPointSpeedCodableTests {
    @Test func roundTripsSpeed() throws {
        let p = TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0),
                           elevation: 100, timestamp: Date(timeIntervalSince1970: 0),
                           speedMetersPerSecond: 7.5)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(TrackPoint.self, from: data)
        #expect(back.speedMetersPerSecond == 7.5)
    }

    @Test func legacyBlobWithoutSpeedDecodesNil() throws {
        // A track encoded before this field existed: no "speedMetersPerSecond" key.
        let legacy = """
        {"coordinate":{"latitude":40.44,"longitude":-80.0},"elevation":100,"timestamp":0}
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(TrackPoint.self, from: legacy)
        #expect(back.speedMetersPerSecond == nil)
        #expect(back.coordinate.latitude == 40.44)
    }

    @Test func defaultInitOmitsSpeed() {
        let p = TrackPoint(coordinate: .init(latitude: 0, longitude: 0),
                           elevation: nil, timestamp: Date(timeIntervalSince1970: 0))
        #expect(p.speedMetersPerSecond == nil)
    }
}
