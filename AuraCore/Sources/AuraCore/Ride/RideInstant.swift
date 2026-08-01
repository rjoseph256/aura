import Foundation

/// One instant, read on both clocks that matter.
///
/// `date` is civil time: it is what gets persisted, displayed, and handed to the OS timer, and iOS
/// moves it (NTP, NITZ, a manual change). `monotonicSeconds` is a reading that only ever moves
/// forward at a real-time rate. **Every duration in the ride path is a difference of
/// `monotonicSeconds`; nothing subtracts two `date`s** (ROH-130).
///
/// One value rather than two parameters so a caller cannot hand a boundary a mismatched pair.
public struct RideInstant: Equatable, Sendable {
    public let date: Date
    /// Seconds since an arbitrary origin taken once per process. **Only ever subtracted from
    /// another reading taken in the same process run** — the origin does not survive a relaunch,
    /// which is a constraint on ROH-144's eventual resume-across-relaunch work.
    public let monotonicSeconds: TimeInterval

    public init(date: Date, monotonicSeconds: TimeInterval) {
        self.date = date
        self.monotonicSeconds = monotonicSeconds
    }

    /// The two clocks are read a few instructions apart and cannot be sampled together. A thread
    /// descheduled between them fabricates a small disagreement; `RideRecorder.align(at:)` is the
    /// only consumer of that agreement, it needs a 2 s disagreement to act, and it self-corrects
    /// on the next reading.
    public static var now: RideInstant {
        RideInstant(date: Date(), monotonicSeconds: elapsedSinceOrigin())
    }

    /// `ContinuousClock` and not `SuspendingClock`: on Darwin this is `mach_continuous_time`, which
    /// keeps advancing while the machine sleeps. A phone in a jersey pocket with the screen locked
    /// is exactly where a suspending clock under-counts, and a ride clock that loses the sleeping
    /// minutes is a worse bug than the one this fixes. `ProcessInfo.systemUptime` is out for the
    /// same reason — it is documented as time *awake* since restart.
    ///
    /// A reboot needs no handling: it terminates the process, so the origin is re-taken.
    private static let origin = ContinuousClock.now

    /// `Duration` has no `TimeInterval` bridge, so the conversion is explicit. Both components
    /// carry the sign, so this is also correct for a negative duration.
    private static func elapsedSinceOrigin() -> TimeInterval {
        let c = origin.duration(to: ContinuousClock.now).components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}

/// The ride path's source of instants.
///
/// A seam rather than a bare `RideInstant.now` call because `RideSessionCoordinator` reads the
/// clock from inside `start`, `pause`, `resume` and `finish`, where a test cannot inject one. A
/// test that injects instants into some entry points and lets others read the real clock puts two
/// different monotonic origins into one recorder and computes stops of tens of millions of seconds
/// — while the `>=`-shaped assertions in the suite keep passing (ROH-130 D7).
///
/// Not `Sendable`-constrained: every consumer is `@MainActor`, so global-actor isolation already
/// covers the stored existential, and requiring it would push the test fake into `@unchecked`.
public protocol RideClocking {
    func now() -> RideInstant
}

public struct SystemRideClock: RideClocking {
    public init() {}
    public func now() -> RideInstant { .now }
}
