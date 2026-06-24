import Foundation
import AuraCore

/// Centralizes the unit-aware number formatting the ride screens display, so
/// `SpeedRail`, `RideSummaryView`, and `HistoryView` don't each reimplement the
/// conversions (the source of the previously-triplicated, untested formatting logic).
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

    public func minutes(_ seconds: Double) -> String { "\(Int(seconds / 60)) min" }

    /// "m:ss" elapsed clock, e.g. 125 -> "2:05".
    public static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
