import Testing
import Foundation
import AuraCore

@Suite struct WorkoutDataTests {
    private func stats(_ distance: Double) -> RideStats {
        RideStats(distanceMeters: distance, movingTimeSeconds: 0,
                  averageSpeedMetersPerSecond: 0, maxSpeedMetersPerSecond: 0,
                  elevationGainMeters: 0)
    }

    private func point(_ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0),
                   elevation: 250, timestamp: Date(timeIntervalSince1970: t))
    }

    private func ride(started: TimeInterval, endedAt: Date?, distance: Double?,
                      track: [TrackPoint] = []) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: started),
             endedAt: endedAt, track: track, stats: distance.map(stats),
             routeId: nil, destinationPlaceId: nil)
    }

    // MARK: WorkoutData(from:)

    @Test func mapsCoreFields() {
        let r = ride(started: 100, endedAt: Date(timeIntervalSince1970: 200),
                     distance: 4321, track: [point(100), point(200)])
        let data = WorkoutData(from: r)
        #expect(data.externalID == r.id)
        #expect(data.start == Date(timeIntervalSince1970: 100))
        #expect(data.end == Date(timeIntervalSince1970: 200))
        #expect(data.distanceMeters == 4321)
        #expect(data.route.count == 2)
    }

    @Test func endFallsBackToLastTrackTimestampWhenNoEndDate() {
        let r = ride(started: 100, endedAt: nil, distance: 50,
                     track: [point(100), point(175)])
        #expect(WorkoutData(from: r).end == Date(timeIntervalSince1970: 175))
    }

    @Test func endFallsBackToStartWhenNoEndDateAndNoTrack() {
        let r = ride(started: 100, endedAt: nil, distance: 50)
        #expect(WorkoutData(from: r).end == Date(timeIntervalSince1970: 100))
    }

    @Test func endIsClampedToStartOnClockSkew() {
        // endedAt earlier than startedAt must not yield end < start.
        let r = ride(started: 500, endedAt: Date(timeIntervalSince1970: 400), distance: 50)
        let data = WorkoutData(from: r)
        #expect(data.end == data.start)
    }

    @Test func distanceDefaultsToZeroWhenStatsMissing() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: nil)
        #expect(WorkoutData(from: r).distanceMeters == 0)
    }

    // MARK: RideWorkoutGate

    @Test func gateBlocksWhenDisabled() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: 1000)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: false) == false)
    }

    @Test func gateBlocksWhenNotEnded() {
        let r = ride(started: 0, endedAt: nil, distance: 1000)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: true) == false)
    }

    @Test func gateBlocksBelowDistanceFloor() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: 9)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: true) == false)
    }

    @Test func gateBlocksWhenStatsMissing() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: nil)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: true) == false)
    }

    @Test func gateWritesWhenEnabledEndedAndOverFloor() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: 10)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: true) == true)
    }
}
