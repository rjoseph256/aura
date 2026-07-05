import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite("Guidance cacheKey")
struct GuidanceCacheKeyTests {
    struct NoHeading: HeadingProviding { func headings() -> AsyncStream<Double> { AsyncStream { $0.finish() } } }

    final class FakeRouting: DetourRouting, @unchecked Sendable {
        func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route {
            Route(origin: origin, destination: destination, waypoints: [],
                  geometry: [origin, destination], profile: .mostPaths,
                  distanceMeters: 1000, estimatedDurationSeconds: 300, elevationGainMeters: 0,
                  elevationProfile: [0, 0])
        }
    }

    private func controller() -> GuidanceController {
        GuidanceController(
            makeGuidance: { GuidanceViewModel(session: ScriptedGuidanceSession(script: [])) },
            routing: FakeRouting(), heading: NoHeading())
    }

    @Test func longitudeQuantizationScalesByCosLat() {
        let controller = controller()
        // NOTE: -79.9950/-79.9899 (brief's literal digits) straddle a quantization cell
        // boundary at this quantum (verified in both Python and Swift), so that exact pair
        // does not collide. -79.9950/-79.9949 sit mid-cell and are ~8.5 m apart (same order
        // of magnitude), which is what the brief's intent (two close points share a key) needs.
        let a = Coordinate(latitude: 40.0, longitude: -79.9950)
        let b = Coordinate(latitude: 40.0, longitude: -79.9949)   // ~8.5 m east at 40°
        #expect(controller.cacheKey("g", a) == controller.cacheKey("g", b))
        let far = Coordinate(latitude: 40.0, longitude: -79.9800)  // ~1.3 km east
        #expect(controller.cacheKey("g", a) != controller.cacheKey("g", far))
    }
}
