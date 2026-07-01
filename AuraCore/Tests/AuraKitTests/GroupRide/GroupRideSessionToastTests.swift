import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideSessionToastTests {
    // Host session in .riding, plus a guest who has actually joined (so backend.roster names them).
    private func hostWithJoinedGuest(named guestName: String)
        async throws -> (GroupRideSession, UUID) {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let host = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                    displayNameProvider: { "Mike" })
        await host.create(route: Route(origin: .init(latitude: 0, longitude: 0),
            destination: .init(latitude: 1, longitude: 1), waypoints: [],
            geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
            profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0))
        host.startRiding()
        let guestBackend = InMemoryGroupRideBackend(sharing: backend)
        try await guestBackend.signIn(idToken: "t2", nonce: "n2", displayName: guestName)
        let guestID = try await guestBackend.currentUserID()
        _ = try await guestBackend.joinRide(code: host.joinCode!)   // now a member with a name
        return (host, guestID)
    }
    private func position(_ id: UUID, _ motion: MotionState, at t: TimeInterval) -> TransportEvent {
        .position(LivePositionPayload(userID: id, coordinate: .init(latitude: 1, longitude: 1),
                                      progressMeters: 10, recordedAt: Date(timeIntervalSince1970: t),
                                      motionState: motion))
    }
    @Test func newPeerPositionEmitsJoinedToastWithResolvedName() async throws {
        let (host, sara) = try await hostWithJoinedGuest(named: "Sara")
        await host.ingest(position(sara, .moving, at: 100))
        #expect(host.nameMap[sara] == "Sara")
        #expect(host.toasts.contains(.joined("Sara")))
    }
    @Test func unnamedPeerBecomesNamedWithinOneRefresh() async throws {
        // Finding #1 / §13 "nobody appears blank": after a new peer's first position, the roster
        // refresh must resolve the real name (not leave it blank).
        let (host, sara) = try await hostWithJoinedGuest(named: "Sara")
        #expect(host.nameMap[sara] == nil)               // unknown before any position
        await host.ingest(position(sara, .moving, at: 100))
        #expect(host.nameMap[sara] == "Sara")            // resolved by the triggered refresh
    }
    @Test func motionChangeEmitsNoToast() async throws {   // D11 — the load-bearing invariant
        let (host, sara) = try await hostWithJoinedGuest(named: "Sara")
        await host.ingest(position(sara, .moving, at: 100))   // first sighting: one .joined
        let afterJoin = host.toasts.count
        await host.ingest(position(sara, .stopped, at: 101))  // motion change only
        await host.ingest(position(sara, .moving, at: 102))
        #expect(host.toasts.count == afterJoin)               // no new toast
    }
    @Test func memberLeftEmitsLeftToastAndRemovesPeer() async throws {
        let (host, sara) = try await hostWithJoinedGuest(named: "Sara")
        await host.ingest(position(sara, .moving, at: 100))   // learn Sara
        await host.ingest(.memberLeft(sara))
        #expect(host.toasts.contains(.left("Sara")))
        #expect(!host.peers.contains { $0.userID == sara })
    }
}
