import Testing
import Foundation
import AuraCore
@testable import AuraKit

private struct StubReading: ResurfacePlacesReading {
    let places: [SavedPlace]
    @MainActor func resurfacePlaces() -> [SavedPlace] { places }
}

@MainActor
@Suite("PersonalGemProvider")
struct PersonalGemProviderTests {
    @Test func mapsResurfacePlacesToTier3PersonalGems() async {
        let id = UUID()
        let reading = StubReading(places: [
            SavedPlace(id: id, name: "My overlook", subtitle: nil,
                       coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
                       category: .custom, kind: .favorite, savedAt: .init(timeIntervalSince1970: 1),
                       resurface: true)
        ])
        let provider = PersonalGemProvider(reading: reading)
        let gems = await provider.gems(near: Coordinate(latitude: 0, longitude: 0))
        #expect(gems.count == 1)
        #expect(gems.first?.id == "personal:\(id.uuidString)")
        #expect(gems.first?.source == .personal)
        #expect(gems.first?.tier == .cardHaptic)
        #expect(gems.first?.name == "My overlook")
    }
}
