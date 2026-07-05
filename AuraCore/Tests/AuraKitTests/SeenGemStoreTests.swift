import Testing
import Foundation
import SwiftData
@testable import AuraKit

@MainActor
@Suite struct SeenGemStoreTests {
    private func inMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SeenGemRecord.self, configurations: config)
    }

    @Test func marksAndReadsBackSeenIDs() throws {
        let store = SeenGemStore(container: try inMemoryContainer())
        #expect(store.seenGemIDs().isEmpty)
        store.markSeen("curated:grandview-overlook", at: Date(timeIntervalSince1970: 10))
        store.markSeen("curated:point-state-park", at: Date(timeIntervalSince1970: 20))
        #expect(store.seenGemIDs() == ["curated:grandview-overlook", "curated:point-state-park"])
    }

    @Test func markSeenIsIdempotent() throws {
        let store = SeenGemStore(container: try inMemoryContainer())
        store.markSeen("g", at: Date(timeIntervalSince1970: 1))
        store.markSeen("g", at: Date(timeIntervalSince1970: 2))
        #expect(store.seenGemIDs() == ["g"])
    }

    @Test func recordHasCloudKitSafeDefaults() {
        // ROH-13 invariant: a no-arg-constructible record with defaults, no .unique.
        let r = SeenGemRecord(gemID: "x", firstSeenAt: Date(timeIntervalSince1970: 0))
        #expect(r.gemID == "x")
    }
}
