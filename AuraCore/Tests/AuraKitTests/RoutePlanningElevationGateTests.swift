import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// THE ROH-94 gate: runs the production route-planning elevation pipeline
/// (sampler → RouteMetrics.elevationGain → RouteRanker) over the committed
/// fixture tile and fails if elevation ever silently goes flat — the
/// Terrain-RGB regression class both golden-ride specs list as "not caught".
///
/// Gains are frozen literals from the DEM function (TERRAIN_FIXTURE_RECORD=1),
/// ±0.5 m absolute: sampling and fixture are deterministic; intentional
/// changes are re-record events, not tolerance headroom. Offset/scale decode
/// errors are the decoder gate's job (pixel literals), not this suite's.
struct RoutePlanningElevationGateTests {

    private static let expectedGains: [Double] = [179.2, 0.0, 32.0]

    private func gains() async throws -> [Double] {
        let tile = try TerrainFixture.decodedTile()
        var result: [Double] = []
        for pixels in [TerrainFixture.hillAPixels, TerrainFixture.riverbankPixels, TerrainFixture.hillBPixels] {
            let elevations = await TerrainRGBSampler.elevations(
                along: TerrainFixture.route(pixels), zoom: 14,
                spacingMeters: 150, minSamples: 16, maxSamples: 96
            ) { id in id == TerrainFixture.tileID ? tile : nil }
            #expect(!elevations.isEmpty)
            result.append(RouteMetrics.elevationGain(elevations: elevations))
        }
        return result
    }

    @Test func gainsMatchFrozenLiteralsAndAreNotFlat() async throws {
        let gains = try await gains()
        #expect(gains.count == 3)
        // The flat-regression kill line: a silently flat pipeline makes every
        // gain 0 — both of these plus the literals fail.
        #expect(gains.contains { $0 > 0.0 })
        #expect(Set(gains).count > 1)
        for (gain, expected) in zip(gains, Self.expectedGains) {
            #expect(abs(gain - expected) < 0.5)
        }
    }

    @Test func flattestLabelGoesToTheRiverbankRoute() async throws {
        let gains = try await gains()
        // Choreographed non-elevation fields (spec §4): RouteRanker assigns
        // mostPaths first and dedups winners, so hillA must win mostPaths
        // (lowest walkFraction) and hillB fastest (lowest duration), forcing
        // .flattest onto the minimum-gain candidate.
        let pixelSets = [TerrainFixture.hillAPixels, TerrainFixture.riverbankPixels, TerrainFixture.hillBPixels]
        let walkFractions = [0.0, 0.1, 0.2]
        let durations = [600.0, 500.0, 300.0]
        let candidates = (0..<3).map { i in
            CandidateRoute(geometry: TerrainFixture.route(pixelSets[i]),
                           distanceMeters: 1600,
                           estimatedDurationSeconds: durations[i],
                           elevationGainMeters: gains[i],
                           walkFraction: walkFractions[i])
        }
        let origin = TerrainFixture.coordinate(px: 16, py: 40)
        let destination = TerrainFixture.coordinate(px: 240, py: 40)
        let labeled = RouteRanker.labeled(origin: origin, destination: destination, candidates: candidates)

        let flattest = try #require(labeled.first { $0.route.profile == .flattest })
        #expect(flattest.sourceIndex == 1)  // the riverbank candidate
        // And the choreography itself held (guards against silent re-labeling):
        let mostPaths = try #require(labeled.first { $0.route.profile == .mostPaths })
        #expect(mostPaths.sourceIndex == 0)
        let fastest = try #require(labeled.first { $0.route.profile == .fastest })
        #expect(fastest.sourceIndex == 2)
    }
}
