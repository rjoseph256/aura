import Foundation
import AuraCore

public struct TurnCardState: Equatable, Sendable {
    public var primaryText: String     // maneuver instruction, e.g. "Right onto Penn Ave"
    public var distanceText: String    // distance to the maneuver, e.g. "390 ft" or "0.2 mi"
    public var isExpanded: Bool         // true when the maneuver is near → the card grows

    public init(primaryText: String, distanceText: String, isExpanded: Bool) {
        self.primaryText = primaryText
        self.distanceText = distanceText
        self.isExpanded = isExpanded
    }

    /// Shown before the first progress update arrives.
    public static let starting = TurnCardState(
        primaryText: "Starting navigation…", distanceText: "–", isExpanded: false)

    /// Shown when guidance can't be established — recording and the map still work,
    /// the turn card just degrades to a generic prompt.
    public static let unavailable = TurnCardState(
        primaryText: "Navigate to destination", distanceText: "–", isExpanded: false)
}

/// Adaptive turn-card display logic (the "option C" behavior). Pure + Mapbox-independent.
public enum TurnCardPresenter {
    public static func state(distanceToManeuverMeters: Double,
                             instruction: String,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        let feet = UnitConverter.feet(fromMeters: distanceToManeuverMeters)
        let distanceText: String
        if feet >= 1000 {
            distanceText = String(format: "%.1f mi", UnitConverter.miles(fromMeters: distanceToManeuverMeters))
        } else {
            let rounded = Int((feet / 10).rounded()) * 10
            distanceText = "\(rounded) ft"
        }
        return TurnCardState(primaryText: instruction,
                             distanceText: distanceText,
                             isExpanded: distanceToManeuverMeters <= expandWithinMeters)
    }

    /// Convenience overload mapping a pure `GuidanceUpdate` straight to card state.
    public static func state(for update: GuidanceUpdate,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        state(distanceToManeuverMeters: update.distanceToManeuverMeters,
              instruction: update.instruction,
              expandWithinMeters: expandWithinMeters)
    }
}
