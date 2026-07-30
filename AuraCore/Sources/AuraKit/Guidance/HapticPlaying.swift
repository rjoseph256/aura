import AuraCore

/// Plays a ride haptic. The app conforms a UIKit-feedback-generator-backed type; the
/// package never imports UIKit, so it builds on the macOS CI host.
/// Driven by `GuidanceViewModel` for turn cues and by `RideSessionCoordinator` for the pause
/// and resume confirmations (ROH-101). It stays here in `Guidance/` for continuity with the
/// cue type rather than because only guidance uses it.
@MainActor
public protocol HapticPlaying: AnyObject {
    /// Warm the generators to cut first-tap latency. Called once when guidance starts.
    func prepare()
    /// Play the cue. Fire-and-forget; a no-op when haptics are unavailable.
    func play(_ cue: RideHapticCue)
}
