import Testing
import AuraCore
@testable import AuraKit

@Suite @MainActor struct GuidanceControllerTests {
    private func gem(_ id: String, lat: Double = 40.50, lng: Double = -79.99) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: lng),
            category: .park, tier: .card, source: .curated)
    }
    private let origin = Coordinate(latitude: 40.44, longitude: -79.99)

    private func route(to gem: Gem) -> Route {
        // Real Route.init: (id:UUID=…, origin, destination, waypoints, geometry, profile,
        // distanceMeters, estimatedDurationSeconds, elevationGainMeters, elevationProfile=[]).
        // Profile cases are .mostPaths/.fastest/.flattest — there is no .cycling (verified).
        Route(origin: origin, destination: gem.coordinate, waypoints: [],
              geometry: [origin, gem.coordinate], profile: .mostPaths,
              distanceMeters: 1000, estimatedDurationSeconds: 300, elevationGainMeters: 0,
              elevationProfile: [0, 0])
    }

    /// A DetourRouting fake whose result we control, recording call count. Returns synchronously.
    final class FakeRouting: DetourRouting, @unchecked Sendable {
        var result: Result<Route, Error>
        private(set) var calls = 0
        init(_ result: Result<Route, Error>) { self.result = result }
        func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route {
            calls += 1
            switch result { case .success(let r): return r; case .failure(let e): throw e }
        }
    }
    /// Like FakeRouting but suspends first, so a `cancel()` issued before it resolves actually
    /// exercises the stale-completion generation guard (a synchronous fake would resolve too fast).
    final class DelayedFakeRouting: DetourRouting, @unchecked Sendable {
        var result: Result<Route, Error>
        init(_ result: Result<Route, Error>) { self.result = result }
        func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route {
            try await Task.sleep(for: .milliseconds(10))
            switch result { case .success(let r): return r; case .failure(let e): throw e }
        }
    }
    struct Offline: Error {}
    struct NoHeading: HeadingProviding { func headings() -> AsyncStream<Double> { AsyncStream { $0.finish() } } }

    private func controller(routing: any DetourRouting) -> GuidanceController {
        GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(script: [])) },
            routing: routing, heading: NoHeading())
    }

    @Test func requestFetchesRouteThenGuides() async throws {
        let g = gem("a")
        let c = controller(routing: FakeRouting(.success(route(to: g))))
        c.requestDetour(g, from: origin)
        #expect(c.phase == .routing(g))
        try await Task.sleep(for: .milliseconds(50))   // let the fetch Task resolve
        #expect(c.phase == .guiding(g))
        #expect(c.activeRoute != nil)
        #expect(c.isGuiding)
        #expect(c.isDetouring)
    }

    @Test func cancelBeforeRouteResolvesDiscardsStaleCompletion() async throws {
        let g = gem("a")
        // DELAYED routing so the route is still pending when cancel runs — this actually
        // exercises the generation guard (a synchronous fake would resolve before cancel, R2).
        let c = controller(routing: DelayedFakeRouting(.success(route(to: g))))
        c.requestDetour(g, from: origin)
        c.cancel()                                      // bumps generation while route pending
        #expect(c.phase == .inactive)
        try await Task.sleep(for: .milliseconds(50))    // let the delayed route resolve late
        #expect(c.phase == .inactive)                   // stale routeReady discarded by guard
        #expect(c.guidance == nil)
    }

    @Test func offlineRouteFallsBackToHeadingOnly() async throws {
        let g = gem("a")
        let c = controller(routing: FakeRouting(.failure(Offline())))
        c.requestDetour(g, from: origin)
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.phase == .headingOnly(g))
    }

    @Test func routeCacheAvoidsRefetchFromSameOrigin() async throws {
        let g = gem("a")
        let fake = FakeRouting(.success(route(to: g)))
        let c = controller(routing: fake)
        c.requestDetour(g, from: origin)
        try await Task.sleep(for: .milliseconds(50))
        c.cancel()
        c.requestDetour(g, from: origin)                // same gem, same origin
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.calls == 1)                         // second request served from cache
        #expect(c.phase == .guiding(g))
    }

    @Test func arrivalDetachesAndConfirmsWithoutEndingRide() async throws {
        // Scripted session that arrives immediately drives onArrive → detach + confirm.
        let g = gem("a")
        let c = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(script: [.arrivedAtDestination])) },
            routing: FakeRouting(.success(route(to: g))), heading: NoHeading())
        c.requestDetour(g, from: origin)
        try await Task.sleep(for: .milliseconds(80))
        #expect(c.phase == .inactive)                    // detached, ride not ended
        #expect(c.arrivalBanner?.id == "a")              // confirm chip set
        #expect(c.guidance == nil)
    }
}
