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
    public var isRecording: Bool { recorder.isRecording }
    public private(set) var elapsed: TimeInterval = 0
    /// Set by `finish()`, bound by the HUD's summary `.sheet(item:)`. Not reset here:
    /// the HUD is torn down on return to `.plan`, so the coordinator goes with it.
    public var finishedRide: Ride?
    public private(set) var saveFailed = false

    /// Navigate keeps this synced to its latest maneuver; free ride leaves it nil.
    public var maneuver: GuidanceUpdate?

    private let kind: Ride.Kind
    private let recorder: RideRecorder
    private let destinationName: String?
    private let screen: any ScreenWakeControlling
    private let activity: any RideActivityControlling
    private let workout: (any WorkoutWriting)?

    // Stashed at start() for the rest of the ride.
    private var location: (any LocationStreaming)?
    private var saving: (any RideSaving)?
    private var startedAt: Date?
    private var saveToHealth = false
    // Internal so a test can await the stream draining; not part of the public surface.
    var streamTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    public init(kind: Ride.Kind,
                destinationName: String?,
                screen: any ScreenWakeControlling,
                activity: any RideActivityControlling,
                workout: (any WorkoutWriting)? = nil) {
        self.kind = kind
        self.recorder = RideRecorder(kind: kind)
        self.destinationName = destinationName
        self.screen = screen
        self.activity = activity
        self.workout = workout
    }

    public enum StartOutcome: Sendable { case started, permissionDenied }

    /// Gates on authorization, then starts the recorder, screen-wake, the Live Activity,
    /// and the stream + ticker tasks. A no-op returning `.started` if already recording.
    @discardableResult
    public func start(location: any LocationStreaming,
                      saving: any RideSaving,
                      units: DistanceUnits,
                      authorization: LocationAuthorization,
                      saveToHealth: Bool = false) -> StartOutcome {
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
        let now = Date()
        startedAt = now
        elapsed = 0
        recorder.start(at: now)
        screen.setKeepAwake(true)
        activity.start(kind: kind, startedAt: now, units: units, destinationName: destinationName)

        streamTask = Task { [weak self] in
            guard let stream = self?.location?.points() else { return }
            for await point in stream { self?.recorder.record(point) }
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
        activity.update(stats: recorder.stats, maneuver: maneuver)
    }

    /// Idempotent on `isRecording`: the End-ride button and a navigate arrival can both
    /// call this. Stops streaming, releases the screen, ends the activity, saves, and
    /// publishes the ride (even on a save failure, so the summary still shows).
    public func finish() {
        guard recorder.isRecording else { return }
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

    /// Teardown for an abandoned (not finished) ride, called from `onDisappear`. Stops
    /// streaming and releases the screen. Does not save, publish, or end the activity,
    /// matching today's `onDisappear`.
    public func cancel() {
        stopStreaming()
        screen.setKeepAwake(false)
    }

    private func stopStreaming() {
        streamTask?.cancel(); streamTask = nil
        tickerTask?.cancel(); tickerTask = nil
        location?.stop()
    }
}
