import Foundation
import AuraCore
@testable import AuraKit

extension RideInstant {
    /// A pair with no clock step: the monotonic reading *is* the wall reading, so any two
    /// `coherent` instants differ by the same amount on both clocks.
    ///
    /// Every pre-ROH-130 test drove time with bare `Date`s and meant exactly this, so the `Date`
    /// overloads below route through it and those suites keep asserting what they asserted.
    ///
    /// **One convention per recorder.** `FakeRideClock` produces the same shape, which is what
    /// lets a test call `coordinator.pause()` and `coordinator.refreshElapsed(now: someDate)` and
    /// get a coherent stop. Mixing this with `RideInstant.now` — process-lifetime origin, roughly
    /// 8e8 seconds away — yields durations in the tens of millions, which is why the coordinator
    /// takes a `RideClocking` rather than reading the clock itself.
    static func coherent(_ date: Date) -> RideInstant {
        RideInstant(date: date, monotonicSeconds: date.timeIntervalSinceReferenceDate)
    }

    /// A pair whose wall half has stepped `by` seconds relative to the monotonic timeline — what
    /// an NTP or NITZ correction does mid-ride. Negative steps the clock backwards.
    ///
    /// `date` is the *unstepped* wall reading, so a fixture reads as "the timeline is here, and
    /// the system clock now disagrees by this much".
    static func stepped(_ date: Date, by seconds: TimeInterval) -> RideInstant {
        RideInstant(date: date.addingTimeInterval(seconds),
                    monotonicSeconds: date.timeIntervalSinceReferenceDate)
    }
}

/// A `RideClocking` a test drives by hand. Shares `coherent`'s convention, so instants it hands
/// the coordinator internally and instants a test injects through a `Date` overload are on one
/// timeline.
///
/// **Time does not pass on its own.** A suite that needs the real 0.5 s ticker to advance
/// `elapsed` must keep `SystemRideClock()`; see `RideSessionCoordinatorPauseTests`.
final class FakeRideClock: RideClocking {
    /// The monotonic timeline's current position, expressed as a `Date`.
    var date: Date
    /// Wall-clock divergence from that timeline. Set this to simulate a system clock step.
    var step: TimeInterval = 0

    init(date: Date = Date()) { self.date = date }

    func now() -> RideInstant { .stepped(date, by: step) }

    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

// `Date`-taking overloads so the existing call sites compile unchanged. Test-target only, so
// production cannot fabricate a monotonic reading from a wall clock; `check-monotonic-instants.sh`
// enforces that from the other side.
@MainActor
extension RideRecorder {
    func start(at date: Date) { start(at: .coherent(date)) }
    func pause(at date: Date) { pause(at: .coherent(date)) }
    func resume(at date: Date) { resume(at: .coherent(date)) }
    func align(at date: Date) { align(at: .coherent(date)) }
    func pausedSeconds(asOf date: Date) -> TimeInterval { pausedSeconds(asOf: .coherent(date)) }
    func currentPauseSeconds(asOf date: Date) -> TimeInterval {
        currentPauseSeconds(asOf: .coherent(date))
    }
    func elapsedSeconds(asOf date: Date) -> TimeInterval { elapsedSeconds(asOf: .coherent(date)) }
    @discardableResult
    func end(at date: Date, destinationName: String? = nil) -> Ride {
        end(at: .coherent(date), destinationName: destinationName)
    }
    func checkpoint(at date: Date, destinationName: String? = nil) -> Ride {
        checkpoint(at: .coherent(date), destinationName: destinationName)
    }
}

@MainActor
extension RideSessionCoordinator {
    func refreshElapsed(now date: Date) { refreshElapsed(now: .coherent(date)) }
    func pushActivityUpdate(now date: Date) { pushActivityUpdate(now: .coherent(date)) }
    func pause(at date: Date) { pause(at: .coherent(date)) }
    func resume(at date: Date) { resume(at: .coherent(date)) }
}
