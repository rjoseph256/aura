import SwiftUI
import AuraCore
import AuraKit

struct SpeedRail: View {
    let stats: RideStats
    let elapsed: TimeInterval
    let units: DistanceUnits

    private func fmt(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Unit-aware values

    private var speedValue: Double {
        units == .metric
            ? UnitConverter.kmh(fromMetersPerSecond: stats.averageSpeedMetersPerSecond)
            : UnitConverter.mph(fromMetersPerSecond: stats.averageSpeedMetersPerSecond)
    }
    private var speedLabel: String { units == .metric ? "KM/H" : "MPH" }

    private var distanceValue: Double {
        units == .metric
            ? UnitConverter.km(fromMeters: stats.distanceMeters)
            : UnitConverter.miles(fromMeters: stats.distanceMeters)
    }
    private var distanceLabel: String { units == .metric ? "KM" : "MI" }

    private var elevationValue: Double {
        units == .metric
            ? stats.elevationGainMeters
            : UnitConverter.feet(fromMeters: stats.elevationGainMeters)
    }
    private var elevationLabel: String { units == .metric ? "M ↑" : "FT ↑" }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.0f", speedValue))
                .font(AuraTheme.heroNumber())
                .foregroundStyle(AuraTheme.text)
            Text(speedLabel).font(AuraTheme.unitLabel).foregroundStyle(AuraTheme.muted)
            HStack(spacing: 12) {
                metric(String(format: "%.1f", distanceValue), distanceLabel)
                metric(fmt(elapsed), "TIME")
                metric(String(format: "%.0f", elevationValue), elevationLabel)
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
