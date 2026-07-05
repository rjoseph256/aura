import Foundation

/// A one-shot "a gem surfaced" haptic. App-target impl uses UIKit generators; tests spy on it.
@MainActor
public protocol GemHapticPlaying {
    func playGemSurfaced()
}
