import Foundation
import SwiftData
import AuraCore

/// V1 → V2: drops `.unique`, moves the track to external storage, and adds the
/// denormalized summary columns + thumbnail. The stage is custom because the new
/// columns are computed from existing rows, which a lightweight stage cannot do.
public enum RideMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [RideSchemaV1.self, RideSchemaV2.self, RideSchemaV3.self, RideSchemaV4.self,
         RideSchemaV5.self, RideSchemaV6.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6]
    }

    public static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: RideSchemaV1.self,
        toVersion: RideSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let records = try context.fetch(FetchDescriptor<RideSchemaV2.RideRecord>())
            for record in records {
                if let statsData = record.statsData {
                    if let stats = try? decoder.decode(RideStats.self, from: statsData) {
                        record.distanceMeters = stats.distanceMeters
                        record.movingTimeSeconds = stats.movingTimeSeconds
                        record.elevationGainMeters = stats.elevationGainMeters
                    } else {
                        // Loud in DEBUG/CI, non-fatal in release: a non-nil blob that fails to
                        // decode leaves the columns at 0, indistinguishable from a statless ride.
                        assertionFailure("Migration: failed to decode statsData for ride \(record.id); columns stay 0")
                    }
                }
                if let track = try? decoder.decode([TrackPoint].self, from: record.trackData) {
                    let thumb = TrackSimplifier.thumbnail(from: track.map(\.coordinate))
                    record.thumbnailData = thumb.count >= 2 ? try? encoder.encode(thumb) : nil
                }
            }
            try context.save()
        })

    /// Adding a model type is lightweight — no data transform.
    public static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: RideSchemaV2.self,
        toVersion: RideSchemaV3.self)

    /// Adding a model type is lightweight — no data transform.
    public static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: RideSchemaV3.self,
        toVersion: RideSchemaV4.self)

    /// Adding one defaulted attribute to SavedPlaceRecord is lightweight — no data transform.
    public static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: RideSchemaV4.self,
        toVersion: RideSchemaV5.self)

    /// V6 redeclares `RideRecord` with one optional attribute (`segmentsData`) and one
    /// defaulted attribute (`pausedSeconds`) added. Both are exactly what a lightweight stage
    /// handles, so **no data moves at launch**.
    ///
    /// **The backfill deliberately does not live here.** Filling `segmentsData` from each
    /// row's flat `trackData` is real work — a decode and a re-encode of every historical
    /// track — and `didMigrate` runs inside `ModelContainer.init`, which the app calls from
    /// `AuraApp.init()` before the first frame. Measured at ~0.043 s per three-hour ride, a
    /// long history is tens of seconds of black screen and a watchdog kill that repeats on
    /// every launch. Worse, a throw in a stage fails the container, and `AuraApp` catches that
    /// by falling back to an in-memory store — the rider's whole History reads as empty and
    /// the widget snapshot is overwritten with nothing.
    ///
    /// `RideSegmentBackfiller` does it instead: off the launch path, batched, resumable, and
    /// unable to fail anything. It is also the only form of this work that can ever finish the
    /// job — a stage runs once, while rides recorded by a V5 device *after* this migration keep
    /// arriving with `segmentsData` nil, and only a re-runnable sweep catches those.
    public static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: RideSchemaV5.self,
        toVersion: RideSchemaV6.self)
}
