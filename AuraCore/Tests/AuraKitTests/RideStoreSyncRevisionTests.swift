import Testing
import Foundation
import SwiftData
@testable import AuraKit

/// Serialized (ROH-65 gate): this suite posts a *global*
/// `.NSPersistentStoreRemoteChange` and asserts its store observed exactly one bump. Any
/// other suite standing up a SwiftData container concurrently can post the same notification
/// and drive `syncRevision` to 2, which is a real intermittent failure observed on CI-like
/// repeat runs. The gate keeps container-owning suites from overlapping.
@MainActor
@Suite(.swiftDataSerialized)
struct RideStoreSyncRevisionTests {
    @Test func remoteChangeNotificationBumpsSyncRevision() async throws {
        let container = try ModelContainer(
            for: RideRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = RideStore(container: container)
        #expect(store.syncRevision == 0)
        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)
        // The observer hops to the main actor via a Task; a single yield is not enough to
        // guarantee it ran, so poll with a bounded wait.
        for _ in 0..<100 where store.syncRevision == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.syncRevision == 1)
    }
}
