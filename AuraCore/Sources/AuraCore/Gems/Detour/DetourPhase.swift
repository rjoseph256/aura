import Foundation

/// The detour is an ephemeral guidance overlay on a `.freeRide` session. This is the
/// pure phase it lives in — decoupled from `Ride.Kind`. See DetourMachine for transitions.
public enum DetourPhase: Equatable, Sendable {
    case inactive
    case routing(Gem)
    case guiding(Gem)
    case headingOnly(Gem)

    /// The gem being detoured to, if any.
    public var gem: Gem? {
        switch self {
        case .inactive: return nil
        case .routing(let g), .guiding(let g), .headingOnly(let g): return g
        }
    }

    /// True whenever a detour is in flight (routing, guiding, or offline heading).
    public var isDetouring: Bool {
        if case .inactive = self { return false }
        return true
    }

    /// True only while actively turn-by-turn guiding (drives the Tier-3 haptic arbiter's
    /// wrist-contention note; card/haptic suppression uses `isDetouring`).
    public var isGuiding: Bool {
        if case .guiding = self { return true }
        return false
    }
}

/// Events fed to `DetourMachine`. Arrival is detected outside the machine (Mapbox event
/// while guiding; straight-line distance while headingOnly) and normalized to `.arrived`.
public enum DetourEvent: Equatable, Sendable {
    case request(Gem)
    case routeReady
    case routeFailedOffline
    case networkRecovered
    case arrived
    case cancel
    case retarget(Gem)
}

/// Side-effect intents the machine emits; the AuraKit controller performs them. All are
/// idempotent by contract (R4): a redundant stop/detach is a harmless no-op.
public enum DetourEffect: Equatable, Sendable {
    case startRouting(Gem)
    case startGuidance(Gem)
    case startHeadingOnly(Gem)
    case stopGuidance
    case stopHeading
    case confirmArrival(Gem)
    case detached
}

/// The offline pointer state: a compass arrow (relative to device heading) + crow-flies
/// distance. NOT turn-by-turn — the overlay labels it "approximate direction" (R14).
public struct HeadingArrow: Equatable, Sendable {
    public var relativeBearingDegrees: Double
    public var straightLineDistanceMeters: Double
    public init(relativeBearingDegrees: Double, straightLineDistanceMeters: Double) {
        self.relativeBearingDegrees = relativeBearingDegrees
        self.straightLineDistanceMeters = straightLineDistanceMeters
    }
}
