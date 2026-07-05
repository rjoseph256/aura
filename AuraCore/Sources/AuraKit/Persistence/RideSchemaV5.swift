import Foundation
import SwiftData
import AuraCore

/// V5 adds `resurface` to `SavedPlaceRecord`. Redeclared here (not mutated in V3) so the
/// V4→V5 delta is a real, well-defined single-attribute add. CloudKit rules hold: default
/// on every attribute, no `.unique`, no relationships. Date default is the fixed sentinel.
public enum RideSchemaV5: VersionedSchema {
    public static let versionIdentifier = Schema.Version(5, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [RideSchemaV2.RideRecord.self, SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self]
    }

    @Model
    public final class SavedPlaceRecord {
        public var id: UUID = UUID()
        public var name: String = ""
        public var subtitle: String?
        public var latitude: Double = 0
        public var longitude: Double = 0
        public var categoryRaw: String = "custom"
        public var kindRaw: String = "favorite"
        public var savedAt: Date = Date(timeIntervalSince1970: 0)
        public var resurface: Bool = false

        public init(_ value: SavedPlace) {
            id = value.id
            name = value.name
            subtitle = value.subtitle
            latitude = value.coordinate.latitude
            longitude = value.coordinate.longitude
            categoryRaw = value.category.rawValue
            kindRaw = value.kind.rawValue
            savedAt = value.savedAt
            resurface = value.resurface
        }

        /// nil when raws come from a newer app version this build can't read.
        public var value: SavedPlace? {
            guard let category = Place.Category(rawValue: categoryRaw),
                  let kind = SavedPlace.Kind(rawValue: kindRaw) else { return nil }
            return SavedPlace(id: id, name: name, subtitle: subtitle,
                              coordinate: Coordinate(latitude: latitude, longitude: longitude),
                              category: category, kind: kind, savedAt: savedAt, resurface: resurface)
        }
    }
}

public typealias SavedPlaceRecord = RideSchemaV5.SavedPlaceRecord
