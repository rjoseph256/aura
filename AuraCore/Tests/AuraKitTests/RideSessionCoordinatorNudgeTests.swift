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
