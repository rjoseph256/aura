import Testing
import Foundation
@testable import AuraKit
import AuraCore

struct InMemoryGroupRideBackendTests {
    @Test func createThenJoinReturnsSameRide() async throws {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Host")
        let ride = try await backend.createRide(route: Data("{}".utf8))
        let joiner = InMemoryGroupRideBackend(sharing: backend)
        try await joiner.signIn(idToken: "t2", nonce: "n2", displayName: "Guest")
        let joined = try await joiner.joinRide(code: ride.joinCode)
        #expect(joined.ride.id == ride.id)
    }
    @Test func joinReturnsStoredRouteAndRoster() async throws {
        let host = InMemoryGroupRideBackend()
        try await host.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let routeBytes = Data("{\"hello\":1}".utf8)
        let ride = try await host.createRide(route: routeBytes)

        let guest = InMemoryGroupRideBackend(sharing: host)
        try await guest.signIn(idToken: "t2", nonce: "n2", displayName: "Sara")
        let joined = try await guest.joinRide(code: ride.joinCode)
        #expect(joined.route == routeBytes)

        let roster = try await host.roster(rideID: ride.id)
        #expect(Set(roster.map(\.displayName)) == ["Mike", "Sara"])
        let selfID = try await guest.currentUserID()
        #expect(roster.contains { $0.userID == selfID })
    }
    @Test func joinRejectsNinthMember() async throws {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Host")
        let ride = try await backend.createRide(route: Data("{}".utf8))
        for i in 2...8 {
            let m = InMemoryGroupRideBackend(sharing: backend)
            try await m.signIn(idToken: "t\(i)", nonce: "n\(i)", displayName: "M\(i)")
            _ = try await m.joinRide(code: ride.joinCode)
        }
        let ninth = InMemoryGroupRideBackend(sharing: backend)
        try await ninth.signIn(idToken: "t9", nonce: "n9", displayName: "M9")
        await #expect(throws: GroupRideError.self) {
            _ = try await ninth.joinRide(code: ride.joinCode)
        }
    }
}
