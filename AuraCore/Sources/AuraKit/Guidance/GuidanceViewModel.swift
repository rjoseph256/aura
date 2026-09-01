import Foundation
import Observation
import AuraCore

/// Drives the navigate HUD's turn card from a `GuidanceSession`'s event stream,
/// keeping the SwiftUI view free of any guidance-engine details.
///
/// The view observes `turn`; side effects it must perform itself (speaking a prompt,
/// ending the ride on arrival) are delivered through `onSpeak` / `onArrive` so the
/// view keeps ownership of the speech synthesizer and ride lifecycle. Because the
/// model talks only to the `GuidanceSession` abstraction, a `ScriptedGuidanceSession`
/// can drive it end-to-end in tests with no Mapbox dependency.
@Observable
@MainActor
public final class GuidanceViewModel: RidePauseObserving {

    /// Current turn-card state — the view renders this.
    public private(set) var turn: TurnCardState = .starting

    /// Raw numbers behind the latest `.progress` event (maneuver distance in meters,
    /// instruction). Exposed alongside the formatted `turn` so surfaces that need the
    /// unprocessed values — the ride Live Activity, which formats them unit-aware itself —
    /// can read them without re-deriving from the display string. `nil` until the first
    /// progress update.
    public private(set) var lastUpdate: GuidanceUpdate?

    /// True while the engine is recalculating after going off-route.
    public private(set) var isRerouting = false
    /// The live route shape after a reroute; the HUD draws this in place of the
    /// original `route.geometry`. `nil` until the first reroute.
    public private(set) var routeGeometry: [Coordinate]?

    /// The rider's distance-units setting, set by the view. Drives the unit-aware turn
    /// card. Not observed (only read inside `run`), so `@ObservationIgnored`.
    @ObservationIgnored public var units: DistanceUnits = .imperial

    /// The app-target haptic player. `nil` in tests and on free ride; the navigate
    /// HUD sets it. Not observed — only read inside `start`/`run`.
    @ObservationIgnored public var haptics: (any HapticPlaying)?

    /// Whether turn haptics are enabled (the rider's setting). Live, like `units`:
    /// the navigate HUD updates it on change, so a mid-ride toggle takes effect.
    @ObservationIgnored public var hapticsEnabled: Bool = false

    /// Pure once-per-maneuver edge-trigger for the approach + arrival cues.
    @ObservationIgnored private var hapticEngine = TurnHapticEngine()

    /// Invoked for each spoken prompt; the view decides whether to actually speak
    /// (honoring the mute toggle and the voice setting).
    @ObservationIgnored public var onSpeak: (String) -> Void = { _ in }

    /// Invoked once the rider reaches the final destination; the view ends the ride.
    @ObservationIgnored public var onArrive: () -> Void = { }

    /// Mirrors the ride's paused state, set through `RidePauseObserving` so it lands in the
    /// same turn as the tap. While true, arrival and spoken prompts are suppressed: riders
    /// pause *at* the destination they navigated to, inside the arrival radius, and `onArrive`
    /// ends the ride and pushes the summary with no confirmation (spec D7).
    ///
    /// Progress events keep flowing, so the turn card carries on when the rider resumes. A
    /// suppressed **arrival**, though, is gone: the Mapbox session yields it once, on the
    /// final-waypoint transition, so a rider who pauses inside the arrival radius and then
    /// resumes will not get another one and must end the ride themselves. Whether that
    /// publisher re-fires is not verifiable off-device; the pass that puts a pause button in
    /// front of riders has to check it and give arrival a visible terminal state.
    @ObservationIgnored public var isPaused = false

    @ObservationIgnored private let session: any GuidanceSession
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(session: any GuidanceSession) {
        self.session = session
    }

    /// Begins guidance for `route` and consumes its event stream until it finishes
    /// (or `stop()` is called).
    public func start(route: Route) {
        task?.cancel()
        haptics?.prepare()
        task = Task { @MainActor in
            await self.run(route: route)
        }
    }

    /// Tears down the underlying session and stops consuming events.
    public func stop() {
        task?.cancel()
        task = nil
        session.stop()
    }

    /// Consumes the session's event stream. Exposed (non-public) so tests can await
    /// the pipeline deterministically without racing the detached `start` task.
    func run(route: Route) async {
        let stream = await session.start(route: route)
        var sawProgress = false
        // Mapbox keeps publishing progress against the OLD route throughout a reroute
        // fetch, so a progress tick can no longer be what clears `isRerouting` (that made
        // the pill flicker off mid-reroute). `.rerouted` is the only *positive* clear left,
        // but the loop can also exit without ever seeing one — arrival, an empty/failed
        // stream, or a reroute that never resolves before the session ends. However this
        // function exits, a stuck "recalculating" pill outliving the guidance it describes
        // would be a real (if quieter) version of the same lie, so this covers every exit
        // uniformly rather than duplicating a clear at each one.
        defer { isRerouting = false }

        for await event in stream {
            switch event {
            case .progress(let update):
                sawProgress = true
                applyProgress(update)
            case .spokenInstruction(let text):
                // Nothing to announce to a rider who is standing still — and voice guidance
                // talking over their music through a café stop is its own small insult.
                if !isPaused { onSpeak(text) }
            case .rerouting:
                isRerouting = true
            case .reroutingAborted:
                // Clear the cue and NOTHING else. The asymmetry with `applyReroute` is
                // deliberate: an aborted reroute leaves the rider on the OLD route, which is
                // still the geometry on screen, so `lastUpdate.fractionTraveled` still measures
                // the line being drawn. Nil-ing it here would discard a correct value and blank
                // the traveled-dim for no reason. Only a real geometry swap invalidates it.
                isRerouting = false
            case .rerouted(let geometry):
                applyReroute(geometry)
            case .arrivedAtDestination:
                // Suppressed, not deferred: a rider who paused at the destination and then
                // resumed has decided to keep riding, so firing the held arrival at them would
                // end the ride under exactly the person who said otherwise (spec D7).
                if isPaused { continue }
                play(hapticEngine.onArrival())
                // `onArrive` is caller-defined: navigate's HUD ends the ride (tearing down
                // this very session), while the detour's `onArrive` detaches and lets the
                // ride continue. Either way, stop consuming by returning rather than
                // letting teardown cancel the task from inside its own loop.
                onArrive()
                return
            }
        }

        // Stream ended without ever reporting progress: guidance couldn't be established —
        // degrade the card to a generic prompt. An UNSUPPRESSED arrival exits above, so
        // reaching here means a failed/empty stream — or a stream that ended right after an
        // arrival this model suppressed because the rider was paused, in which case the card
        // holds its last maneuver rather than being reset to a prompt.
        if !sawProgress {
            turn = .unavailable
        }
    }

    /// Set by `RideSessionCoordinator` at the moment of the tap.
    public func rideDidSetPaused(_ paused: Bool) { isPaused = paused }

    /// Plays one haptic cue if the rider has turn haptics on and the engine produced one.
    /// Shared by the progress and arrival paths so the settings gate is written once.
    private func play(_ cue: RideHapticCue?) {
        guard hapticsEnabled, let cue else { return }
        haptics?.play(cue)
    }

    /// The geometry swap for one `.rerouted` event. Split out of `run` for the same reason as
    /// `applyProgress`: the unwrap that clears the stale fraction pushes that loop one past the
    /// cyclomatic budget.
    private func applyReroute(_ geometry: [Coordinate]) {
        routeGeometry = geometry
        isRerouting = false
        // The last fraction measured the OLD route; nil it so no frame pairs it with the new
        // geometry (trim renders full-bright until fresh progress arrives).
        if var update = lastUpdate {
            update.fractionTraveled = nil
            lastUpdate = update
        }
    }

    /// The turn card, the raw update and the once-per-maneuver haptic for one progress event.
    /// Split out of `run` to keep that loop within the cyclomatic budget.
    private func applyProgress(_ update: GuidanceUpdate) {
        lastUpdate = update
        turn = TurnCardPresenter.state(for: update, units: units)
        // Same gate as `.spokenInstruction`: a rider who does not need to be told about the
        // turn does not need to be buzzed about it either (ROH-101 P1).
        //
        // The gate has to cover the *engine*, not just the play. `TurnHapticEngine` is
        // edge-triggered once per maneuver key: feeding it a threshold crossing that happened
        // during the stop would spend that turn's only trigger on a buzz nobody felt, and the
        // rider would resume inside the threshold and never be buzzed for it.
        guard !isPaused else { return }
        let cue = hapticEngine.onProgress(
            distanceToManeuverMeters: update.distanceToManeuverMeters,
            maneuverKey: update.instruction)
        play(cue)
    }
}
