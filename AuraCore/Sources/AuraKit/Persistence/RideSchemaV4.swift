import Foundation
import SwiftData
import AuraCore

/// V4 adds `SeenGemRecord` beside the unchanged V2 `RideRecord` and V3 `SavedPlaceRecord`
/// — adding a model type is a lightweight migration. CloudKit rules hold: a default on every
/// attribute, no `.unique`, no relationships. The Date default is the fixed sentinel.
public enum RideSchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [RideSchemaV2.RideRecord.self, RideSchemaV3.SavedPlaceRecord.self, SeenGemRecord.self]
    }

    @Model
    public final class SeenGemRecord {
        public var gemID: String = ""
        public var firstSeenAt: Date = Date(timeIntervalSince1970: 0)
        public init(gemID: String, firstSeenAt: Date) {
            self.gemID = gemID
            self.firstSeenAt = firstSeenAt
        }
    }
}

public typealias SeenGemRecord = RideSchemaV4.SeenGemRecord
