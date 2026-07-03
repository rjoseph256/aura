import AuraCore

/// Maps a structured `Maneuver` to an SF Symbol name. Pure `String` output — no UI import —
/// so it is the single source of truth for the turn card, the then-chip, and the Live Activity.
public enum ManeuverIcon {
    public static let genericSymbol = "arrow.turn.up.right"

    public static func symbol(for maneuver: Maneuver?) -> String {
        guard let m = maneuver else { return genericSymbol }
        switch m.kind {
        case .turn, .endOfRoad:
            return directional(m.modifier)
        // Forks and off-ramps *diverge*; merges and on-ramps *join*. When the SDK supplies a
        // side, that sided arrow wins (it's the more precise cue); only the sideless
        // .straight/.none case falls back to the kind-specific glyph instead of a plain up-arrow.
        case .fork, .offRamp:
            return directional(m.modifier, fallback: "arrow.triangle.branch")
        case .merge, .onRamp:
            return directional(m.modifier, fallback: "arrow.merge")
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

    /// A sided arrow for left/right variants and the U-turn glyph for a U-turn. The sideless
    /// cases (.straight/.none) return `fallback`, which the caller uses to keep a maneuver
    /// indicative when the engine gives a kind (fork/merge/ramp) but no direction.
    private static func directional(_ modifier: Maneuver.Modifier, fallback: String = "arrow.up") -> String {
        switch modifier {
        case .left, .slightLeft, .sharpLeft: return "arrow.turn.up.left"
        case .right, .slightRight, .sharpRight: return "arrow.turn.up.right"
        case .straight, .none: return fallback
        case .uTurn: return "arrow.uturn.down"
        }
    }
}
