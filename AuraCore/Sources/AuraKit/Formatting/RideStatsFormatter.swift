import Foundation
import AuraCore

/// Centralizes the unit-aware number formatting the ride screens display, so the cockpit
/// panels, `RideSummaryView`, and `HistoryView` don't each reimplement the conversions
/// (the source of the previously-triplicated, untested formatting logic).
///
/// Returns formatted value strings plus canonical short units; views keep their own
/// label voice ("mi" vs "miles" vs "MI") by composing around `*Unit`.
public struct RideStatsFormatter {
    public let units: DistanceUnits
    public init(units: DistanceUnits) { self.units = units }

    private var metric: Bool { units == .metric }

    public func distanceValue(_ meters: Double) -> String {
        let v = metric ? UnitConverter.km(fromMeters: meters)
                       : UnitConverter.miles(fromMeters: meters)
        return String(format: "%.1f", v)
    }
    public var distanceUnit: String { metric ? "km" : "mi" }

    public func elevationValue(_ meters: Double) -> String {
        let v = metric ? meters : UnitConverter.feet(fromMeters: meters)
        return String(format: "%.0f", v)
    }
    public var elevationUnit: String { metric ? "m" : "ft" }

    public func speedValue(_ metersPerSecond: Double, decimals: Int = 0) -> String {
        let v = metric ? UnitConverter.kmh(fromMetersPerSecond: metersPerSecond)
                       : UnitConverter.mph(fromMetersPerSecond: metersPerSecond)
        return String(format: "%.\(decimals)f", v)
    }
    public var speedUnit: String { metric ? "km/h" : "mph" }
    public var speedUnitSpoken: String { metric ? "kilometers per hour" : "miles per hour" }
    public var distanceUnitSpoken: String { metric ? "kilometers" : "miles" }
    public var elevationUnitSpoken: String { metric ? "meters" : "feet" }

    public func minutes(_ seconds: Double) -> String { "\(Int(seconds / 60)) min" }

    private struct ManeuverParts { let value: String; let short: String; let spoken: String }

    /// The maneuver distance split into its formatted value and both unit forms, so the
    /// short glyph string and the spoken string share one rounding path and never drift.
    private func maneuverParts(_ meters: Double) -> ManeuverParts {
        if metric {
            if meters >= 1000 {
                return ManeuverParts(value: String(format: "%.1f", UnitConverter.km(fromMeters: meters)), short: "km", spoken: "kilometers")
            }
            let rounded = Int((meters / 10).rounded()) * 10
            return ManeuverParts(value: "\(rounded)", short: "m", spoken: "meters")
        } else {
            let feet = UnitConverter.feet(fromMeters: meters)
            if feet >= 1000 {
                return ManeuverParts(value: String(format: "%.1f", UnitConverter.miles(fromMeters: meters)), short: "mi", spoken: "miles")
            }
            let rounded = Int((feet / 10).rounded()) * 10
            return ManeuverParts(value: "\(rounded)", short: "ft", spoken: "feet")
        }
    }

    /// Short distance-to-maneuver string, e.g. "390 ft" / "0.2 mi" / "120 m" / "0.3 km".
    /// Output is unchanged from the previous implementation (the Live Activity and Lock
    /// Screen widgets depend on it).
    public func maneuverDistance(_ meters: Double) -> String {
        let p = maneuverParts(meters)
        return "\(p.value) \(p.short)"
    }

    /// Spoken distance-to-maneuver, e.g. "390 feet" / "0.2 miles" / "120 meters" /
    /// "0.3 kilometers". Same value and rounding as `maneuverDistance`, spelled units.
    public func maneuverDistanceSpoken(_ meters: Double) -> String {
        let p = maneuverParts(meters)
        return "\(p.value) \(p.spoken)"
    }

    /// "m:ss" elapsed clock, e.g. 125 -> "2:05".
    public static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
