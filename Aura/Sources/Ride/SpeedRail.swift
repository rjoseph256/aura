import SwiftUI
import AuraCore
import AuraKit

struct SpeedRail: View {
    enum Layout { case full, speedOnly }

    let stats: RideStats
    let elapsed: TimeInterval
    let units: DistanceUnits
    /// Navigate mode passes `.speedOnly`; free ride keeps the default `.full`.
    var layout: Layout = .full

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        VStack(alignment: .trailing, spacing: AuraTheme.Spacing.xs) {
            // Hero speed: one element, static "Speed" label + spoken value, so the live
            // (slow-moving average) value re-announces alone, never the whole rail.
            SpeedReadout(value: fmt.speedValue(stats.averageSpeedMetersPerSecond),
                         unit: fmt.speedUnit.uppercased())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Speed")
                .accessibilityValue(SpeedRailVoice.speedValue(stats, units: units))
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
        .background(AuraTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        StatPair(value: value, label: label, context: .cockpit)
    }
}
