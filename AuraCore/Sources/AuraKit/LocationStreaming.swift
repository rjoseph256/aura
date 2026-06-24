import Foundation
import AuraCore

/// Source of GPS samples, expressed as AuraCore `TrackPoint`s.
/// Implementations: `LiveLocationProvider` (CoreLocation) and `SimulatedLocationProvider` (GPX).
public protocol LocationStreaming: AnyObject, Sendable {
    func points() -> AsyncStream<TrackPoint>
    func stop()
}
