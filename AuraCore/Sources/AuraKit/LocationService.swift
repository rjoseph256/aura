import Foundation
import CoreLocation
import Observation
import AuraCore

@Observable
@MainActor
public final class LocationService: NSObject, LocationStreaming {
    public private(set) var authorization: LocationAuthorization = .notDetermined
    public private(set) var signal: SignalQuality = .good

    @ObservationIgnored let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        authorization = LocationAuthorization(manager.authorizationStatus)
    }

    /// Classify + filter one fix. Updates `signal`; returns a TrackPoint only if the
    /// fix is acceptable for the recorded track. Pure logic, unit-tested.
    func ingest(_ location: CLLocation, now: Date) -> TrackPoint? {
        let age = now.timeIntervalSince(location.timestamp)
        signal = GPSFix.quality(horizontalAccuracy: location.horizontalAccuracy, age: age)
        guard GPSFix.isAcceptable(horizontalAccuracy: location.horizontalAccuracy) else { return nil }
        return TrackPoint(
            coordinate: Coordinate(latitude: location.coordinate.latitude,
                                   longitude: location.coordinate.longitude),
            elevation: location.altitude,
            timestamp: location.timestamp)
    }

    // Placeholder protocol conformance — real bodies land in Task 4.
    public func points() -> AsyncStream<TrackPoint> { AsyncStream { $0.finish() } }
    public func stop() {}
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.authorization = LocationAuthorization(m.authorizationStatus) }
    }
}
