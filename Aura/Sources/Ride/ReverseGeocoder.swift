import Foundation
import CoreLocation
import AuraCore

/// App-target reverse-geocode for auto-naming a marked spot. Best-effort: nil on
/// failure/offline (the caller keeps the provisional name). CoreLocation is iOS-only,
/// so this stays out of the package.
enum ReverseGeocoder {
    static func name(for coordinate: Coordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return placemark.name ?? placemark.thoroughfare ?? placemark.locality
    }
}
