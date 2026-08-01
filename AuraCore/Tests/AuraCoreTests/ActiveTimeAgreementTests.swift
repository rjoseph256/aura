import Testing
import Foundation
@testable import AuraCore

/// The Live Activity's rendered clock, and the finished ride's, must report the same active time
/// for the same inputs. Parent spec D5 rests on it: the rider sees the number they watched when
/// they pressed End.
///
/// **What this catches and what it does not.** After the rewire both sides of these expectations
/// call the same function, so this cannot fail for a change to the *definition* of active time —
/// `RideActiveClockTests` pins that against frozen literals. What it does catch is a re-inline of
/// `make`'s running branch that disagrees *numerically* with the primitive — notably one that
/// drops the primitive's clamp and hands `Text(_, style: .timer)` a future anchor, which makes
/// the Lock Screen clock count DOWN instead of up. It does NOT catch every re-inline: the
/// expression revision 1 of this plan left behind,
/// `min(startedAt.addingTimeInterval(pausedSeconds), now)`, is bit-identical to the primitive for
/// every input (verified over 7,200 ticks, including the clamped regime), so an algebraically
/// equivalent re-inline is still GREEN here. `scripts/check-single-active-definition.sh` is what
/// catches that class — it fails on the re-derivation itself, not on its output.
///
/// The HUD's own clock (`RideSessionCoordinator.refreshElapsed`) is the third caller and is not
/// tested here: its `startedAt` is private and stamped from `Date()`, so a test cannot supply both
/// sides. The guard script is what holds it, and `RideSessionCoordinatorPauseTests` its behavior.
@Suite("Active time agreement")
struct ActiveTimeAgreementTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let pausedCases: [TimeInterval] = [0, 240, 5000]

    // The paused branch is no longer expressible here: `make` copies a value the recorder froze at
    // the tap instead of calling the primitive, so there is nothing to compare it against without
    // a `RideRecorder`. Its agreement is pinned by
    // `RideClockStepTests.theFrozenActiveTimeMatchesThePrimitive`, in `AuraKitTests`.

    @Test("The running anchor is `now` less the active seconds — this is the branch that renders")
    func runningAnchorMatchesPrimitive() {
        // `Text(anchor, style: .timer)` counts up from the anchor, so the rendered number is
        // `now - anchor`. That, not the discarded `activeSeconds` local, is what the rider sees.
        let now = start.addingTimeInterval(900)
        for paused in pausedCases {
            let clock = RideActiveClock.make(startedAt: start, pausedSeconds: paused,
                                             openStop: nil, now: now)
            guard case .running(let anchor) = clock else {
                Issue.record("expected a running clock for paused: \(paused)")
                continue
            }
            #expect(now.timeIntervalSince(anchor)
                    == RideDuration.activeSeconds(
                        elapsed: .betweenStamps(startedAt: start, endedAt: now),
                        pausedSeconds: paused))
        }
    }

    @Test("A finished ride's active time matches the primitive at its end instant")
    func finishedRideMatchesPrimitive() throws {
        let end = start.addingTimeInterval(2880)
        let d = try #require(RideDuration(startedAt: start, endedAt: end,
                                          checkpointedAt: nil, pausedSeconds: 600))
        #expect(d.activeSeconds == RideDuration.activeSeconds(
            elapsed: .betweenStamps(startedAt: start, endedAt: end),
            pausedSeconds: 600))
    }
}
