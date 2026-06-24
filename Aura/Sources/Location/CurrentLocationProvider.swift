import CoreLocation
import AuraCore

// NOTE: v1 uses a one-shot / last-known origin with a Pittsburgh downtown fallback
// (40.4406, -79.9959). A shared, continuous location source (integrated with
// LiveLocationProvider) can replace this in a later task when the ride HUD and
// preview share a single CLLocationManager owner.

/// Fetches the rider's current location once, with a graceful Pittsburgh fallback.
///
/// Usage:
/// ```swift
/// let coord = await CurrentLocationProvider.shared.current()
/// ```
@MainActor
final class CurrentLocationProvider: NSObject {

    static let shared = CurrentLocationProvider()

    // Pittsburgh downtown — safe fallback when location is unavailable.
    private static let pittsburghFallback = Coordinate(latitude: 40.4406, longitude: -79.9959)

    private let manager = CLLocationManager()
    // Each pending call is awaited on a continuation; we resolve them all at once.
    private var pending: [CheckedContinuation<Coordinate, Never>] = []
    private var isFetching = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Returns the device's best available location, or the Pittsburgh fallback.
    /// Never throws, never hangs — resolves within ~3 s regardless of auth status.
    func current() async -> Coordinate {
        // Fast path: if we already have a recent fix, use it immediately.
        if let loc = manager.location, -loc.timestamp.timeIntervalSinceNow < 30 {
            return Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        }

        let authStatus = manager.authorizationStatus

        // If denied or restricted, return fallback immediately — no point waiting.
        switch authStatus {
        case .denied, .restricted:
            return Self.pittsburghFallback
        default:
            break
        }

        // Request auth if not yet determined, then kick off a one-shot location fetch.
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            if !isFetching {
                isFetching = true
                if authStatus == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                    // Delegate will call requestLocation() once auth resolves.
                } else {
                    manager.requestLocation()
                }
                // Hard timeout — resolve with fallback after 3 s no matter what.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.resolvePending(with: Self.pittsburghFallback)
                }
            }
        }
    }

    // MARK: - Private

    private func resolvePending(with coordinate: Coordinate) {
        guard !pending.isEmpty else { return }
        let continuations = pending
        pending.removeAll()
        isFetching = false
        for c in continuations { c.resume(returning: coordinate) }
    }
}

// MARK: - CLLocationManagerDelegate

extension CurrentLocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                self.resolvePending(with: Self.pittsburghFallback)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coord = Coordinate(latitude: loc.coordinate.latitude,
                               longitude: loc.coordinate.longitude)
        Task { @MainActor in
            self.resolvePending(with: coord)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // On failure (e.g. simulator with no location set), fall back to Pittsburgh.
        Task { @MainActor in
            self.resolvePending(with: Self.pittsburghFallback)
        }
    }
}
