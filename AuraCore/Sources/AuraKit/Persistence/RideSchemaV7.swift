import Foundation
import SwiftData
import AuraCore

/// V7 adds `checkpointedAt` — when the pause-boundary flush last wrote the row, nil once the
/// rider ends the ride (ROH-107). One optional attribute, so the stage is lightweight and
/// nothing moves at launch.
///
/// **The entity name stays `RideRecord`.** CloudKit derives its record type from it, so a
/// rename produces a new `CD_` type and orphans every already-synced ride.
///
/// CloudKit rules hold: optionality or a default on every attribute, no `.unique`, no
/// relationships — machine-checked by `SchemaInvariantTests`. Date defaults are the fixed
/// sentinel, per the V2 comment.
///
/// **Why a column rather than a nil `endedAt`.** Revision 1 of the spec used nil `endedAt` and
/// needed no schema change. Two things a nil cannot do: tell a second synced device that the
/// row is being recorded *right now* rather than abandoned, and say what the recording covers
/// when the rider resumed and was killed later while riding. See the spec's D1.
public enum RideSchemaV7: VersionedSchema {
    public static let versionIdentifier = Schema.Version(7, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [RideRecord.self, RideSchemaV5.SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self]
    }

    @Model
    public final class RideRecord {
        public var id: UUID = UUID()
        public var kindRaw: String = "free"
        // Fixed sentinel, not `.now`: a default is only used when CloudKit materializes a
        // record missing this key, and "now" would be a misleading start time.
        public var startedAt: Date = Date(timeIntervalSince1970: 0)
        public var endedAt: Date?
        /// Flat, complete JSON `[TrackPoint]`. Still written from V6 on: a V5 build syncing
        /// the same CloudKit record reads this and only this, so it must never go partial.
        @Attribute(.externalStorage) public var trackData: Data = Data()
        /// JSON-encoded `[RideSegment]` — the segmented truth V6 exists for.
        @Attribute(.externalStorage) public var segmentsData: Data?
        public var statsData: Data?
        public var distanceMeters: Double = 0
        public var movingTimeSeconds: Double = 0
        public var pausedSeconds: Double = 0
        /// Set by the pause-boundary flush, cleared by `finish()`. Nil on every row written
        /// before V7, which is the correct reading: they all came from `finish()`.
        public var checkpointedAt: Date?
        public var elevationGainMeters: Double = 0
        public var thumbnailData: Data?
        public var destinationName: String?
        public var routeId: UUID?
        public var destinationPlaceId: UUID?

        public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                    trackData: Data, segmentsData: Data?, statsData: Data?,
                    distanceMeters: Double = 0, movingTimeSeconds: Double = 0,
                    pausedSeconds: Double = 0, checkpointedAt: Date? = nil,
                    elevationGainMeters: Double = 0,
                    thumbnailData: Data? = nil, destinationName: String? = nil,
                    routeId: UUID?, destinationPlaceId: UUID?) {
            self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
            self.trackData = trackData; self.segmentsData = segmentsData; self.statsData = statsData
            self.distanceMeters = distanceMeters; self.movingTimeSeconds = movingTimeSeconds
            self.pausedSeconds = pausedSeconds; self.checkpointedAt = checkpointedAt
            self.elevationGainMeters = elevationGainMeters
            self.thumbnailData = thumbnailData; self.destinationName = destinationName
            self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
        }
    }
}

/// The rest of AuraKit refers to the current model as `RideRecord`.
public typealias RideRecord = RideSchemaV7.RideRecord
