import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite struct GemDiscoveryStoreActiveTests {
    private struct StubProvider: GemProviding {
        let gems: [Gem]
        func gems(near coordinate: Coordinate) async -> [Gem] { gems }
    }
    private let here = Coordinate(latitude: 40.4406, longitude: -79.9959)
    private func near(_ id: String, meters: Double, tier: GemTier) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: 40.4406 + meters / 111_320.0, longitude: -79.9959),
            category: .park, tier: tier, source: .curated)
    }

    @Test func surfacesCardAndFiresHapticForTier3() async {
        let haptics = SpyHaptics()
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("v", meters: 80, tier: .cardHaptic)]),
                                      seen: InMemorySeen(), haptics: haptics)
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(store.activeCard?.id == "v")
        #expect(haptics.count == 1)
    }

    @Test func tier2SurfacesCardWithoutHaptic() async {
        let haptics = SpyHaptics()
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("p", meters: 80, tier: .card)]),
                                      seen: InMemorySeen(), haptics: haptics)
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(store.activeCard?.id == "p")
        #expect(haptics.count == 0)
    }

    @Test func writesSeenOnSurface() async {
        let seen = InMemorySeen()
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("v", meters: 80, tier: .cardHaptic)]),
                                      seen: seen, haptics: SpyHaptics())
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(seen.ids.contains("v"))
    }

    @Test func seenBeforeSuppressesTheCard() async {
        let seen = InMemorySeen(); seen.ids = ["v"]
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("v", meters: 80, tier: .cardHaptic)]),
                                      seen: seen, haptics: SpyHaptics())
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(store.activeCard == nil)
    }
}
