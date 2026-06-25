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
            VStack(spacing: AuraTheme.Spacing.xl) {
                if hasRoute {
                    StaticRouteMap(coordinates: ride.track.map(\.coordinate))
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous)
                                .strokeBorder(AuraTheme.border, lineWidth: 1)
                        )
                        .padding(.horizontal, AuraTheme.Spacing.xl)
                        .padding(.top, AuraTheme.Spacing.lg)
                }

                VStack(spacing: AuraTheme.Spacing.xs) {
                    Text("Nice ride").font(.largeTitle.bold()).foregroundStyle(AuraTheme.textPrimary)
                    if let name = ride.destinationName, !name.isEmpty {
                        Text("to \(name)")
                            .font(.subheadline)
                            .foregroundStyle(AuraTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }

                if isLongest {
                    Label("Longest ride yet", systemImage: "trophy.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AuraTheme.accent)
                        .padding(.horizontal, AuraTheme.Spacing.lg).padding(.vertical, AuraTheme.Spacing.sm)
                        .background(AuraTheme.accent.opacity(0.14), in: Capsule())
                }

                if saveFailed {
                    Label("Couldn't save this ride — it won't appear in History.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(AuraTheme.destructive)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AuraTheme.Spacing.sm)
                }

                HStack(spacing: AuraTheme.Spacing.xxl) {
                    stat(fmt.distanceValue(stats.distanceMeters), metric ? "km" : "miles")
                    stat(fmt.minutes(stats.movingTimeSeconds), "moving")
                    stat(fmt.elevationValue(stats.elevationGainMeters), metric ? "m climbed" : "ft climbed")
                }
                stat(fmt.speedValue(stats.maxSpeedMetersPerSecond, decimals: 1), metric ? "km/h top" : "mph top")

                Button("Done") { dismiss() }
                    .buttonStyle(.ctaPrimary)
                    .padding(.horizontal, AuraTheme.Spacing.xl)
                    .padding(.top, AuraTheme.Spacing.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, AuraTheme.Spacing.xxxl)
        }
        .background(AuraTheme.background.ignoresSafeArea())
        .onAppear(perform: computeRecord)
    }

    /// One value+label metric cell. Combined into a single VoiceOver element so it reads
    /// as a unit (e.g. "21.6, km/h top") instead of two separate stops.
    private func stat(_ value: String, _ label: String) -> some View {
        StatPair(value: value, label: label, context: .brand, alignment: .center)
            .accessibilityElement(children: .combine)
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
