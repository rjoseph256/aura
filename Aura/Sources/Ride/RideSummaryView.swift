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
    @Environment(RideStore.self) private var store

    @State private var isLongest = false

    private var stats: RideStats { ride.stats ?? .zero }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: settings.units) }
    private var metric: Bool { settings.units == .metric }
    private var hasRoute: Bool { ride.track.count > 1 }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if hasRoute {
                    StaticRouteMap(coordinates: ride.track.map(\.coordinate))
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(AuraTheme.surface, lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }

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

                if isLongest {
                    Label("Longest ride yet", systemImage: "trophy.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AuraTheme.route)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(AuraTheme.route.opacity(0.14), in: Capsule())
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
                    stat(fmt.distanceValue(stats.distanceMeters), metric ? "km" : "miles")
                    stat(fmt.minutes(stats.movingTimeSeconds), "moving")
                    stat(fmt.elevationValue(stats.elevationGainMeters), metric ? "m climbed" : "ft climbed")
                }
                stat(fmt.speedValue(stats.maxSpeedMetersPerSecond, decimals: 1), metric ? "km/h top" : "mph top")

                Button("Done") { dismiss() }
                    .font(.headline).foregroundStyle(.black)
                    .padding(.vertical, 12).padding(.horizontal, 40)
                    .background(AuraTheme.auroraGradient, in: Capsule())
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 32)
        }
        .background(AuraTheme.bg.ignoresSafeArea())
        .onAppear(perform: computeRecord)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(.title, design: .rounded).weight(.heavy)).foregroundStyle(AuraTheme.text)
            Text(label).font(.caption).foregroundStyle(AuraTheme.muted)
        }
    }

    /// "Longest ride yet" when this ride's distance is the max across all saved rides
    /// (and there's more than one). The just-finished ride is already saved by the time
    /// the summary appears, so it's included in the comparison.
    private func computeRecord() {
        let all = (try? store.allRides()) ?? []
        let distance = stats.distanceMeters
        guard distance > 0, all.count > 1 else { isLongest = false; return }
        isLongest = all.allSatisfy { $0.id == ride.id || ($0.stats?.distanceMeters ?? 0) <= distance }
    }
}
