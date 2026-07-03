/// Decides when to fire turn-approach and arrival haptics, edge-triggered so each
/// fires exactly once per maneuver. Pure and deterministic: no Foundation type
/// beyond `Double`/`String`, no CoreLocation, no UIKit — it builds and tests on the
/// macOS CI host. `GuidanceViewModel` owns one of these and feeds it each event.
///
/// "Current maneuver" is keyed on the guidance instruction string (the stream
/// carries no maneuver id). Once an approach fires for a key, that key never fires
/// again, so the buzz is once-per-maneuver no matter how the (non-monotonic) maneuver
/// distance moves afterward — a stop or a position re-snap that pushes the distance
/// back up cannot re-fire it. A new key (a new maneuver, or the end-of-route flip
/// from the upcoming step to the current step) is eligible to fire again.
public struct TurnHapticEngine {
    private let approachWithinMeters: Double
    private var firedApproachKey: String?
    private var arrivalFired = false

    /// - Parameter approachWithinMeters: the maneuver distance at/under which the
    ///   approach fires. Defaults to 150, matching `TurnCardPresenter.expandWithinMeters`
    ///   so the buzz coincides with the turn card expanding to mint.
    public init(approachWithinMeters: Double = 150) {
        self.approachWithinMeters = approachWithinMeters
    }

    /// Feed one progress update. Returns `.approach` on the first update for a
    /// not-yet-fired key that is within the threshold; `nil` otherwise.
    public mutating func onProgress(distanceToManeuverMeters: Double,
                                    maneuverKey: String) -> RideHapticCue? {
        guard maneuverKey != firedApproachKey else { return nil }  // already buzzed this turn
        guard distanceToManeuverMeters <= approachWithinMeters else { return nil }
        firedApproachKey = maneuverKey
        return .approach
    }

    /// Feed arrival. Returns `.arrival` once, ever.
    public mutating func onArrival() -> RideHapticCue? {
        guard !arrivalFired else { return nil }
        arrivalFired = true
        return .arrival
    }
}
