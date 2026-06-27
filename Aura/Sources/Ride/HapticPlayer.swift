import UIKit
import os
import AuraCore
import AuraKit

/// Plays turn-approach and arrival haptics during a navigated ride — the app-target
/// shell behind AuraKit's `HapticPlaying` seam, the analog of `WorkoutWriter` and
/// `RideLiveActivityController`. UIKit feedback generators rather than Core Haptics:
/// two simple cues need no `CHHapticEngine` lifecycle, and the generators honor the
/// system "System Haptics" setting and no-op on hardware without a Taptic Engine, so
/// no explicit capability gate is needed.
@MainActor
final class HapticPlayer: HapticPlaying {
    static let shared = HapticPlayer()

    /// A firm, crisp tap for an imminent turn.
    private let approachGenerator = UIImpactFeedbackGenerator(style: .rigid)
    /// The distinct success rhythm for reaching the destination.
    private let arrivalGenerator = UINotificationFeedbackGenerator()
    private let log = Logger(subsystem: "app.aura.ios", category: "haptics")

    private init() {}

    func prepare() {
        approachGenerator.prepare()
        arrivalGenerator.prepare()
    }

    func play(_ cue: RideHapticCue) {
        switch cue {
        case .approach:
            approachGenerator.impactOccurred()
            approachGenerator.prepare()   // re-prime for the next turn
        case .arrival:
            arrivalGenerator.notificationOccurred(.success)
        }
        log.info("Turn haptic fired: \(String(describing: cue), privacy: .public)")
    }
}
