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
                                 activity: SpyRideActivity = SpyRideActivity(),
                                 haptics: HapticSpy = HapticSpy(),
                                 clock: any RideClocking = FakeRideClock())
        -> RideSessionCoordinator {
        RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                               screen: screen, activity: activity, haptics: haptics,
                               nudges: NudgeSpy(), clock: clock)
    }

    /// A ride with two fixes — comfortably past the discard floor, so the pause writes a real
    /// checkpoint — left paused.
    private func pausedRideWithACheckpoint(saving: any RideSaving) async throws
        -> RideSessionCoordinator {
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: saving, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        return c
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
        // The one suite member that needs time to pass on its own: it drives the real 0.5 s
        // ticker and waits on `c.elapsed` moving. A `FakeRideClock` is frozen unless a test
        // advances it, so both `waitUntil`s would run out the clock and report as timeouts.
        let c = makeCoordinator(clock: SystemRideClock())
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

    /// Guidance has to learn about the pause in the same turn as the tap, not a SwiftUI
    /// `.onChange` later: the turn in between is the one where an arrival event can still end
    /// the ride under a rider who paused at their destination (spec D7).
    @Test func pauseNotifiesTheObserverSynchronously() async throws {
        let observer = SpyPauseObserver()
        let c = makeCoordinator()
        c.pauseObserver = observer
        c.start(location: ManualLocationProvider(), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.pause()
        #expect(observer.calls == [true])
        c.resume()
        #expect(observer.calls == [true, false])
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

    /// The coordinate keeps flowing while paused — a silent rider ages into `.dropped` after
    /// 40 s, which is the opposite of what a deliberate stop should look like — while the
    /// progress number, which is no longer being computed, is not republished. Asserted at the
    /// sink boundary; what the crew actually renders is unchanged until Slice C (see
    /// `GroupLocationSink`).
    @Test func theCoordinatorPublishesNoProgressWhilePaused() async throws {
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

    // MARK: Pause/resume haptics (spec, ROH-101)

    @Test func pausingConfirmsWithAHaptic() async throws {
        let store = try RideStore.inMemory()
        let haptics = HapticSpy()
        let location = ManualLocationProvider()
        let c = makeCoordinator(haptics: haptics)
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        // `> 0`, not `>= 0`: the latter is true on the first poll, so the wait would return before
        // the emitted points were consumed and the test would assert against an empty recorder.
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        #expect(haptics.cues == [.pause])
    }

    @Test func resumingConfirmsWithADistinctHaptic() async throws {
        let store = try RideStore.inMemory()
        let haptics = HapticSpy()
        let location = ManualLocationProvider()
        let c = makeCoordinator(haptics: haptics)
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        c.pause()
        c.resume()
        #expect(haptics.cues == [.pause, .resume])
    }

    @Test func redundantTransitionsPlayNothing() async throws {
        let store = try RideStore.inMemory()
        let haptics = HapticSpy()
        let c = makeCoordinator(haptics: haptics)
        c.start(location: ManualLocationProvider(), saving: store, units: .metric,
                authorization: .authorized)
        c.pause()
        c.pause()   // already paused — guarded
        c.resume()
        c.resume()  // already recording — guarded
        #expect(haptics.cues == [.pause, .resume])
    }

    @Test func pausingBeforeTheRideStartsPlaysNothing() {
        let haptics = HapticSpy()
        let c = makeCoordinator(haptics: haptics)
        c.pause()
        #expect(haptics.cues.isEmpty)
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

    init() {
        (stream, continuation) = AsyncStream<TrackPoint>.makeStream()
    }

    func points() -> AsyncStream<TrackPoint> { stream }

    func emit(_ point: TrackPoint) { continuation.yield(point) }

    func stop() {
        stopped = true
        continuation.finish()
    }
}

/// Fails the nominated saves (1-indexed) and records everything, so a test can put the store
/// into the states a real one reaches under disk pressure or a CloudKit hiccup.
@MainActor
final class FlakyRideSaving: RideSaving {
    struct SaveError: Error {}
    private let failingSaveNumbers: Set<Int>
    private(set) var saveCount = 0
    private(set) var discarded: [UUID] = []

    init(failingSaveNumbers: Set<Int>) { self.failingSaveNumbers = failingSaveNumbers }

    func save(_ ride: Ride) throws {
        saveCount += 1
        if failingSaveNumbers.contains(saveCount) { throw SaveError() }
    }

    func discard(id: UUID) throws { discarded.append(id) }
}

@MainActor
final class SpyPauseObserver: RidePauseObserving {
    private(set) var calls: [Bool] = []
    func rideDidSetPaused(_ paused: Bool) { calls.append(paused) }
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
