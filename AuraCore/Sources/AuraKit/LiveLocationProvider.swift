import Foundation
import CoreLocation
import AuraCore

/// CoreLocation-backed provider. Accuracy is intentionally *not* `best` (battery — see spec §8 / Apple guidance).
///
/// The whole type is `@MainActor`-isolated: `CLLocationManager` is created and driven
/// on the main run loop, so its delegate callbacks are delivered on the main thread,
/// and the stream `continuation` is only ever touched there. That closes the data race
/// the old `@unchecked Sendable` version papered over.
@MainActor
public final class LiveLocationProvider: NSObject, LocationStreaming, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: AsyncStream<TrackPoint>.Continuation?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        #if os(iOS)
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        #endif
    }

    public func points() -> AsyncStream<TrackPoint> {
        AsyncStream { continuation in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
            continuation.onTermination = { [weak self] _ in
                // onTermination fires on an arbitrary thread when the consumer drops
                // the stream; hop back to the main actor to touch the manager.
                Task { @MainActor in self?.manager.stopUpdatingLocation() }
            }
        }
    }

    public func stop() {
        manager.stopUpdatingLocation()
        continuation?.finish()
        continuation = nil
    }

    nonisolated public func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        // CLLocationManager delivers on the run loop it was created on (the main actor
        // here), so it is safe to assume main-actor isolation to reach the continuation.
        // Build the Sendable TrackPoints first, before crossing in.
        let points = locs.map {
            TrackPoint(coordinate: Coordinate(latitude: $0.coordinate.latitude,
                                              longitude: $0.coordinate.longitude),
                       elevation: $0.altitude,
                       timestamp: $0.timestamp)
        }
        MainActor.assumeIsolated {
            for point in points { continuation?.yield(point) }
        }
    }
}
