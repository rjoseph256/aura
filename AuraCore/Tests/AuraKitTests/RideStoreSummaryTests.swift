import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct RideStoreSummaryTests {
    private func ride(_ t: TimeInterval, distance: Double) -> Ride {
        Ride(kind: .navigate, startedAt: Date(timeIntervalSince1970: t),
             endedAt: Date(timeIntervalSince1970: t + 100),
             track: [TrackPoint(coordinate: .init(latitude: 1, longitude: 1), elevation: nil,
                                timestamp: Date(timeIntervalSince1970: t)),
                     TrackPoint(coordinate: .init(latitude: 2, longitude: 2), elevation: nil,
                                timestamp: Date(timeIntervalSince1970: t + 50))],
             stats: RideStats(distanceMeters: distance, movingTimeSeconds: 100,
                              averageSpeedMetersPerSecond: 1, maxSpeedMetersPerSecond: 2,
                              elevationGainMeters: 5),
             destinationName: "X", routeId: nil, destinationPlaceId: nil)
    }

    @Test func summariesAreNewestFirstAndCarryColumns() throws {
        let store = try RideStore.inMemory()
        try store.save(ride(100, distance: 10))
        try store.save(ride(300, distance: 30))
        try store.save(ride(200, distance: 20))
        let summaries = try store.summaries()
        #expect(summaries.map(\.startedAt.timeIntervalSince1970) == [300, 200, 100])
        #expect(summaries.first?.distanceMeters == 30)
        #expect(summaries.first?.thumbnailCoordinates.count == 2)
    }

    @Test func rideByIdReturnsFullTrack() throws {
        let store = try RideStore.inMemory()
        let r = ride(100, distance: 10)
        try store.save(r)
        let full = try #require(try store.ride(id: r.id))
        #expect(full.track.count == 2)
        #expect(full.stats?.distanceMeters == 10)
    }

    @Test func rideByIdMissingIsNil() throws {
        let store = try RideStore.inMemory()
        #expect(try store.ride(id: UUID()) == nil)
    }
}
