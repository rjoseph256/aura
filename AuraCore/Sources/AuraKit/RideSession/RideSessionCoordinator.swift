import Foundation
import Observation
import AuraCore

/// Owns the start-to-finish lifecycle of one ride: the recorder, the location stream,
/// the permission-gate decision, screen-wake, the Live Activity loop, the save, and the
/// finished-ride result. The two app-target side effects and the store are injected as
/// protocol seams, so this whole type compiles and tests on the macOS host.
///
/// Construction takes the env-free pieces (kind, destination, the seams); the
/// environment-derived collaborators (the location stream, the store, the units, the
/// current authorization) arrive at `start()`.
@MainActor
@Observable
public final class RideSessionCoordinator {
    // Read by the HUDs.
    public var stats: RideStats { recorder.stats }
    public var segments: [RideSegment] { recorder.segments }
    /// Smoothed live speed for the HUD dial (current speed, not the ride average).
    public var currentSpeedMetersPerSecond: Double { recorder.currentSpeedMetersPerSecond }
    /// True for the whole ride, **including while it is paused** — it is "a ride is in
    /// progress", which is what `router.isRideActive` mirrors (spec D6). Use `isPaused` for
    /// the paused reading.
    public var isRecording: Bool { recorder.isRecording }
    public var isPaused: Bool { recorder.isPaused }
    /// **Active** time: wall-clock since the start, less everything spent paused (spec D5).
    /// The ticker keeps running while paused; this simply stops advancing.
    public private(set) var elapsed: TimeInterval = 0
    /// Set by `finish()`; observed by the HUD's `onChange(of:)`, which pushes the summary route
    /// (ROH-85). Not reset here: the HUD is torn down when the path collapses to the summary, so
    /// the coordinator goes with it.
    public var finishedRide: Ride?
    public private(set) var saveFailed = false

    /// Navigate keeps this synced to its latest maneuver; free ride leaves it nil.
    public var maneuver: GuidanceUpdate?

    /// Notified synchronously inside `pause()`/`resume()`. The navigate HUD sets its
    /// `GuidanceViewModel` here; a SwiftUI `.onChange` would land a turn later, and that turn
    /// is the one in which an arrival event can still end the ride under a rider who has just
    /// paused at their destination (see `RidePauseObserving`).
    @ObservationIgnored public weak var pauseObserver: (any RidePauseObserving)?
    /// True whenever a detour overlay is in flight (drives the gem card/haptic arbiter).
    public var isDetouring: Bool { guidance?.isDetouring ?? false }
    /// True only while turn-by-turn guiding.
    public var isGuiding: Bool { guidance?.isGuiding ?? false }

    private let kind: Ride.Kind
    private let recorder: RideRecorder
    private let destinationName: String?
    private let screen: any ScreenWakeControlling
    private let activity: any RideActivityControlling
    private let workout: (any WorkoutWriting)?
    @ObservationIgnored private let guidance: (any GuidanceControlling)?

    // Stashed at start() for the rest of the ride.
    private var location: (any LocationStreaming)?
    private var saving: (any RideSaving)?
    private var startedAt: Date?
    private var saveToHealth = false
    private var groupSink: (any GroupLocationSink)?
    private var discoverySink: (any RideDiscoverySink)?
    /// The ride id written by the last pause-boundary flush, while that row is still a
    /// checkpoint. Cleared by `finish()` — after which the row is a real finished ride and
    /// `cancel()` must leave it alone.
    private var checkpointedRideID: UUID?
    // Internal so a test can await the stream draining; not part of the public surface.
    var streamTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    public init(kind: Ride.Kind,
                destinationName: String?,
                screen: any ScreenWakeControlling,
                activity: any RideActivityControlling,
                workout: (any WorkoutWriting)? = nil,
                guidance: (any GuidanceControlling)? = nil) {
        self.kind = kind
        self.recorder = RideRecorder(kind: kind)
        self.destinationName = destinationName
        self.screen = screen
        self.activity = activity
        self.workout = workout
        self.guidance = guidance
    }

    public enum StartOutcome: Sendable { case started, permissionDenied }

    /// Gates on authorization, then starts the recorder, screen-wake, the Live Activity,
    /// and the stream + ticker tasks. A no-op returning `.started` if already recording.
    @discardableResult
    public func start(location: any LocationStreaming,
                      saving: any RideSaving,
                      units: DistanceUnits,
                      authorization: LocationAuthorization,
                      saveToHealth: Bool = false,
                      groupSink: (any GroupLocationSink)? = nil,
                      discoverySink: (any RideDiscoverySink)? = nil) -> StartOutcome {
        guard !recorder.isRecording else { return .started }
        switch authorization {
        case .denied, .restricted:
            return .permissionDenied
        // .notDetermined proceeds: the location stream's points() requests When-In-Use,
        // which surfaces the system prompt on first use.
        case .authorized, .notDetermined:
            break
        }

        self.location = location
        self.saving = saving
        self.saveToHealth = saveToHealth
        self.groupSink = groupSink
        self.discoverySink = discoverySink
        let now = Date()
        startedAt = now
        elapsed = 0
        recorder.start(at: now)
        screen.setKeepAwake(true)
        activity.start(kind: kind, startedAt: now, units: units, destinationName: destinationName)

        streamTask = Task { [weak self] in
            guard let stream = self?.location?.points() else { return }
            for await point in stream {
                guard let self else { return }
                let paused = self.recorder.isPaused
                self.recorder.record(point)   // a no-op while paused
                self.groupSink?.locationDidUpdate(
                    coordinate: point.coordinate,
                    // Paused: the coordinate keeps flowing, so the crew's dot stays alive and
                    // the rider does not age into `.dropped` mid-café-stop. Progress is not
                    // published, because it is no longer being computed — though see
                    // `GroupLocationSink`: the wire still carries the held value, so the crew's
                    // view is unchanged until Slice C puts `paused` on the wire.
                    progressMeters: paused ? nil : self.recorder.stats.distanceMeters,
                    speed: point.speedMetersPerSecond ?? self.recorder.currentSpeedMetersPerSecond,
                    at: point.timestamp)
                if !paused { self.discoverySink?.rideDidUpdateLocation(point) }
                self.guidance?.riderDidUpdate(point)
            }
        }
        tickerTask = Task { [weak self] in
            // Terminates when finish()/cancel() cancels this task; the isRecording guard is a
            // secondary exit. It must NOT be tripped by a pause — it is a `return`, so the
            // ticker would never come back, and `isRecording` stays true while paused (D6).
            while !Task.isCancelled {
                guard let self, self.recorder.isRecording else { return }
                self.refreshElapsed()
                self.pushActivityUpdate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return .started
    }

    /// Recompute active time: wall-clock since the start, less paused time — including the
    /// pause currently in flight, so the clock stops the moment the rider taps rather than
    /// when the interval eventually closes.
    private func refreshElapsed(now: Date = Date()) {
        guard let startedAt else { return }
        elapsed = max(0, now.timeIntervalSince(startedAt) - recorder.pausedSeconds(asOf: now))
    }

    /// Pause the ride: stop recording, release the wake lock, and flush what has been ridden so
    /// far. The ride stays *active* throughout — `isRecording` does not move (spec D6/D7). A
    /// no-op unless a ride is running and not already paused.
    ///
    /// The flush is the expensive part (a full-track encode and a mirrored write, in this same
    /// turn). One per manual pause is fine; auto-pause, which fires at every red light, will
    /// have to make it incremental or move it off the tap.
    public func pause() {
        guard recorder.isRecording, !recorder.isPaused else { return }
        let now = Date()
        recorder.pause(at: now)
        // Before anything that can yield: an arrival draining after the pause but before
        // guidance knows about it would end the ride under the rider.
        pauseObserver?.rideDidSetPaused(true)
        refreshElapsed(now: now)
        screen.setKeepAwake(false)
        flushCheckpoint(at: now)
    }

    /// Resume recording: open the next segment and re-acquire the screen. A no-op unless the
    /// ride is paused.
    public func resume() {
        guard recorder.isPaused else { return }
        let now = Date()
        recorder.resume(at: now)
        pauseObserver?.rideDidSetPaused(false)
        refreshElapsed(now: now)
        screen.setKeepAwake(true)
    }

    /// Persist the ride as it stands at a pause boundary. Nothing else persists mid-ride, and
    /// a pause deliberately creates the conditions for a jetsam kill — backgrounded, no
    /// interaction, screen wake released, for tens of minutes — so losing that gamble would
    /// cost the rider everything they rode *before* the stop (spec D7).
    ///
    /// Best-effort by design: the checkpoint is a safety net, so a failure here must not set
    /// `saveFailed` (which the summary reads) or interrupt the ride. The row carries the same
    /// id as the finished ride, so End updates it rather than adding a second copy, and
    /// `discard()` removes it if the rider throws the ride away instead.
    private func flushCheckpoint(at date: Date) {
        guard let saving else { return }
        // Nothing worth recovering: a ride the app would itself discard silently on a back-out
        // has no business appearing in History if the pause is killed. This also covers a
        // pause taken before the first fix, where there is no track at all.
        guard !RideBackOutGate.canDiscard(distanceMeters: recorder.stats.distanceMeters) else { return }
        do {
            try saving.save(recorder.checkpoint(at: date, destinationName: destinationName))
            checkpointedRideID = recorder.rideID
        } catch {
            // Deliberately NOT cleared: `checkpointedRideID` tracks whether a row is out there,
            // not whether the last write succeeded. A failed second flush leaves the first one
            // in the store, and forgetting its id would make it undeletable.
        }
    }

    /// Pushes current stats + maneuver to the Live Activity. Factored out so a test can
    /// call it directly instead of waiting on the 0.5 s ticker. The production activity
    /// conformer throttles internally; test doubles record every call.
    func pushActivityUpdate() {
        activity.update(stats: recorder.stats,
                        currentSpeedMetersPerSecond: recorder.currentSpeedMetersPerSecond,
                        maneuver: maneuver)
    }

    /// Idempotent on `isRecording`: the End-ride button and a navigate arrival can both
    /// call this. Stops streaming, releases the screen, ends the activity, saves, and
    /// publishes the ride (even on a save failure, so the summary still shows).
    public func finish() {
        guard recorder.isRecording else { return }
        guidance?.detach()
        stopStreaming()
        screen.setKeepAwake(false)
        activity.end()
        let ride = recorder.end(at: Date(), destinationName: destinationName)
        do {
            // An upsert on `ride.id`: if a pause already flushed this ride, the same row is
            // updated rather than duplicated. Cleared first so a later `cancel()` — which
            // `onDisappear` always fires — cannot delete the ride that was just saved.
            checkpointedRideID = nil
            try saving?.save(ride)
            saveFailed = false
        } catch {
            saveFailed = true
        }
        finishedRide = ride
        if RideWorkoutGate.shouldWrite(ride: ride, saveToHealthEnabled: saveToHealth) {
            workout?.writeWorkout(WorkoutData(from: ride))
        }
    }

    /// Teardown for an abandoned (not finished) ride, called from `onDisappear` and from the
    /// free-ride back-out discard. Stops streaming, releases the screen, and ends the Live
    /// Activity — so an auto-started ride discarded before it is worth saving leaves no
    /// orphaned Lock Screen activity. Does not save or publish a ride. `activity.end()` is
    /// idempotent, so calling this after `finish()` (e.g. onDisappear after End) is a no-op.
    public func cancel() {
        guidance?.detach()
        stopStreaming()
        screen.setKeepAwake(false)
        activity.end()
    }

    /// The rider threw this ride away: tear down as `cancel()` does, and remove any checkpoint
    /// a pause left in the store.
    ///
    /// Deliberately separate from `cancel()`. `cancel()` runs from `onDisappear`, which this
    /// codebase already documents as unreliable on the retained nav root (`AuraApp.swift`'s
    /// tier controller refuses to key on it) — so a delete there would let a spurious teardown
    /// destroy the one persisted copy of a ride, which is the exact outcome the checkpoint
    /// exists to prevent. A discard is an explicit rider action and says so.
    public func discard() {
        if let id = checkpointedRideID {
            try? saving?.discard(id: id)
            checkpointedRideID = nil
        }
        cancel()
    }

    private func stopStreaming() {
        streamTask?.cancel(); streamTask = nil
        tickerTask?.cancel(); tickerTask = nil
        location?.stop()
        groupSink = nil
        discoverySink = nil
    }
}
