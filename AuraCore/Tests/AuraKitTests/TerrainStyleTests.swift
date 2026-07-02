import Testing
@testable import AuraKit

@Suite struct TerrainStyleTests {
    @Test func fallbackIsAWellFormedMapboxStyleURI() {
        #expect(TerrainStyle.fallbackStyleURI.hasPrefix("mapbox://styles/"))
    }

    @Test func resolvePrefersCustomWhenPresent() {
        #expect(TerrainStyle.resolve(custom: "mapbox://styles/aura/terrain123") == "mapbox://styles/aura/terrain123")
    }

    @Test func resolveFallsBackWhenNil() {
        #expect(TerrainStyle.resolve(custom: nil) == TerrainStyle.fallbackStyleURI)
    }

    @Test func isCustomTrueOnlyForAuraAuthoredStyles() {
        #expect(TerrainStyle.isCustom("mapbox://styles/aura/terrain123") == true)
        #expect(TerrainStyle.isCustom(TerrainStyle.fallbackStyleURI) == false)
        // A stock non-fallback Mapbox style must NOT read as the authored terrain.
        #expect(TerrainStyle.isCustom("mapbox://styles/mapbox/outdoors-v12") == false)
    }
}
