import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// ROH-174 defect 2: `retryEndIfNeeded` replays the latched `finishIntent` without
/// re-deriving it, and `isHost` can flip underneath (a host who leaves promotes the earliest
/// joiner, `0018_ride_ended_broadcast.sql`). The question this suite settles is what a Retry
/// should do after that promotion.
///
/// The answer asserted here is that it replays what the rider **asked for**. A member who
/// tapped "End ride" used a dialog reading "Leave the crew or end your ride?" — that is
/// `endAsMember`, meaning leave the crew and finish my own ride. Being promoted while the
/// call was in flight does not turn that into consent to end the ride for everyone else.
/// Re-deriving intent from the new `isHost` would silently escalate a retry of a *failed*
/// action into a crew-wide end that N riders never agreed to.
@MainActor
struct GroupRideRetryAfterPromotionTests {
    private func route() -> Route {
        Route(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1),
              waypoints: [], geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
              profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0)
    }

    /// The guest side of a started ride: their session, their backend, and the ride id.
    private struct RidingGuest {
        let session: GroupRideSession
        let backend: InMemoryGroupRideBackend
        let rideID: UUID
    }

    /// Host creates and starts a ride; a guest joins it.
    private func ridingGuest(ctrl: SleepControl) async throws -> RidingGuest {
        let hostBackend = InMemoryGroupRideBackend()
        try await hostBackend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let host = GroupRideSession(backend: hostBackend, transport: InMemoryRideSessionTransport(),
                                    displayNameProvider: { "Mike" })
        await host.create(route: route())
        await host.startRiding()
        let code = try #require(host.joinCode)
        let rideID = try #require(host.rideID)

        let guestBackend = InMemoryGroupRideBackend(sharing: hostBackend)
        try await guestBackend.signIn(idToken: "t2", nonce: "n2", displayName: "Priya")
        let guest = GroupRideSession(backend: guestBackend, transport: InMemoryRideSessionTransport(),
                                     displayNameProvider: { "Priya" },
                                     endTimeout: .seconds(4), sleep: { try await ctrl.sleep($0) })
        await guest.join(code: code)
        #expect(guest.phase == .riding)
        #expect(guest.isHost == false)
        return RidingGuest(session: guest, backend: guestBackend, rideID: rideID)
    }

    @Test func aRetryAfterBeingPromotedStillLeavesRatherThanEndingForEveryone() async throws {
        let ctrl = SleepControl(fireImmediately: true)
        let fixture = try await ridingGuest(ctrl: ctrl)
        let guest = fixture.session
        let backend = fixture.backend
        let rideID = fixture.rideID
        let guestID = try #require(guest.selfUserID)

        // The member taps "End ride" and the call hangs past the timeout.
        backend.store.hangEndLeave = true
        await guest.endAsMember()
        #expect(guest.endFailed == true)
        #expect(guest.phase == .riding)

        // Meanwhile the host leaves and the server promotes this rider (0018's rule).
        let ride = try #require(backend.store.rides[rideID])
        backend.store.rides[rideID] = GroupRide(id: ride.id, hostID: guestID, joinCode: ride.joinCode,
                                                status: ride.status, createdAt: ride.createdAt,
                                                startedAt: ride.startedAt, endedAt: ride.endedAt)
        await guest.reconcileFromStatus()
        #expect(guest.isHost == true, "the promotion has landed on this session")

        // Retry now succeeds.
        backend.store.hangEndLeave = false
        ctrl.fireImmediately = false
        await guest.retryEndIfNeeded()

        #expect(guest.phase == .ended)
        #expect(backend.store.leaveCalled == true, "the retry left the crew, as the rider asked")
        #expect(backend.store.rides[rideID]?.status == .active,
                "the ride is NOT ended for everyone — the rider never asked for that")
    }
}
