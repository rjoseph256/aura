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

    @Test func isCustomTrueOnlyForTheAuthoredIdentity() {
        #expect(TerrainStyle.isCustom(TerrainStyle.authoredStyleIdentity) == true)
        #expect(TerrainStyle.isCustom(TerrainStyle.fallbackStyleURI) == false)
        #expect(TerrainStyle.isCustom("mapbox://styles/mapbox/outdoors-v12") == false)
    }

    @Test func authoredIdentityCarriesTheVersion() {
        #expect(TerrainStyle.authoredStyleIdentity == "aura-terrain-v\(TerrainStyle.styleVersion)")
        #expect(TerrainStyle.authoredStyleIdentity != TerrainStyle.fallbackStyleURI)
    }

    @Test func authoredResourceIsTheBundledBaseName() {
        #expect(TerrainStyle.authoredStyleResource == "AuraTerrainStyle")
    }
}
