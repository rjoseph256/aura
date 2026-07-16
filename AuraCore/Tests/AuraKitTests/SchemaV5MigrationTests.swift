import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

// This suite loads a pre-`resurface` (V3-class) SavedPlaceRecord container alongside a V5
// one. `.serialized` keeps its own tests in order; `.swiftDataSerialized` is the real flake
// fix — it serializes this suite against every other SavedPlaceRecord-container suite so the
// process-global CoreData entity cache can't serve a stale V3 model to the V5 container mid
// migration (an `NSUnknownKeyException` on `resurface` that aborts the run). See ROH-65 and
// SwiftDataSerialGate.swift.
@Suite("Schema V5 migration", .serialized, .swiftDataSerialized)
struct SchemaV5MigrationTests {
    @Test func existingPlaceMigratesWithResurfaceFalse() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-v5-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // Open at V4, insert a place (no resurface column), close.
        // cloudKitDatabase: .none — macOS CI has no CloudKit entitlement; a file-backed
        // container that tried to mirror would fail there. File-backed (not in-memory) is
        // required so the store persists across the reopen that triggers migration.
        do {
            let v4 = try ModelContainer(
                for: RideSchemaV2.RideRecord.self, RideSchemaV3.SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let ctx = ModelContext(v4)
            ctx.insert(RideSchemaV3.SavedPlaceRecord(
                SavedPlace(name: "Old", subtitle: nil,
                           coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
                           category: .custom, kind: .favorite, savedAt: Date(timeIntervalSince1970: 5))))
            try ctx.save()
        }

        // Reopen through the migration plan → V5; the place gains resurface == false.
        let v5 = try ModelContainer(
            for: RideSchemaV2.RideRecord.self, SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self,
            migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let records = try ModelContext(v5).fetch(FetchDescriptor<SavedPlaceRecord>())
        #expect(records.count == 1)
        #expect(records.first?.resurface == false)
        #expect(records.first?.name == "Old")
    }
}
