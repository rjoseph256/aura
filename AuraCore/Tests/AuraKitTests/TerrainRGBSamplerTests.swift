import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// Unit gate on the extracted sampling orchestration (ROH-94): ordered reads,
/// one lookup per unique tile, drop-on-miss. This is the SAME code the app
/// provider runs — that identity is the point of the extraction.
struct TerrainRGBSamplerTests {

    private actor LookupCounter {
        private(set) var requested: [TerrainTileID] = []
        func note(_ id: TerrainTileID) { requested.append(id) }
    }

    @Test func readsElevationsInRouteOrder() async throws {
        let tile = try TerrainFixture.decodedTile()
        // hillA is a monotonic climb: in-order reads are strictly increasing.
        let elevations = await TerrainRGBSampler.elevations(
            along: TerrainFixture.route(TerrainFixture.hillAPixels), zoom: 14,
            spacingMeters: 150, minSamples: 16, maxSamples: 96
        ) { id in id == TerrainFixture.tileID ? tile : nil }
        #expect(elevations.count == 16)
        for i in 1..<elevations.count {
            #expect(elevations[i] > elevations[i - 1])
        }
    }

    @Test func looksUpEachUniqueTileOnce() async throws {
        let tile = try TerrainFixture.decodedTile()
        let counter = LookupCounter()
        _ = await TerrainRGBSampler.elevations(
            along: TerrainFixture.route(TerrainFixture.riverbankPixels), zoom: 14,
            spacingMeters: 150, minSamples: 16, maxSamples: 96
        ) { id in
            await counter.note(id)
            return id == TerrainFixture.tileID ? tile : nil
        }
        // All 33 vertices live in one tile: exactly one lookup.
        #expect(await counter.requested == [TerrainFixture.tileID])
    }

    @Test func dropsSamplesWhoseTileIsUnavailable() async throws {
        // Lookup returns nil for everything: best-effort means empty, not zeros.
        let elevations = await TerrainRGBSampler.elevations(
            along: TerrainFixture.route(TerrainFixture.hillAPixels), zoom: 14,
            spacingMeters: 150, minSamples: 16, maxSamples: 96
        ) { _ in nil }
        #expect(elevations.isEmpty)
    }

    @Test func emptyRouteYieldsEmpty() async {
        let elevations = await TerrainRGBSampler.elevations(
            along: [], zoom: 14, spacingMeters: 150, minSamples: 16, maxSamples: 96
        ) { _ in nil }
        #expect(elevations.isEmpty)
    }
}
