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

    // A GUEST session (not yet joined) against a host's ride, optionally started server-side.
    // Returns (guest session, join code, shared backend, its transport — exposed so tests can
    // `transport.emit(_:)` onto the live wire). Caller then `await session.join(code:)`.
    // The four-member tuple is a deliberate test-fixture bundle; all members are used by callers.
    // swiftlint:disable:next large_tuple
    static func hostedRide(started: Bool) async -> (GroupRideSession, JoinCode, InMemoryGroupRideBackend, InMemoryRideSessionTransport) {
        let host = InMemoryGroupRideBackend()
        try? await host.signIn(idToken: "h", nonce: "n", displayName: "Host")
        let ride = try! await host.createRide(route: JSONEncoder().encode(route()))
        if started { try? await host.startRide(rideID: ride.id) }
        let guest = InMemoryGroupRideBackend(sharing: host)   // shares the store
        try? await guest.signIn(idToken: "g", nonce: "n", displayName: "Guest")
        let transport = InMemoryRideSessionTransport()
        let session = GroupRideSession(backend: guest, transport: transport,
                                       displayNameProvider: { "Guest" })
        return (session, ride.joinCode, guest, transport)
    }

    /// Rewrites the ride's `hostID` server-side (simulates a host transfer/promotion),
    /// looked up by join code. Rebuilds the value since `GroupRide`'s fields are `let`.
    static func promoteHost(_ backend: InMemoryGroupRideBackend, forCode code: JoinCode, to newHostID: UUID) {
        guard let rideID = backend.store.codes[code.rawValue], let ride = backend.store.rides[rideID] else { return }
        backend.store.rides[rideID] = GroupRide(id: ride.id, hostID: newHostID, joinCode: ride.joinCode,
                                                 status: ride.status, createdAt: ride.createdAt,
                                                 startedAt: ride.startedAt, endedAt: ride.endedAt)
    }
}

@MainActor
struct GroupRideSessionLifecycleSyncTests {
    @Test func joinBeforeStartLandsInLobby() async {
        let (session, code, _, _) = await LifecycleFixtures.hostedRide(started: false)
        await session.join(code: code)
        #expect(session.phase == .lobby)
    }

    @Test func joinAfterStartLandsInRiding() async {
        let (session, code, _, _) = await LifecycleFixtures.hostedRide(started: true)
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

    @Test func rideStartedBroadcastMovesLobbyToRiding() async {
        let (session, code, _, _) = await LifecycleFixtures.hostedRide(started: false)
        await session.join(code: code)
        await session.beginLiveSession()
        await session.ingest(.rideStarted)
        #expect(session.phase == .riding)
    }

    // exercise the NEW event through the transport wire (not just direct ingest)
    @Test func rideStartedViaTransportMovesLobbyToRiding() async {
        let (session, code, _, transport) = await LifecycleFixtures.hostedRide(started: false)
        await session.join(code: code)
        await session.beginLiveSession()
        transport.emit(.rideStarted)
        // let the session's owned event loop drain
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.phase == .riding)
    }

    @Test func rideEndedBroadcastTearsDown() async {
        let (session, code, _, _) = await LifecycleFixtures.hostedRide(started: true)
        await session.join(code: code)
        await session.beginLiveSession()
        await session.ingest(.rideEnded)
        #expect(session.phase == .ended)
    }

    @Test func rideEndedToastsHostEndedForGuest() async {
        let (session, code, _, _) = await LifecycleFixtures.hostedRide(started: true)
        await session.join(code: code)                 // guest, not host
        await session.beginLiveSession()
        await session.ingest(.rideEnded)
        #expect(session.toasts.contains(.hostEnded))
    }

    @Test func connectedReconcileCorrectsPhantomStart() async {
        let (session, code, _, _) = await LifecycleFixtures.hostedRide(started: false)
        await session.join(code: code)
        await session.beginLiveSession()
        await session.ingest(.rideStarted)            // optimistic → riding
        #expect(session.phase == .riding)
        await session.ingest(.connected)              // authoritative read: started_at still nil
        #expect(session.phase == .lobby)              // corrected back
    }

    @Test func connectedReconcileRederivesPromotedHost() async {
        let (session, code, backend, _) = await LifecycleFixtures.hostedRide(started: false)
        await session.join(code: code)
        #expect(session.isHost == false)
        LifecycleFixtures.promoteHost(backend, forCode: code, to: session.selfUserID!)
        await session.ingest(.connected)
        #expect(session.isHost == true)
    }

    @Test func endTransientFailureKeepsRidingThenRetrySucceeds() async {
        let (session, backend) = await LifecycleFixtures.createdHost()
        await session.startRiding()                       // .riding
        backend.store.forceEndError = .joinFailed         // one transient failure, then clears
        await session.end()
        #expect(session.phase == .riding)                 // chrome retained, not faked ended
        #expect(session.endFailed == true)
        await session.retryEndIfNeeded()                  // second attempt succeeds
        #expect(session.phase == .ended)
    }

    @Test func endAlreadyGoneCountsAsSuccess() async {
        let (session, backend) = await LifecycleFixtures.createdHost()
        await session.startRiding()
        backend.store.forceEndError = .notHost            // "already ended / not host anymore"
        await session.end()
        #expect(session.phase == .ended)                  // notHost/notMember ⇒ treat as done
        #expect(session.endFailed == false)
    }

    // Belt-and-suspenders: the ended-from-lobby UI branch no longer mounts a container
    // that re-invokes `beginLiveSession()`, but the session itself must refuse to go
    // live once `.ended` regardless of caller. Drives a guest to `.ended` WITHOUT ever
    // calling `beginLiveSession()` (so no prior latch/subscription exists), calls it,
    // then proves no live subscription got established: a `.connected` event emitted
    // on the wire afterward never reaches the session (isLive stays false). Without the
    // guard, `beginLiveSession()` would subscribe fresh and `isLive` would flip true.
    @Test func beginLiveSessionNoOpWhenEnded() async {
        let (session, code, _, transport) = await LifecycleFixtures.hostedRide(started: true)
        await session.join(code: code)
        await session.ingest(.rideEnded)
        #expect(session.phase == .ended)

        await session.beginLiveSession()
        transport.emit(.connected)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.isLive == false)
    }
}
