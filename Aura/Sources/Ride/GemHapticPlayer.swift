import UIKit
import AuraKit

/// UIKit-backed `GemHapticPlaying` — a soft impact when a gem surfaces.
@MainActor
final class GemHapticPlayer: GemHapticPlaying {
    private let generator = UIImpactFeedbackGenerator(style: .soft)
    func playGemSurfaced() { generator.impactOccurred() }
}
