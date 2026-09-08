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
    /// never conflicts with Home's always-present dashboard sheet. `seed` pre-fills the code
    /// boxes — "" for a fresh entry, the typed code for a Try-again return (ROH-231).
    case joinRide(seed: String)
    /// Ride history, pushed on the nav stack. Reached from the Home control cluster (there
    /// is no tab bar); pushing it empties Home's dashboard sheet so it shows full-screen.
    case history
    /// App settings, pushed on the nav stack — same rationale as `history`.
    case settings
    /// The finished-ride summary, pushed as a navigation destination (not a sheet) so that
    /// returning Home via `popToRoot()` animates summary → Home directly, with no ride HUD
    /// left in the stack to flash (ROH-85). Reached by collapsing the whole path to this single
    /// entry, so only Home sits beneath it.
    case rideSummary(RideSummaryPayload)

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

/// The entry point into the group-ride flow: either creating a session, or joining one via a
/// `JoinCode`. `Hashable` is hand-written because `Route` is not `Hashable` (only `Equatable`)
/// and `JoinCode` is only `Equatable` as well, so this hashes by `Route.id` / `Place.id` /
/// `JoinCode.rawValue`.
public enum GroupRideEntry: Sendable {
    /// `route` is nil for a destination-free ride (ROH-114).
    ///
    /// `place` is what the host was heading to, and exists only so the lobby can say
    /// "Heading to Blue Bottle" instead of naming nothing (D5.4). A `Route` carries bare
    /// `Coordinate`s and no name, so without carrying the `Place` alongside it the name is
    /// simply gone — `AppRoute.navigate(route:destination:)` already pairs the two for the solo
    /// path, and this case was the one place in the app that threw the name away.
    ///
    /// It is nil for an open ride, and also for a guest, who joins by code and never had a
    /// `Place` to begin with. Copy has to work without it.
    case create(route: Route?, place: Place?)
    case join(JoinCode)
}

extension GroupRideEntry: Equatable {
    public static func == (lhs: GroupRideEntry, rhs: GroupRideEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.create(routeA, placeA), .create(routeB, placeB)):
            // `Optional`'s own conformances do the work: two open creates are equal because
            // nil == nil, with no invented discriminator (spec D1.3).
            return routeA?.id == routeB?.id && placeA?.id == placeB?.id
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
        case let .create(route, place):
            hasher.combine(0)
            hasher.combine(route?.id)
            hasher.combine(place?.id)
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
        case let (.joinRide(a), .joinRide(b)):
            return a == b
        case (.history, .history):
            return true
        case (.settings, .settings):
            return true
        case let (.rideSummary(a), .rideSummary(b)):
            // saveFailed deliberately excluded — identity is the ride, not its save outcome.
            return a.ride.id == b.ride.id
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
        case let .joinRide(seed):
            hasher.combine(4)
            hasher.combine(seed)
        case .history:
            hasher.combine(5)
        case .settings:
            hasher.combine(6)
        case let .rideSummary(payload):
            // saveFailed deliberately excluded from identity — hash the ride only.
            hasher.combine(7)
            hasher.combine(payload.ride.id)
        }
    }
}

/// Self-contained payload for `AppRoute.rideSummary`: the finished ride and whether it failed
/// to persist. Held by value so the summary renders after the producing coordinator/HUD is torn
/// down. `AppRoute` hashes/equates this case by `ride.id` ONLY (see the comment on `AppRoute`'s
/// `==`/`hash`); `saveFailed` is deliberately outside identity.
public struct RideSummaryPayload: Sendable {
    public var ride: Ride
    public var saveFailed: Bool
    public init(ride: Ride, saveFailed: Bool) {
        self.ride = ride
        self.saveFailed = saveFailed
    }
}
