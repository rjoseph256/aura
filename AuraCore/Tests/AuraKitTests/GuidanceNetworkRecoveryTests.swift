import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// e2e coverage for the `probeNetworkRecovery` throttle (GuidanceController.riderDidUpdate):
/// offline → `.headingOnly` → routing seam recovers → controller upgrades back to full
/// `.guiding`. Reuses the Plan-3 detour doubles/helpers from GuidanceControllerTests.swift
/// (`FakeRouting`, `HeadingProviding` stubs, `awaitState`) rather than inventing new ones.
@MainActor
@Suite("Guidance network recovery")
struct GuidanceNetworkRecoveryTests {
    private func gem(_ id: String, lat: Double = 40.50, lng: Double = -79.99) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: lng),
            category: .park, tier: .card, source: .curated)
    }
    private let origin = Coordinate(latitude: 40.44, longitude: -79.99)

    private func route(to gem: Gem) -> Route {
        Route(origin: origin, destination: gem.coordinate, waypoints: [],
              geometry: [origin, gem.coordinate], profile: .mostPaths,
              distanceMeters: 1000, estimatedDurationSeconds: 300, elevationGainMeters: 0,
              elevationProfile: [0, 0])
    }

    /// A DetourRouting fake whose result can be flipped mid-test (failing → succeeding), so a
    /// single instance can drive the offline phase and then the recovery phase. Mirrors
    /// GuidanceControllerTests.FakeRouting, but `result` is settable from the test body — the
    /// original FakeRouting already declares `result` as `var`, so this is the same shape,
    /// duplicated here (test-only) rather than reaching into the other file's private type.
    final class MutableFakeRouting: DetourRouting, @unchecked Sendable {
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
    struct Offline: Error {}
    struct NoHeading: HeadingProviding { func headings() -> AsyncStream<Double> { AsyncStream { $0.finish() } } }

    @Test func headingOnlyUpgradesToFullGuidanceOnRecovery() async throws {
        // Far away so the throttle's worth of fixes below never enter the arrival radius (mirrors
        // headingOnlyPublishesArrowBeforeArrival's distance choice).
        let g = gem("a", lat: 40.55, lng: -79.99)
        let fake = MutableFakeRouting(.failure(Offline()))
        let c = GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(script: [])) },
            routing: fake, heading: NoHeading())

        // 1. Offline: routing fails → controller falls back to headingOnly.
        c.requestDetour(g, from: origin)
        await c.awaitState { if case .headingOnly = c.phase { return true } else { return false } }
        #expect(c.phase == .headingOnly(g))

        // 2. Network recovers: flip the stub to succeed.
        fake.result = .success(route(to: g))

        // 3. Feed the probeNetworkRecovery throttle's worth of rider updates (every 8th fix
        //    triggers a probe — GuidanceController.riderDidUpdate, `recoveryThrottle % 8 == 0`).
        //    Coordinates stay far from `g` so none of these satisfy the arrival radius.
        let riderNear = Coordinate(latitude: 40.45, longitude: -79.99)
        for _ in 0..<8 {
            c.riderDidUpdate(TrackPoint(coordinate: riderNear, elevation: nil,
                                        timestamp: .init(), speedMetersPerSecond: 3))
        }

        // 4. Await the in-flight routing task(s) — first the recovery probe, then the
        //    follow-up fetchRoute triggered by .networkRecovered — and assert the phase
        //    upgraded to full guidance.
        await c.awaitState { c.isGuiding }
        #expect(c.phase == .guiding(g))
        #expect(c.activeRoute != nil)
        #expect(c.isGuiding)
    }
}
