import Foundation
import AuraCore

/// Source of GPS samples, expressed as AuraCore `TrackPoint`s.
/// Implementations: `LocationService` (CoreLocation) and `SimulatedLocationProvider` (GPX).
///
/// Streaming is a main-actor concern: `CLLocationManager` and its delegate callbacks
/// live on the main run loop, and the ride HUDs call `points()`/`stop()` from the
/// main actor. Marking the protocol `@MainActor` lets conformers keep their mutable
/// stream state (the continuation, the replay task) main-actor-isolated instead of
/// leaning on `@unchecked Sendable`.
@MainActor
public protocol LocationStreaming: AnyObject {
    func points() -> AsyncStream<TrackPoint>
    func stop()

    /// Tell the stream that the ride it is feeding has paused (or resumed). The stream keeps
    /// running — the map stays roughly live — but a conformer backed by real hardware drops to
    /// a low-power configuration, because a forgotten pause otherwise wakes the app for every
    /// fix to record points the recorder immediately discards (spec D7).
    ///
    /// A deliberate protocol requirement rather than a defaulted extension: a conformer that
    /// silently keeps burning the battery through a two-hour café stop is exactly the failure
    /// this exists to prevent, so every conformer is forced to say what it does.
    func setRidePaused(_ paused: Bool)
}
