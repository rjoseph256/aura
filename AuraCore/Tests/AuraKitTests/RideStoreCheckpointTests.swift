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

    /// The update branch of `save` is a hand-written field copy. This is the guard that it is
    /// complete: every column the mapper writes differs between the two rides, so a field left
    /// out of the copy keeps the first ride's value and fails here. **A schema pass that adds a
    /// column adds it to this test and to the copy.**
    @Test func updatePathCarriesEveryColumn() throws {
        let store = try RideStore.inMemory()
        let id = UUID()
        let first = Ride(id: id, kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                         endedAt: Date(timeIntervalSince1970: 100),
                         track: [pt(40.0, 0), pt(40.1, 10)],
                         stats: RideStats(distanceMeters: 10, movingTimeSeconds: 5,
                                          averageSpeedMetersPerSecond: 2,
                                          maxSpeedMetersPerSecond: 3, elevationGainMeters: 1),
                         checkpointedAt: Date(timeIntervalSince1970: 100),
                         destinationName: "First", routeId: UUID(), destinationPlaceId: UUID())
        try store.save(first)

        // Two segments and a non-zero paused total, so the V6 columns differ from the first
        // write too — this is the checkpoint-then-End shape `save`'s doc comment warns about.
        // `checkpointedAt` goes nil here, as `finish()` clears it — the V7 column.
        let second = Ride(id: id, kind: .navigate, startedAt: Date(timeIntervalSince1970: 500),
                          endedAt: Date(timeIntervalSince1970: 900),
                          segments: [RideSegment(points: [pt(41.0, 500), pt(41.2, 600)]),
                                     RideSegment(points: [pt(41.4, 700)])],
                          stats: RideStats(distanceMeters: 2000, movingTimeSeconds: 300,
                                           averageSpeedMetersPerSecond: 6.7,
                                           maxSpeedMetersPerSecond: 12, elevationGainMeters: 45),
                          pausedSeconds: 120,
                          checkpointedAt: nil,
                          destinationName: "Second", routeId: UUID(),
                          destinationPlaceId: UUID())
        try store.save(second)

        let back = try #require(try store.ride(id: id))
        #expect(back.kind == .navigate)
        #expect(back.startedAt == second.startedAt)
        #expect(back.endedAt == second.endedAt)
        #expect(back.segments == second.segments, "segmentsData is copied on the update path")
        #expect(back.flattenedPoints == second.flattenedPoints)
        #expect(back.stats == second.stats)
        #expect(back.pausedSeconds == 120)
        #expect(back.checkpointedAt == nil, "checkpointedAt is copied on the update path")
        #expect(back.destinationName == "Second")
        #expect(back.routeId == second.routeId)
        #expect(back.destinationPlaceId == second.destinationPlaceId)

        // The denormalized columns and the thumbnail blob are not on `Ride`, so read them
        // through the projection that History actually uses.
        let summary = try #require(try store.summaries().first)
        #expect(summary.distanceMeters == 2000)
        #expect(summary.movingTimeSeconds == 300)
        #expect(summary.elevationGainMeters == 45)
        #expect(summary.pausedSeconds == 120)
        #expect(summary.thumbnailCoordinates.count == 3,
                "the thumbnail was re-derived, not kept — and stays flat across the pause (D3)")
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

    /// Was the KNOWN-WRONG-FOR-NOW pin for paused time being dropped on save; schema V6's
    /// `pausedSeconds` column flipped it, as its old comment said a V6 pass would. This is the
    /// number D5 computes active time from, so losing it on reload means the summary of a
    /// reopened ride disagrees with the summary the rider saw at End.
    @Test func pausedSecondsSurvivesTheStoreFromV6() throws {
        let store = try RideStore.inMemory()
        var ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                        endedAt: Date(timeIntervalSince1970: 600), track: [pt(40.0, 0)],
                        stats: .zero, routeId: nil, destinationPlaceId: nil)
        ride.pausedSeconds = 300
        try store.save(ride)

        let back = try #require(try store.ride(id: ride.id))
        #expect(back.pausedSeconds == 300)
        #expect(try store.summaries().first?.pausedSeconds == 300)
    }
}
