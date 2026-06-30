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
        #expect(joined.id == ride.id)
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
