import SwiftUI
import AuraCore
import AuraKit

struct RideSummaryView: View {
    let ride: Ride
    /// When true, the ride finished but couldn't be persisted — warn the rider rather
    /// than letting it silently vanish from History.
    var saveFailed: Bool = false
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
            VStack(spacing: 6) {
                Text("Nice ride").font(.largeTitle.bold()).foregroundStyle(AuraTheme.text)
                if let name = ride.destinationName, !name.isEmpty {
                    Text("to \(name)")
                        .font(.subheadline)
                        .foregroundStyle(AuraTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            if saveFailed {
                Label("Couldn't save this ride — it won't appear in History.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.pink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
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
