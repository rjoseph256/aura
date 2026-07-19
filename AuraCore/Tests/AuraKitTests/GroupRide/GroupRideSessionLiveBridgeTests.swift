import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Proves the LIVE transport stream drives `GroupRideSession.ingest` (names/toasts/host-end
/// dissolve) — not just the direct `ingest` calls the tick/toast suites use. The wiring under
/// test: `beginLiveSession()` calls `RideSession.startManaged`, which opens the subscription
/// and hands the event stream back so `GroupRideSession` OWNS the loop and its own `ingest`
/// runs on every emitted event. Before this bridge, `RideSession.start(roster:)` spawned its
/// own loop calling only `RideSession.ingest` (dots), so the group layer never saw the stream.
@MainActor
struct GroupRideSessionLiveBridgeTests {
    private func route() -> Route {
        Route(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1),
              waypoints: [], geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
              profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0)
    }

    private func position(_ id: UUID, at t: TimeInterval) -> TransportEvent {
        .position(LivePositionPayload(userID: id, coordinate: .init(latitude: 1, longitude: 1),
                                      progressMeters: 10, recordedAt: Date(timeIntervalSince1970: t),
                                      motionState: .moving))
    }

    /// Yield to the runtime so the owned event-loop task consumes what was just emitted.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    @Test func liveStreamDrivesJoinToastAndNameResolution() async throws {
        // Shared transport we hold, so `emit` reaches the subscription the session opens.
        let transport = InMemoryRideSessionTransport()
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let host = GroupRideSession(backend: backend, transport: transport,
                                    displayNameProvider: { "Mike" })
        await host.create(route: route())
        await host.startRiding()

        await host.beginLiveSession()   // opens the subscription + owns the loop (before Sara joins)

        // Sara joins the shared store AFTER the host is live, so her first position is a
        // genuine new-peer sighting on the wire (not a pre-seeded roster member).
        let guestBackend = InMemoryGroupRideBackend(sharing: backend)
        try await guestBackend.signIn(idToken: "t2", nonce: "n2", displayName: "Sara")
        let sara = try await guestBackend.currentUserID()
        _ = try await guestBackend.joinRide(code: host.joinCode!)

        // Drive the LIVE stream (not a direct ingest): Sara's first position arrives on the wire.
        transport.emit(position(sara, at: 100))
        await settle()

        #expect(host.nameMap[sara] == "Sara")            // resolved via the live-triggered refresh
        #expect(host.toasts.contains(.joined("Sara")))   // .joined fired off the live stream
    }

    @Test func liveHostLeftSignalDissolvesGuest() async throws {
        // Guest session; a `.rideEnded` broadcast arriving on the LIVE stream must drive
        // .hostEnded + phase == .ended.
        let transport = InMemoryRideSessionTransport()
        let hostBackend = InMemoryGroupRideBackend()
        try await hostBackend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let host = GroupRideSession(backend: hostBackend, transport: InMemoryRideSessionTransport(),
                                    displayNameProvider: { "Mike" })
        await host.create(route: route())

        let guestBackend = InMemoryGroupRideBackend(sharing: hostBackend)
        try await guestBackend.signIn(idToken: "t2", nonce: "n2", displayName: "Sara")
        let guest = GroupRideSession(backend: guestBackend, transport: transport,
                                     displayNameProvider: { "Sara" })
        await guest.join(code: host.joinCode!)

        await guest.beginLiveSession()

        transport.emit(.rideEnded)
        await settle()

        #expect(guest.toasts.contains(.hostEnded))
        #expect(guest.phase == .ended)
    }
}
