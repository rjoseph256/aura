import Testing
import Foundation
import SwiftData
@testable import AuraKit

/// The CloudKit mirror requires every non-optional attribute to have a default.
/// This proves the store still builds and round-trips a record after the defaults
/// were added in place (hash-neutral change, no migration). The authoritative
/// "CloudKit accepts this schema" check is the signed-simulator initializeCloudKitSchema
/// step in the app target; a local container cannot validate CloudKit rules.
@MainActor
struct RideSchemaV2DefaultsTests {
    @Test func recordRoundTripsInAFreshInMemoryStore() throws {
        let container = try ModelContainer(
            for: RideRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let id = UUID()
        let record = RideRecord(id: id, kindRaw: "free", startedAt: Date(timeIntervalSince1970: 100),
                                endedAt: nil, trackData: Data([1, 2, 3]), statsData: nil,
                                routeId: nil, destinationPlaceId: nil)
        container.mainContext.insert(record)
        try container.mainContext.save()
        let fetched = try container.mainContext.fetch(FetchDescriptor<RideRecord>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == id)
        #expect(fetched.first?.trackData == Data([1, 2, 3]))
    }
}
