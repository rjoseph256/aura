import SwiftUI
import AuraCore
import AuraKit

struct SpeedRail: View {
    enum Layout { case full, speedOnly }

    let stats: RideStats
    let elapsed: TimeInterval
    /// Smoothed live current speed (m/s) — the hero reads this, not the ride average.
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    /// Navigate mode passes `.speedOnly`; free ride keeps the default `.full`.
    var layout: Layout = .full

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        VStack(alignment: .trailing, spacing: AuraTheme.Spacing.xs) {
            // Hero speed: one element, static "Speed" label + spoken value, so the live
            // current speed re-announces alone, never the whole rail.
            SpeedReadout(value: fmt.speedValue(currentSpeedMetersPerSecond),
                         unit: fmt.speedUnit.uppercased())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Speed")
                .accessibilityValue(SpeedRailVoice.speedValue(currentSpeedMetersPerSecond, units: units))
            if layout == .full {
                HStack(spacing: AuraTheme.Spacing.md) {
                    metric(fmt.distanceValue(stats.distanceMeters), fmt.distanceUnit.uppercased())
                    metric(RideStatsFormatter.clock(elapsed), "TIME")
                    metric(fmt.elevationValue(stats.elevationGainMeters), "\(fmt.elevationUnit.uppercased()) ↑")
                }
                .padding(.top, AuraTheme.Spacing.xs)
                // The trio composes into one element so VoiceOver reads "Distance ...,
                // time ..., elevation gain ..." instead of four mechanical stops.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SpeedRailVoice.statsLabel(stats, elapsed: elapsed, units: units))
            }
        }
        .padding(AuraTheme.Spacing.lg)
        .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast),
                    in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg))
        // The HUD is a compact glance target; let it enlarge meaningfully but not so
        // far it swamps the map. Standard sizes scale freely; cap the accessibility tail.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        StatPair(value: value, label: label, context: .cockpit)
    }
}
