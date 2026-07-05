import AuraCore

/// A per-ride observer of live location fixes, injected at `start()` (mirrors `GroupLocationSink`).
@MainActor
public protocol RideDiscoverySink: AnyObject {
    func rideDidUpdateLocation(_ point: TrackPoint)
}
