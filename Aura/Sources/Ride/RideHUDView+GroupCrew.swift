import SwiftUI
import AuraCore
import AuraKit

/// The crew exit for a destination-free group ride riding the Explore cockpit (ROH-114).
///
/// This is a **named subset** of spec D5.1, not all of it: it exists because without it the HUD
/// had no path that leaves a crew at all. Every exit — the End button, the chevron, the edge
/// swipe — reached `coordinator.finish()` or `discard()` and destroyed the session without ever
/// calling `endRide`/`leaveRide`. The consequences were silent on every phone: the ride stayed
/// `active` server-side with a live join code and no `ended_at` until it expired 36 hours later,
/// guests watched the host age to `.dropped` without ever learning the ride was over, and host
/// promotion never fired — because that is driven by `leave_ride`, which nobody had called — so
/// no guest could end it either.
///
/// D5.1's full rules (every exit through a confirmation regardless of the discard floor, and the
/// wording that goes with them) remain in plan 3.
///
/// Deliberately mirrors `NavigateHUDView+GroupCrew` rather than inventing a second vocabulary
/// for the same decision. Nothing here touches a `private` member of `RideHUDView`, so the
/// extraction needed no widening of access — it exists because the main file is at SwiftLint's
/// 500-line ceiling.
extension RideHUDView {
    /// True only when this HUD is hosting a live group ride AND the rider is its host.
    var isGroupHost: Bool { groupSession?.isHost == true }

    var groupEndTitle: String {
        isGroupHost ? "End the group ride for everyone?" : "Leave the crew or end your ride?"
    }

    /// Host: dissolve the crew for everyone — `end()` calls the backend, emitting the host-left
    /// signal that dissolves every guest's crew chrome — then finish this rider's own ride, but
    /// only once that has actually landed server-side. A transient failure sets
    /// `groupSession.endFailed` instead of faking success; the rider stays on this HUD.
    func endGroupRideAsHost() {
        Task {
            await groupSession?.end()
            await finishOwnRideIfEnded()
        }
    }

    /// Drop out of the crew and keep riding solo. The ride itself is not ended and this rider's
    /// recording continues, so a transient failure is tolerable here in a way it is not above:
    /// this path never finishes the ride, so the rider keeps riding either way.
    func leaveCrewKeepRiding() {
        Task { await groupSession?.leave() }
    }

    /// Member: leave the crew first, then finish — same ordering as the host path, so the ride
    /// is never finished locally while the rider is still a member server-side.
    func endRideAsMember() {
        Task {
            await groupSession?.endAsMember()
            await finishOwnRideIfEnded()
        }
    }

    /// Finish only once the crew side has landed. The one-runloop hop comes with the pattern
    /// from navigate: `phase` has just been written, and the view needs to observe it before the
    /// HUD is torn out from under the dialog that triggered this.
    private func finishOwnRideIfEnded() async {
        guard groupSession?.phase == .ended else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        finishOrDiscardOwnRide()
    }
}
