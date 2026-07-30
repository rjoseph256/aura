import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

/// CloudKit-compatibility guards: the mirror rejects models with unique
/// constraints, relationships, or non-optional attributes without defaults.
///
/// `.swiftDataSerialized` even though this suite builds no container: `Schema(versionedSchema:)`
/// materializes entity descriptions, and CoreData caches those process-globally by entity name.
/// From V6 on this suite materializes `RideSchemaV7.RideRecord` while the migration suites hold
/// `RideSchemaV2.RideRecord` — the same name, a different class, which is the ROH-65 hazard. It
/// crashed CI (a malloc abort, in an unrelated suite) before this trait was added; the gate's
/// own grep does not find this file, because there is no `ModelContainer(` in it.
@Suite("Schema invariants (CloudKit)", .swiftDataSerialized)
struct SchemaInvariantTests {
    private var entities: [Schema.Entity] {
        // Always guard the CURRENT schema so every persisted model — including
        // RideRecord.checkpointedAt (V7) — is machine-checked for CloudKit compatibility.
        Schema(versionedSchema: RideSchemaV7.self).entities
    }

    @Test func everyAttributeIsOptionalOrDefaulted() {
        for entity in entities {
            for attribute in entity.attributes {
                #expect(attribute.isOptional || attribute.defaultValue != nil,
                        "\(entity.name).\(attribute.name) needs a default or optionality for CloudKit")
            }
        }
    }

    @Test func noUniqueConstraintsAndNoRelationships() {
        for entity in entities {
            for attribute in entity.attributes {
                #expect(!attribute.isUnique,
                        "\(entity.name).\(attribute.name) is .unique — CloudKit-incompatible")
            }
            #expect(entity.relationships.isEmpty,
                    "\(entity.name) has relationships — out of contract for this store")
        }
    }

    /// The entity name must stay `RideRecord` even though V6 redeclares the class: CloudKit
    /// derives its record type from it, so a rename orphans every already-synced ride.
    @Test func v6ContainsAllModelsUnderTheirExistingNames() {
        #expect(Set(entities.map(\.name)) == ["RideRecord", "SavedPlaceRecord", "SeenGemRecord"])
    }

    /// Asserted on the attribute, not on behavior: `trackData` externalizes on the same row,
    /// so a sidecar file exists whether or not `segmentsData` kept `.externalStorage`. An
    /// inline ~300 KB blob would be faulted by `summaries()` on every row — ROH-64.
    @Test func segmentAndTrackBlobsAreExternallyStored() {
        let ride = entities.first { $0.name == "RideRecord" }
        let segments = ride?.attributes.first { $0.name == "segmentsData" }
        #expect(segments != nil, "V6 must carry segmentsData")
        #expect(segments?.isOptional == true, "nil is how an un-backfilled row is representable")
        #expect(segments?.options.contains(.externalStorage) == true)
        #expect(ride?.attributes.first { $0.name == "trackData" }?
            .options.contains(.externalStorage) == true)
    }

    /// `checkpointedAt` must be optional: nil is how "the rider ended this ride" is
    /// representable, and CloudKit requires optionality or a default regardless.
    @Test func checkpointedAtIsOptional() {
        let ride = entities.first { $0.name == "RideRecord" }
        let attribute = ride?.attributes.first { $0.name == "checkpointedAt" }
        #expect(attribute != nil, "V7 must carry checkpointedAt")
        #expect(attribute?.isOptional == true)
    }

    @Test func resurfaceDefaultsFalse() {
        let saved = entities.first { $0.name == "SavedPlaceRecord" }
        let attr = saved?.attributes.first { $0.name == "resurface" }
        #expect(attr != nil)
        #expect(attr?.isOptional == true || attr?.defaultValue != nil)
    }

    @Test func recordRoundTripsValue() {
        let value = SavedPlace(name: "Trace", subtitle: "Butler St",
                               coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
                               category: .brewery, kind: .home,
                               savedAt: Date(timeIntervalSince1970: 7))
        let record = SavedPlaceRecord(value)
        #expect(record.value == value)
    }

    @Test func recordWithUnknownRawsMapsToNil() {
        let record = SavedPlaceRecord(SavedPlace(name: "X", subtitle: nil,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            category: .custom, kind: .favorite, savedAt: .init(timeIntervalSince1970: 0)))
        record.kindRaw = "??"
        #expect(record.value == nil)   // a future kind never crashes an old build
    }
}
