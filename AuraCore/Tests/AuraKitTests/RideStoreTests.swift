import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Converted from XCTest so it can adopt `.swiftDataSerialized`: it builds a `RideStore`, and
/// from schema V6 on two `@Model` classes share the CoreData entity name `RideRecord`, which
/// is the ROH-65 hazard. An `XCTestCase` cannot take a Swift Testing suite trait, so leaving it
/// as one would have left the only ungated container suite in the run.
@MainActor
@Suite(.swiftDataSerialized)
struct RideStoreTests {
    private func ride(_ t: TimeInterval) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: t),
             endedAt: Date(timeIntervalSince1970: t + 100),
             track: [], stats: .zero, routeId: nil, destinationPlaceId: nil)
    }

    @Test func savesAndFetchesNewestFirst() throws {
        let store = try RideStore.inMemory()
        try store.save(ride(100))
        try store.save(ride(300))
        try store.save(ride(200))
        let all = try store.allRides()
        #expect(all.map(\.startedAt.timeIntervalSince1970) == [300, 200, 100])
    }

    @Test func deleteRemovesTheRide() throws {
        let store = try RideStore.inMemory()
        let r = ride(100)
        try store.save(r)
        try store.delete(id: r.id)
        #expect(try store.allRides().isEmpty)
    }

    /// `RideStore.save`'s update branch is a hand-written field copy. Pass 3 shipped
    /// `segmentsData` and nearly missed this; a missed copy here means `finish()` never clears
    /// the marker and every paused ride stays unfinished forever.
    @Test func savingOverACheckpointClearsCheckpointedAt() throws {
        let store = try RideStore.inMemory()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let checkpoint = Ride(id: id, kind: .freeRide, startedAt: start,
                              endedAt: Date(timeIntervalSince1970: 1_600),
                              track: [], stats: nil, pausedSeconds: 0,
                              checkpointedAt: Date(timeIntervalSince1970: 1_600),
                              routeId: nil, destinationPlaceId: nil)
        try store.save(checkpoint)
        #expect(try #require(store.summaries().first).checkpointedAt != nil)

        let finished = Ride(id: id, kind: .freeRide, startedAt: start,
                            endedAt: Date(timeIntervalSince1970: 2_000),
                            track: [], stats: nil, pausedSeconds: 0,
                            checkpointedAt: nil,
                            routeId: nil, destinationPlaceId: nil)
        try store.save(finished)

        let rows = try store.summaries()
        #expect(rows.count == 1, "the upsert must update, not duplicate")
        #expect(rows[0].checkpointedAt == nil, "the update branch dropped checkpointedAt")
    }
}
