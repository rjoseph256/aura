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

    /// Invoked for each spoken prompt; the view decides whether to actually speak
    /// (honoring the mute toggle and the voice setting).
    @ObservationIgnored public var onSpeak: (String) -> Void = { _ in }

    /// Invoked once the rider reaches the final destination; the view ends the ride.
    @ObservationIgnored public var onArrive: () -> Void = { }

    @ObservationIgnored private let session: any GuidanceSession
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(session: any GuidanceSession) {
        self.session = session
    }

    /// Begins guidance for `route` and consumes its event stream until it finishes
    /// (or `stop()` is called).
    public func start(route: Route) {
        task?.cancel()
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
                lastUpdate = update
                turn = TurnCardPresenter.state(for: update)
            case .spokenInstruction(let text):
                onSpeak(text)
            case .arrivedAtDestination:
                // `onArrive` ends the ride, which tears down this very session. Stop
                // consuming by returning rather than letting teardown cancel the task
                // from inside its own loop.
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
}
