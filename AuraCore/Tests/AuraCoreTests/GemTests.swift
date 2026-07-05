import Testing
import Foundation
@testable import AuraCore

@Suite struct GemTests {
    @Test func tierIsComparable() {
        #expect(GemTier.pin < GemTier.card)
        #expect(GemTier.cardHaptic > GemTier.card)
    }

    @Test func categoryCarriesDefaultTierAndArrivalRadius() {
        #expect(GemCategory.viewpoint.defaultTier == .cardHaptic)
        #expect(GemCategory.cafe.defaultTier == .pin)
        #expect(GemCategory.viewpoint.arrivalRadiusMeters > GemCategory.cafe.arrivalRadiusMeters)
    }

    @Test func cafeArrivalRadiusIsForgivingForBikes() {
        #expect(GemCategory.cafe.arrivalRadiusMeters == 40)
        #expect(GemCategory.viewpoint.arrivalRadiusMeters == 70)   // unchanged
    }

    @Test func gemRoundTripsThroughCodable() throws {
        let gem = Gem(id: "curated:grandview-overlook", name: "Grandview overlook",
                      coordinate: Coordinate(latitude: 40.43, longitude: -80.0),
                      category: .viewpoint, tier: .cardHaptic, source: .curated,
                      photoAsset: "grandview", why: "City skyline from the incline.")
        let data = try JSONEncoder().encode(gem)
        let decoded = try JSONDecoder().decode(Gem.self, from: data)
        #expect(decoded == gem)
    }
}
