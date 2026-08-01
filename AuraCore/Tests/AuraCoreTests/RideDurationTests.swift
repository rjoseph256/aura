import Testing
import Foundation
@testable import AuraCore

@Suite("Ride duration")
struct RideDurationTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Active time is elapsed less the time spent paused")
    func activeIsElapsedLessPaused() throws {
        let d = try #require(RideDuration(startedAt: start,
                                          endedAt: start.addingTimeInterval(2880),
                                          checkpointedAt: nil, pausedSeconds: 600))
        #expect(d.elapsedSeconds == 2880)
        #expect(d.activeSeconds == 2280)
    }

    @Test("A ride with no recorded pauses reports active equal to elapsed")
    func noPausesMeansActiveIsElapsed() throws {
        // Every ride recorded before pause existed, and every ride the rider never paused.
        let d = try #require(RideDuration(startedAt: start,
                                          endedAt: start.addingTimeInterval(2880),
                                          checkpointedAt: nil, pausedSeconds: 0))
        #expect(d.activeSeconds == d.elapsedSeconds)
    }

    @Test("A checkpoint row — endedAt stamped AT the pause — is disqualified")
    func checkpointRowIsDisqualified() {
        // `RideRecorder.checkpoint(at:)` writes endedAt and checkpointedAt to the SAME instant.
        // The rider may have resumed and ridden for another hour before the kill, so this
        // interval can be a fraction of the real ride.
        let end = start.addingTimeInterval(1800)
        #expect(RideDuration(startedAt: start, endedAt: end,
                             checkpointedAt: end, pausedSeconds: 0) == nil)
    }

    @Test("A ride that failed to save still reports its real duration")
    func saveFailureRideKeepsItsDuration() throws {
        // `RideSessionCoordinator.finish()`'s catch branch restores the MARKER onto a ride whose
        // endedAt came from `RideRecorder.end(at:)` — the real End tap, strictly after the
        // checkpoint. Both durations are exactly known, and the rider is looking at this summary
        // right now. Disqualifying it would print "—" beside a real distance and a real top speed.
        // Pinned against `RideSessionCheckpointFlushTests.swift:238`, which asserts this ride is
        // "still a real duration".
        let d = try #require(RideDuration(startedAt: start,
                                          endedAt: start.addingTimeInterval(5400),
                                          checkpointedAt: start.addingTimeInterval(1800),
                                          pausedSeconds: 600))
        #expect(d.elapsedSeconds == 5400)
        #expect(d.activeSeconds == 4800)
    }

    @Test("A ride with no end at all has no duration")
    func noEndMeansNoDuration() {
        // The legacy PR #90 dev-build rows: nil endedAt and no marker.
        #expect(RideDuration(startedAt: start, endedAt: nil,
                             checkpointedAt: nil, pausedSeconds: 0) == nil)
    }

    @Test("Active never exceeds elapsed, whatever the stored paused seconds say")
    func activeIsBoundedByElapsed() throws {
        // Unlike the live clocks, this reads a persisted, CloudKit-mirrored Double column
        // (`RideSchemaV7.swift:42`). A negative value would render active ABOVE elapsed with the
        // caption present to make it unmissable; an oversized one would zero the headline.
        for paused in [-500.0, 900.0] {
            let d = try #require(RideDuration(startedAt: start,
                                              endedAt: start.addingTimeInterval(600),
                                              checkpointedAt: nil, pausedSeconds: paused))
            #expect(d.activeSeconds >= 0)
            #expect(d.activeSeconds <= d.elapsedSeconds)
        }
    }

    @Test("The shared primitive is what every clock in the app subtracts with")
    func sharedPrimitiveSubtractsPausedTime() {
        let now = start.addingTimeInterval(1000)
        #expect(RideDuration.activeSeconds(startedAt: start, asOf: now,
                                           pausedSeconds: 250) == 750)
        #expect(RideDuration.activeSeconds(startedAt: start, asOf: now,
                                           pausedSeconds: 5000) == 0)
    }

    @Test("A Ride projects its own duration")
    func rideProjectsItsDuration() throws {
        let end = start.addingTimeInterval(2880)
        let ride = Ride(kind: .freeRide, startedAt: start, endedAt: end, track: [],
                        stats: nil, pausedSeconds: 600, checkpointedAt: nil,
                        routeId: nil, destinationPlaceId: nil)
        #expect(try #require(ride.duration).activeSeconds == 2280)
    }
}
