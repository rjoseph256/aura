import Foundation
import AuraCore

/// The formatted instruments the Explore (free-ride) cockpit renders beside the speed
/// hero: distance ridden, elapsed time, and elevation climbed, plus one composed VoiceOver
/// read. Pure and unit-aware, mirroring the `CruisingState`/`CruisingPresenter` pattern the
/// navigate cockpit uses, so the composition is unit-tested in CI instead of living in the
/// SwiftUI view. The spoken label delegates to `SpeedRailVoice.statsLabel`, so the free-ride
/// read stays identical to the rail this cockpit replaces.
public struct ExploreInstrumentState: Equatable, Sendable {
    /// Distance ridden with its short unit, e.g. "5.0 mi".
    public let distance: String
    /// Elapsed clock, e.g. "24:00".
    public let time: String
    /// Elevation climbed with its short unit, e.g. "340 ft".
    public let elevationGain: String
    /// One composed VoiceOver read for the whole instrument cluster, e.g.
    /// "Distance 5.0 miles, time 24 minutes, elevation gain 340 feet".
    public let accessibilityLabel: String

    public init(stats: RideStats, elapsed: TimeInterval, units: DistanceUnits) {
        let fmt = RideStatsFormatter(units: units)
        self.distance = "\(fmt.distanceValue(stats.distanceMeters)) \(fmt.distanceUnit)"
        self.time = RideStatsFormatter.clock(elapsed)
        self.elevationGain = "\(fmt.elevationValue(stats.elevationGainMeters)) \(fmt.elevationUnit)"
        self.accessibilityLabel = SpeedRailVoice.statsLabel(stats, elapsed: elapsed, units: units)
    }
}
