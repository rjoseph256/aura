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
}
