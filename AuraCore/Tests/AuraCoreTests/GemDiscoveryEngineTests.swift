import Testing
@testable import AuraCore

@Suite struct GemDiscoveryEngineTests {
    private func gem(_ id: String, _ lat: Double, _ lng: Double) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: lng),
            category: .park, tier: .card, source: .curated)
    }
    private let here = Coordinate(latitude: 40.4406, longitude: -79.9959) // Pittsburgh

    @Test func dropsGemsOutsideTheProximityRadius() {
        let engine = GemDiscoveryEngine(proximityRadiusMeters: 1000, pinCap: 10)
        let near = gem("near", 40.4410, -79.9959)     // ~45 m
        let far  = gem("far", 40.5000, -79.9959)      // ~6.6 km
        let pins = engine.visiblePins(from: [near, far], at: here)
        #expect(pins.map(\.id) == ["near"])
    }

    @Test func capsToNearestN() {
        let engine = GemDiscoveryEngine(proximityRadiusMeters: 5000, pinCap: 2)
        let gems = [gem("d3", 40.4460, -79.9959), gem("d1", 40.4411, -79.9959),
                    gem("d2", 40.4430, -79.9959)]
        let pins = engine.visiblePins(from: gems, at: here)
        #expect(pins.map(\.id) == ["d1", "d2"]) // nearest two, sorted by distance
    }
}
