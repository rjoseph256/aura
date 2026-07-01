import Foundation
import SwiftData
import AuraCore

/// V3 adds `SavedPlaceRecord` beside the (unchanged) V2 `RideRecord` —
/// adding a model type is a lightweight migration. CloudKit rules hold:
/// defaults on every attribute, no `.unique`, no relationships. The Date
/// default is the fixed sentinel, not `.now` (see the V2 comment).
public enum RideSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [RideSchemaV2.RideRecord.self, SavedPlaceRecord.self]
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

        public init(_ value: SavedPlace) {
            id = value.id
            name = value.name
            subtitle = value.subtitle
            latitude = value.coordinate.latitude
            longitude = value.coordinate.longitude
            categoryRaw = value.category.rawValue
            kindRaw = value.kind.rawValue
            savedAt = value.savedAt
        }

        /// nil when raws come from a newer app version this build can't read.
        public var value: SavedPlace? {
            guard let category = Place.Category(rawValue: categoryRaw),
                  let kind = SavedPlace.Kind(rawValue: kindRaw) else { return nil }
            return SavedPlace(id: id, name: name, subtitle: subtitle,
                              coordinate: Coordinate(latitude: latitude, longitude: longitude),
                              category: category, kind: kind, savedAt: savedAt)
        }
    }
}

public typealias SavedPlaceRecord = RideSchemaV3.SavedPlaceRecord
