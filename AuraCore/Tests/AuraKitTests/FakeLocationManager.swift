import CoreLocation
@testable import AuraKit

/// A test double for the `LocationManaging` seam so `LocationService` unit tests never
/// construct a real `CLLocationManager` — which, on the headless macos CI runner (no
/// `locationd`), opens an XPC connection that never releases and makes `swift test` exit
/// non-zero *after* every test passes (ROH-88). Records the calls the tests assert on and
/// lets them stage `authorizationStatus`/`location`.
@MainActor
final class FakeLocationManager: LocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var distanceFilter: CLLocationDistance = kCLDistanceFilterNone
    #if os(iOS)
    var activityType: CLActivityType = .other
    var pausesLocationUpdatesAutomatically = true
    var showsBackgroundLocationIndicator = false
    #endif
    var authorizationStatus: CLAuthorizationStatus
    var location: CLLocation?

    private(set) var requestWhenInUseCount = 0
    private(set) var startUpdatingCount = 0
    private(set) var stopUpdatingCount = 0
    private(set) var requestLocationCount = 0

    init(authorizationStatus: CLAuthorizationStatus = .notDetermined, location: CLLocation? = nil) {
        self.authorizationStatus = authorizationStatus
        self.location = location
    }

    func requestWhenInUseAuthorization() { requestWhenInUseCount += 1 }
    func startUpdatingLocation() { startUpdatingCount += 1 }
    func stopUpdatingLocation() { stopUpdatingCount += 1 }
    func requestLocation() { requestLocationCount += 1 }
}
