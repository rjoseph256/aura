import UIKit
import os
import AuraCore
import AuraKit

/// Plays turn-approach and arrival haptics during a navigated ride, and the pause/resume
/// confirmations on either HUD — the app-target shell behind AuraKit's `HapticPlaying` seam,
/// the analog of `WorkoutWriter` and `RideLiveActivityController`. UIKit feedback generators
/// rather than Core Haptics: these short cues need no `CHHapticEngine` lifecycle, and the
/// generators honor the system "System Haptics" setting and no-op on hardware without a
/// Taptic Engine, so no explicit capability gate is needed.
@MainActor
final class HapticPlayer: HapticPlaying {
    static let shared = HapticPlayer()

    /// The firm, crisp `.rigid` tap. Two cues use it: the single beat for an imminent turn, and
    /// both beats of `.resume`, which wants the same crispness and would otherwise need a
    /// third generator with an identical style. Named for its first use; `play(_:)` is the
    /// authority on what it fires for.
    private let approachGenerator = UIImpactFeedbackGenerator(style: .rigid)
    /// The distinct success rhythm for reaching the destination.
    private let arrivalGenerator = UINotificationFeedbackGenerator()
    /// A softer, settling tap for a pause. Distinct in character from `.resume`, which is a
    /// rising double, so the two are told apart with gloves on and the phone in a bar mount.
    private let pauseGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let log = Logger(subsystem: "app.aura.ios", category: "haptics")

    private init() {}

    func prepare() {
        approachGenerator.prepare()
        arrivalGenerator.prepare()
        pauseGenerator.prepare()
    }

    func play(_ cue: RideHapticCue) {
        switch cue {
        case .approach:
            approachGenerator.impactOccurred()
            approachGenerator.prepare()   // re-prime for the next turn
        case .arrival:
            arrivalGenerator.notificationOccurred(.success)
        case .pause:
            pauseGenerator.impactOccurred()
            pauseGenerator.prepare()
        case .resume:
            // A rising double against the pause's single soft tap. `.rigid` for the crispness
            // that survives a bar mount and a glove.
            approachGenerator.impactOccurred(intensity: 0.7)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [approachGenerator] in
                approachGenerator.impactOccurred(intensity: 1.0)
                approachGenerator.prepare()
            }
        }
        log.info("Ride haptic fired: \(String(describing: cue), privacy: .public)")
    }
}
