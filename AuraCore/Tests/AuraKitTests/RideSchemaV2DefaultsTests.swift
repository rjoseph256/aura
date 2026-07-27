import Testing
import Foundation
import SwiftData
@testable import AuraKit

/// The CloudKit mirror requires every non-optional attribute to have a default.
/// This proves the store still builds and round-trips a record after the defaults
/// were added in place (hash-neutral change, no migration). The authoritative
/// "CloudKit accepts this schema" check is the signed-simulator initializeCloudKitSchema
/// step in the app target; a local container cannot validate CloudKit rules.
///
/// **Pinned to `RideSchemaV2.RideRecord` explicitly.** The bare `RideRecord` typealias now
/// points at V6, so writing it here would silently turn the V2-defaults guard into a V6 one
/// and leave V2 — still the class every V2→V5 stage migrates through — untested.
/// `SchemaInvariantTests` is what guards the current schema.
@MainActor
@Suite(.swiftDataSerialized)
struct RideSchemaV2DefaultsTests {
    @Test func recordRoundTripsInAFreshInMemoryStore() throws {
        let container = try ModelContainer(
            for: RideSchemaV2.RideRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let id = UUID()
        let record = RideSchemaV2.RideRecord(
            id: id, kindRaw: "free", startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil, trackData: Data([1, 2, 3]), statsData: nil,
            routeId: nil, destinationPlaceId: nil)
        container.mainContext.insert(record)
        try container.mainContext.save()
        let fetched = try container.mainContext.fetch(FetchDescriptor<RideSchemaV2.RideRecord>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == id)
        #expect(fetched.first?.trackData == Data([1, 2, 3]))
    }
}
