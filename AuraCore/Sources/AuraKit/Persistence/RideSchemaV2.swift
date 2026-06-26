import Foundation
import SwiftData

/// The current persisted shape. Drops `@Attribute(.unique)` (CloudKit-ready),
/// moves the GPS track to external storage so a summary fetch never faults it,
/// and denormalizes the summary numbers + a thumbnail polyline into columns.
public enum RideSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] { [RideRecord.self] }

    @Model
    public final class RideRecord {
        public var id: UUID
        public var kindRaw: String
        public var startedAt: Date
        public var endedAt: Date?
        @Attribute(.externalStorage) public var trackData: Data   // JSON-encoded [TrackPoint]
        public var statsData: Data?                                // JSON-encoded RideStats (canonical)
        // Denormalized summary columns (defaults let old rows migrate cleanly;
        // backfilled by RideMigrationPlan, written by RideMapper.record(from:)).
        public var distanceMeters: Double = 0
        public var movingTimeSeconds: Double = 0
        public var elevationGainMeters: Double = 0
        public var thumbnailData: Data?                            // JSON-encoded [Coordinate]; nil when < 2 points
        public var destinationName: String?
        public var routeId: UUID?
        public var destinationPlaceId: UUID?

        public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                    trackData: Data, statsData: Data?,
                    distanceMeters: Double = 0, movingTimeSeconds: Double = 0,
                    elevationGainMeters: Double = 0, thumbnailData: Data? = nil,
                    destinationName: String? = nil, routeId: UUID?, destinationPlaceId: UUID?) {
            self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
            self.trackData = trackData; self.statsData = statsData
            self.distanceMeters = distanceMeters; self.movingTimeSeconds = movingTimeSeconds
            self.elevationGainMeters = elevationGainMeters; self.thumbnailData = thumbnailData
            self.destinationName = destinationName
            self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
        }
    }
}

/// The rest of AuraKit refers to the current model as `RideRecord`.
public typealias RideRecord = RideSchemaV2.RideRecord
