import Foundation

/// Whether to push the Live Activity.
///
/// There is deliberately no "skip but advance the clock" case. The controller's throttle state
/// moves only inside the `.push` branch, so a skipped push cannot advance the clock the heartbeat
/// measures against — the defect that would otherwise make the heartbeat dead code (spec D4).
public enum RideActivityPushDecision: Hashable, Sendable {
    case push
    case skip
}

/// When the in-progress-ride Live Activity should be pushed.
///
/// Pure and host-tested, because the controller that consumes it imports ActivityKit and cannot
/// be tested on any platform this repo runs tests on (spec D2).
public enum RideActivityPushPolicy {
    /// Smallest gap between pushes of changed stats. GPS samples and the half-second ticker
    /// arrive far faster than a glanceable surface needs.
    public static let coalesceInterval: TimeInterval = 4
    /// A push goes out at least this often even when nothing changed, so `staleDate` keeps
    /// advancing while the app is alive. Not gated on paused: a ride receiving no acceptable
    /// fixes is equally quiet and equally alive.
    public static let heartbeatInterval: TimeInterval = 60
    /// How far ahead pushed content is marked stale — longer than the heartbeat, so an alive app
    /// never dims and a dead one confesses within the window.
    public static let staleInterval: TimeInterval = 90

    /// `secondsSinceLastPush` is nil before the first push of an activity.
    ///
    /// A `TimeInterval` rather than two `Date`s: the caller measures it on the monotonic clock, so
    /// a system clock step cannot make it negative and stall every gate below (ROH-130 D6).
    public static func decide(last: RideActivityPayload?,
                              next: RideActivityPayload,
                              secondsSinceLastPush: TimeInterval?) -> RideActivityPushDecision {
        guard let last, let secondsSinceLastPush else { return .push }
        // A new maneuver and a pause/resume are both state the rider is waiting to see, so
        // neither waits on the coalescing cadence.
        if next.turnInstruction != last.turnInstruction { return .push }
        if next.clock.isPaused != last.clock.isPaused { return .push }
        if secondsSinceLastPush >= heartbeatInterval { return .push }
        if next != last && secondsSinceLastPush >= coalesceInterval { return .push }
        return .skip
    }
}
