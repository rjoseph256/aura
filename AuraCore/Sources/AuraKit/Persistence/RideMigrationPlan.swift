import Foundation
import SwiftData
import AuraCore

/// V1 → V2: drops `.unique`, moves the track to external storage, and adds the
/// denormalized summary columns + thumbnail. The stage is custom because the new
/// columns are computed from existing rows, which a lightweight stage cannot do.
public enum RideMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [RideSchemaV1.self, RideSchemaV2.self]
    }

    public static var stages: [MigrationStage] { [migrateV1toV2] }

    public static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: RideSchemaV1.self,
        toVersion: RideSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let records = try context.fetch(FetchDescriptor<RideSchemaV2.RideRecord>())
            for record in records {
                if let statsData = record.statsData,
                   let stats = try? decoder.decode(RideStats.self, from: statsData) {
                    record.distanceMeters = stats.distanceMeters
                    record.movingTimeSeconds = stats.movingTimeSeconds
                    record.elevationGainMeters = stats.elevationGainMeters
                }
                if let track = try? decoder.decode([TrackPoint].self, from: record.trackData) {
                    let thumb = TrackSimplifier.thumbnail(from: track.map(\.coordinate))
                    record.thumbnailData = thumb.count >= 2 ? try? encoder.encode(thumb) : nil
                }
            }
            try context.save()
        })
}
