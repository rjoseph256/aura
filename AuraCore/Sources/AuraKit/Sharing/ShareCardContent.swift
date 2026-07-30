import Foundation
import AuraCore

/// Everything the shareable ride card renders, resolved to display-ready primitives in the
/// pure layer so the branching (units, has-elevation, has-route, has-destination) is unit
/// tested without the app target. The SwiftUI card view is a dumb projection of this.
public struct ShareCardContent: Equatable, Sendable {
    public let distanceValue: String
    public let distanceUnit: String
    public let movingTime: String
    public let climbedValue: String
    public let climbedUnit: String
    public let dateText: String
    public let destinationName: String?
    /// True when Aura never recorded this ride's end (`Ride.isUnfinished`).
    ///
    /// The card is the one surface other people see. Without this the rider reads "anything
    /// after 2:14 PM wasn't saved", taps Share, and posts a truncated distance as though it
    /// were the whole ride (PO decision, 2026-07-29).
    ///
    /// **The same predicate the summary sheet gates on, not the narrower marker test.** Share is
    /// tapped *from* that sheet, so a row the sheet badges and the card does not is a rider
    /// posting a truncated ride they were just warned about — which a legacy PR #90 dev-build row
    /// (nil `endedAt`, no marker) hits exactly.
    public let isUnfinished: Bool
    /// The route to stroke, one run per ride segment. Empty when there is nothing to draw.
    /// Segmented rather than flattened: a share card that connected two segments would draw
    /// a straight line across the café stop.
    public let routeSegments: [[Coordinate]]
    public let elevationSamples: [Double]

    public init(ride: Ride, units: DistanceUnits,
                locale: Locale = .current, timeZone: TimeZone = .current) {
        let fmt = RideStatsFormatter(units: units)
        let stats = ride.stats ?? .zero
        distanceValue = fmt.distanceValue(stats.distanceMeters)
        distanceUnit = fmt.distanceUnit
        movingTime = fmt.minutes(stats.movingTimeSeconds)
        climbedValue = fmt.elevationValue(stats.elevationGainMeters)
        climbedUnit = fmt.elevationUnit

        var dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        dateStyle.timeZone = timeZone
        dateText = ride.startedAt.formatted(dateStyle)

        let trimmed = ride.destinationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        destinationName = (trimmed?.isEmpty == false) ? trimmed : nil

        isUnfinished = ride.isUnfinished

        routeSegments = ride.segments.map { $0.points.map(\.coordinate) }.filter { $0.count > 1 }

        // The card draws the silhouette only for a real climb, gated on cumulative gain
        // via the shared classifier so the card and the ride summary never disagree.
        if case .profile(let samples) = ElevationProfile.classify(
            track: ride.flattenedPoints, gainMeters: stats.elevationGainMeters) {
            elevationSamples = samples
        } else {
            elevationSamples = []
        }
    }
}
