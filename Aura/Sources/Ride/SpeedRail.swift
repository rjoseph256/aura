import SwiftUI
import AuraCore
import AuraKit

struct SpeedRail: View {
    let stats: RideStats
    let elapsed: TimeInterval
    let units: DistanceUnits

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    // Dynamic Type-aware sizes: the glanceable numerics keep their deliberate scale
    // but grow with the rider's text-size setting. Anchored to nearby text styles.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var metricSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption2) private var metricLabelSize: CGFloat = 9

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(fmt.speedValue(stats.averageSpeedMetersPerSecond))
                .font(AuraTheme.heroNumber(heroSize))
                .foregroundStyle(AuraTheme.text)
            Text(fmt.speedUnit.uppercased()).font(AuraTheme.unitLabel).foregroundStyle(AuraTheme.muted)
            HStack(spacing: 12) {
                metric(fmt.distanceValue(stats.distanceMeters), fmt.distanceUnit.uppercased())
                metric(RideStatsFormatter.clock(elapsed), "TIME")
                metric(fmt.elevationValue(stats.elevationGainMeters), "\(fmt.elevationUnit.uppercased()) ↑")
            }.padding(.top, 6)
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        // The HUD is a compact glance target; let it enlarge meaningfully but not so
        // far it swamps the map. Standard sizes scale freely; cap the accessibility tail.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: metricSize, weight: .heavy, design: .rounded)).foregroundStyle(AuraTheme.text)
            Text(label).font(.system(size: metricLabelSize, weight: .bold)).foregroundStyle(AuraTheme.muted)
        }
    }
}
