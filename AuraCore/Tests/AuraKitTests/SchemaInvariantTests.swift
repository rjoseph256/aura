import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

/// CloudKit-compatibility guards: the mirror rejects models with unique
/// constraints, relationships, or non-optional attributes without defaults.
@Suite("Schema invariants (CloudKit)")
struct SchemaInvariantTests {
    private var entities: [Schema.Entity] {
        // Always guard the CURRENT schema so every persisted model — including
        // SeenGemRecord (V4) — is machine-checked for CloudKit compatibility.
        Schema(versionedSchema: RideSchemaV4.self).entities
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

    @Test func v4ContainsAllModels() {
        #expect(Set(entities.map(\.name)) == ["RideRecord", "SavedPlaceRecord", "SeenGemRecord"])
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
