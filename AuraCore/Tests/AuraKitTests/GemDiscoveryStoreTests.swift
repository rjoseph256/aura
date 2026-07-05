import Testing
import AuraCore
@testable import AuraKit

@MainActor
@Suite struct GemDiscoveryStoreTests {
    private struct StubProvider: GemProviding {
        let gems: [Gem]
        func gems(near coordinate: Coordinate) async -> [Gem] { gems }
    }
    private func gem(_ id: String, _ lat: Double) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: -80.0),
            category: .park, tier: .card, source: .curated)
    }

    @Test func publishesNearbyPinsAfterLoadAndUpdate() async {
        let store = GemDiscoveryStore(provider: StubProvider(gems: [gem("a", 40.4411), gem("b", 40.60)]),
                                      engine: GemDiscoveryEngine(proximityRadiusMeters: 1000, pinCap: 10))
        await store.load()
        store.update(at: Coordinate(latitude: 40.4406, longitude: -79.9959))
        #expect(store.visiblePins.map(\.id) == ["a"])
    }

    @Test func suppressedStorePublishesNoPins() async {
        let store = GemDiscoveryStore(provider: StubProvider(gems: [gem("a", 40.4406)]))
        await store.load()
        store.isSuppressed = true
        store.update(at: Coordinate(latitude: 40.4406, longitude: -79.9959))
        #expect(store.visiblePins.isEmpty)
    }
}
