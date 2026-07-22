import Testing
@testable import AuraCore

/// Frozen-literal gate on the Web Mercator tile/pixel placement (ROH-94).
/// Literals recorded 2026-07-22 from the independent slippy-map formula
/// (see the plan's Task 1 one-liner) — never recompute at test time.
struct TerrainRGBPlacementTests {

    @Test func pointStateParkPlacement() {
        let p = TerrainRGBPlacement.placement(lat: 40.4417, lon: -80.0086, z: 14)
        #expect(p.tileX == 4550)
        #expect(p.tileY == 6176)
        #expect(p.px == 184)
        #expect(p.py == 80)
    }

    @Test func southSideAnchorPlacement() {
        let p = TerrainRGBPlacement.placement(lat: 40.428, lon: -79.976, z: 14)
        #expect(p.tileX == 4552)
        #expect(p.tileY == 6177)
        #expect(p.px == 52)
        #expect(p.py == 34)
    }

    @Test func cathedralOfLearningPlacement() {
        let p = TerrainRGBPlacement.placement(lat: 40.4443, lon: -79.9532, z: 14)
        #expect(p.tileX == 4553)
        #expect(p.tileY == 6176)
        #expect(p.px == 61)
        #expect(p.py == 40)
    }

}
