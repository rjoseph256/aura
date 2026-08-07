import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// ROH-167: `beginLiveSession()` sets its `didBeginLive` latch before its first await, so
/// anything that stops the function at that await leaves the latch set and the live layer
/// never started — no subscription, no event loop, no ticker — with every later call
/// returning at the guard.
///
/// The discriminator is the transport, not `isLive`: driving `session.ingest(.connected)`
/// directly would set `isLive` whether or not a subscription was ever opened. Emitting
/// through `InMemoryRideSessionTransport` only reaches the session if `startManaged` ran.
@MainActor
struct GroupRideSessionBeginLiveTests {
    private func route() -> Route {
        Route(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1),
              waypoints: [], geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
              profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// The roster fetch is a display-name lookup. Its failure must not take the live layer
    /// with it: the crew still needs to appear, and this rider still needs to publish.
    @Test func aFailedRosterStillStartsTheLiveLayer() async throws {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let transport = InMemoryRideSessionTransport()
        let session = GroupRideSession(backend: backend, transport: transport,
                                       displayNameProvider: { "Mike" })
        await session.create(route: route())
        backend.store.forceRosterError = .notMember

        await session.beginLiveSession()

        transport.emit(.connected)
        await settle()
        #expect(session.isLive == true)
    }
}
