import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

/// V7 adds one optional attribute (`checkpointedAt`), which is exactly what a lightweight
/// stage handles — so this migration must be as inert as V5→V6: no data moves, nothing is
/// lost, and an un-backfilled row (every pre-V7 row) reads `checkpointedAt` as nil, which is
/// the correct reading — it means the ride was finished, not that a checkpoint is stale.
///
/// `@MainActor` and `.swiftDataSerialized`: same shape as `SchemaV6MigrationTests` for the
/// same reasons — `ModelContainer.mainContext` is main-actor isolated under
/// `swiftLanguageModes: [.v6]`, and **three** `@Model` classes now share the CoreData entity
/// name `RideRecord` (`RideSchemaV2`'s for V2–V5, `RideSchemaV6`'s, `RideSchemaV7`'s), which
/// crashes CI without the serialization gate (ROH-65).
@MainActor
@Suite("Schema V6 → V7", .swiftDataSerialized)
struct SchemaV7MigrationTests {
    /// A unique directory per test holding the store and its `_SUPPORT` external-data
    /// sidecar, so the whole subtree goes away with one remove.
    private func tempStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-v7-\(UUID().uuidString)", isDirectory: true)
    }

    /// Every V6 row survives, and arrives with `checkpointedAt` nil — the correct reading,
    /// since every pre-V7 row was written by `finish()`.
    @Test func v6RowsMigrateWithANilCheckpoint() throws {
        let dir = tempStoreDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "v7.store")
        let id = UUID()

        // Seed on the EXACT V6 model set, so SwiftData stamps the store as V6.
        do {
            let container = try ModelContainer(
                for: RideSchemaV6.RideRecord.self, RideSchemaV5.SavedPlaceRecord.self,
                     RideSchemaV4.SeenGemRecord.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            container.mainContext.insert(RideSchemaV6.RideRecord(
                id: id, kindRaw: "freeRide", startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 2_000), trackData: Data(),
                segmentsData: nil, statsData: nil, routeId: nil, destinationPlaceId: nil))
            try container.mainContext.save()
        }

        // Reopen on the live model set + the plan, so the destination resolves unambiguously.
        let migrated = try ModelContainer(
            for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
            migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let rows = try migrated.mainContext.fetch(FetchDescriptor<RideRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
        #expect(rows.first?.checkpointedAt == nil)
    }
}
