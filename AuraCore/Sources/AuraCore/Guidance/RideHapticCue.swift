/// A haptic cue to play during a navigated ride. Pure — names the moment, never the
/// hardware. The app-target player maps each case to a feedback generator.
public enum RideHapticCue: Equatable, Sendable {
    /// A turn is imminent (the maneuver distance reached the approach threshold).
    case approach
    /// The rider reached the destination.
    case arrival
}
