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
    case groupRide(GroupRideEntry)
}

/// The entry point into the group-ride flow: either creating a session around a
/// planned `Route`, or joining one via a `JoinCode`. `Hashable` is hand-written
/// because `Route` is not `Hashable` (only `Equatable`) and `JoinCode` is only
/// `Equatable` as well, so this hashes by `Route.id` / `JoinCode.rawValue`.
public enum GroupRideEntry: Sendable {
    case create(Route)
    case join(JoinCode)
}

extension GroupRideEntry: Equatable {
    public static func == (lhs: GroupRideEntry, rhs: GroupRideEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.create(a), .create(b)):
            return a.id == b.id
        case let (.join(a), .join(b)):
            return a == b
        default:
            return false
        }
    }
}

extension GroupRideEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .create(route):
            hasher.combine(0)
            hasher.combine(route.id)
        case let .join(code):
            hasher.combine(1)
            hasher.combine(code.rawValue)
        }
    }
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
        case let (.groupRide(a), .groupRide(b)):
            return a == b
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
        case let .groupRide(entry):
            hasher.combine(3)
            hasher.combine(entry)
        }
    }
}
