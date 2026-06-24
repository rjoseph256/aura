import SwiftUI
import AuraCore

struct RideSummaryView: View {
    let ride: Ride
    @Environment(\.dismiss) private var dismiss

    private var stats: RideStats { ride.stats ?? .zero }
    private var duration: TimeInterval {
        guard let end = ride.endedAt else { return 0 }
        return end.timeIntervalSince(ride.startedAt)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Nice ride").font(.largeTitle.bold()).foregroundStyle(AuraTheme.text)
            HStack(spacing: 26) {
                stat(String(format: "%.1f", UnitConverter.miles(fromMeters: stats.distanceMeters)), "miles")
                stat(String(format: "%d min", Int(duration / 60)), "moving")
                stat(String(format: "%.0f", UnitConverter.feet(fromMeters: stats.elevationGainMeters)), "ft climbed")
            }
            stat(String(format: "%.1f", UnitConverter.mph(fromMetersPerSecond: stats.maxSpeedMetersPerSecond)), "mph top")
            Button("Done") { dismiss() }
                .font(.headline).foregroundStyle(.black)
                .padding(.vertical, 12).padding(.horizontal, 40)
                .background(AuraTheme.auroraGradient, in: Capsule())
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.bg.ignoresSafeArea())
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(AuraTheme.text)
            Text(label).font(.caption).foregroundStyle(AuraTheme.muted)
        }
    }
}
