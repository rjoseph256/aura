import Foundation

/// A destination on the app's navigation stack. Held by `NavigationStack(path:)`.
///
/// `Equatable` and `Hashable` are written by hand against the stable ids of the payloads,
/// not their contents, so the path stays cheap to hash and a `Route`'s geometry is never
/// hashed. Two values with the same case and the same ids are the same navigation entry.
public enum AppRoute: Sendable {
    case freeRide
    case preview(Place)
    case navigate(route: Route, destination: Place?)
    case groupRide(GroupRideEntry)
    /// The group-ride join-code entry screen, pushed on the nav stack (not a sheet) so it
    /// never conflicts with Home's always-present dashboard sheet.
    case joinRide
    /// Ride history, pushed on the nav stack. Reached from the Home control cluster (there
    /// is no tab bar); pushing it empties Home's dashboard sheet so it shows full-screen.
    case history
    /// App settings, pushed on the nav stack — same rationale as `history`.
    case settings

    /// The navigation path a parsed `DeepLink` resolves to. Pure so it is unit-testable
    /// (the app target has no test bundle). `.home` maps to an empty path (pop to root);
    /// every other link becomes a single-entry stack. Side effects (remembering a previewed
    /// place, the ride-active guard) stay in `AppRouter.handle(url:)`.
    public static func stack(for link: DeepLink) -> [AppRoute] {
        switch link {
        case .home:              return []
        case .history:           return [.history]
        case .settings:          return [.settings]
        case .freeRide:          return [.freeRide]
        case let .preview(place): return [.preview(place)]
        case let .join(code):    return [.groupRide(.join(code))]
        }
    }
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
        case (.joinRide, .joinRide):
            return true
        case (.history, .history):
            return true
        case (.settings, .settings):
            return true
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
        case .joinRide:
            hasher.combine(4)
        case .history:
            hasher.combine(5)
        case .settings:
            hasher.combine(6)
        }
    }
}
