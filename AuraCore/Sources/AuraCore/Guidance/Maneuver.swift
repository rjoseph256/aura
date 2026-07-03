/// A structured turn maneuver, engine-independent (no SDK type). Mapbox's maneuver model
/// maps 1:1 onto these cases in `MapboxGuidanceSession`.
public struct Maneuver: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case turn, fork, roundabout, rotary, merge, onRamp, offRamp
        case depart, arrive, continueOn, endOfRoad, uTurn, other
    }
    public enum Modifier: String, Equatable, Sendable, CaseIterable {
        case left, right, slightLeft, slightRight, sharpLeft, sharpRight, straight, uTurn, none
    }
    public var kind: Kind
    public var modifier: Modifier
    /// Optional short label, e.g. a roundabout exit ordinal ("3") when the engine supplies it.
    public var label: String?
    public init(kind: Kind, modifier: Modifier, label: String? = nil) {
        self.kind = kind; self.modifier = modifier; self.label = label
    }
}
