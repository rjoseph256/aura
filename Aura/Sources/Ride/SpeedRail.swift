import SwiftUI
import AuraCore
import AuraKit

struct SpeedRail: View {
    let stats: RideStats
    let elapsed: TimeInterval
    let units: DistanceUnits

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(fmt.speedValue(stats.averageSpeedMetersPerSecond))
                .font(AuraTheme.heroNumber())
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
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(AuraTheme.text)
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(AuraTheme.muted)
        }
    }
}
