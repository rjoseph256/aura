import SwiftUI
import AuraCore
import AuraKit

struct RideSummaryView: View {
    let ride: Ride
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings

    private var stats: RideStats { ride.stats ?? .zero }
    private var metric: Bool { settings.units == .metric }

    // MARK: Unit-aware values

    private var distanceValue: Double {
        metric ? UnitConverter.km(fromMeters: stats.distanceMeters)
               : UnitConverter.miles(fromMeters: stats.distanceMeters)
    }
    private var distanceLabel: String { metric ? "km" : "miles" }

    private var elevationValue: Double {
        metric ? stats.elevationGainMeters
               : UnitConverter.feet(fromMeters: stats.elevationGainMeters)
    }
    private var elevationLabel: String { metric ? "m climbed" : "ft climbed" }

    private var topSpeedValue: Double {
        metric ? UnitConverter.kmh(fromMetersPerSecond: stats.maxSpeedMetersPerSecond)
               : UnitConverter.mph(fromMetersPerSecond: stats.maxSpeedMetersPerSecond)
    }
    private var topSpeedLabel: String { metric ? "km/h top" : "mph top" }

    var body: some View {
        VStack(spacing: 20) {
            Text("Nice ride").font(.largeTitle.bold()).foregroundStyle(AuraTheme.text)
            HStack(spacing: 26) {
                stat(String(format: "%.1f", distanceValue), distanceLabel)
                stat(String(format: "%d min", Int(stats.movingTimeSeconds / 60)), "moving")
                stat(String(format: "%.0f", elevationValue), elevationLabel)
            }
            stat(String(format: "%.1f", topSpeedValue), topSpeedLabel)
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
