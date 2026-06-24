import Foundation
import CoreLocation
import AuraCore

/// CoreLocation-backed provider. Accuracy is intentionally *not* `best` (battery — see spec §8 / Apple guidance).
public final class LiveLocationProvider: NSObject, LocationStreaming, CLLocationManagerDelegate, @unchecked Sendable {
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
                Task { @MainActor in self?.manager.stopUpdatingLocation() }
            }
        }
    }

    public func stop() {
        manager.stopUpdatingLocation()
        continuation?.finish()
        continuation = nil
    }

    public func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        for loc in locs {
            continuation?.yield(TrackPoint(
                coordinate: Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude),
                elevation: loc.altitude,
                timestamp: loc.timestamp))
        }
    }
}
