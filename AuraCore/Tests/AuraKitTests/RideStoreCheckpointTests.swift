import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// The store side of spec D7's pause-boundary flush. A ride is now written more than once —
/// once per pause, then again at End — so `save` has to be keyed on the ride's id instead of
/// inserting blindly, or every pause leaves another copy of the same ride in History.
@MainActor
@Suite(.swiftDataSerialized)
struct RideStoreCheckpointTests {
    private func pt(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: nil,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    @Test func savingTheSameRideAgainUpdatesTheRowInsteadOfDuplicatingIt() throws {
        let store = try RideStore.inMemory()
        let id = UUID()
        let checkpoint = Ride(id: id, kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                              endedAt: nil, track: [pt(40.0, 0), pt(40.1, 10)],
                              stats: .zero, routeId: nil, destinationPlaceId: nil)
        try store.save(checkpoint)

        let finished = Ride(id: id, kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                            endedAt: Date(timeIntervalSince1970: 600),
                            track: [pt(40.0, 0), pt(40.1, 10), pt(40.2, 600)],
                            stats: .zero, routeId: nil, destinationPlaceId: nil)
        try store.save(finished)

        let all = try store.allRides()
        #expect(all.count == 1)
        #expect(all.first?.endedAt == Date(timeIntervalSince1970: 600))
        #expect(all.first?.flattenedPoints.count == 3)
    }

    @Test func savingTwoDifferentRidesStillKeepsBoth() throws {
        let store = try RideStore.inMemory()
        try store.save(Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                            endedAt: nil, track: [], stats: .zero,
                            routeId: nil, destinationPlaceId: nil))
        try store.save(Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 100),
                            endedAt: nil, track: [], stats: .zero,
                            routeId: nil, destinationPlaceId: nil))
        #expect(try store.allRides().count == 2)
    }

    @Test func discardRemovesTheCheckpointRow() throws {
        let store = try RideStore.inMemory()
        let ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                        endedAt: nil, track: [pt(40.0, 0)], stats: .zero,
                        routeId: nil, destinationPlaceId: nil)
        let saving: any RideSaving = store
        try saving.save(ride)
        try saving.discard(id: ride.id)
        #expect(try store.allRides().isEmpty)
    }

    /// Pins the KNOWN-WRONG-FOR-NOW gap, the same way `multiSegmentRideFlattensThroughTheStoreUntilV6`
    /// pins the segment collapse: `RideRecord` has no column for paused time until schema V6
    /// (Pass 3), so a paused ride's accounting survives in memory and is lost on reload. A V6
    /// pass is expected to flip this assertion, not to keep it green.
    @Test func pausedSecondsIsDroppedByTheStoreUntilV6() throws {
        let store = try RideStore.inMemory()
        var ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                        endedAt: Date(timeIntervalSince1970: 600), track: [pt(40.0, 0)],
                        stats: .zero, routeId: nil, destinationPlaceId: nil)
        ride.pausedSeconds = 300
        try store.save(ride)

        let back = try #require(try store.ride(id: ride.id))
        #expect(back.pausedSeconds == 0, "known-wrong-for-now: no V6 column to carry it yet")
    }
}
