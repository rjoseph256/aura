import Testing
import Foundation
@testable import AuraCore
@testable import AuraKit

@MainActor
final class NudgeSpy: RideNudgeScheduling {
    private(set) var prepareCount = 0
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0
    private(set) var lastStart: Date?

    func prepareAuthorization() { prepareCount += 1 }
    func scheduleForgottenPauseNudges(startingAt: Date) { scheduleCount += 1; lastStart = startingAt }
    func cancelForgottenPauseNudges() { cancelCount += 1 }
}

@MainActor
@Suite(.swiftDataSerialized)
struct RideSessionCoordinatorNudgeTests {
    private func point(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80),
                   elevation: 250, timestamp: Date(timeIntervalSince1970: t),
                   speedMetersPerSecond: nil)
    }

    private func makeCoordinator(nudges: NudgeSpy) -> RideSessionCoordinator {
        RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                               screen: SpyScreenWake(), activity: SpyRideActivity(),
                               haptics: HapticSpy(), nudges: nudges)
    }

    /// A started ride carrying enough distance that `RideBackOutGate.canDiscard` is false —
    /// the same two-fix setup `pausedRideWithACheckpoint` uses in the pause suite.
    private func ridePastTheDiscardFloor(_ c: RideSessionCoordinator,
                                         _ location: ManualLocationProvider,
                                         _ store: RideStore) async {
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
    }

    @Test func aPauseAboveTheFloorSchedulesTheLadder() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        #expect(nudges.scheduleCount == 1)
    }

    @Test func aPauseBelowTheFloorSchedulesNothing() async throws {
        // A ride the app would itself discard has no business sending notifications, and this
        // gate is what closes the orphan an edge-swipe back-out would otherwise leave behind.
        let nudges = NudgeSpy()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .authorized)
        c.pause()
        #expect(nudges.scheduleCount == 0)
    }

    @Test func startPreparesAuthorizationWhileTheAppIsForegrounded() async throws {
        // Asking here rather than at the first pause is the whole reason scheduling can be
        // synchronous: a forgotten pause is backgrounded, and iOS defers the alert until the
        // app is active again, so a pause-time request would never resolve for the one case
        // the ladder exists to rescue.
        let nudges = NudgeSpy()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .authorized)
        #expect(nudges.prepareCount == 1)
    }

    @Test func aFirstEverRideDoesNotStackTwoPermissionPromptsOnTheRider() async throws {
        // `.notDetermined` means the location prompt the rider tapped Start expecting is about
        // to appear. An unexplained notification prompt in front of it is how both get
        // declined — and a declined notification permission is the one thing that makes the
        // whole ladder dead for the life of the install.
        let nudges = NudgeSpy()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .notDetermined)
        #expect(nudges.prepareCount == 0)
        #expect(nudges.cancelCount == 1,
                "but the ride still started, so it still clears an earlier ride's orphan")
        c.cancel()
    }

    @Test func aDeniedRideNeverAsksForNotifications() async throws {
        let nudges = NudgeSpy()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .denied)
        #expect(nudges.prepareCount == 0)
    }

    @Test func resumeCancels() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        let before = nudges.cancelCount
        c.resume()
        #expect(nudges.cancelCount > before)
    }

    @Test func finishCancels() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        let before = nudges.cancelCount
        c.finish()
        #expect(nudges.cancelCount > before)
    }

    @Test func discardCancels() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        let before = nudges.cancelCount
        c.discard()
        #expect(nudges.cancelCount > before)
    }

    @Test func startingARideClearsWhatAnEarlierOneOrphaned() async throws {
        let nudges = NudgeSpy()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .authorized)
        #expect(nudges.cancelCount == 1)
    }

    @Test func teardownDoesNotCancel() async throws {
        // A spurious onDisappear on the retained nav root would otherwise silently remove the
        // safety net for a still-paused ride, and pause()'s !isPaused guard means nothing
        // would ever re-arm it for that stop.
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        let before = nudges.cancelCount
        c.cancel()
        #expect(nudges.cancelCount == before)
    }

    // MARK: The chip's stop clock

    /// The reset in `resume()` is the load-bearing one, and its absence is *permanent* rather
    /// than transient: `refreshElapsed` only ever raises `currentPauseSeconds`, so a value left
    /// standing at the resume can never fall again. The chip would read "paused 14:32" at a
    /// rider who is moving, for the rest of the ride.
    @Test func theStopClockZeroesTheMomentTheRiderIsMovingAgain() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        #expect(c.currentPauseSeconds == 0, "zero while recording")

        c.pause()
        let stop = Date()
        c.refreshElapsed(now: stop.addingTimeInterval(600))
        #expect(c.currentPauseSeconds >= 599, "the stop in progress is what the chip counts")

        c.resume()
        #expect(c.currentPauseSeconds == 0)
        // And a later tick must not resurrect it, which is the half a naive reset would miss.
        c.refreshElapsed(now: Date().addingTimeInterval(600))
        #expect(c.currentPauseSeconds == 0, "a tick while recording keeps it at zero")
        c.cancel()
    }

    /// A second stop counts only itself. Without a per-stop reset the `max` carries the first
    /// stop's duration into the second, so a 30-second stop would open reading ten minutes.
    @Test func aSecondStopCountsOnlyItself() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        c.refreshElapsed(now: Date().addingTimeInterval(600))
        c.resume()

        c.pause()
        #expect(c.currentPauseSeconds == 0, "a fresh stop opens at zero, not at the first one's")
        let second = Date()
        c.refreshElapsed(now: second.addingTimeInterval(30))
        #expect(c.currentPauseSeconds >= 29)
        #expect(c.currentPauseSeconds < 120, "the first stop's ten minutes must not carry over")
        c.cancel()
    }

    /// The clamp itself. A backward wall-clock step mid-stop must not make the chip count down
    /// while the headline active clock jumps forward in the same tick.
    @Test func theStopClockNeverCountsDownWithinAStop() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        let stop = Date()
        c.refreshElapsed(now: stop.addingTimeInterval(600))
        let peak = c.currentPauseSeconds
        #expect(peak >= 599)

        c.refreshElapsed(now: stop.addingTimeInterval(300))
        #expect(c.currentPauseSeconds == peak, "a backward step holds, it does not rewind")
        c.cancel()
    }

    /// A reused coordinator must not open its next ride wearing the last one's stop. Unreachable
    /// through today's HUDs, which each build a fresh coordinator — but `elapsed` is reset one
    /// line away, and the `max` is what turns the asymmetry into a permanent wrong reading.
    @Test func startingAFreshRideZeroesTheStopClock() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        c.pause()
        c.refreshElapsed(now: Date().addingTimeInterval(600))
        #expect(c.currentPauseSeconds > 0, "premise: the finished ride ended on a stop")
        c.finish()

        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .authorized)
        #expect(c.currentPauseSeconds == 0)
        c.cancel()
    }

    @Test func theLadderIsAnchoredToTheTap() async throws {
        let nudges = NudgeSpy(), location = ManualLocationProvider()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(nudges: nudges)
        await ridePastTheDiscardFloor(c, location, store)
        let before = Date()
        c.pause()
        let start = try #require(nudges.lastStart)
        #expect(start.timeIntervalSince(before) >= 0)
        #expect(start.timeIntervalSince(before) < 5)
    }
}
