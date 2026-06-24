import SwiftUI
import AuraCore

struct SpeedRail: View {
    let stats: RideStats
    let elapsed: TimeInterval

    private func fmt(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.0f", UnitConverter.mph(fromMetersPerSecond: stats.averageSpeedMetersPerSecond)))
                .font(AuraTheme.heroNumber())
                .foregroundStyle(AuraTheme.text)
            Text("MPH").font(AuraTheme.unitLabel).foregroundStyle(AuraTheme.muted)
            HStack(spacing: 12) {
                metric(String(format: "%.1f", UnitConverter.miles(fromMeters: stats.distanceMeters)), "MI")
                metric(fmt(elapsed), "TIME")
                metric(String(format: "%.0f", UnitConverter.feet(fromMeters: stats.elevationGainMeters)), "FT ↑")
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
