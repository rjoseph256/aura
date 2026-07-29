import Foundation
import SwiftData
import AuraCore

/// V6 adds `segmentsData` — the ride's track split at every pause — and `pausedSeconds` to
/// `RideRecord`.
///
/// **Redeclared, not mutated.** `RideRecord` was a typealias to `RideSchemaV2.RideRecord`, and
/// V3, V4 and V5 all list that same class. Adding a property to it would retroactively change
/// the entity hash of V2 through V5, so a store on disk stamped V5 would match no schema in
/// the plan at all. `RideSchemaV5` redeclared `SavedPlaceRecord` for the same family of
/// reason (`RideSchemaV5.swift:5-7`): a schema version's delta has to be a real, well-defined
/// add against a frozen predecessor.
///
/// **The entity name stays `RideRecord`.** CloudKit derives its record type from it, so a
/// rename produces a new `CD_` type and orphans every already-synced ride.
///
/// CloudKit rules hold: optionality or a default on every attribute, no `.unique`, no
/// relationships — machine-checked by `SchemaInvariantTests`. Date defaults are the fixed
/// sentinel, per the V2 comment.
///
/// **No "unfinished ride" flag (ROH-107).** Considered here and deliberately left out. The
/// production schema is immutable once promoted, ROH-107 has not settled what that state
/// stores, and it may need no column at all: `RideSummary.endedAt` is already `Date?` and
/// spec D5 already describes a statless treatment for a nil `endedAt`. What blocks that today
/// is that Pass 2's checkpoint stamps `endedAt` *because* no surface reads it — an app-side
/// problem, not a schema one. See decision D-g in the Pass 3 plan.
public enum RideSchemaV6: VersionedSchema {
    public static let versionIdentifier = Schema.Version(6, 0, 0)
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
        /// JSON-encoded `[RideSegment]` — the segmented truth this schema exists for.
        ///
        /// `nil` means "not backfilled": a row written before V6, or one materialized from a
        /// V5 device's CloudKit copy. Reads fall back to wrapping `trackData` for those, and
        /// `RideSegmentBackfiller` fills them in off the launch path.
        ///
        /// `.externalStorage` for the same reason as `trackData`: `RideStore.summaries()`
        /// fetches every row, and a ~300 KB blob sitting inline would be faulted on each one
        /// (ROH-64). Asserted on the attribute in `SchemaInvariantTests`, because a behavioral
        /// check cannot see it — `trackData` externalizes on the same row regardless.
        @Attribute(.externalStorage) public var segmentsData: Data?
        public var statsData: Data?                                // JSON-encoded RideStats (canonical)
        // Denormalized summary columns (defaults let old rows migrate cleanly;
        // written by RideMapper.record(from:)).
        public var distanceMeters: Double = 0
        public var movingTimeSeconds: Double = 0
        /// Accumulated paused time. Active time — the number the summary leads with — is
        /// `elapsed - pausedSeconds` (spec D5). `0` is the correct reading for every ride
        /// recorded before pause existed, which is why nothing has to backfill it.
        public var pausedSeconds: Double = 0
        public var elevationGainMeters: Double = 0
        /// JSON-encoded `[Coordinate]`; nil when < 2 points. **Stays flat across pauses**
        /// (spec D3): older builds decode it with a bare `try?` that falls back to blank, so
        /// changing its shape would silently blank History on a mixed-version fleet.
        public var thumbnailData: Data?
        public var destinationName: String?
        public var routeId: UUID?
        public var destinationPlaceId: UUID?

        public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                    trackData: Data, segmentsData: Data?, statsData: Data?,
                    distanceMeters: Double = 0, movingTimeSeconds: Double = 0,
                    pausedSeconds: Double = 0, elevationGainMeters: Double = 0,
                    thumbnailData: Data? = nil, destinationName: String? = nil,
                    routeId: UUID?, destinationPlaceId: UUID?) {
            self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
            self.trackData = trackData; self.segmentsData = segmentsData; self.statsData = statsData
            self.distanceMeters = distanceMeters; self.movingTimeSeconds = movingTimeSeconds
            self.pausedSeconds = pausedSeconds; self.elevationGainMeters = elevationGainMeters
            self.thumbnailData = thumbnailData; self.destinationName = destinationName
            self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
        }
    }
}
