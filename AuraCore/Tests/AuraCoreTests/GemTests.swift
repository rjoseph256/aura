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

    @Test func photoAttributionDefaultsToNilAndRoundTrips() throws {
        // Absent in JSON decodes to nil (backward-compat with existing gems.json).
        let json = #"{"id":"curated:x","name":"X","coordinate":{"latitude":40.44,"longitude":-80.0},"category":"park","tier":2,"source":"curated"}"#
        let decoded = try JSONDecoder().decode(Gem.self, from: Data(json.utf8))
        #expect(decoded.photoAttribution == nil)

        // Present round-trips.
        let gem = Gem(id: "curated:y", name: "Y",
                      coordinate: Coordinate(latitude: 40.44, longitude: -80.0),
                      category: .mural, tier: .cardHaptic, source: .curated,
                      photoAsset: "gem-y", why: "A wall.", photoAttribution: "Jane Doe, CC BY-SA 4.0")
        let data = try JSONEncoder().encode(gem)
        #expect(try JSONDecoder().decode(Gem.self, from: data).photoAttribution == "Jane Doe, CC BY-SA 4.0")
    }

    @Test func muralAndLandmarkArrivalRadiusSurvivesOneMissedFix() {
        // At ~7 m/s a sub-25m radius can be blown past between GPS fixes; 38m is the floor.
        #expect(GemCategory.mural.arrivalRadiusMeters == 38)
        #expect(GemCategory.landmark.arrivalRadiusMeters == 38)
        #expect(GemCategory.viewpoint.arrivalRadiusMeters == 70)   // deliberately unchanged this pass
    }
}
