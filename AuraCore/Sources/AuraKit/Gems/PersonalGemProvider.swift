import Foundation
import AuraCore

/// Turns resurface-flagged saved places into Tier-3 `.personal` gems. Ignores `near:` —
/// the set is small and the engine's proximity gate handles range.
public struct PersonalGemProvider: GemProviding {
    private let reading: any ResurfacePlacesReading
    public init(reading: any ResurfacePlacesReading) { self.reading = reading }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
        let places = await reading.resurfacePlaces()
        return places.map { place in
            Gem(id: "personal:\(place.id.uuidString)", name: place.name,
                coordinate: place.coordinate, category: Self.gemCategory(place.category),
                tier: .cardHaptic, source: .personal, photoAsset: nil, why: nil)
        }
    }

    // `Place.Category` cases are exactly: brewery, trailhead, address, custom
    // (verified in AuraCore/Sources/AuraCore/Models/Place.swift). Tier is forced to
    // .cardHaptic below regardless — this only picks the pin glyph / arrival radius.
    private static func gemCategory(_ c: Place.Category) -> GemCategory {
        switch c {
        case .trailhead: return .viewpoint
        case .brewery: return .cafe
        default: return .landmark   // address / custom / any future case
        }
    }
}
