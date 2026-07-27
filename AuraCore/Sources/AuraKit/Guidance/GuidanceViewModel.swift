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
public final class GuidanceViewModel {

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

    /// Mirrors the ride's paused state. While true, arrival and spoken prompts are suppressed:
    /// riders pause *at* the destination they navigated to, inside the arrival radius, and
    /// `onArrive` ends the ride and pushes the summary with no confirmation (spec D7). The
    /// event stream keeps being consumed, so guidance carries on when the rider resumes.
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
            case .rerouted(let geometry):
                routeGeometry = geometry
                isRerouting = false
            case .arrivedAtDestination:
                // Suppressed, not deferred: a rider who paused at the destination and then
                // resumed has decided to keep riding, so firing the held arrival at them would
                // end the ride under exactly the person who said otherwise (spec D7).
                if isPaused { continue }
                let cue = hapticEngine.onArrival()
                if hapticsEnabled, let cue { haptics?.play(cue) }
                // `onArrive` is caller-defined: navigate's HUD ends the ride (tearing down
                // this very session), while the detour's `onArrive` detaches and lets the
                // ride continue. Either way, stop consuming by returning rather than
                // letting teardown cancel the task from inside its own loop.
                onArrive()
                return
            }
        }

        // Stream ended without ever reporting progress: guidance couldn't be
        // established — degrade the card to a generic prompt. (An arrival exits above,
        // so reaching here always means a failed/empty stream, never a normal finish.)
        if !sawProgress {
            turn = .unavailable
        }
    }

    /// The turn card, the raw update and the once-per-maneuver haptic for one progress event.
    /// Split out of `run` to keep that loop within the cyclomatic budget.
    private func applyProgress(_ update: GuidanceUpdate) {
        isRerouting = false
        lastUpdate = update
        turn = TurnCardPresenter.state(for: update, units: units)
        let cue = hapticEngine.onProgress(
            distanceToManeuverMeters: update.distanceToManeuverMeters,
            maneuverKey: update.instruction)
        if hapticsEnabled, let cue { haptics?.play(cue) }
    }
}
