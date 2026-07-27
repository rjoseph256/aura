import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// The coordinator half of spec D6/D7. The first four tests are the `isRecording` call-site
/// audit: each one breaks in a *different* direction if a pause clears the flag, so each gets
/// its own test rather than a single "isRecording stays true".
@MainActor
@Suite(.swiftDataSerialized)
struct RideSessionCoordinatorPauseTests {
    private func point(_ lat: Double, _ t: TimeInterval, speed: Double? = nil) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80),
                   elevation: 250, timestamp: Date(timeIntervalSince1970: t),
                   speedMetersPerSecond: speed)
    }

    private func makeCoordinator(screen: SpyScreenWake = SpyScreenWake(),
                                 activity: SpyRideActivity = SpyRideActivity())
        -> RideSessionCoordinator {
        RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                               screen: screen, activity: activity)
    }

    // MARK: isRecording call sites (spec D6)

    /// `RideSessionCoordinator.finish()` guards on `isRecording`. If a pause cleared it, End
    /// would do nothing while paused and the ride would be discarded — and
    /// `NavigateHUDView+GroupCrew` documents that same guard as load-bearing for group end.
    @Test func endingAPausedRideStillSavesIt() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        c.finish()
        #expect(c.finishedRide != nil)
        #expect(try store.allRides().count == 1)
    }

    /// The ticker's guard is a `return`, not a `continue`: if a pause cleared `isRecording`
    /// the loop would terminate permanently, freezing `elapsed` and killing the Live Activity
    /// push for the rest of the ride.
    @Test func theTickerKeepsPushingWhilePaused() async throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(activity: activity)
        c.start(location: ManualLocationProvider(), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.pause()
        let before = activity.updates.count
        #expect(await waitUntil(timeout: 3) { activity.updates.count > before },
                "the ticker must keep running while paused")
        c.cancel()
    }

    /// `start()`'s re-entry guard is `!isRecording`. A re-entrant start calls
    /// `recorder.start(at:)`, which wipes the track and the stats.
    @Test func startingAgainWhilePausedDoesNotWipeTheRide() async throws {
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        let distance = c.stats.distanceMeters
        c.pause()
        c.start(location: ManualLocationProvider(), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        #expect(c.stats.distanceMeters == distance)
        #expect(c.segments.flatMap(\.points).count == 2)
        c.cancel()
    }

    /// Both HUDs mirror `coordinator.isRecording` into `router.isRideActive`, which is the
    /// only thing stopping a deep link from replacing the nav path — tearing the HUD down
    /// into `cancel()`, which does not save. It also drives the location tier, the post-ride
    /// Home reset and the Settings lockout.
    @Test func aPausedRideStillReadsAsRecordingForIsRideActive() async throws {
        let c = makeCoordinator()
        c.start(location: ManualLocationProvider(), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.pause()
        #expect(c.isRecording)
        #expect(c.isPaused)
        c.resume()
        #expect(c.isRecording)
        #expect(c.isPaused == false)
        c.cancel()
    }

    // MARK: The active clock (spec D5/D6)

    @Test func elapsedStopsAdvancingWhilePausedAndResumes() async throws {
        let c = makeCoordinator()
        c.start(location: ManualLocationProvider(), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        #expect(await waitUntil { c.elapsed > 0 })
        c.pause()
        let frozen = c.elapsed
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(abs(c.elapsed - frozen) < 0.2, "active time must not count the stop")
        c.resume()
        #expect(await waitUntil(timeout: 3) { c.elapsed > frozen })
        c.cancel()
    }

    // MARK: Paused side effects (spec D7)

    @Test func pauseReleasesScreenWakeAndResumeReacquiresIt() async throws {
        let screen = SpyScreenWake()
        let c = makeCoordinator(screen: screen)
        c.start(location: ManualLocationProvider(), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.pause()
        #expect(screen.keepAwakeCalls == [true, false])
        c.resume()
        #expect(screen.keepAwakeCalls == [true, false, true])
        c.cancel()
    }

    /// Holding the navigating tier through a forgotten two-hour pause burns the battery the
    /// rider still needs to get home, to record points `record()` then discards.
    @Test func pauseDropsTheLocationTierAndResumeRestoresIt() async throws {
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.pause()
        #expect(location.ridePausedCalls == [true])
        c.resume()
        #expect(location.ridePausedCalls == [true, false])
        c.cancel()
    }

    @Test func pausedPointsAreDroppedButTheStreamKeepsFlowing() async throws {
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        #expect(await waitUntil { c.segments.first?.points.count == 1 })
        c.pause()
        location.emit(point(40.41, 10))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(c.segments.flatMap(\.points).count == 1)
        #expect(location.stopped == false, "the stream stays subscribed; only recording is gated")
        c.cancel()
    }

    @Test func discoveryIsGatedWhilePaused() async throws {
        let location = ManualLocationProvider()
        let sink = SpyDiscoverySink()
        let c = makeCoordinator()
        c.start(location: location, saving: try RideStore.inMemory(), units: .metric,
                authorization: .authorized, discoverySink: sink)
        location.emit(point(40.40, 0))
        #expect(await waitUntil { sink.points.count == 1 })
        c.pause()
        location.emit(point(40.41, 10))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sink.points.count == 1)
        c.cancel()
    }

    /// A live coordinate published beside a frozen `progressMeters` makes the crew's display
    /// contradict itself: the roster reports the rider ever further behind while their dot
    /// sits at the front. The coordinate keeps flowing; the progress number stops (spec D7).
    @Test func theGroupSinkStopsPublishingProgressWhilePaused() async throws {
        let location = ManualLocationProvider()
        let sink = SpyGroupSink()
        let c = makeCoordinator()
        c.start(location: location, saving: try RideStore.inMemory(), units: .metric,
                authorization: .authorized, groupSink: sink)
        location.emit(point(40.40, 0, speed: 6))
        location.emit(point(40.41, 10, speed: 6))
        #expect(await waitUntil { sink.updates.count == 2 })
        c.pause()
        location.emit(point(40.42, 20, speed: 0))
        #expect(await waitUntil { sink.updates.count == 3 })
        #expect(sink.updates.last?.progressMeters == nil)
        #expect(sink.updates.last?.coordinate == Coordinate(latitude: 40.42, longitude: -80))
        c.cancel()
    }

    // MARK: The pause-boundary flush (spec D7)

    /// Nothing persists mid-ride today, and a pause deliberately creates the conditions for a
    /// jetsam kill: backgrounded, no interaction, screen wake released, for tens of minutes.
    @Test func pauseFlushesTheClosedSegmentsToTheStore() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        let flushed = try store.allRides()
        #expect(flushed.count == 1)
        #expect(flushed.first?.endedAt == nil)
        #expect(flushed.first?.flattenedPoints.count == 2)
        c.cancel()
    }

    @Test func finishingAfterAPauseUpdatesTheCheckpointInsteadOfDuplicatingIt() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        c.resume()
        location.emit(point(40.42, 20))
        #expect(await waitUntil { c.segments.flatMap(\.points).count == 3 })
        c.finish()
        let rides = try store.allRides()
        #expect(rides.count == 1)
        #expect(rides.first?.endedAt != nil)
        #expect(rides.first?.flattenedPoints.count == 3)
    }

    /// Backing out of a ride discards it. A checkpoint written at a pause must go with it,
    /// or an abandoned ride is left behind in History as a ghost.
    @Test func abandoningAPausedRideDiscardsTheCheckpoint() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        #expect(try store.allRides().count == 1)
        c.cancel()
        #expect(try store.allRides().isEmpty)
    }

    /// `onDisappear` calls `cancel()` after every finish, including the normal End. That must
    /// not delete the ride that was just saved.
    @Test func cancelAfterFinishKeepsTheSavedRide() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        c.finish()
        c.cancel()
        #expect(try store.allRides().count == 1)
    }

    @Test func aFlushFailureDoesNotBreakTheRide() async throws {
        let saving = ThrowingRideSaving()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: saving, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        #expect(saving.saveCount == 1, "the flush was attempted")
        #expect(c.isRecording)
        #expect(c.saveFailed == false, "a checkpoint is best-effort; only the real save reports")
        c.cancel()
        #expect(saving.discardCount == 0, "nothing was written, so there is nothing to discard")
    }

    /// A ride the app itself would discard silently is not worth a row in History. Flushing one
    /// would leave a mis-tap behind if the app were killed during the pause — and a rider who
    /// pauses before the first fix has literally nothing to recover.
    @Test func pausingAMisTapRideWritesNoCheckpoint() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        #expect(await waitUntil { c.segments.first?.points.count == 1 })
        #expect(RideBackOutGate.canDiscard(distanceMeters: c.stats.distanceMeters),
                "premise: one fix is under the discard floor")
        c.pause()
        #expect(try store.allRides().isEmpty)
        c.cancel()
    }
}

// MARK: - Doubles

/// A location stream the test drives point by point, so a pause can land *between* two fixes.
/// `ScriptedLocationProvider` yields its whole script at subscribe time, which cannot express
/// that.
@MainActor
final class ManualLocationProvider: LocationStreaming {
    // Built up front, not in `points()`: the coordinator subscribes inside a Task, so a test
    // that emits immediately after `start()` would otherwise race the subscription and lose
    // the point. The stream's unbounded buffer holds anything emitted early.
    private let stream: AsyncStream<TrackPoint>
    private let continuation: AsyncStream<TrackPoint>.Continuation
    private(set) var stopped = false
    private(set) var ridePausedCalls: [Bool] = []

    init() {
        (stream, continuation) = AsyncStream<TrackPoint>.makeStream()
    }

    func points() -> AsyncStream<TrackPoint> { stream }

    func emit(_ point: TrackPoint) { continuation.yield(point) }

    func stop() {
        stopped = true
        continuation.finish()
    }

    func setRidePaused(_ paused: Bool) { ridePausedCalls.append(paused) }
}

@MainActor
final class SpyDiscoverySink: RideDiscoverySink {
    private(set) var points: [TrackPoint] = []
    func rideDidUpdateLocation(_ point: TrackPoint) { points.append(point) }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses. The coordinator's
/// stream task consumes asynchronously, so a plain `Task.yield()` is not enough to observe an
/// emitted point.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
