import AuraCore

/// Everything the ride summary's elevation band renders, resolved to display-ready
/// primitives in the pure layer. The SwiftUI band is a dumb `switch` over `kind`.
/// The climb callout number and the profile/flat decision are both cumulative gain,
/// so the label and the number can never disagree on screen.
public struct ElevationProfileContent: Equatable, Sendable {
    public let kind: ElevationProfile.Kind
    public let climbedValue: String
    public let climbedUnit: String
    public let climbedUnitSpoken: String
    /// True when the formatted climb reads zero — the flat line drops the climb clause.
    public let isTrivialClimb: Bool

    public init(ride: Ride, units: DistanceUnits) {
        let stats = ride.stats ?? .zero
        let fmt = RideStatsFormatter(units: units)
        kind = ElevationProfile.classify(track: ride.track,
                                         gainMeters: stats.elevationGainMeters)
        climbedValue = fmt.elevationValue(stats.elevationGainMeters)
        climbedUnit = fmt.elevationUnit
        climbedUnitSpoken = fmt.elevationUnitSpoken
        isTrivialClimb = climbedValue == "0"   // depends on RideStatsFormatter's %.0f contract
    }

    /// The single combined VoiceOver label for the band, per state. `nil` for
    /// `.unavailable` (the band renders nothing). Lives here (pure) so the exact spoken
    /// strings are unit-tested, not trapped inside the SwiftUI view.
    public var accessibilityLabel: String? {
        switch kind {
        case .profile:
            return "Elevation. Climbed \(climbedValue) \(climbedUnitSpoken)."
        case .flat:
            return isTrivialClimb
                ? "Mostly flat."
                : "Mostly flat. Climbed \(climbedValue) \(climbedUnitSpoken)."
        case .unavailable:
            return nil
        }
    }
}
