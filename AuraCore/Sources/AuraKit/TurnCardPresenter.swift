import Foundation
import AuraCore

public struct TurnCardState: Equatable, Sendable {
    public var primaryText: String     // maneuver instruction, e.g. "Right onto Penn Ave"
    public var distanceText: String    // distance to the maneuver, e.g. "390 ft" or "120 m"
    public var isExpanded: Bool         // true when the maneuver is near → the card grows
    /// One composed VoiceOver read for the whole card, e.g. "In 390 feet, Right onto Penn Ave".
    public var accessibilityLabel: String

    public init(primaryText: String, distanceText: String, isExpanded: Bool, accessibilityLabel: String) {
        self.primaryText = primaryText
        self.distanceText = distanceText
        self.isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel
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

/// Adaptive turn-card display logic (the "option C" behavior). Pure + Mapbox-independent.
/// Unit-aware: the visible distance and the spoken label both honor the rider's units.
public enum TurnCardPresenter {
    public static func state(distanceToManeuverMeters: Double,
                             instruction: String,
                             units: DistanceUnits,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        let formatter = RideStatsFormatter(units: units)
        return TurnCardState(
            primaryText: instruction,
            distanceText: formatter.maneuverDistance(distanceToManeuverMeters),
            isExpanded: distanceToManeuverMeters <= expandWithinMeters,
            accessibilityLabel: "In \(formatter.maneuverDistanceSpoken(distanceToManeuverMeters)), \(instruction)")
    }

    /// Convenience overload mapping a pure `GuidanceUpdate` straight to card state.
    public static func state(for update: GuidanceUpdate,
                             units: DistanceUnits,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        state(distanceToManeuverMeters: update.distanceToManeuverMeters,
              instruction: update.instruction,
              units: units,
              expandWithinMeters: expandWithinMeters)
    }
}
