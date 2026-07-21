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
    public var track: [TrackPoint] { recorder.track }
    /// Smoothed live speed for the HUD dial (current speed, not the ride average).
    public var currentSpeedMetersPerSecond: Double { recorder.currentSpeedMetersPerSecond }
    public var isRecording: Bool { recorder.isRecording }
    public private(set) var elapsed: TimeInterval = 0
    /// Set by `finish()`; observed by the HUD's `onChange(of:)`, which pushes the summary route
    /// (ROH-85). Not reset here: the HUD is torn down when the path collapses to the summary, so
    /// the coordinator goes with it.
    public var finishedRide: Ride?
    public private(set) var saveFailed = false

    /// Navigate keeps this synced to its latest maneuver; free ride leaves it nil.
    public var maneuver: GuidanceUpdate?
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
                self.recorder.record(point)
                self.groupSink?.locationDidUpdate(
                    coordinate: point.coordinate,
                    progressMeters: self.recorder.stats.distanceMeters,
                    speed: point.speedMetersPerSecond ?? self.recorder.currentSpeedMetersPerSecond,
                    at: point.timestamp)
                self.discoverySink?.rideDidUpdateLocation(point)
                self.guidance?.riderDidUpdate(point)
            }
        }
        tickerTask = Task { [weak self] in
            // Terminates when finish()/cancel() cancels this task; the isRecording guard is a secondary exit.
            while !Task.isCancelled {
                guard let self, self.recorder.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt ?? Date())
                self.pushActivityUpdate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return .started
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

    private func stopStreaming() {
        streamTask?.cancel(); streamTask = nil
        tickerTask?.cancel(); tickerTask = nil
        location?.stop()
        groupSink = nil
        discoverySink = nil
    }
}
