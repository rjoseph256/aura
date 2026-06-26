import Foundation
import SwiftData

/// The persisted shape as it shipped before Wave 1 persistence. Frozen: do not
/// change it. It exists so the migration has a real "from" version and the
/// round-trip migration test can write old-shaped rows.
public enum RideSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [RideRecord.self] }

    @Model
    public final class RideRecord {
        @Attribute(.unique) public var id: UUID
        public var kindRaw: String
        public var startedAt: Date
        public var endedAt: Date?
        public var trackData: Data        // JSON-encoded [TrackPoint]
        public var statsData: Data?       // JSON-encoded RideStats
        public var destinationName: String?
        public var routeId: UUID?
        public var destinationPlaceId: UUID?

        public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                    trackData: Data, statsData: Data?, destinationName: String? = nil,
                    routeId: UUID?, destinationPlaceId: UUID?) {
            self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
            self.trackData = trackData; self.statsData = statsData
            self.destinationName = destinationName
            self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
        }
    }
}
