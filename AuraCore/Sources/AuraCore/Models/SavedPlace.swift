import Foundation

/// A rider-saved destination: Home or a favorite. Persisted as
/// `SavedPlaceRecord` (AuraKit) and mirrored per-record through CloudKit.
public struct SavedPlace: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case home, favorite
    }

    public var id: UUID
    public var name: String
    /// The search result's address/context line, shown in lists for provenance.
    public var subtitle: String?
    public var coordinate: Coordinate
    public var category: Place.Category
    public var kind: Kind
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, subtitle: String?,
                coordinate: Coordinate, category: Place.Category,
                kind: Kind, savedAt: Date) {
        self.id = id; self.name = name; self.subtitle = subtitle
        self.coordinate = coordinate; self.category = category
        self.kind = kind; self.savedAt = savedAt
    }

    /// Save a picked place. Keeps the place's id so a row pushed back into
    /// navigation matches by id, not just coordinate.
    public init(place: Place, subtitle: String? = nil,
                kind: Kind = .favorite, savedAt: Date) {
        self.init(id: place.id, name: place.name,
                  subtitle: subtitle ?? place.subtitle,
                  coordinate: place.coordinate, category: place.category,
                  kind: kind, savedAt: savedAt)
    }

    /// The navigable place, flagged saved.
    public var place: Place {
        Place(id: id, name: name, subtitle: subtitle,
              coordinate: coordinate, category: category, isSaved: true)
    }
}
