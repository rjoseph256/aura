import AuraCore

/// Plays a ride haptic. The app conforms a UIKit-feedback-generator-backed type; the
/// package never imports UIKit, so it builds on the macOS CI host. Guidance-scoped —
/// driven by `GuidanceViewModel`, not `RideSessionCoordinator` — so it lives here in
/// `Guidance/` rather than with the coordinator seams in `RideSessionSeams.swift`.
@MainActor
public protocol HapticPlaying: AnyObject {
    /// Warm the generators to cut first-tap latency. Called once when guidance starts.
    func prepare()
    /// Play the cue. Fire-and-forget; a no-op when haptics are unavailable.
    func play(_ cue: RideHapticCue)
}
