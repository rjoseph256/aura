import CoreLocation

/// The location-permission states the UI distinguishes.
public enum LocationAuthorization: Sendable, Equatable {
    case notDetermined, denied, restricted, authorized

    public init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways: self = .authorized
        #if !os(macOS)
        case .authorizedWhenInUse: self = .authorized
        #endif
        case .denied: self = .denied
        case .restricted: self = .restricted
        default: self = .notDetermined
        }
    }
}
