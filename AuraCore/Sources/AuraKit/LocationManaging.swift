import CoreLocation

/// The slice of `CLLocationManager` that `LocationService` actually drives, expressed as a
/// seam so unit tests inject a fake instead of constructing a real `CLLocationManager`. On the
/// headless macOS CI runner (no `locationd`) a real manager opens an XPC connection that never
/// releases, so `swift test` exits non-zero *after* every test passes (ROH-88). `CLLocationManager`
/// already provides every member, so it satisfies this as-is.
///
/// `@MainActor` mirrors `LocationService` / `LocationStreaming`: the manager is only ever touched
/// on the main actor, so a fake can hold plain mutable state without `@unchecked Sendable`.
/// `AnyObject` keeps object identity working — the delegate demux routes a fix by comparing the
/// `ObjectIdentifier` of the ambient vs the one-shot manager. The iOS-only knobs are `#if`-guarded
/// to match `LocationService.setMode`, so the package still builds for the macOS CI host.
@MainActor
protocol LocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var location: CLLocation? { get }
    #if os(iOS)
    var activityType: CLActivityType { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    #endif
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func requestLocation()
}

extension CLLocationManager: LocationManaging {}
