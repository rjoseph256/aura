import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideSessionTickTests {
    struct RidingHost {
        let session: GroupRideSession
        let transport: InMemoryRideSessionTransport
        let selfID: UUID
    }
    private func ridingHost() async throws -> RidingHost {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let selfID = try await backend.currentUserID()
        let transport = InMemoryRideSessionTransport()
        let s = GroupRideSession(backend: backend, transport: transport, displayNameProvider: { "Mike" })
        await s.create(route: Route(origin: .init(latitude: 0, longitude: 0),
            destination: .init(latitude: 1, longitude: 1), waypoints: [],
            geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
            profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0))
        s.startRiding()
        return RidingHost(session: s, transport: transport, selfID: selfID)
    }
    private func position(_ id: UUID, _ meters: Double, at t: TimeInterval) -> TransportEvent {
        .position(LivePositionPayload(userID: id, coordinate: .init(latitude: 1, longitude: 1),
                                      progressMeters: meters, recordedAt: Date(timeIntervalSince1970: t),
                                      motionState: .moving))
    }
    @Test func ingestSnapshotsPeersForObservation() async throws {
        let host = try await ridingHost()
        let peer = UUID()
        await host.session.ingest(position(peer, 10, at: 100))
        #expect(host.session.peers.contains { $0.userID == peer })
    }
    @Test func disconnectThenConnectReseeds() async throws {
        let host = try await ridingHost()
        await host.session.ingest(.disconnected(nil))
        #expect(host.session.isLive == false)
        let seeded = UUID()
        host.transport.snapshotResult = [LivePositionPayload(userID: seeded, coordinate: .init(latitude: 2, longitude: 2),
            progressMeters: 42, recordedAt: Date(timeIntervalSince1970: 200), motionState: .moving)]
        await host.session.ingest(.connected)
        #expect(host.session.isLive == true)
        #expect(host.session.peers.contains { $0.userID == seeded })   // re-seeded from the snapshot
    }
    @Test func endTransitionsToEnded() async throws {
        let host = try await ridingHost()
        await host.session.end()
        #expect(host.session.phase == .ended)
    }
    @Test func tickDoesNotUseWallClock() async throws {
        // Purely exercises the injected-time entry; a fixed `now` must be accepted with no real waiting.
        let host = try await ridingHost()
        await host.session.tick(now: Date(timeIntervalSince1970: 500))
        #expect(host.session.phase == .riding)
    }
}
