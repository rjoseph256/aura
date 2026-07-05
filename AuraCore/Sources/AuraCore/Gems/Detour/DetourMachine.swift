import Foundation

/// The pure heart of the detour: `(phase, event) -> (phase, effects)`. Deterministic,
/// no `Date()`/timers/IO. Any unlisted (phase, event) pair is a no-op returning
/// `(phase, [])` — including `(inactive, routeReady)` / `(inactive, routeFailedOffline)`,
/// which are reachable ONLY via a stale async route completion after cancel (R2); the
/// controller's generation guard makes them unreachable in practice, and the no-op is the
/// safety net.
public enum DetourMachine {
    public static func reduce(_ phase: DetourPhase, on event: DetourEvent) -> (DetourPhase, [DetourEffect]) {
        switch (phase, event) {
        // Cancel from any phase → inactive, tearing down whatever was live. Idempotent (R4).
        case (_, .cancel):
            return (.inactive, [.stopGuidance, .stopHeading, .detached])

        case (.inactive, .request(let g)):
            return (.routing(g), [.startRouting(g)])

        case (.routing(let g), .routeReady):
            return (.guiding(g), [.startGuidance(g)])

        case (.routing(let g), .routeFailedOffline):
            return (.headingOnly(g), [.startHeadingOnly(g)])

        case (.guiding(let g), .arrived):
            return (.inactive, [.stopGuidance, .confirmArrival(g), .detached])

        case (.headingOnly(let g), .arrived):
            return (.inactive, [.stopHeading, .confirmArrival(g), .detached])

        case (.headingOnly(let g), .networkRecovered):
            return (.routing(g), [.stopHeading, .startRouting(g)])

        // Re-target from any active phase → route to the new gem, dropping the old leg.
        case (.routing, .retarget(let g2)),
             (.guiding, .retarget(let g2)),
             (.headingOnly, .retarget(let g2)):
            return (.routing(g2), [.stopGuidance, .stopHeading, .startRouting(g2)])

        default:
            return (phase, [])
        }
    }
}
