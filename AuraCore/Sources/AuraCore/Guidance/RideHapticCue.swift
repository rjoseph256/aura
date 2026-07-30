/// A haptic cue played during a ride. Turn cues fire only while navigating; the pause and
/// resume confirmations fire on any ride, including a free ride (ROH-101). Pure — names the
/// moment, never the hardware. The app-target player maps each case to a feedback generator.
public enum RideHapticCue: Equatable, Sendable {
    /// A turn is imminent (the maneuver distance reached the approach threshold).
    case approach
    /// The rider reached the destination.
    case arrival
    /// The rider paused the ride. A confirmation of their own tap, not a guidance cue, so it
    /// is not gated on the turn-haptics setting — the same treatment as the mark-spot haptic.
    case pause
    /// The rider resumed. Deliberately distinct from `.pause` so the two are told apart with
    /// gloves on and the phone in a bar mount.
    case resume
}
