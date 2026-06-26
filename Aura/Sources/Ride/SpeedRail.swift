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
            // Hero speed + lime unit — Saira Condensed via SpeedReadout. Grouped so it
            // reads as one VoiceOver element ("24, km/h") instead of two stops.
            SpeedReadout(value: fmt.speedValue(stats.averageSpeedMetersPerSecond),
                         unit: fmt.speedUnit.uppercased())
                .accessibilityElement(children: .combine)
            if layout == .full {
                HStack(spacing: AuraTheme.Spacing.md) {
                    metric(fmt.distanceValue(stats.distanceMeters), fmt.distanceUnit.uppercased())
                    metric(RideStatsFormatter.clock(elapsed), "TIME")
                    metric(fmt.elevationValue(stats.elevationGainMeters), "\(fmt.elevationUnit.uppercased()) ↑")
                }.padding(.top, AuraTheme.Spacing.xs)
            }
        }
        .padding(AuraTheme.Spacing.lg)
        .background(AuraTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg))
        // The HUD is a compact glance target; let it enlarge meaningfully but not so
        // far it swamps the map. Standard sizes scale freely; cap the accessibility tail.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        StatPair(value: value, label: label, context: .cockpit)
            .accessibilityElement(children: .combine)
    }
}
