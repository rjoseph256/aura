import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite struct GemDiscoveryStoreArbiterTests {
    private struct StubProvider: GemProviding {
        let gems: [Gem]
        func gems(near coordinate: Coordinate) async -> [Gem] { gems }
    }
    private let here = Coordinate(latitude: 40.4406, longitude: -79.9959)
    private func near(_ id: String, meters: Double, tier: GemTier) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: 40.4406 + meters / 111_320.0, longitude: -79.9959),
            category: .park, tier: tier, source: .curated)
    }

    @Test func detourActiveSuppressesCardAndHapticButKeepsPinsAndSeen() async {
        let haptics = SpyHaptics()
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("v", meters: 80, tier: .cardHaptic)]),
                                      seen: InMemorySeen(), haptics: haptics)
        store.detourActive = { true }
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(store.activeCard == nil)
        #expect(haptics.count == 0)
        #expect(store.visiblePins.contains { $0.id == "v" })
        #expect(store.seenIDs.contains("v"))
    }
}
