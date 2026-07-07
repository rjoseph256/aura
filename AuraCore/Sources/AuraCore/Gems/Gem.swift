import Foundation

public enum GemTier: Int, Codable, Sendable, Comparable {
    case pin = 1, card = 2, cardHaptic = 3
    public static func < (lhs: GemTier, rhs: GemTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum GemSource: String, Codable, Sendable {
    case curated, personal, live

    /// Cross-source arbitration order: personal (your own) beats curated beats live.
    /// Lower is higher priority. Used by the engine's surfacing pick and composite dedupe.
    public var priorityRank: Int {
        switch self {
        case .personal: return 0
        case .curated: return 1
        case .live: return 2
        }
    }
}

public enum GemCategory: String, Codable, Sendable, CaseIterable {
    case viewpoint, water, park, cafe, mural, climb, historic, landmark

    public var defaultTier: GemTier {
        switch self {
        case .viewpoint, .mural, .landmark: return .cardHaptic
        case .park, .water, .climb, .historic: return .card
        case .cafe: return .pin
        }
    }

    /// How close (meters) counts as "arrived" for this kind of place.
    public var arrivalRadiusMeters: Double {
        switch self {
        case .mural, .landmark: return 30
        case .cafe: return 40
        case .water, .historic: return 45
        case .park, .viewpoint, .climb: return 70
        }
    }
}

public struct Gem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let coordinate: Coordinate
    public let category: GemCategory
    public let tier: GemTier
    public let source: GemSource
    public let photoAsset: String?
    public let why: String?
    public let photoAttribution: String?

    public init(id: String, name: String, coordinate: Coordinate,
                category: GemCategory, tier: GemTier, source: GemSource,
                photoAsset: String? = nil, why: String? = nil,
                photoAttribution: String? = nil) {
        self.id = id; self.name = name; self.coordinate = coordinate
        self.category = category; self.tier = tier; self.source = source
        self.photoAsset = photoAsset; self.why = why
        self.photoAttribution = photoAttribution
    }
}
