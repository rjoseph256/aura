import Foundation
import SwiftData

/// Drops `@Attribute(.unique)` (CloudKit-ready), moves the GPS track to external storage so a
/// summary fetch never faults it, and denormalizes the summary numbers + a thumbnail polyline
/// into columns.
///
/// **Frozen.** V3, V4 and V5 all list this exact class, so adding a property here would
/// retroactively rehash four schema versions and leave an on-disk V5 store matching none of
/// them. The current shape is `RideSchemaV7.RideRecord`, at the end of a redeclaration chain
/// (V6 redeclares this one, V7 redeclares V6's) that the `RideRecord` typealias follows.
public enum RideSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] { [RideRecord.self] }

    @Model
    public final class RideRecord {
        public var id: UUID = UUID()
        public var kindRaw: String = "free"
        // Fixed sentinel, not `.now`: a default is only used when CloudKit materializes a
        // record missing this key, and "now" would be a misleading start time. Every
        // app-created row sets startedAt in init, so the sentinel is never seen normally.
        public var startedAt: Date = Date(timeIntervalSince1970: 0)
        public var endedAt: Date?
        @Attribute(.externalStorage) public var trackData: Data = Data()   // JSON-encoded [TrackPoint]
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
