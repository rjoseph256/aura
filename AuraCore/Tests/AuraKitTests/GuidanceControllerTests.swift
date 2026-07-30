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
            switch result {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }
    /// Like FakeRouting but suspends first, so a `cancel()` issued before it resolves actually
    /// exercises the stale-completion generation guard (a synchronous fake would resolve too fast).
    final class DelayedFakeRouting: DetourRouting, @unchecked Sendable {
        var result: Result<Route, Error>
        init(_ result: Result<Route, Error>) { self.result = result }
        func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route {
            try await Task.sleep(for: .milliseconds(10))
            switch result {
            case .success(let r): return r
            case .failure(let e): throw e
            }
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
        await c.awaitState { c.isGuiding }
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
        await c.awaitState { true }                      // await the delayed fetch's late completion
        #expect(c.phase == .inactive)                   // stale routeReady discarded by guard
        #expect(c.guidance == nil)
    }

    @Test func offlineRouteFallsBackToHeadingOnly() async throws {
        let g = gem("a")
        let c = controller(routing: FakeRouting(.failure(Offline())))
        c.requestDetour(g, from: origin)
        await c.awaitState { if case .headingOnly = c.phase { return true } else { return false } }
        #expect(c.phase == .headingOnly(g))
    }

    @Test func routeCacheAvoidsRefetchFromSameOrigin() async throws {
        let g = gem("a")
        let fake = FakeRouting(.success(route(to: g)))
        let c = controller(routing: fake)
        c.requestDetour(g, from: origin)
        await c.awaitState { c.isGuiding }
        c.cancel()
        c.requestDetour(g, from: origin)                // same gem, same origin
        await c.awaitState { c.isGuiding }
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
        await c.awaitState { c.phase == .inactive }
        #expect(c.phase == .inactive)                    // detached, ride not ended
        #expect(c.arrivalBanner?.id == "a")              // confirm chip set
        #expect(c.guidance == nil)
    }

    /// Heading provider that emits one fixed heading then stays open.
    struct FixedHeading: HeadingProviding {
        let degrees: Double
        func headings() -> AsyncStream<Double> {
            AsyncStream { cont in cont.yield(degrees); /* stays open */ }
        }
    }

    @Test func headingOnlyArrivesWithinRadius() async throws {
        let g = gem("a", lat: 40.4410, lng: -79.9959)   // park → 70 m radius
        let c = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(script: [])) },
            routing: FakeRouting(.failure(Offline())), heading: FixedHeading(degrees: 0))
        c.requestDetour(g, from: Coordinate(latitude: 40.4406, longitude: -79.9959))
        await c.awaitState { if case .headingOnly = c.phase { return true } else { return false } }
        #expect(c.phase == .headingOnly(g))
        // Feed a fix ~10 m from the gem → inside the 70 m arrival radius.
        // Real TrackPoint.init: (coordinate:, elevation: Double?, timestamp:, speedMetersPerSecond: Double? = nil).
        c.riderDidUpdate(TrackPoint(coordinate: g.coordinate, elevation: nil, timestamp: .init(), speedMetersPerSecond: 3))
        #expect(c.phase == .inactive)
        #expect(c.arrivalBanner?.id == "a")
    }

    @Test func retargetSwitchesToNewGem() async throws {
        let g1 = gem("a")
        let g2 = gem("b", lat: 40.60, lng: -79.98)
        let c = controller(routing: FakeRouting(.success(route(to: g1))))
        c.requestDetour(g1, from: origin)
        await c.awaitState { c.isGuiding }
        #expect(c.phase == .guiding(g1))
        c.retarget(g2, from: origin)
        await c.awaitState { c.phase == .guiding(g2) }
        #expect(c.phase == .guiding(g2))
    }

    @Test func headingOnlyPublishesArrowBeforeArrival() async throws {
        let g = gem("a", lat: 40.55, lng: -79.99)        // far away
        let c = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(script: [])) },
            routing: FakeRouting(.failure(Offline())), heading: FixedHeading(degrees: 0))
        c.requestDetour(g, from: Coordinate(latitude: 40.44, longitude: -79.99))
        await c.awaitState { if case .headingOnly = c.phase { return true } else { return false } }
        c.riderDidUpdate(TrackPoint(coordinate: Coordinate(latitude: 40.45, longitude: -79.99),
                                    elevation: nil, timestamp: .init(), speedMetersPerSecond: 3))
        #expect(c.headingArrow != nil)
        #expect((c.headingArrow?.straightLineDistanceMeters ?? 0) > 100)
    }

    // MARK: - Pause forwarding (ROH-101)

    /// The Explore HUD sets the coordinator's `pauseObserver` to the controller, so a pause has
    /// to reach the `GuidanceViewModel` the controller built for the leg in flight — otherwise
    /// turn haptics keep firing at a rider standing still.
    @Test func pauseForwardsToTheLegInFlight() async throws {
        let g = gem("a")
        let c = controller(routing: FakeRouting(.success(route(to: g))))
        c.requestDetour(g, from: origin)
        await c.awaitState { c.isGuiding }
        let vm = try #require(c.guidance)
        #expect(vm.isPaused == false)

        c.rideDidSetPaused(true)
        #expect(vm.isPaused)

        c.rideDidSetPaused(false)
        #expect(vm.isPaused == false)
    }

    /// A rider can pause at a café and only then tap "Take me there". The leg built during that
    /// stop must start paused rather than buzz at them.
    @Test func legStartedWhilePausedStartsPaused() async throws {
        let g = gem("a")
        let c = controller(routing: FakeRouting(.success(route(to: g))))
        c.rideDidSetPaused(true)            // paused before any leg exists
        #expect(c.guidance == nil)

        c.requestDetour(g, from: origin)
        await c.awaitState { c.isGuiding }
        #expect(try #require(c.guidance).isPaused)
    }
}

extension GuidanceController {
    /// Test barrier: await the in-flight routing task, then cooperatively yield until
    /// `predicate` holds (bounded). Deterministic — drains real async work instead of
    /// racing a fixed sleep, so it is stable under parallel `swift test`.
    func awaitState(_ predicate: @escaping () -> Bool) async {
        await pendingRoutingTask?.value
        for _ in 0..<100_000 {
            if predicate() { return }
            await Task.yield()
        }
    }
}
