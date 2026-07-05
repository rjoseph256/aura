import Foundation

/// Pure OSM-tag → gem mapping for the live feed. No networking: `LiveGemProvider`
/// parses Overpass JSON and calls these. Unmapped tags are dropped (nil), never surfaced.
public enum OSMGemMapping {
    /// First matching rule wins. Kept deliberately small — scenic/outdoor gems, not commerce.
    public static func category(for tags: [String: String]) -> GemCategory? {
        if tags["tourism"] == "viewpoint" { return .viewpoint }
        if tags["amenity"] == "drinking_water" || tags["natural"] == "spring" { return .water }
        if tags["leisure"] == "park" { return .park }
        if tags["amenity"] == "cafe" { return .cafe }
        if tags["tourism"] == "artwork" { return .mural }
        if tags["historic"] != nil { return .historic }
        if tags["tourism"] == "attraction" { return .landmark }
        return nil
    }

    /// Display noun when an element has no `name` tag.
    private static func noun(_ category: GemCategory) -> String {
        switch category {
        case .viewpoint: return "Viewpoint"
        case .water: return "Water"
        case .park: return "Park"
        case .cafe: return "Café"
        case .mural: return "Mural"
        case .climb: return "Climb"
        case .historic: return "Historic site"
        case .landmark: return "Landmark"
        }
    }

    public static func gem(id: String, name: String?, coordinate: Coordinate,
                           tags: [String: String]) -> Gem? {
        guard let category = category(for: tags) else { return nil }
        let tier: GemTier = min(category.defaultTier, .card)   // live caps at Tier 2
        return Gem(id: id, name: name ?? noun(category), coordinate: coordinate,
                   category: category, tier: tier, source: .live, photoAsset: nil, why: nil)
    }
}
