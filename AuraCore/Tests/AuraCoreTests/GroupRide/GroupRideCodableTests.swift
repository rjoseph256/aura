import Foundation
import Testing
@testable import AuraCore

struct GroupRideCodableTests {
    @Test func groupRideRoundTrips() throws {
        let code = try #require(JoinCode(rawValue: "ABCDEFGH"))
        let ride = GroupRide(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            joinCode: code,
            status: .active,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(ride)
        let back = try JSONDecoder().decode(GroupRide.self, from: data)
        #expect(back == ride)
    }

    @Test func remoteTrackPointRoundTrips() throws {
        let point = RemoteTrackPoint(
            userID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            coordinate: Coordinate(latitude: 37.7749, longitude: -122.4194),
            recordedAt: Date(timeIntervalSince1970: 1000),
            progressMeters: 500.0
        )
        let data = try JSONEncoder().encode(point)
        let back = try JSONDecoder().decode(RemoteTrackPoint.self, from: data)
        #expect(back == point)
    }
}
