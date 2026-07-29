import Foundation
import os
import SwiftData
import AuraCore

/// V1 → V2: drops `.unique`, moves the track to external storage, and adds the
/// denormalized summary columns + thumbnail. The stage is custom because the new
/// columns are computed from existing rows, which a lightweight stage cannot do.
public enum RideMigrationPlan: SchemaMigrationPlan {
    private static let log = Logger(subsystem: "app.aura.kit", category: "persistence")

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
                record.thumbnailData = thumbnailData(
                    forTrack: record.trackData, rideID: record.id,
                    decoder: decoder, encoder: encoder)
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

    // MARK: - Backfill helpers

    /// The V1→V2 thumbnail backfill, extracted from `didMigrate` so its outcomes are testable
    /// without driving a migration.
    ///
    /// Returns nil for a ride that legitimately has no polyline to draw, and logs + asserts only
    /// on corruption. The distinction matters: `assertionFailure` here fires inside
    /// `ModelContainer.init`, on the launch path, so a false positive is a DEBUG crash at app
    /// start rather than a test failure.
    ///
    /// Neither loud path is covered by a test, because `assertionFailure` traps in DEBUG and
    /// `swift test` builds DEBUG — driving one would abort the suite. The sibling `statsData`
    /// assert above is untested for the same reason. This is a deliberate gap, not an oversight.
    ///
    /// **That trap is reachable through the migration, not just through this function.** A future
    /// test that opens a V1 store containing a non-empty garbage `trackData` will abort the suite
    /// rather than fail an expectation. Existing suites that write such blobs — see
    /// `RideSegmentBackfillTests` — are safe only because they insert into a current-schema store
    /// that never runs `didMigrate`.
    static func thumbnailData(forTrack trackData: Data, rideID: UUID,
                              decoder: JSONDecoder, encoder: JSONEncoder) -> Data? {
        // An EMPTY blob is an empty ride, not a corrupt one: `trackData`'s default is `Data()`,
        // which is what CloudKit materializes for a record that never carried the key, and
        // JSONDecoder throws on it. Same distinction RideMapper draws (`RideMapper.swift:72-75`).
        guard !trackData.isEmpty else { return nil }

        guard let track = try? decoder.decode([TrackPoint].self, from: trackData) else {
            log.error("""
                Migration: trackData unreadable for ride \(rideID, privacy: .public) \
                (\(trackData.count) bytes); thumbnail dropped, History draws a blank card
                """)
            assertionFailure("Migration: failed to decode trackData for ride \(rideID)")
            return nil
        }

        // Fewer than two points is a ride too short to draw, not a failure.
        let thumb = TrackSimplifier.thumbnail(from: track.map(\.coordinate))
        guard thumb.count >= 2 else { return nil }

        do {
            return try encoder.encode(thumb)
        } catch {
            // Unreachable today: JSON carries no non-finite literal, so a coordinate that would
            // break the encoder fails the decode above instead, and TrackSimplifier only selects
            // existing coordinates by index. Diagnosed anyway, to catch a future edit that makes
            // it reachable — a changed encoder strategy, or a simplifier that interpolates.
            log.error("""
                Migration: thumbnail unencodable for ride \(rideID, privacy: .public) \
                (\(thumb.count) points); thumbnail dropped, History draws a blank card
                """)
            assertionFailure("Migration: failed to encode thumbnail for ride \(rideID): \(error)")
            return nil
        }
    }
}
