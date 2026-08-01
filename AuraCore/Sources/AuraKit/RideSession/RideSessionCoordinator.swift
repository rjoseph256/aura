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
    /// The id of the ride being recorded, for the glance surfaces to exclude (ROH-107, D3).
    /// **The `isRecording` check is load-bearing:** `recorder.rideID` survives `end()`, so a
    /// bare passthrough would keep filtering the ride out of Home after it finished.
    public var activeRideID: UUID? { recorder.isRecording ? recorder.rideID : nil }
    /// **Active** time: wall-clock since the start, less everything spent paused (spec D5).
    /// The ticker keeps running while paused; this simply stops advancing.
    public private(set) var elapsed: TimeInterval = 0
    /// Duration of the stop in progress, zero while recording.
    ///
    /// No longer clamped non-decreasing. It was, against a backward wall-clock step; the input is
    /// now a difference of monotonic readings, so within one stop it cannot fall, and a clamp that
    /// cannot fire is a guard nobody can test (ROH-130 D6).
    public private(set) var currentPauseSeconds: TimeInterval = 0
    /// Set by `finish()`; observed by the HUD's `onChange(of:)`, which pushes the summary route
    /// (ROH-85). Not reset here: the HUD is torn down when the path collapses to the summary, so
    /// the coordinator goes with it.
    ///
    /// **For display, and it is not always byte-identical to what was saved.** When the save
    /// throws, this carries the surviving checkpoint's `checkpointedAt` so the summary describes
    /// the row that reached History; see `finish()`. Never feed it back into a save.
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
    private let haptics: any HapticPlaying
    private let nudges: any RideNudgeScheduling
    private let workout: (any WorkoutWriting)?
    @ObservationIgnored private let guidance: (any GuidanceControlling)?
    /// Where every instant in this type comes from. `start`, `pause`, `resume` and `finish` read
    /// the clock themselves, so without a seam a test could inject instants into `refreshElapsed`
    /// and leave the recorder holding two different monotonic origins — which computes stops of
    /// tens of millions of seconds while `>=` assertions keep passing (ROH-130 D7).
    ///
    /// Internal rather than private only so the test target's `Date` overloads can refuse to run
    /// against a real clock — see `RideClockTestSupport.requireFakeClock`. Nothing in the module
    /// reads it outside this file.
    @ObservationIgnored let clock: any RideClocking

    // Stashed at start() for the rest of the ride.
    private var location: (any LocationStreaming)?
    private var saving: (any RideSaving)?
    // public (not private), like pushActivityUpdate is internal, so a test can anchor its own
    // injected instants to the ride's actual start stamp. NOT the Live Activity's anchor — that
    // is `recorder.anchorStartedAt`, which carries the wallOffset correction this stamp does not
    // (ROH-130 D2/D5).
    public private(set) var startedAt: Date?
    private var saveToHealth = false
    private var groupSink: (any GroupLocationSink)?
    private var discoverySink: (any RideDiscoverySink)?
    /// Identifies the row the last **successful** pause-boundary flush left in the store, while
    /// that row is still a checkpoint.
    struct PendingCheckpoint: Equatable, Sendable {
        let rideID: UUID
        /// The `checkpointedAt` that is actually on that row — the instant of the flush that
        /// wrote it, which is not necessarily the latest pause: a later flush that threw leaves
        /// the earlier row, and the earlier stamp, in place.
        let at: Date
    }

    /// The checkpoint row currently out there, or nil if there is none. Cleared by `finish()` —
    /// after which the row is a real finished ride and `cancel()` must leave it alone.
    ///
    /// One optional rather than two properties: the id and the stamp describe the *same* row, so
    /// clearing one without the other would either strand the row or badge a ride whose row is
    /// gone. `finish()` reads the stamp to tell the summary what actually reached History when
    /// the save throws.
    private(set) var pendingCheckpoint: PendingCheckpoint?
    // Internal so a test can await the stream draining; not part of the public surface.
    var streamTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    /// `haptics` and `nudges` are required rather than optional on purpose: they are wired at
    /// two production call sites each, and an optional would let a missed one ship silently.
    public init(kind: Ride.Kind,
                destinationName: String?,
                screen: any ScreenWakeControlling,
                activity: any RideActivityControlling,
                workout: (any WorkoutWriting)? = nil,
                guidance: (any GuidanceControlling)? = nil,
                haptics: any HapticPlaying,
                nudges: any RideNudgeScheduling,
                clock: any RideClocking = SystemRideClock()) {
        self.kind = kind
        self.recorder = RideRecorder(kind: kind)
        self.destinationName = destinationName
        self.screen = screen
        self.activity = activity
        self.workout = workout
        self.guidance = guidance
        self.haptics = haptics
        self.nudges = nudges
        self.clock = clock
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
        case .authorized:
            // Ask now, while the app is foregrounded and the rider is looking at it. A
            // pause-time request cannot work: a forgotten pause is backgrounded and iOS defers
            // the alert.
            //
            // Only once location is already granted. On a first ride `.notDetermined` means the
            // location prompt — the one the rider tapped Start expecting — is about to appear,
            // and stacking an unexplained "Aura Would Like to Send You Notifications" in front
            // of it is how a rider declines both.
            //
            // The cost is accepted, not avoided: a rider who pauses and forgets on that very
            // first ride gets no ladder at all. Nothing has asked yet, so iOS drops the
            // requests at delivery. From the next ride onward — the first one that starts with
            // location already decided — the prompt has been shown and the ladder works. One
            // unprotected ride is the price of not poisoning the location prompt.
            nudges.prepareAuthorization()
        // .notDetermined proceeds: the location stream's points() requests When-In-Use,
        // which surfaces the system prompt on first use.
        case .notDetermined:
            break
        }

        // The one moment the app knows no ride is paused. Clears anything an earlier ride in
        // this same app session orphaned. Unconditional across both starting cases: a
        // `.notDetermined` ride can still reach a pause, so it can still inherit an orphan.
        nudges.cancelForgottenPauseNudges()

        self.location = location
        self.saving = saving
        self.saveToHealth = saveToHealth
        self.groupSink = groupSink
        self.discoverySink = discoverySink
        let instant = clock.now()
        let now = instant.date
        startedAt = now
        elapsed = 0
        // Reset alongside `elapsed`. The only *synchronous* zeroing on the reused-coordinator
        // path: `refreshElapsed` now assigns this from the recorder, but the first tick is half a
        // second away, and `RideSessionCoordinatorNudgeTests.startingAFreshRideZeroesTheStopClock`
        // reads the chip before any tick has run.
        currentPauseSeconds = 0
        recorder.start(at: instant)
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
                // One instant for both, and refreshElapsed first: it runs `recorder.align`, whose
                // `wallOffset` is what `pushActivityUpdate` reads through the anchor properties.
                let now = self.clock.now()
                self.refreshElapsed(now: now)
                self.pushActivityUpdate(now: now)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return .started
    }

    /// Recompute active time: wall-clock since the start, less paused time — including the
    /// pause currently in flight, so the clock stops the moment the rider taps rather than
    /// when the interval eventually closes.
    ///
    /// Internal rather than private, like `pushActivityUpdate`, so a test can drive a specific
    /// `now` instead of waiting on the 0.5 s ticker.
    func refreshElapsed(now: RideInstant) {
        guard startedAt != nil else { return }
        // The one place `align` runs on the ticker. Before the reads below and before
        // `pushActivityUpdate`, which consumes the anchors it maintains.
        recorder.align(at: now)
        elapsed = RideDuration.activeSeconds(
            elapsed: .measured(recorder.elapsedSeconds(asOf: now)),
            pausedSeconds: recorder.pausedSeconds(asOf: now))
        currentPauseSeconds = recorder.currentPauseSeconds(asOf: now)
    }

    /// Pause the ride: stop recording, release the wake lock, and flush what has been ridden so
    /// far. The ride stays *active* throughout — `isRecording` does not move (spec D6/D7). A
    /// no-op unless a ride is running and not already paused.
    ///
    /// The flush is the expensive part (a full-track encode and a mirrored write, in this same
    /// turn). One per manual pause is fine; auto-pause, which fires at every red light, will
    /// have to make it incremental or move it off the tap.
    public func pause() { pause(at: clock.now()) }

    func pause(at now: RideInstant) {
        guard recorder.isRecording, !recorder.isPaused else { return }
        recorder.pause(at: now)
        haptics.play(.pause)
        // Before anything that can yield: an arrival draining after the pause but before
        // guidance knows about it would end the ride under the rider. `haptics.play` above,
        // `pushActivityUpdate` below, and `scheduleNudges` further down are all synchronous, so
        // none of them opens that window.
        pauseObserver?.rideDidSetPaused(true)
        refreshElapsed(now: now)
        // Before flushCheckpoint, which is a full-track encode and a mirrored write in this same
        // turn (see its doc comment) at the instant a jetsam kill is most likely. The rider's
        // Lock Screen learns about the stop first. Creating a Task does not suspend this
        // function, so the no-yield window above is unaffected.
        pushActivityUpdate(now: now)
        screen.setKeepAwake(false)
        flushCheckpoint(at: now)
        scheduleNudges(from: now.date)
    }

    /// Schedule the forgotten-pause ladder, if this stop is worth one.
    ///
    /// Gated on the same discard floor as `flushCheckpoint`: a ride the app would itself throw
    /// away has no business sending notifications, and that gate is also what stops an
    /// edge-swipe back-out below the floor from orphaning a ladder.
    private func scheduleNudges(from date: Date) {
        guard !RideBackOutGate.canDiscard(distanceMeters: recorder.stats.distanceMeters) else { return }
        nudges.scheduleForgottenPauseNudges(startingAt: date)
    }

    /// Resume recording: open the next segment and re-acquire the screen. A no-op unless the
    /// ride is paused.
    public func resume() { resume(at: clock.now()) }

    func resume(at now: RideInstant) {
        guard recorder.isPaused else { return }
        recorder.resume(at: now)
        haptics.play(.resume)
        nudges.cancelForgottenPauseNudges()
        pauseObserver?.rideDidSetPaused(false)
        refreshElapsed(now: now)
        pushActivityUpdate(now: now)
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
    private func flushCheckpoint(at instant: RideInstant) {
        guard let saving else { return }
        // Nothing worth recovering: a ride the app would itself discard silently on a back-out
        // has no business appearing in History if the pause is killed. This also covers a
        // pause taken before the first fix, where there is no track at all.
        guard !RideBackOutGate.canDiscard(distanceMeters: recorder.stats.distanceMeters) else { return }
        do {
            let row = recorder.checkpoint(at: instant, destinationName: destinationName)
            try saving.save(row)
            pendingCheckpoint = PendingCheckpoint(rideID: row.id,
                                                  at: row.checkpointedAt ?? instant.date)
        } catch {
            // Deliberately NOT cleared: `pendingCheckpoint` tracks whether a row is out there,
            // not whether the last write succeeded. A failed second flush leaves the first one
            // in the store, and forgetting its id would make it undeletable — and its stamp is
            // still the right one, because the surviving row is the first flush's.
        }
    }

    /// Pushes current stats, the maneuver and the clock. Factored out so a test can call it
    /// directly instead of waiting on the 0.5 s ticker; `now` is injectable for the same reason.
    /// The controller decides whether the push actually goes out.
    ///
    /// What keeps the paused clock constant through a stop is that both of its fields were frozen
    /// at the tap — `anchorPausedSince` and `activeSecondsAtPause`, neither of which moves while
    /// the stop is open. The old coupling between `pausedSeconds(asOf: now)` and `now` went with
    /// the arithmetic it protected: the paused branch no longer reads `pausedSeconds` at all, and
    /// that argument now feeds only the running anchor (ROH-130 D5).
    func pushActivityUpdate(now: RideInstant) {
        // The recorder's anchor stamps, not the coordinator's `startedAt`: these carry the
        // wall-offset correction, and `startedAt` deliberately does not (ROH-130 D2/D5).
        guard let anchorStartedAt = recorder.anchorStartedAt else { return }
        let openStop = recorder.anchorPausedSince.flatMap { since in
            recorder.activeSecondsAtPause.map {
                RideOpenStop(since: since, activeSecondsAtPause: $0)
            }
        }
        activity.update(stats: recorder.stats,
                        currentSpeedMetersPerSecond: recorder.currentSpeedMetersPerSecond,
                        maneuver: maneuver,
                        activeClock: .make(startedAt: anchorStartedAt,
                                           pausedSeconds: recorder.pausedSeconds(asOf: now),
                                           openStop: openStop,
                                           now: now.date))
    }

    /// Idempotent on `isRecording`: the End-ride button and a navigate arrival can both
    /// call this. Stops streaming, releases the screen, ends the activity, saves, and
    /// publishes the ride (even on a save failure, so the summary still shows).
    public func finish() {
        guard recorder.isRecording else { return }
        nudges.cancelForgottenPauseNudges()
        guidance?.detach()
        stopStreaming()
        screen.setKeepAwake(false)
        activity.end()
        let ride = recorder.end(at: clock.now(), destinationName: destinationName)
        // The ride as the summary should present it. Diverges from `ride` only when the save
        // throws; `ride` is what is handed to `save`, so the divergence can never be persisted.
        var published = ride
        do {
            // An upsert on `ride.id`: if a pause already flushed this ride, the same row is
            // updated rather than duplicated.
            try saving?.save(ride)
            // Cleared only on success, and only after the save. Clearing first meant a throw
            // stranded the checkpoint row with nothing able to remove it (ROH-107). Safe to
            // clear here: only `discard()` deletes, and `cancel()` — the one thing
            // `onDisappear` always fires — does not.
            pendingCheckpoint = nil
            saveFailed = false
        } catch {
            saveFailed = true
            // The save threw, so what a rider will find in History is the pause checkpoint: a
            // row whose track stops at the flush. Publish the ride wearing that row's marker so
            // the summary *says so* — otherwise the sheet suppresses nothing, and tells the rider
            // the ride "won't appear in History" while it sits there marked "No end recorded".
            //
            // **This restores the marker, not the numbers.** The sheet's distance, moving time,
            // top speed, elevation band and route map all still come from the full in-memory
            // ride, so it legitimately shows more than the History row has. That is what the
            // badge's detail line is for ("Anything after that wasn't saved"); reconciling the
            // figures to the persisted row is not attempted here.
            //
            // Nil when no checkpoint was ever written (an unpaused ride, or a pause under the
            // discard floor), which correctly leaves the "it won't appear" wording.
            //
            // Presentation only. Nothing downstream of `finishedRide` writes: both HUDs hand it
            // to `router.showRideSummary` (a value pushed onto the nav path) and refresh the
            // widgets by re-reading the store, and the workout write below uses `ride`.
            published.checkpointedAt = pendingCheckpoint?.at
        }
        finishedRide = published
        if RideWorkoutGate.shouldWrite(ride: ride, saveToHealthEnabled: saveToHealth) {
            workout?.writeWorkout(WorkoutData(from: ride))
        }
    }

    /// Teardown for an abandoned (not finished) ride, called from `onDisappear` and from the
    /// free-ride back-out discard. Stops streaming, releases the screen, and ends the Live
    /// Activity — so an auto-started ride discarded before it is worth saving leaves no
    /// orphaned Lock Screen activity. Does not save or publish a ride. `activity.end()` is
    /// idempotent, so calling this after `finish()` (e.g. onDisappear after End) is a no-op.
    ///
    /// Deliberately does **not** cancel the pause nudges. This runs from `onDisappear`, which
    /// this codebase documents as firing without the rider asking for anything, and `pause()`'s
    /// `!isPaused` guard means a nudge cancelled here could never be re-armed for a stop still
    /// in progress. Every *legitimate* exit goes through `finish()` or `discard()` first, both
    /// of which cancel; the below-floor path that reaches only `cancel()` never scheduled
    /// anything, because `scheduleNudges` is gated on the discard floor (ROH-101 P5).
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
        nudges.cancelForgottenPauseNudges()
        if let pending = pendingCheckpoint {
            try? saving?.discard(id: pending.rideID)
            pendingCheckpoint = nil
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
