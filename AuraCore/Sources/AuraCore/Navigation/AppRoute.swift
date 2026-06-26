import Foundation

/// A destination on the Ride tab's navigation stack. Held by `NavigationStack(path:)`.
///
/// `Equatable` and `Hashable` are written by hand against the stable ids of the payloads,
/// not their contents, so the path stays cheap to hash and a `Route`'s geometry is never
/// hashed. Two values with the same case and the same ids are the same navigation entry.
public enum AppRoute: Sendable {
    case freeRide
    case preview(Place)
    case navigate(route: Route, destination: Place?)
}

extension AppRoute: Hashable {
    public static func == (lhs: AppRoute, rhs: AppRoute) -> Bool {
        switch (lhs, rhs) {
        case (.freeRide, .freeRide):
            return true
        case let (.preview(a), .preview(b)):
            return a.id == b.id
        case let (.navigate(ra, da), .navigate(rb, db)):
            return ra.id == rb.id && da?.id == db?.id
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .freeRide:
            hasher.combine(0)
        case let .preview(place):
            hasher.combine(1)
            hasher.combine(place.id)
        case let .navigate(route, destination):
            hasher.combine(2)
            hasher.combine(route.id)
            hasher.combine(destination?.id)
        }
    }
}
