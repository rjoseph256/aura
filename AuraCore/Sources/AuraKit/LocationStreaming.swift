import Foundation
import AuraCore

/// Source of GPS samples, expressed as AuraCore `TrackPoint`s.
/// Implementations: `LiveLocationProvider` (CoreLocation) and `SimulatedLocationProvider` (GPX).
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
}
