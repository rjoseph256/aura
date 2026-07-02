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
    public let routeCoordinates: [Coordinate]
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

        routeCoordinates = ride.track.count > 1 ? ride.track.map(\.coordinate) : []

        let elevations = ride.track.compactMap(\.elevation)
        elevationSamples = elevations.count > 1 ? elevations : []
    }
}
