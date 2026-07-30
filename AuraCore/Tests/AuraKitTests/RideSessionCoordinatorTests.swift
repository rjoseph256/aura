import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite(.swiftDataSerialized)
struct RideSessionCoordinatorTests {
    private func ride(_ t: TimeInterval) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: t),
             endedAt: Date(timeIntervalSince1970: t + 1), track: [], stats: .zero,
             routeId: nil, destinationPlaceId: nil)
    }

    private func point(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80), elevation: 250,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    private func makeCoordinator(kind: Ride.Kind = .freeRide, destinationName: String? = nil,
                                 screen: SpyScreenWake, activity: SpyRideActivity)
        -> RideSessionCoordinator {
        RideSessionCoordinator(kind: kind, destinationName: destinationName,
                               screen: screen, activity: activity, haptics: HapticSpy(), nudges: NudgeSpy())
    }

    @Test func rideStoreConformsToRideSaving() throws {
        let store = try RideStore.inMemory()
        let saving: any RideSaving = store
        try saving.save(ride(100))
        #expect(try store.allRides().count == 1)
    }

    @Test(arguments: [LocationAuthorization.denied, .restricted])
    func blockedAuthorizationGatesStart(_ auth: LocationAuthorization) throws {
        let screen = SpyScreenWake(); let activity = SpyRideActivity()
        let c = makeCoordinator(screen: screen, activity: activity)
        let outcome = c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                              units: .metric, authorization: auth)
        #expect(outcome == .permissionDenied)
        #expect(c.isRecording == false)
        #expect(screen.keepAwakeCalls.isEmpty)
        #expect(activity.started == nil)
    }

    @Test func startWhileRecordingIsNoOp() throws {
        let screen = SpyScreenWake(); let activity = SpyRideActivity()
        let c = makeCoordinator(screen: screen, activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        let outcome = c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                              units: .metric, authorization: .authorized)
        #expect(outcome == .started)
        #expect(screen.keepAwakeCalls == [true]) // screen-wake not called a second time
        #expect(c.isRecording == true)
        c.cancel()
    }

    @Test func authorizedStartWiresSideEffects() throws {
        let screen = SpyScreenWake(); let activity = SpyRideActivity()
        let c = makeCoordinator(kind: .navigate, destinationName: "Church Brew Works",
                                screen: screen, activity: activity)
        let outcome = c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                              units: .imperial, authorization: .authorized)
        #expect(outcome == .started)
        #expect(c.isRecording == true)
        #expect(screen.keepAwakeCalls == [true])
        #expect(activity.started?.kind == .navigate)
        #expect(activity.started?.units == .imperial)
        #expect(activity.started?.destinationName == "Church Brew Works")
        c.cancel()
    }

    @Test func streamedPointsAccumulateStats() async throws {
        let c = makeCoordinator(screen: SpyScreenWake(), activity: SpyRideActivity())
        let provider = ScriptedLocationProvider([point(40.40, 0), point(40.41, 10), point(40.42, 20)])
        c.start(location: provider, saving: try RideStore.inMemory(), units: .metric, authorization: .authorized)
        await c.streamTask?.value
        #expect(c.segments.count == 1)
        #expect(c.segments.first?.points.count == 3)
        #expect(c.stats.distanceMeters > 0)
        c.cancel()
    }

    @Test func finishSavesEndsAndPublishes() async throws {
        let screen = SpyScreenWake(); let activity = SpyRideActivity()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(screen: screen, activity: activity)
        c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
                saving: store, units: .metric, authorization: .authorized)
        await c.streamTask?.value
        c.finish()
        #expect(c.isRecording == false)
        #expect(c.finishedRide != nil)
        #expect(activity.ended == true)
        #expect(screen.keepAwakeCalls == [true, false])
        #expect(c.saveFailed == false)
        #expect(try store.allRides().count == 1)
    }

    @Test func finishIsIdempotent() async throws {
        let store = try RideStore.inMemory()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: SpyRideActivity())
        c.start(location: ScriptedLocationProvider([]), saving: store, units: .metric, authorization: .authorized)
        c.finish()
        c.finish()
        #expect(try store.allRides().count == 1)
    }

    @Test func saveFailureSetsFlagButStillPublishes() async throws {
        let saving = ThrowingRideSaving()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: SpyRideActivity())
        c.start(location: ScriptedLocationProvider([point(40.40, 0)]), saving: saving,
                units: .metric, authorization: .authorized)
        await c.streamTask?.value
        c.finish()
        #expect(c.saveFailed == true)
        #expect(c.finishedRide != nil)
        #expect(saving.saveCount == 1)
    }

    @Test func cancelBeforeFinishDoesNotSaveOrPublish() async throws {
        let screen = SpyScreenWake()
        let store = try RideStore.inMemory()
        let c = makeCoordinator(screen: screen, activity: SpyRideActivity())
        c.start(location: ScriptedLocationProvider([point(40.40, 0)]), saving: store,
                units: .metric, authorization: .authorized)
        await c.streamTask?.value
        c.cancel()
        #expect(c.finishedRide == nil)
        #expect(c.saveFailed == false)
        #expect(screen.keepAwakeCalls == [true, false])
        #expect(try store.allRides().isEmpty)
    }

    @Test func maneuverFlowsToActivityUpdate() throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .imperial, authorization: .authorized)
        let update = GuidanceUpdate(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave")
        c.maneuver = update
        c.pushActivityUpdate()
        #expect(activity.updates.last?.maneuver == update)
        c.cancel()
    }

    @Test func currentSpeedFlowsToActivityUpdate() async throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
                saving: try RideStore.inMemory(), units: .imperial, authorization: .authorized)
        await c.streamTask?.value
        c.pushActivityUpdate()
        // The Live Activity receives the live current speed, not the ride average.
        #expect(c.currentSpeedMetersPerSecond > 0)
        #expect(activity.updates.last?.currentSpeedMetersPerSecond == c.currentSpeedMetersPerSecond)
        c.cancel()
    }

    @Test func finishWritesWorkoutWhenEnabledAndQualifies() async throws {
        let spy = SpyWorkoutWriter()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: SpyRideActivity(),
                                       workout: spy, haptics: HapticSpy(), nudges: NudgeSpy())
        c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
                saving: try RideStore.inMemory(), units: .metric,
                authorization: .authorized, saveToHealth: true)
        await c.streamTask?.value
        c.finish()
        #expect(spy.written.count == 1)
        #expect(spy.written.first?.externalID == c.finishedRide?.id)
    }

    @Test func finishDoesNotWriteWhenDisabled() async throws {
        let spy = SpyWorkoutWriter()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: SpyRideActivity(),
                                       workout: spy, haptics: HapticSpy(), nudges: NudgeSpy())
        c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
                saving: try RideStore.inMemory(), units: .metric,
                authorization: .authorized, saveToHealth: false)
        await c.streamTask?.value
        c.finish()
        #expect(spy.written.isEmpty)
    }

    @Test func finishDoesNotWriteBelowDistanceFloor() async throws {
        let spy = SpyWorkoutWriter()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: SpyRideActivity(),
                                       workout: spy, haptics: HapticSpy(), nudges: NudgeSpy())
        c.start(location: ScriptedLocationProvider([point(40.40, 0)]),
                saving: try RideStore.inMemory(), units: .metric,
                authorization: .authorized, saveToHealth: true)
        await c.streamTask?.value
        #expect(c.stats.distanceMeters < 10)  // guard the premise: one fix => under the floor
        c.finish()
        #expect(spy.written.isEmpty)
    }

    @Test func workoutWriteStillHappensWhenSaveFails() async throws {
        let spy = SpyWorkoutWriter()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: SpyRideActivity(),
                                       workout: spy, haptics: HapticSpy(), nudges: NudgeSpy())
        c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
                saving: ThrowingRideSaving(), units: .metric,
                authorization: .authorized, saveToHealth: true)
        await c.streamTask?.value
        c.finish()
        #expect(c.saveFailed == true)        // save threw
        #expect(c.finishedRide != nil)       // ride still published
        #expect(spy.written.count == 1)      // write runs after the save, unaffected
    }

    @Test func cancelEndsActivityAndReleasesScreen() throws {
        let screen = SpyScreenWake(); let activity = SpyRideActivity()
        let c = makeCoordinator(screen: screen, activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        #expect(activity.ended == false)
        c.cancel()
        #expect(activity.ended == true)
        #expect(screen.keepAwakeCalls == [true, false])
    }
}

// MARK: - Live Activity clock (ROH-102)
//
// Split into its own extension, rather than appended to the struct above, purely to keep
// `type_body_length` under its threshold; the tests still run as part of the same suite.
extension RideSessionCoordinatorTests {
    @Test func pausePushesTheActivityInTheSameTurnWithAPausedClock() throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        let before = activity.updates.count

        c.pause()

        // pause() must push in the same turn as the tap, not wait on the 0.5 s ticker.
        #expect(activity.updates.count == before + 1)
        #expect(try #require(activity.updates.last).activeClock.isPaused)
        c.cancel()
    }

    @Test func resumePushesTheActivityInTheSameTurnWithARunningClock() throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.pause()
        let before = activity.updates.count

        c.resume()

        #expect(activity.updates.count == before + 1)
        #expect(try #require(activity.updates.last).activeClock.isPaused == false)
        c.cancel()
    }

    @Test func theResumedAnchorShiftsForwardByExactlyTheStopDuration() throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        let started = try #require(c.startedAt)

        c.pushActivityUpdate(now: started.addingTimeInterval(600))
        guard case .running(let firstAnchor) =
                try #require(activity.updates.last).activeClock else {
            Issue.record("expected a running clock before the stop")
            return
        }

        // A 240-second stop, driven by injected instants: pause()/resume() calling Date()
        // internally would make the stop microseconds long and the assertion a tautology.
        c.pause(at: started.addingTimeInterval(600))
        c.resume(at: started.addingTimeInterval(840))
        c.pushActivityUpdate(now: started.addingTimeInterval(900))

        guard case .running(let resumedAnchor) =
                try #require(activity.updates.last).activeClock else {
            Issue.record("expected a running clock after the resume")
            return
        }
        #expect(resumedAnchor.timeIntervalSince(firstAnchor) == 240)
        c.cancel()
    }

    @Test func thePausedClockIsIdenticalAcrossTwentyTicks() throws {
        // The highest-value test in this pass. `RideActiveClock.make`'s stability holds only
        // because pushActivityUpdate passes pausedSeconds(asOf: now) with the SAME now it passes
        // as now. A pure-function suite that hand-writes both in lockstep proves the arithmetic
        // and nothing about the wiring, which is the only place the coupling can break.
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        let started = try #require(c.startedAt)
        let stoppedAt = started.addingTimeInterval(600)

        c.pause(at: stoppedAt)
        for i in 0..<20 {
            c.pushActivityUpdate(now: stoppedAt.addingTimeInterval(Double(i) * 0.5))
        }

        let clocks = activity.updates.suffix(20).map(\.activeClock)
        #expect(clocks.count == 20)
        #expect(Set(clocks).count == 1)
        c.cancel()
    }

    @Test func thePausePushPrecedesTheCheckpointFlush() async throws {
        // flushCheckpoint is a full-track encode plus a mirrored write in this same turn, at the
        // exact instant a jetsam kill is most likely. If the kill lands during it, the activity
        // must already know about the stop.
        let order = CallOrder()
        let activity = SpyRideActivity(order: order)
        let saving = OrderRecordingRideSaving(order: order, inner: try RideStore.inMemory())
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        // Two points far enough apart to clear RideBackOutGate's 25 m discard floor, or the
        // pause flushes nothing and there is no ordering to assert.
        c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.45, 60)]),
                saving: saving, units: .metric, authorization: .authorized)
        await c.streamTask?.value

        c.pause()

        #expect(try #require(activity.lastUpdateSequence) < #require(saving.lastSaveSequence))
        c.cancel()
    }
}

// MARK: - Doubles

@MainActor
final class SpyScreenWake: ScreenWakeControlling {
    private(set) var keepAwakeCalls: [Bool] = []
    func setKeepAwake(_ on: Bool) { keepAwakeCalls.append(on) }
}

@MainActor
final class SpyRideActivity: RideActivityControlling {
    struct StartCall {
        let kind: Ride.Kind
        let units: DistanceUnits
        let destinationName: String?
    }
    struct UpdateCall {
        let stats: RideStats
        let currentSpeedMetersPerSecond: Double
        let maneuver: GuidanceUpdate?
        let activeClock: RideActiveClock
    }
    private let order: CallOrder?
    private(set) var started: StartCall?
    private(set) var updates: [UpdateCall] = []
    private(set) var lastUpdateSequence: Int?
    private(set) var ended = false

    init(order: CallOrder? = nil) { self.order = order }

    func start(kind: Ride.Kind, startedAt: Date, units: DistanceUnits, destinationName: String?) {
        started = StartCall(kind: kind, units: units, destinationName: destinationName)
    }
    func update(stats: RideStats,
                currentSpeedMetersPerSecond: Double,
                maneuver: GuidanceUpdate?,
                activeClock: RideActiveClock) {
        updates.append(UpdateCall(stats: stats,
                                  currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
                                  maneuver: maneuver,
                                  activeClock: activeClock))
        lastUpdateSequence = order?.stamp()
    }
    func end() { ended = true }
}

/// Shared monotonic counter, so a test can assert the relative order of two collaborators'
/// calls inside one synchronous turn.
@MainActor
final class CallOrder {
    private var next = 0
    func stamp() -> Int { defer { next += 1 }; return next }
}

/// Stamps its saves against a shared `CallOrder`, then delegates. Wraps rather than replaces
/// `RideStore`, so the checkpoint really writes and the discard-floor gate still applies.
@MainActor
final class OrderRecordingRideSaving: RideSaving {
    private let order: CallOrder
    private let inner: any RideSaving
    private(set) var lastSaveSequence: Int?

    init(order: CallOrder, inner: any RideSaving) {
        self.order = order
        self.inner = inner
    }

    func save(_ ride: Ride) throws {
        lastSaveSequence = order.stamp()
        try inner.save(ride)
    }

    func discard(id: UUID) throws { try inner.discard(id: id) }
}

/// Yields a fixed, buffered set of points then finishes, so a test can await the
/// coordinator's stream task to drain deterministically.
@MainActor
final class ScriptedLocationProvider: LocationStreaming {
    private let samples: [TrackPoint]
    private(set) var stopped = false
    init(_ samples: [TrackPoint]) { self.samples = samples }
    func points() -> AsyncStream<TrackPoint> {
        let samples = self.samples
        return AsyncStream { continuation in
            for p in samples { continuation.yield(p) }
            continuation.finish()
        }
    }
    func stop() { stopped = true }
}

@MainActor
final class ThrowingRideSaving: RideSaving {
    struct SaveError: Error {}
    private(set) var saveCount = 0
    private(set) var discardCount = 0
    func save(_ ride: Ride) throws { saveCount += 1; throw SaveError() }
    func discard(id: UUID) throws { discardCount += 1; throw SaveError() }
}

@MainActor
final class SpyWorkoutWriter: WorkoutWriting {
    private(set) var written: [WorkoutData] = []
    func writeWorkout(_ data: WorkoutData) { written.append(data) }
}
