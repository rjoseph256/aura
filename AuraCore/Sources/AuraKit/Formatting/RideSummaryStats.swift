import Foundation
import AuraCore

/// The ride summary's supporting stat row, resolved to display-ready strings in the pure layer so
/// the branching is unit tested without the app target. `RideSummaryView`'s row is a projection
/// of this.
///
/// **Takes scalars, never a `Ride`.** The view builds this during `body`, and this project's rule
/// (see `RideSummaryView.swift:52`) is that nothing track-derived is read there. A type holding a
/// whole ride invites the next author to add one `flattenedPoints`-derived field and hand the
/// summary an O(n) walk on every body evaluation — which is exactly why `ShareCardContent`, the
/// other type of this shape, is built in a `.task` instead.
public struct RideSummaryStats: Equatable, Sendable {
    /// "38 min", or "—" when the ride's end instant cannot be trusted (see `RideDuration.init`).
    public let activeValue: String
    /// "48 min elapsed", or nil when it would merely repeat `activeValue`.
    public let elapsedCaption: String?
    /// One explicit spoken label, rather than `children: .combine` over a value, a label and a
    /// caption, whose composed order is a layout detail.
    public let activeAccessibilityLabel: String
    public let movingValue: String
    public let topSpeedValue: String
    public let topSpeedLabel: String

    public init(duration: RideDuration?, movingTimeSeconds: Double,
                maxSpeedMetersPerSecond: Double, units: DistanceUnits) {
        let fmt = RideStatsFormatter(units: units)
        movingValue = fmt.minutes(movingTimeSeconds)
        topSpeedValue = fmt.speedValue(maxSpeedMetersPerSecond, decimals: 1)
        // Composed from the formatter's own unit rather than a second `units == .metric` ternary,
        // so "km/h" has one source.
        topSpeedLabel = "\(fmt.speedUnit) top"

        guard let duration else {
            activeValue = "—"
            elapsedCaption = nil
            activeAccessibilityLabel = "Active time, unavailable."
            return
        }

        let active = fmt.minutes(duration.activeSeconds)
        let elapsed = fmt.minutes(duration.elapsedSeconds)
        activeValue = active
        // Compared as RENDERED STRINGS, not on `pausedSeconds > 0`: `minutes` truncates, so a
        // pause that does not cross a minute boundary also renders the same number twice. On an
        // unpaused ride — the majority path, and every ride recorded before pause existed — the
        // two are equal by definition, and stacking a number under itself tells the rider nothing.
        //
        // The caption's absence is therefore ambiguous in a third way worth knowing about: until
        // ROH-108 promotes the CloudKit PRODUCTION schema, `CD_pausedSeconds` does not mirror, so
        // a ride paused on one phone shows the pair on that phone and a lone active reading on a
        // second one. There is no in-app signal for that; the release gate is the fix.
        elapsedCaption = (elapsed == active) ? nil : "\(elapsed) elapsed"
        activeAccessibilityLabel = elapsedCaption == nil
            ? "Active time, \(active)."
            : "Active time, \(active). Elapsed, \(elapsed)."
    }
}
