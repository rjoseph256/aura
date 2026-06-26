import Foundation

/// A parsed deep-link intent. Separate from `AppRoute` because `home`, `history`, and
/// `settings` select a tab rather than push a route, so this is not a subset of the path
/// element. The app maps an intent onto `selectedTab` and the path in `AppRouter.handle(url:)`.
public enum DeepLink: Equatable, Sendable {
    case home          // Ride tab, pop to root
    case history
    case settings
    case freeRide      // Ride tab, pre-start free-ride HUD
    case preview(Place)

    /// Parses an `aura://…` URL. Returns nil for any scheme, host, or parameter set the app
    /// does not recognize, so an unknown link is a no-op rather than a guess.
    public static func parse(_ url: URL) -> DeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "aura" else { return nil }
        // Custom-scheme URLs carry the route in the host (aura://plan). Fall back to a
        // slash-trimmed path for the rare opaque form.
        let host = components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "plan":     return .home
        case "history":  return .history
        case "settings": return .settings
        case "ride":     return .freeRide
        case "preview":  return preview(from: components)
        default:         return nil
        }
    }

    private static func preview(from components: URLComponents) -> DeepLink? {
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let latText = value("lat"), let lat = Double(latText),
              let lngText = value("lng"), let lng = Double(lngText),
              let name = value("name"), !name.isEmpty else {
            return nil
        }
        let place = Place(name: name,
                          coordinate: Coordinate(latitude: lat, longitude: lng),
                          category: .custom)
        return .preview(place)
    }
}
