import Foundation
import AuraCore

public struct TurnCardState: Equatable, Sendable {
    public var primaryText: String     // maneuver instruction, e.g. "Right onto Penn Ave"
    public var distanceText: String    // distance to the maneuver, e.g. "390 ft" or "120 m"
    public var isExpanded: Bool         // true when the maneuver is near → the card grows
    /// One composed VoiceOver read for the whole card, e.g. "In 390 feet, Right onto Penn Ave".
    public var accessibilityLabel: String
    /// The structured upcoming maneuver, driving the directional arrow. nil → generic arrow.
    public var maneuver: Maneuver?

    public init(primaryText: String, distanceText: String, isExpanded: Bool,
                accessibilityLabel: String, maneuver: Maneuver? = nil) {
        self.primaryText = primaryText
        self.distanceText = distanceText
        self.isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel
        self.maneuver = maneuver
    }

    /// Shown before the first progress update arrives.
    public static let starting = TurnCardState(
        primaryText: "Starting navigation…", distanceText: "–", isExpanded: false,
        accessibilityLabel: "Starting navigation.")

    /// Shown when guidance can't be established — recording and the map still work,
    /// the turn card just degrades to a generic prompt.
    public static let unavailable = TurnCardState(
        primaryText: "Navigate to destination", distanceText: "–", isExpanded: false,
        accessibilityLabel: "Navigate to destination.")
}

/// The maneuver after the upcoming one, driving the "then …" preview chip. Carries a
/// required non-empty label (the next street) — the chip only renders when one exists.
public struct NextManeuver: Equatable, Sendable {
    public var maneuver: Maneuver
    public var label: String
    public init(maneuver: Maneuver, label: String) { self.maneuver = maneuver; self.label = label }
}

/// Adaptive turn-card display logic (the "option C" behavior). Pure + Mapbox-independent.
/// Unit-aware: the visible distance and the spoken label both honor the rider's units.
public enum TurnCardPresenter {
    public static func state(distanceToManeuverMeters: Double,
                             instruction: String,
                             units: DistanceUnits,
                             maneuver: Maneuver? = nil,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        let formatter = RideStatsFormatter(units: units)
        return TurnCardState(
            primaryText: instruction,
            distanceText: formatter.maneuverDistance(distanceToManeuverMeters),
            isExpanded: distanceToManeuverMeters <= expandWithinMeters,
            accessibilityLabel: "In \(formatter.maneuverDistanceSpoken(distanceToManeuverMeters)), \(instruction)",
            maneuver: maneuver)
    }

    /// Convenience overload mapping a pure `GuidanceUpdate` straight to card state. Carries the
    /// maneuver through and, when a labeled next maneuver exists, appends a ", then <street>"
    /// clause to the composed VoiceOver label (extending the one-composed-element contract).
    public static func state(for update: GuidanceUpdate,
                             units: DistanceUnits,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        var s = state(distanceToManeuverMeters: update.distanceToManeuverMeters,
                      instruction: update.instruction,
                      units: units,
                      maneuver: update.maneuver,
                      expandWithinMeters: expandWithinMeters)
        if let next = nextManeuver(for: update) {
            s.accessibilityLabel += ", then \(next.label)"
        }
        return s
    }

    /// The next-maneuver preview, or nil when the engine supplies no next maneuver or no
    /// label for it (the then-chip needs a street name to render).
    public static func nextManeuver(for update: GuidanceUpdate) -> NextManeuver? {
        guard let m = update.nextManeuver, let label = m.label, !label.isEmpty else { return nil }
        return NextManeuver(maneuver: m, label: label)
    }
}
