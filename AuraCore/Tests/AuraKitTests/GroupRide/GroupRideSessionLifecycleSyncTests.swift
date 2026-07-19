import Foundation
import Testing
import AuraCore
@testable import AuraKit

@MainActor
enum LifecycleFixtures {
    static func route() -> Route {
        Route(id: UUID(), origin: Coordinate(latitude: 40.44, longitude: -79.99),
              destination: Coordinate(latitude: 40.46, longitude: -79.95),
              waypoints: [], geometry: [], profile: .fastest,
              distanceMeters: 8_000, estimatedDurationSeconds: 1_800, elevationGainMeters: 60)
    }

    /// Host session that has created a ride (phase `.lobby`). Returns (session, its backend).
    static func createdHost(forceStartError: GroupRideError? = nil) async -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "h", nonce: "n", displayName: "Host")
        backend.store.forceStartError = forceStartError
        let session = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                       displayNameProvider: { "Host" })
        await session.create(route: route())     // phase -> .lobby
        return (session, backend)
    }

    /// A GUEST session (not yet joined) against a host's ride, optionally started server-side.
    /// Returns (guest session, join code, shared backend). Caller then `await session.join(code:)`.
    static func hostedRide(started: Bool) async -> (GroupRideSession, JoinCode, InMemoryGroupRideBackend) {
        let host = InMemoryGroupRideBackend()
        try? await host.signIn(idToken: "h", nonce: "n", displayName: "Host")
        let ride = try! await host.createRide(route: JSONEncoder().encode(route()))
        if started { try? await host.startRide(rideID: ride.id) }
        let guest = InMemoryGroupRideBackend(sharing: host)   // shares the store
        try? await guest.signIn(idToken: "g", nonce: "n", displayName: "Guest")
        let session = GroupRideSession(backend: guest, transport: InMemoryRideSessionTransport(),
                                       displayNameProvider: { "Guest" })
        return (session, ride.joinCode, guest)
    }
}

@MainActor
struct GroupRideSessionLifecycleSyncTests {
    @Test func joinBeforeStartLandsInLobby() async {
        let (session, code, _) = await LifecycleFixtures.hostedRide(started: false)
        await session.join(code: code)
        #expect(session.phase == .lobby)
    }

    @Test func joinAfterStartLandsInRiding() async {
        let (session, code, _) = await LifecycleFixtures.hostedRide(started: true)
        await session.join(code: code)
        #expect(session.phase == .riding)
    }

    @Test func hostStartSuccessMovesToRiding() async {
        let (session, _) = await LifecycleFixtures.createdHost()
        await session.startRiding()
        #expect(session.phase == .riding)
        #expect(session.startFailed == false)
    }

    @Test func hostStartFailureStaysInLobby() async {
        let (session, _) = await LifecycleFixtures.createdHost(forceStartError: .joinFailed)
        await session.startRiding()
        #expect(session.phase == .lobby)
        #expect(session.startFailed == true)
    }
}
