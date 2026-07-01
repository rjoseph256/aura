import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideSessionLifecycleTests {
    private func route() -> Route {
        Route(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1),
              waypoints: [], geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
              profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0)
    }
    private func make(name: String = "Mike") async throws -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: name)
        let s = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                 displayNameProvider: { name })
        return (s, backend)
    }
    @Test func createEntersLobbyAsHost() async throws {
        let (s, _) = try await make()
        await s.create(route: route())
        #expect(s.phase == .lobby)
        #expect(s.isHost == true)
        #expect(s.joinCode != nil)
        #expect(s.route != nil)
    }
    @Test func startRidingTransitions() async throws {
        let (s, _) = try await make()
        await s.create(route: route())
        s.startRiding()
        #expect(s.phase == .riding)
    }
    // Builds a signed-in guest session sharing the host's store, ready to join.
    private func guest(sharing host: InMemoryGroupRideBackend, name: String) async throws
        -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend(sharing: host)
        try await backend.signIn(idToken: "t2", nonce: "n2", displayName: name)
        return (GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                 displayNameProvider: { name }), backend)
    }
    @Test func joinEntersRidingAsMemberWithRoute() async throws {
        let (host, hostBackend) = try await make(name: "Mike")
        await host.create(route: route())
        let (guest, _) = try await guest(sharing: hostBackend, name: "Sara")
        await guest.join(code: host.joinCode!)
        #expect(guest.phase == .riding)          // D3 rolling join — never parked in a lobby
        #expect(guest.isHost == false)
        #expect(guest.route?.geometry.count == 2)
    }
    @Test func joinWithCorruptRouteEntersRouteUnavailableAndLeaves() async throws {
        let (host, hostBackend) = try await make(name: "Mike")
        await host.create(route: route())
        // Corrupt the stored route bytes so JSONDecoder().decode(Route.self) fails on join.
        hostBackend.store.routes[host.rideID!] = Data("not-a-route".utf8)
        let (guest, guestBackend) = try await guest(sharing: hostBackend, name: "Sara")
        await guest.join(code: host.joinCode!)
        #expect(guest.phase == .routeUnavailable)
        #expect(guestBackend.store.leaveCalled == true)   // auto-left to free the slot
    }
    @Test func createTooLargeEntersCreateFailed() async throws {
        let (s, backend) = try await make()
        backend.store.forceCreateError = .routeTooLarge   // simulates the >256 KB rides.route check
        await s.create(route: route())
        #expect(s.phase == .createFailed)
    }
    @Test func emptyNameGatesCreate() async throws {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "")
        let s = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                 displayNameProvider: { "   " })
        await s.create(route: route())
        #expect(s.phase == .needsDisplayName)
    }
    @Test func emptyNameGatesJoin() async throws {          // the deep-link-reachable gate
        let (host, hostBackend) = try await make(name: "Mike")
        await host.create(route: route())
        let (guest, _) = try await guest(sharing: hostBackend, name: "")   // provider returns ""
        await guest.join(code: host.joinCode!)
        #expect(guest.phase == .needsDisplayName)
    }
}
