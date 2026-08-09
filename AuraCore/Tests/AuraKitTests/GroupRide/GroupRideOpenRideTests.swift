import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// ROH-114: a group ride with no destination. The host creates one without a `Route`, and a
/// guest joining it must reach the lobby rather than the "couldn't load this ride's route"
/// dead end.
///
/// The discrimination that matters is three-way, and collapsing two of the cases is the trap
/// this suite exists to catch:
///
/// | route bytes | meaning | phase |
/// | --- | --- | --- |
/// | nil | open ride, by design | proceed |
/// | present, decodes | route ride | proceed |
/// | present, undecodable | corrupt payload | `.routeUnavailable`, and leave the ride |
///
/// Treating "nil" as "undecodable" bounces every guest out of an open ride *and removes them
/// server-side*. Treating "undecodable" as "nil" turns a corrupt route into a silent open
/// ride — a data-loss bug wearing a feature's clothes.
@MainActor
struct GroupRideOpenRideTests {
    private func route() -> Route {
        Route(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1),
              waypoints: [], geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
              profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0)
    }

    private func host(name: String = "Mike") async throws -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: name)
        let session = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                       displayNameProvider: { name })
        return (session, backend)
    }

    private func guest(sharing other: InMemoryGroupRideBackend, name: String)
        async throws -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend(sharing: other)
        try await backend.signIn(idToken: "t2", nonce: "n2", displayName: name)
        let session = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                       displayNameProvider: { name })
        return (session, backend)
    }

    @Test func creatingWithoutARouteReachesTheLobby() async throws {
        let (session, _) = try await host()

        await session.create(route: nil)

        #expect(session.phase == .lobby)
        #expect(session.isHost == true)
        #expect(session.joinCode != nil)
        #expect(session.route == nil, "an open ride carries no route")
    }

    @Test func joiningAnOpenRideReachesTheLobbyRatherThanRouteUnavailable() async throws {
        let (hostSession, hostBackend) = try await host()
        await hostSession.create(route: nil)
        let code = try #require(hostSession.joinCode)

        let (guestSession, guestBackend) = try await guest(sharing: hostBackend, name: "Priya")
        await guestSession.join(code: code)

        #expect(guestSession.phase == .lobby)
        #expect(guestSession.route == nil)
        #expect(guestBackend.store.leaveCalled == false,
                "an open ride must not bounce the guest back out")
    }

    @Test func aCreatedOpenRideReportsItsKind() async throws {
        let (session, _) = try await host()

        await session.create(route: nil)

        #expect(session.rideKind == .open)
    }

    @Test func aCreatedRouteRideReportsItsKind() async throws {
        let (session, _) = try await host()

        await session.create(route: route())

        #expect(session.rideKind == .route)
    }

    /// The one that catches the fake lying about the seam.
    ///
    /// A guest joining a *started* ride reads kind off a `GroupRide` that has been through the
    /// backend's start rebuild, so this covers both halves of the trap at once: the origin, where
    /// `createRide` has to derive kind from the absence of route bytes rather than stamping a
    /// fixed value, and the rebuild, which has to carry that value across instead of dropping it.
    /// Get either wrong and this ride reports `.route` with no route to show — which is the exact
    /// state that puts the rider on the "couldn't load this ride's route" screen.
    ///
    /// The host must finish acting **before** the guest exists: `Store.currentUserID` is one
    /// shared field, so `guest(sharing:)`'s sign-in overwrites the host's identity and a later
    /// `startRiding()` would fail its host check.
    @Test func aGuestJoiningAfterTheStartStillReportsAnOpenRide() async throws {
        let (hostSession, hostBackend) = try await host()
        await hostSession.create(route: nil)
        await hostSession.startRiding()
        #expect(hostSession.phase == .riding)
        let code = try #require(hostSession.joinCode)

        let (guestSession, _) = try await guest(sharing: hostBackend, name: "Priya")
        await guestSession.join(code: code)

        #expect(guestSession.phase == .riding)
        #expect(guestSession.rideKind == .open, "the ride's stored kind survives the start rebuild")
        #expect(guestSession.route == nil)
    }

    @Test func joiningARideWhoseRouteWillNotDecodeStillFailsAndLeaves() async throws {
        let (hostSession, hostBackend) = try await host()
        await hostSession.create(route: route())
        let code = try #require(hostSession.joinCode)
        let rideID = try #require(hostSession.rideID)
        // Corrupt the stored route: present on the wire, but not a `Route`.
        hostBackend.store.routes[rideID] = Data("{\"nonsense\":true}".utf8)

        let (guestSession, guestBackend) = try await guest(sharing: hostBackend, name: "Priya")
        await guestSession.join(code: code)

        #expect(guestSession.phase == .routeUnavailable,
                "a corrupt route is an error, not an open ride")
        #expect(guestBackend.store.leaveCalled == true)
    }
}
