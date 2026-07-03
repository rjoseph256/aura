import AuraCore

/// Maps a structured `Maneuver` to an SF Symbol name. Pure `String` output — no UI import —
/// so it is the single source of truth for the turn card, the then-chip, and the Live Activity.
public enum ManeuverIcon {
    public static let genericSymbol = "arrow.turn.up.right"

    public static func symbol(for maneuver: Maneuver?) -> String {
        guard let m = maneuver else { return genericSymbol }
        switch m.kind {
        case .turn, .endOfRoad, .fork, .merge, .onRamp, .offRamp:
            return directional(m.modifier)
        case .roundabout, .rotary:
            return "arrow.clockwise.circle"
        case .uTurn:
            return "arrow.uturn.down"
        case .continueOn:
            return "arrow.up"
        case .depart:
            return "location.fill"
        case .arrive:
            return "flag.checkered"
        case .other:
            return genericSymbol
        }
    }

    private static func directional(_ modifier: Maneuver.Modifier) -> String {
        switch modifier {
        case .left, .slightLeft, .sharpLeft: return "arrow.turn.up.left"
        case .right, .slightRight, .sharpRight: return "arrow.turn.up.right"
        case .straight, .none: return "arrow.up"
        case .uTurn: return "arrow.uturn.down"
        }
    }
}
